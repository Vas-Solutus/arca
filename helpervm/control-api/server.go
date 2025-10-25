package main

import (
	"context"
	"crypto/md5"
	"fmt"
	"log"
	"os/exec"
	"sync"
	"time"

	pb "arca-network-api/proto"
)

// NetworkServer implements the NetworkControl gRPC service
type NetworkServer struct {
	pb.UnimplementedNetworkControlServer
	mu            sync.RWMutex
	bridges       map[string]*BridgeMetadata
	containerMap  map[string]map[string]bool   // networkID -> containerID -> exists
	dnsEntries    map[string]map[string]*DNSEntry // networkID -> containerID -> DNS entry
	containerIPs  map[string]map[string]string // containerID -> networkID -> IP (tracks all IPs for multi-network containers)
	relayManager  *TAPRelayManager
	containerPort map[string]uint32 // containerID -> helperPort (for TAP relay cleanup)
	startTime     time.Time
}

// BridgeMetadata stores metadata about a network bridge
type BridgeMetadata struct {
	NetworkID  string
	BridgeName string // The actual br-XXXX name
	Subnet     string
	Gateway    string
}

// DNSEntry stores DNS information for a container
type DNSEntry struct {
	ContainerID string
	Hostname    string
	IPAddress   string
	Aliases     []string
}

// NewNetworkServer creates a new NetworkServer
func NewNetworkServer() *NetworkServer {
	return &NetworkServer{
		bridges:       make(map[string]*BridgeMetadata),
		containerMap:  make(map[string]map[string]bool),
		dnsEntries:    make(map[string]map[string]*DNSEntry),
		containerIPs:  make(map[string]map[string]string),
		relayManager:  NewTAPRelayManager(),
		containerPort: make(map[string]uint32),
		startTime:     time.Now(),
	}
}

// CreateBridge creates a new OVS bridge and OVN logical switch
func (s *NetworkServer) CreateBridge(ctx context.Context, req *pb.CreateBridgeRequest) (*pb.CreateBridgeResponse, error) {
	log.Printf("CreateBridge: networkID=%s, subnet=%s, gateway=%s", req.NetworkId, req.Subnet, req.Gateway)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Bridge name must be <= 15 chars (Linux IFNAMSIZ limit)
	// Use MD5 hash of network ID to ensure uniqueness with short names
	// Format: br-{12 hex chars} = 15 chars total
	hash := md5.Sum([]byte(req.NetworkId))
	bridgeName := fmt.Sprintf("br-%x", hash[:6]) // 12 hex chars from 6 bytes

	// Create OVS bridge with netdev datapath (userspace)
	if err := runCommand("ovs-vsctl", "add-br", bridgeName, "--", "set", "bridge", bridgeName, "datapath_type=netdev"); err != nil {
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to create OVS bridge with netdev datapath: %v", err),
		}, nil
	}

	log.Printf("OVS bridge %s created successfully", bridgeName)

	// Bring bridge interface up
	if err := runCommand("ip", "link", "set", bridgeName, "up"); err != nil {
		// Cleanup: delete bridge
		_ = runCommand("ovs-vsctl", "del-br", bridgeName)
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to bring bridge up: %v", err),
		}, nil
	}

	// Disable TX checksum offloading on bridge for OVS userspace datapath
	// This is critical for proper DNS/UDP packet handling in userspace datapath
	// See: https://docs.openvswitch.org/en/latest/topics/userspace-checksum-offloading/
	log.Printf("Disabling TX offloading on bridge %s for OVS userspace datapath", bridgeName)
	if err := runCommand("ethtool", "-K", bridgeName, "tx", "off"); err != nil {
		log.Printf("Warning: Failed to disable TX offloading: %v", err)
		// Don't fail - continue anyway
	}

	// Assign gateway IP to bridge
	if err := runCommand("ip", "addr", "add", fmt.Sprintf("%s/24", req.Gateway), "dev", bridgeName); err != nil {
		// Cleanup: delete bridge
		_ = runCommand("ovs-vsctl", "del-br", bridgeName)
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to assign IP to bridge: %v", err),
		}, nil
	}

	// Create OVN logical switch
	if err := runCommand("ovn-nbctl", "ls-add", req.NetworkId); err != nil {
		// Cleanup: delete bridge
		_ = runCommand("ovs-vsctl", "del-br", bridgeName)
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to create OVN logical switch: %v", err),
		}, nil
	}

	// Set subnet and gateway in OVN
	if err := runCommand("ovn-nbctl", "set", "logical_switch", req.NetworkId,
		fmt.Sprintf("other_config:subnet=%s", req.Subnet),
		fmt.Sprintf("other_config:gateway=%s", req.Gateway)); err != nil {
		// Cleanup
		_ = runCommand("ovn-nbctl", "ls-del", req.NetworkId)
		_ = runCommand("ovs-vsctl", "del-br", bridgeName)
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to configure OVN logical switch: %v", err),
		}, nil
	}

	// Store metadata
	s.bridges[req.NetworkId] = &BridgeMetadata{
		NetworkID:  req.NetworkId,
		BridgeName: bridgeName,
		Subnet:     req.Subnet,
		Gateway:    req.Gateway,
	}
	s.containerMap[req.NetworkId] = make(map[string]bool)
	s.dnsEntries[req.NetworkId] = make(map[string]*DNSEntry)

	// Create initial dnsmasq configuration for this network
	if err := s.writeDnsmasqConfig(req.NetworkId); err != nil {
		log.Printf("Warning: Failed to create dnsmasq config: %v", err)
	}

	log.Printf("Successfully created bridge %s for network %s", bridgeName, req.NetworkId)

	return &pb.CreateBridgeResponse{
		BridgeName: bridgeName,
		Success:    true,
	}, nil
}

// DeleteBridge removes an OVS bridge and OVN logical switch
func (s *NetworkServer) DeleteBridge(ctx context.Context, req *pb.DeleteBridgeRequest) (*pb.DeleteBridgeResponse, error) {
	log.Printf("DeleteBridge: networkID=%s", req.NetworkId)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Bridge name must be <= 15 chars (Linux IFNAMSIZ limit)
	// Use MD5 hash of network ID to ensure uniqueness
	hash := md5.Sum([]byte(req.NetworkId))
	bridgeName := fmt.Sprintf("br-%x", hash[:6])

	// Delete OVN logical switch
	if err := runCommand("ovn-nbctl", "ls-del", req.NetworkId); err != nil {
		log.Printf("Warning: Failed to delete OVN logical switch: %v", err)
	}

	// Delete OVS bridge
	if err := runCommand("ovs-vsctl", "del-br", bridgeName); err != nil {
		return &pb.DeleteBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to delete OVS bridge: %v", err),
		}, nil
	}

	// Remove metadata
	delete(s.bridges, req.NetworkId)
	delete(s.containerMap, req.NetworkId)
	delete(s.dnsEntries, req.NetworkId)

	// Stop per-network dnsmasq instance
	shortNetID := req.NetworkId[:12]
	pidFile := fmt.Sprintf("/var/run/dnsmasq-network-%s.pid", shortNetID)
	if pidContent, err := readFile(pidFile); err == nil && len(pidContent) > 0 {
		log.Printf("Stopping dnsmasq instance for network %s (PID: %s)", shortNetID, pidContent)
		_ = runCommand("kill", "-9", pidContent)
	}

	// Remove dnsmasq config and PID files
	configFile := fmt.Sprintf("/etc/dnsmasq.d/network-%s.conf", shortNetID)
	_ = runCommand("rm", "-f", configFile)
	_ = runCommand("rm", "-f", pidFile)

	log.Printf("Successfully deleted bridge %s", bridgeName)

	return &pb.DeleteBridgeResponse{
		Success: true,
	}, nil
}

// AttachContainer attaches a container to a network
func (s *NetworkServer) AttachContainer(ctx context.Context, req *pb.AttachContainerRequest) (*pb.AttachContainerResponse, error) {
	log.Printf("AttachContainer: containerID=%s, networkID=%s, ip=%s, mac=%s",
		req.ContainerId, req.NetworkId, req.IpAddress, req.MacAddress)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Bridge name must be <= 15 chars (Linux IFNAMSIZ limit)
	// Use MD5 hash of network ID to ensure uniqueness
	hash := md5.Sum([]byte(req.NetworkId))
	bridgeName := fmt.Sprintf("br-%x", hash[:6])

	// For TAP-over-vsock architecture, we don't create OVS/OVN ports here
	// The TAP relay will create its own OVS internal port when it starts
	// We just track the container attachment for now
	portName := fmt.Sprintf("port-%s", req.ContainerId[:12])

	// Track container IP for cross-network DNS propagation
	if s.containerIPs[req.ContainerId] == nil {
		s.containerIPs[req.ContainerId] = make(map[string]string)
	}
	s.containerIPs[req.ContainerId][req.NetworkId] = req.IpAddress

	// Configure DNS on THIS network for this container with THIS network's IP
	if err := s.configureDNS(req.NetworkId, req.ContainerId, req.Hostname, req.IpAddress, req.Aliases); err != nil {
		log.Printf("Warning: Failed to configure DNS on network %s: %v", req.NetworkId, err)
		// Don't fail the entire operation for DNS issues
	}

	// CROSS-NETWORK DNS PROPAGATION (BIDIRECTIONAL):
	// When container1 joins my-network2:
	// 1. Add container1's IPs from OTHER networks to my-network2's DNS
	// 2. Add container1's my-network2 IP to OTHER networks' DNS (where container1 already exists)
	// 3. Add OTHER containers' IPs from my-network2 to container1's OTHER networks' DNS
	for otherNetworkID := range s.containerMap {
		if otherNetworkID == req.NetworkId {
			continue // Skip current network
		}

		// PART 1 & 2: Propagate THIS container's IPs across networks it's on
		if s.containerMap[otherNetworkID][req.ContainerId] {
			// Get the container's IP on the OTHER network
			if otherIP, exists := s.containerIPs[req.ContainerId][otherNetworkID]; exists {
				// DIRECTION 1: Add THIS container's IP from OTHER network to THIS network's DNS
				log.Printf("Cross-network DNS: Adding %s (%s) to network %s with IP %s (from network %s)",
					req.Hostname, req.ContainerId[:12], req.NetworkId[:12], otherIP, otherNetworkID[:12])
				if err := s.configureDNS(req.NetworkId, req.ContainerId, req.Hostname, otherIP, req.Aliases); err != nil {
					log.Printf("Warning: Failed to add other network IP to current network DNS: %v", err)
				}

				// DIRECTION 2: Add THIS container's IP from THIS network to OTHER network's DNS
				log.Printf("Cross-network DNS: Adding %s (%s) to network %s with IP %s (from network %s)",
					req.Hostname, req.ContainerId[:12], otherNetworkID[:12], req.IpAddress, req.NetworkId[:12])
				if err := s.configureDNS(otherNetworkID, req.ContainerId, req.Hostname, req.IpAddress, req.Aliases); err != nil {
					log.Printf("Warning: Failed to add current network IP to other network DNS: %v", err)
				}
			}
		}

		// PART 3: Propagate OTHER containers from THIS network to OTHER networks where THIS container exists
		// When container1 joins my-network2, add container3's IP to my-network's DNS
		if s.containerMap[otherNetworkID][req.ContainerId] {
			// THIS container is on BOTH networks, so propagate OTHER containers from THIS network to OTHER network
			for otherContainerID := range s.containerMap[req.NetworkId] {
				if otherContainerID == req.ContainerId {
					continue // Skip THIS container
				}

				// Get DNS entry for the other container on THIS network
				if dnsEntry, exists := s.dnsEntries[req.NetworkId][otherContainerID]; exists {
					log.Printf("Cross-network DNS: Adding %s (%s) to network %s with IP %s (from network %s)",
						dnsEntry.Hostname, otherContainerID[:12], otherNetworkID[:12], dnsEntry.IPAddress, req.NetworkId[:12])
					if err := s.configureDNS(otherNetworkID, otherContainerID, dnsEntry.Hostname, dnsEntry.IPAddress, dnsEntry.Aliases); err != nil {
						log.Printf("Warning: Failed to add other container to other network DNS: %v", err)
					}
				}
			}
		}
	}

	// Track container attachment
	if s.containerMap[req.NetworkId] == nil {
		s.containerMap[req.NetworkId] = make(map[string]bool)
	}
	s.containerMap[req.NetworkId][req.ContainerId] = true

	// Start TAP relay for packet forwarding (if vsock port provided)
	if req.VsockPort > 0 {
		// Helper VM listens on host_port + 10000
		helperPort := req.VsockPort + 10000
		if err := s.relayManager.StartRelay(helperPort, bridgeName, req.NetworkId, req.ContainerId, req.MacAddress); err != nil {
			log.Printf("Warning: Failed to start TAP relay: %v", err)
			// Don't fail the entire operation - networking may still work via other means
		} else {
			// Track the port for cleanup during detach
			s.containerPort[req.ContainerId] = helperPort
			log.Printf("Started TAP relay on helper VM port %d for container %s", helperPort, req.ContainerId)
		}
	}

	log.Printf("Successfully attached container %s to network %s", req.ContainerId, req.NetworkId)

	return &pb.AttachContainerResponse{
		PortName: portName,
		Success:  true,
	}, nil
}

// DetachContainer detaches a container from a network
func (s *NetworkServer) DetachContainer(ctx context.Context, req *pb.DetachContainerRequest) (*pb.DetachContainerResponse, error) {
	log.Printf("DetachContainer: containerID=%s, networkID=%s", req.ContainerId, req.NetworkId)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Stop TAP relay if one was started for this container
	if helperPort, exists := s.containerPort[req.ContainerId]; exists {
		if err := s.relayManager.StopRelay(helperPort); err != nil {
			log.Printf("Warning: Failed to stop TAP relay on port %d: %v", helperPort, err)
		} else {
			log.Printf("Stopped TAP relay on port %d for container %s", helperPort, req.ContainerId)
		}
		delete(s.containerPort, req.ContainerId)
	}

	// Remove DNS entries from this network
	if err := s.removeDNS(req.NetworkId, req.ContainerId); err != nil {
		log.Printf("Warning: Failed to remove DNS entries: %v", err)
	}

	// Remove container IP tracking for this network
	if s.containerIPs[req.ContainerId] != nil {
		delete(s.containerIPs[req.ContainerId], req.NetworkId)
		// If container is not on any networks anymore, clean up the map
		if len(s.containerIPs[req.ContainerId]) == 0 {
			delete(s.containerIPs, req.ContainerId)
		}
	}

	// Update tracking
	if s.containerMap[req.NetworkId] != nil {
		delete(s.containerMap[req.NetworkId], req.ContainerId)
	}

	log.Printf("Successfully detached container %s from network %s", req.ContainerId, req.NetworkId)

	return &pb.DetachContainerResponse{
		Success: true,
	}, nil
}

// ListBridges returns all bridges
func (s *NetworkServer) ListBridges(ctx context.Context, req *pb.ListBridgesRequest) (*pb.ListBridgesResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var bridges []*pb.BridgeInfo
	for networkID, metadata := range s.bridges {
		containers := make([]string, 0)
		if containerMap := s.containerMap[networkID]; containerMap != nil {
			for containerID := range containerMap {
				containers = append(containers, containerID)
			}
		}

		bridges = append(bridges, &pb.BridgeInfo{
			NetworkId:  networkID,
			BridgeName: fmt.Sprintf("arca-br-%s", networkID[:12]),
			Subnet:     metadata.Subnet,
			Gateway:    metadata.Gateway,
			Containers: containers,
		})
	}

	return &pb.ListBridgesResponse{
		Bridges: bridges,
		Success: true,
	}, nil
}

// SetNetworkPolicy sets network policies
func (s *NetworkServer) SetNetworkPolicy(ctx context.Context, req *pb.SetNetworkPolicyRequest) (*pb.SetNetworkPolicyResponse, error) {
	log.Printf("SetNetworkPolicy: networkID=%s, rules=%d", req.NetworkId, len(req.Rules))

	// TODO: Implement OVN ACLs for network policies
	// For now, return success but log that it's not implemented
	log.Printf("Warning: Network policies not yet implemented")

	return &pb.SetNetworkPolicyResponse{
		Success: true,
	}, nil
}

// GetHealth returns health status
func (s *NetworkServer) GetHealth(ctx context.Context, req *pb.GetHealthRequest) (*pb.GetHealthResponse, error) {
	ovsStatus := checkServiceStatus("ovs-vswitchd")
	ovnStatus := checkServiceStatus("ovn-controller")
	dnsmasqStatus := checkServiceStatus("dnsmasq")

	healthy := ovsStatus == "running" && ovnStatus == "running"
	uptime := uint64(time.Since(s.startTime).Seconds())

	return &pb.GetHealthResponse{
		Healthy:        healthy,
		OvsStatus:      ovsStatus,
		OvnStatus:      ovnStatus,
		DnsmasqStatus:  dnsmasqStatus,
		UptimeSeconds:  uptime,
	}, nil
}

// configureDNS adds DNS entries for a container
func (s *NetworkServer) configureDNS(networkID, containerID, hostname, ipAddress string, aliases []string) error {
	// Initialize DNS entries map for this network if needed
	if s.dnsEntries[networkID] == nil {
		s.dnsEntries[networkID] = make(map[string]*DNSEntry)
	}

	// Store DNS entry
	s.dnsEntries[networkID][containerID] = &DNSEntry{
		ContainerID: containerID,
		Hostname:    hostname,
		IPAddress:   ipAddress,
		Aliases:     aliases,
	}

	// Regenerate dnsmasq config for this network
	return s.writeDnsmasqConfig(networkID)
}

// removeDNS removes DNS entries for a container
func (s *NetworkServer) removeDNS(networkID, containerID string) error {
	// Remove DNS entry
	if s.dnsEntries[networkID] != nil {
		delete(s.dnsEntries[networkID], containerID)
	}

	// Regenerate dnsmasq config for this network
	return s.writeDnsmasqConfig(networkID)
}

// writeDnsmasqConfig generates the complete dnsmasq config file for a network
func (s *NetworkServer) writeDnsmasqConfig(networkID string) error {
	bridge := s.bridges[networkID]
	if bridge == nil {
		return fmt.Errorf("network %s not found", networkID)
	}

	shortNetID := networkID[:12]
	configFile := fmt.Sprintf("/etc/dnsmasq.d/network-%s.conf", shortNetID)
	pidFile := fmt.Sprintf("/var/run/dnsmasq-network-%s.pid", shortNetID)

	// Build per-network dnsmasq configuration
	// CRITICAL: Do NOT include conf-dir - this instance should ONLY use this config
	var config string

	config += "no-resolv\n"                                      // Don't read /etc/resolv.conf
	config += "no-hosts\n"                                       // Don't read /etc/hosts
	config += "bind-interfaces\n"                                // Bind only to specified interfaces
	config += fmt.Sprintf("listen-address=%s\n", bridge.Gateway) // Listen ONLY on this network's gateway
	config += "port=53\n"                                        // DNS port
	config += fmt.Sprintf("pid-file=%s\n", pidFile)              // PID file for management
	config += "log-queries\n"                                    // Enable query logging
	config += fmt.Sprintf("log-facility=/var/log/dnsmasq-%s.log\n", shortNetID)

	// Make dnsmasq authoritative for local domain
	// This ensures it returns NXDOMAIN for non-existent hosts instead of forwarding
	config += "local=/arca/\n"           // .arca domain is local (don't forward)
	config += "domain=arca\n"            // Set domain for unqualified names
	config += "expand-hosts\n"           // Add domain to simple names in /etc/hosts
	config += "no-negcache\n"            // Don't cache negative responses
	config += "filterwin2k\n"            // Filter useless windows queries

	// Authoritative mode - prevents "Non-authoritative answer" messages
	config += "auth-server=dns.arca\n"   // Authoritative DNS server name
	config += "auth-zone=arca\n"         // Authoritative for .arca zone

	// Add host records ONLY for containers on THIS network
	if entries := s.dnsEntries[networkID]; entries != nil {
		for _, entry := range entries {
			// Add A records for hostname (both bare and FQDN)
			if entry.Hostname != "" {
				// host-record creates A records for both names
				config += fmt.Sprintf("host-record=%s,%s.arca,%s\n", entry.Hostname, entry.Hostname, entry.IPAddress)

				// Explicitly return NODATA for AAAA (IPv6) queries to prevent "No answer" errors
				// This tells DNS clients "this name exists but has no IPv6 address"
				config += fmt.Sprintf("host-record=%s,%s.arca\n", entry.Hostname, entry.Hostname)
			}

			// Add A records for aliases
			for _, alias := range entry.Aliases {
				if alias != "" {
					config += fmt.Sprintf("host-record=%s,%s.arca,%s\n", alias, alias, entry.IPAddress)
					config += fmt.Sprintf("host-record=%s,%s.arca\n", alias, alias)
				}
			}
		}
	}

	// Forward all other queries upstream
	config += "server=8.8.8.8\n"
	config += "server=8.8.4.4\n"

	// Write config file
	if err := writeFile(configFile, config); err != nil {
		return fmt.Errorf("failed to write dnsmasq config: %v", err)
	}

	log.Printf("Wrote per-network dnsmasq config for network %s with %d entries", shortNetID, len(s.dnsEntries[networkID]))

	// Test config before applying
	if err := runCommand("dnsmasq", "--conf-file="+configFile, "--test"); err != nil {
		log.Printf("ERROR: dnsmasq config test failed: %v", err)
		return fmt.Errorf("dnsmasq config test failed: %v", err)
	}
	log.Printf("dnsmasq config test passed for network %s", shortNetID)

	// Check if this network's dnsmasq is already running and kill only that instance
	pidContent, _ := readFile(pidFile)
	if len(pidContent) > 0 {
		// Trim whitespace and newlines from PID
		pid := ""
		for _, c := range pidContent {
			if c >= '0' && c <= '9' {
				pid += string(c)
			}
		}
		if len(pid) > 0 {
			log.Printf("Stopping existing dnsmasq instance for network %s (PID: %s)", shortNetID, pid)
			_ = runCommand("kill", "-9", pid)

			// Poll until process is dead (max 100 iterations = ~1 second)
			for i := 0; i < 100; i++ {
				if err := runCommand("kill", "-0", pid); err != nil {
					// Process is dead (kill -0 failed)
					log.Printf("Successfully killed dnsmasq PID %s after %d checks", pid, i+1)
					break
				}
				// Sleep for 10ms between checks
				time.Sleep(10 * time.Millisecond)
			}
		}
		_ = runCommand("rm", "-f", pidFile)
	}

	// Start network-specific dnsmasq instance
	log.Printf("Starting dnsmasq instance for network %s on %s", shortNetID, bridge.Gateway)
	if err := runCommand("dnsmasq", "--conf-file="+configFile); err != nil {
		return fmt.Errorf("failed to start dnsmasq: %v", err)
	}
	log.Printf("dnsmasq started successfully for network %s", shortNetID)

	// Verify dnsmasq is running
	sleep(1)
	verifyPid, err := readFile(pidFile)
	if err != nil || len(verifyPid) == 0 {
		return fmt.Errorf("dnsmasq PID file not created for network %s", shortNetID)
	}
	log.Printf("Verified dnsmasq is running for network %s (PID: %s)", shortNetID, verifyPid)

	// Debug: Check what this instance is listening on
	output, _ := runCommandWithOutput("ss", "-lunp")
	log.Printf("Network listeners after starting dnsmasq for %s:\n%s", shortNetID, output)

	return nil
}

// Helper functions

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("command failed: %s %v: %v (output: %s)", name, args, err, string(output))
	}
	return nil
}

func runCommandWithOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	return string(output), err
}

func checkServiceStatus(serviceName string) string {
	cmd := exec.Command("pgrep", serviceName)
	if err := cmd.Run(); err != nil {
		return "stopped"
	}
	return "running"
}

func appendToFile(filename, content string) error {
	cmd := exec.Command("sh", "-c", fmt.Sprintf("echo '%s' >> %s", content, filename))
	return cmd.Run()
}

func writeFile(filename, content string) error {
	cmd := exec.Command("sh", "-c", fmt.Sprintf("cat > %s <<'EOF'\n%s\nEOF", filename, content))
	return cmd.Run()
}

func readFile(filename string) (string, error) {
	cmd := exec.Command("cat", filename)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

func sleep(seconds int) {
	time.Sleep(time.Duration(seconds) * time.Second)
}

func getOVSLogs() string {
	// Try to get the last 50 lines of ovs-vswitchd.log
	cmd := exec.Command("tail", "-n", "50", "/var/log/openvswitch/ovs-vswitchd.log")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Sprintf("Could not read OVS logs: %v", err)
	}
	return string(output)
}
