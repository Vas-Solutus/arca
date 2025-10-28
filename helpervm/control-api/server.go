package main

import (
	"context"
	"crypto/md5"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	pb "arca-network-api/proto"
)

// NetworkServer implements the NetworkControl gRPC service
type NetworkServer struct {
	pb.UnimplementedNetworkControlServer
	mu            sync.RWMutex
	bridges       map[string]*BridgeMetadata
	containerMap  map[string]map[string]bool // networkID -> containerID -> exists
	relayManager  *TAPRelayManager
	containerPort map[string]uint32 // containerID -> helperPort (for TAP relay cleanup)
	startTime     time.Time
	nextVLAN      uint32 // Next available VLAN tag (starts at 100)
}

// BridgeMetadata stores metadata about a network bridge
type BridgeMetadata struct {
	NetworkID  string
	BridgeName string // The actual br-XXXX name
	Subnet     string
	Gateway    string
}

// NewNetworkServer creates a new NetworkServer
func NewNetworkServer() *NetworkServer {
	return &NetworkServer{
		bridges:       make(map[string]*BridgeMetadata),
		containerMap:  make(map[string]map[string]bool),
		relayManager:  NewTAPRelayManager(),
		containerPort: make(map[string]uint32),
		startTime:     time.Now(),
		nextVLAN:      100, // VLAN tags 100-4095 available (1-99 reserved)
	}
}

// CreateBridge creates an OVN logical switch with VLAN tag (OVN-native architecture)
// No manual OVS bridges are created - all traffic flows through br-int with VLAN isolation
func (s *NetworkServer) CreateBridge(ctx context.Context, req *pb.CreateBridgeRequest) (*pb.CreateBridgeResponse, error) {
	log.Printf("CreateBridge: networkID=%s, subnet=%s, gateway=%s", req.NetworkId, req.Subnet, req.Gateway)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if logical switch already exists (idempotency)
	if _, err := runCommandWithOutput("ovn-nbctl", "get", "logical_switch", req.NetworkId, "name"); err == nil {
		// Logical switch exists - get existing VLAN tag
		vlanStr, err := runCommandWithOutput("ovn-nbctl", "get", "logical_switch", req.NetworkId, "external_ids:vlan_tag")
		vlanStr = strings.Trim(strings.TrimSpace(vlanStr), "\"")
		if err != nil || vlanStr == "" {
			log.Printf("WARNING: Logical switch %s exists but has no VLAN tag", req.NetworkId)
			vlanStr = "0"
		}

		log.Printf("Logical switch %s already exists with VLAN tag %s (idempotent)", req.NetworkId, vlanStr)

		return &pb.CreateBridgeResponse{
			BridgeName: "br-int", // All networks use br-int now
			Success:    true,
		}, nil
	}

	// Allocate VLAN tag for this network (100-4095)
	vlanTag := s.nextVLAN
	if vlanTag > 4095 {
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   "VLAN tag exhaustion: maximum 3996 networks reached (100-4095)",
		}, nil
	}
	s.nextVLAN++

	log.Printf("Allocated VLAN tag %d for network %s", vlanTag, req.NetworkId)

	// Create OVN logical switch
	if err := runCommand("ovn-nbctl", "ls-add", req.NetworkId); err != nil {
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to create OVN logical switch: %v", err),
		}, nil
	}

	// Store VLAN tag in logical switch external_ids for TAP relay to read
	if err := runCommand("ovn-nbctl", "set", "logical_switch", req.NetworkId,
		fmt.Sprintf("external_ids:vlan_tag=%d", vlanTag)); err != nil {
		// Cleanup
		_ = runCommand("ovn-nbctl", "ls-del", req.NetworkId)
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to set VLAN tag on logical switch: %v", err),
		}, nil
	}

	// Set subnet, gateway, and exclude IPs in OVN
	// exclude_ips prevents OVN from allocating the gateway IP to containers
	if err := runCommand("ovn-nbctl", "set", "logical_switch", req.NetworkId,
		fmt.Sprintf("other_config:subnet=%s", req.Subnet),
		fmt.Sprintf("other_config:gateway=%s", req.Gateway),
		fmt.Sprintf("other_config:exclude_ips=%s", req.Gateway)); err != nil {
		// Cleanup
		_ = runCommand("ovn-nbctl", "ls-del", req.NetworkId)
		return &pb.CreateBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to configure OVN logical switch: %v", err),
		}, nil
	}

	// Configure OVN DHCP options for this network
	log.Printf("Configuring OVN DHCP for network %s (subnet: %s, gateway: %s, VLAN: %d)", req.NetworkId, req.Subnet, req.Gateway, vlanTag)

	// Generate a MAC address for the DHCP server (gateway) based on VLAN tag
	// This ensures uniqueness across networks
	serverMAC := fmt.Sprintf("00:00:00:00:%02x:%02x", (vlanTag>>8)&0xff, vlanTag&0xff)

	// Create DHCP options using 'ovn-nbctl create' which returns the UUID directly
	// Note: 'dhcp-options-create' does NOT return a UUID (known OVN limitation)
	// Format: create dhcp_options cidr=SUBNET options="key1"="value1" "key2"="value2" ...
	dhcpUUID, err := runCommandWithOutput("ovn-nbctl", "create", "dhcp_options",
		fmt.Sprintf("cidr=%s", req.Subnet),
		fmt.Sprintf(`options="lease_time"="3600" "router"="%s" "server_id"="%s" "server_mac"="%s" "dns_server"="{%s}"`,
			req.Gateway, req.Gateway, serverMAC, req.Gateway))

	if err != nil {
		log.Printf("ERROR: Failed to create DHCP options for subnet %s: %v (output: %q)", req.Subnet, err, dhcpUUID)
		// Continue anyway - DHCP is optional enhancement
	} else {
		// Trim whitespace from UUID
		dhcpUUID = strings.TrimSpace(dhcpUUID)
		log.Printf("Created DHCP options with UUID: %s", dhcpUUID)

		// Validate UUID is not empty
		if dhcpUUID == "" {
			log.Printf("ERROR: DHCP UUID is empty! Command succeeded but returned no output.")
		} else {
			log.Printf("DHCP options configured successfully for network %s", req.NetworkId)

			// Store DHCP UUID in logical switch other_config for later use
			if err := runCommand("ovn-nbctl", "set", "logical_switch", req.NetworkId,
				fmt.Sprintf("other_config:dhcp_options=%s", dhcpUUID)); err != nil {
				log.Printf("Warning: Failed to store DHCP UUID in logical switch: %v", err)
			}
		}
	}

	// Store metadata (still tracking for compatibility, but bridgeName is always br-int now)
	s.bridges[req.NetworkId] = &BridgeMetadata{
		NetworkID:  req.NetworkId,
		BridgeName: "br-int", // All networks use br-int with VLAN tags
		Subnet:     req.Subnet,
		Gateway:    req.Gateway,
	}
	s.containerMap[req.NetworkId] = make(map[string]bool)

	log.Printf("Successfully created OVN logical switch %s with VLAN tag %d", req.NetworkId, vlanTag)

	return &pb.CreateBridgeResponse{
		BridgeName: "br-int", // All networks use br-int now
		Success:    true,
	}, nil
}

// DeleteBridge removes an OVN logical switch (no manual bridge to delete)
func (s *NetworkServer) DeleteBridge(ctx context.Context, req *pb.DeleteBridgeRequest) (*pb.DeleteBridgeResponse, error) {
	log.Printf("DeleteBridge: networkID=%s", req.NetworkId)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Delete OVN logical switch (this removes all ports, DHCP, etc.)
	if err := runCommand("ovn-nbctl", "ls-del", req.NetworkId); err != nil {
		return &pb.DeleteBridgeResponse{
			Success: false,
			Error:   fmt.Sprintf("Failed to delete OVN logical switch: %v", err),
		}, nil
	}

	// Remove metadata
	delete(s.bridges, req.NetworkId)
	delete(s.containerMap, req.NetworkId)

	// Note: We don't reclaim VLAN tags (nextVLAN counter keeps growing)
	// This is fine - 3996 VLANs should be enough for any single daemon lifetime
	// If we need to reclaim, would need to track allocated VLANs in a set

	log.Printf("Successfully deleted OVN logical switch %s", req.NetworkId)

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
	// However, we DO create OVN logical switch ports for DHCP and DNS
	// Port name must be unique per container+network combination to support multi-network containers
	portName := fmt.Sprintf("lsp-%s-%s", req.ContainerId[:12], req.NetworkId[:12])

	// Create OVN logical switch port for DHCP/DNS
	log.Printf("Creating OVN logical switch port %s on network %s", portName, req.NetworkId)
	if err := runCommand("ovn-nbctl", "lsp-add", req.NetworkId, portName); err != nil {
		log.Printf("Warning: Failed to create logical switch port: %v", err)
		// Continue anyway - port may already exist
	}

	// Configure port addresses (MAC + IP)
	var portAddress string
	var allocatedIP string

	if req.IpAddress == "" {
		// Dynamic DHCP allocation
		// Format: "MAC dynamic" - OVN will allocate IP and populate dynamic_addresses
		// Note: OVN does NOT support "MAC dynamic hostname" syntax - hostname must be set separately
		portAddress = fmt.Sprintf("%s dynamic", req.MacAddress)
		if req.Hostname != "" {
			log.Printf("Configuring port %s for dynamic DHCP with hostname %s (MAC: %s)", portName, req.Hostname, req.MacAddress)
		} else {
			log.Printf("Configuring port %s for dynamic DHCP (MAC: %s)", portName, req.MacAddress)
		}

		// Set port addresses - this triggers OVN to allocate an IP
		if err := runCommand("ovn-nbctl", "lsp-set-addresses", portName, portAddress); err != nil {
			log.Printf("Warning: Failed to set port addresses: %v", err)
		}

		// Link DHCP options to this port BEFORE querying for allocated IP
		// OVN requires DHCP options to be linked before it will allocate an IP
		dhcpUUID, err := runCommandWithOutput("ovn-nbctl", "get", "logical_switch", req.NetworkId, "other_config:dhcp_options")
		if err == nil && dhcpUUID != "" {
			dhcpUUID = strings.Trim(strings.TrimSpace(dhcpUUID), "\"")
			log.Printf("Linking DHCP options %s to port %s", dhcpUUID, portName)
			if err := runCommand("ovn-nbctl", "lsp-set-dhcpv4-options", portName, dhcpUUID); err != nil {
				log.Printf("Warning: Failed to link DHCP options: %v", err)
			}
		} else {
			log.Printf("Warning: No DHCP options found for network %s", req.NetworkId)
		}

		// Query the dynamically allocated IP from OVN with retry
		// OVN stores it in the port's dynamic_addresses field
		// ovn-northd may need a moment to process the allocation
		var dynamicAddr string
		for i := 0; i < 5; i++ {
			time.Sleep(100 * time.Millisecond) // Wait for ovn-northd to process

			dynamicAddr, err = runCommandWithOutput("ovn-nbctl", "get", "logical_switch_port", portName, "dynamic_addresses")
			if err == nil && dynamicAddr != "" {
				// Parse dynamic_addresses: "MAC IP"
				dynamicAddr = strings.Trim(strings.TrimSpace(dynamicAddr), "\"")
				parts := strings.Fields(dynamicAddr)
				if len(parts) >= 2 {
					allocatedIP = parts[1]
					log.Printf("OVN allocated IP %s for port %s (attempt %d)", allocatedIP, portName, i+1)
					break
				}
			}
			if i < 4 {
				log.Printf("Waiting for OVN to allocate IP (attempt %d/5)", i+1)
			}
		}

		if allocatedIP == "" {
			log.Printf("Warning: Could not retrieve dynamically allocated IP for port %s after 5 attempts", portName)

			// Diagnostic: dump OVN state to understand why allocation failed
			log.Printf("=== DHCP Allocation Failure Diagnostics ===")

			// Check logical switch configuration
			lsConfig, err := runCommandWithOutput("ovn-nbctl", "list", "logical_switch", req.NetworkId)
			if err == nil {
				log.Printf("Logical switch %s config:\n%s", req.NetworkId, lsConfig)
			} else {
				log.Printf("Failed to get logical switch config: %v", err)
			}

			// Check logical switch port configuration
			portConfig, err := runCommandWithOutput("ovn-nbctl", "list", "logical_switch_port", portName)
			if err == nil {
				log.Printf("Logical switch port %s config:\n%s", portName, portConfig)
			} else {
				log.Printf("Failed to get port config: %v", err)
			}

			// Check DHCP options
			dhcpList, err := runCommandWithOutput("ovn-nbctl", "list", "dhcp_options")
			if err == nil {
				log.Printf("All DHCP options:\n%s", dhcpList)
			} else {
				log.Printf("Failed to list DHCP options: %v", err)
			}

			// Check ovn-northd logs for allocation errors
			northdLogs, err := runCommandWithOutput("tail", "-50", "/var/log/ovn/ovn-northd.log")
			if err == nil {
				log.Printf("ovn-northd recent logs:\n%s", northdLogs)
			} else {
				log.Printf("Failed to read ovn-northd logs: %v", err)
			}

			log.Printf("=== End Diagnostics ===")
		}
	} else {
		// Static IP reservation
		portAddress = fmt.Sprintf("%s %s", req.MacAddress, req.IpAddress)
		allocatedIP = req.IpAddress
		log.Printf("Configuring port %s with static IP %s (MAC: %s)", portName, req.IpAddress, req.MacAddress)

		if err := runCommand("ovn-nbctl", "lsp-set-addresses", portName, portAddress); err != nil {
			log.Printf("Warning: Failed to set port addresses: %v", err)
		}

		// Note: For static IPs, we don't link DHCP options since the IP is already configured
	}

	// Add DNS records for hostname and aliases using dnsmasq
	// OVN handles DHCP, dnsmasq handles DNS resolution
	if allocatedIP != "" && req.Hostname != "" {
		if err := addDNSMasqRecord(req.NetworkId, req.Hostname, allocatedIP); err != nil {
			log.Printf("Warning: Failed to add dnsmasq record for %s: %v", req.Hostname, err)
		} else {
			log.Printf("Added dnsmasq record: %s -> %s", req.Hostname, allocatedIP)
		}

		// Add DNS aliases
		for _, alias := range req.Aliases {
			if err := addDNSMasqRecord(req.NetworkId, alias, allocatedIP); err != nil {
				log.Printf("Warning: Failed to add dnsmasq alias %s: %v", alias, err)
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

	log.Printf("Successfully attached container %s to network %s (IP: %s)", req.ContainerId, req.NetworkId, allocatedIP)

	return &pb.AttachContainerResponse{
		PortName:  portName,
		Success:   true,
		IpAddress: allocatedIP,
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

	// Remove OVN logical switch port (this also removes DHCP lease and DNS records)
	portName := fmt.Sprintf("lsp-%s", req.ContainerId[:12])
	log.Printf("Removing OVN logical switch port %s from network %s", portName, req.NetworkId)
	if err := runCommand("ovn-nbctl", "lsp-del", portName); err != nil {
		log.Printf("Warning: Failed to delete logical switch port: %v", err)
		// Continue anyway - port may not exist
	}
	// Note: OVN automatically:
	// - Releases IP allocation when port is deleted
	// - Removes DNS records associated with the port (if using "dynamic hostname")
	// - Cancels DHCP leases

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

	healthy := ovsStatus == "running" && ovnStatus == "running"
	uptime := uint64(time.Since(s.startTime).Seconds())

	return &pb.GetHealthResponse{
		Healthy:       healthy,
		OvsStatus:     ovsStatus,
		OvnStatus:     ovnStatus,
		UptimeSeconds: uptime,
	}, nil
}

// Helper functions

// addDNSRecord adds a DNS record (hostname -> IP) to an OVN logical switch
// This handles existing DNS records properly by merging them
func addDNSRecord(networkID, hostname, ipAddress string) error {
	if hostname == "" || ipAddress == "" {
		return fmt.Errorf("hostname and IP address are required")
	}

	log.Printf("addDNSRecord: Starting for network=%s hostname=%s ip=%s", networkID, hostname, ipAddress)

	// OVN DNS records are stored as a UUID reference in the logical switch
	// We need to create or update the DNS record in the DNS table

	// Check if DNS record already exists for this logical switch
	log.Printf("addDNSRecord: Querying existing DNS records for network %s", networkID)
	dnsUUIDs, err := runCommandWithOutput("ovn-nbctl", "get", "logical_switch", networkID, "dns_records")
	log.Printf("addDNSRecord: Query result - error=%v dnsUUIDs=%q", err, dnsUUIDs)
	if err != nil {
		// No DNS records yet, create a new one
		log.Printf("Creating new DNS record set for network %s", networkID)

		// Create DNS record with hostname -> IP mapping
		createCmd := fmt.Sprintf(`ovn-nbctl create DNS records='{"%s"="%s"}'`, hostname, ipAddress)
		output, err := runCommandWithOutput("sh", "-c", createCmd)
		if err != nil {
			return fmt.Errorf("failed to create DNS record: %v", err)
		}

		dnsRecordUUID := strings.TrimSpace(output)
		log.Printf("Created DNS record UUID: %s", dnsRecordUUID)

		// Link DNS record to logical switch
		if err := runCommand("ovn-nbctl", "add", "logical_switch", networkID, "dns_records", dnsRecordUUID); err != nil {
			return fmt.Errorf("failed to link DNS record to logical switch: %v", err)
		}

		log.Printf("DNS record added: %s -> %s on network %s", hostname, ipAddress, networkID)
		return nil
	}

	// DNS records exist, update them
	dnsUUIDs = strings.TrimSpace(dnsUUIDs)
	if dnsUUIDs == "[]" {
		// Empty list, create new DNS record
		return addDNSRecord(networkID, hostname, ipAddress) // Recurse to create path
	}

	// Extract first UUID from the list (format: [uuid1, uuid2, ...])
	dnsUUIDs = strings.Trim(dnsUUIDs, "[]")
	parts := strings.Split(dnsUUIDs, ",")
	if len(parts) == 0 {
		return fmt.Errorf("invalid DNS UUID list: %s", dnsUUIDs)
	}

	dnsRecordUUID := strings.TrimSpace(parts[0])
	log.Printf("Updating existing DNS record UUID: %s", dnsRecordUUID)

	// Add hostname -> IP mapping to existing DNS record
	setCmd := fmt.Sprintf(`ovn-nbctl set DNS %s records:"%s"="%s"`, dnsRecordUUID, hostname, ipAddress)
	if err := runCommand("sh", "-c", setCmd); err != nil {
		return fmt.Errorf("failed to update DNS record: %v", err)
	}

	log.Printf("DNS record updated: %s -> %s on network %s", hostname, ipAddress, networkID)
	return nil
}

// removeDNSRecord removes a DNS record (hostname) from an OVN logical switch
func removeDNSRecord(networkID, hostname string) error {
	if hostname == "" {
		return fmt.Errorf("hostname is required")
	}

	// Get DNS record UUIDs for this logical switch
	dnsUUIDs, err := runCommandWithOutput("ovn-nbctl", "get", "logical_switch", networkID, "dns_records")
	if err != nil || dnsUUIDs == "" || dnsUUIDs == "[]" {
		// No DNS records, nothing to remove
		return nil
	}

	// Extract first UUID
	dnsUUIDs = strings.Trim(strings.TrimSpace(dnsUUIDs), "[]")
	parts := strings.Split(dnsUUIDs, ",")
	if len(parts) == 0 {
		return nil
	}

	dnsRecordUUID := strings.TrimSpace(parts[0])

	// Remove hostname from DNS record
	removeCmd := fmt.Sprintf(`ovn-nbctl remove DNS %s records "%s"`, dnsRecordUUID, hostname)
	if err := runCommand("sh", "-c", removeCmd); err != nil {
		log.Printf("Warning: Failed to remove DNS record for %s: %v", hostname, err)
		// Don't fail - record may not exist
	} else {
		log.Printf("DNS record removed: %s from network %s", hostname, networkID)
	}

	return nil
}

// addDNSMasqRecord adds a DNS record to dnsmasq configuration for a specific network
// Creates/updates a network-specific config file in /etc/dnsmasq.d/
func addDNSMasqRecord(networkID, hostname, ipAddress string) error {
	if hostname == "" || ipAddress == "" {
		return fmt.Errorf("hostname and IP address are required")
	}

	// Config file per network
	configFile := fmt.Sprintf("/etc/dnsmasq.d/%s.conf", networkID)

	// Read existing content to check if entry already exists
	existingContent := ""
	if data, err := os.ReadFile(configFile); err == nil {
		existingContent = string(data)
	}

	// Check if this exact record already exists
	hostRecord := fmt.Sprintf("host-record=%s,%s\n", hostname, ipAddress)
	if strings.Contains(existingContent, hostRecord) {
		// Record already exists, no need to add again
		return nil
	}

	// Append host-record entry
	f, err := os.OpenFile(configFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open dnsmasq config: %v", err)
	}
	defer f.Close()

	if _, err := f.WriteString(hostRecord); err != nil {
		return fmt.Errorf("failed to write dnsmasq config: %v", err)
	}

	// Reload dnsmasq to pick up new records (SIGHUP)
	if err := runCommand("killall", "-HUP", "dnsmasq"); err != nil {
		log.Printf("Warning: Failed to reload dnsmasq: %v (may not be running yet)", err)
	}

	return nil
}

// removeDNSMasqRecord removes a DNS record from dnsmasq configuration
func removeDNSMasqRecord(networkID, hostname string) error {
	if hostname == "" {
		return fmt.Errorf("hostname is required")
	}

	configFile := fmt.Sprintf("/etc/dnsmasq.d/%s.conf", networkID)

	// Read existing content
	data, err := os.ReadFile(configFile)
	if err != nil {
		// File doesn't exist, nothing to remove
		return nil
	}

	// Filter out lines matching this hostname
	lines := strings.Split(string(data), "\n")
	var newLines []string
	prefix := fmt.Sprintf("host-record=%s,", hostname)

	for _, line := range lines {
		if !strings.HasPrefix(line, prefix) {
			newLines = append(newLines, line)
		}
	}

	// Write back filtered content
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile(configFile, []byte(newContent), 0644); err != nil {
		return fmt.Errorf("failed to update dnsmasq config: %v", err)
	}

	// Reload dnsmasq
	if err := runCommand("killall", "-HUP", "dnsmasq"); err != nil {
		log.Printf("Warning: Failed to reload dnsmasq: %v", err)
	}

	return nil
}

// ResolveDNS resolves a hostname across multiple networks (for embedded DNS in vminit)
func (s *NetworkServer) ResolveDNS(ctx context.Context, req *pb.ResolveDNSRequest) (*pb.ResolveDNSResponse, error) {
	log.Printf("ResolveDNS: hostname=%s networks=%v", req.Hostname, req.NetworkIds)

	// Search for hostname in each network's dnsmasq config
	for _, networkID := range req.NetworkIds {
		configFile := fmt.Sprintf("/etc/dnsmasq.d/%s.conf", networkID)

		data, err := os.ReadFile(configFile)
		if err != nil {
			continue // Network config doesn't exist, try next
		}

		// Search for host-record matching this hostname
		lines := strings.Split(string(data), "\n")
		prefix := fmt.Sprintf("host-record=%s,", req.Hostname)

		for _, line := range lines {
			if strings.HasPrefix(line, prefix) {
				// Extract IP address: host-record=hostname,IP
				parts := strings.Split(line, ",")
				if len(parts) >= 2 {
					ipAddress := strings.TrimSpace(parts[1])
					log.Printf("ResolveDNS: Found %s -> %s in network %s", req.Hostname, ipAddress, networkID)
					return &pb.ResolveDNSResponse{
						Found:     true,
						IpAddress: ipAddress,
						NetworkId: networkID,
					}, nil
				}
			}
		}
	}

	// Hostname not found in any of the container's networks
	log.Printf("ResolveDNS: hostname %s not found in networks %v", req.Hostname, req.NetworkIds)
	return &pb.ResolveDNSResponse{
		Found: false,
		Error: fmt.Sprintf("hostname %s not found", req.Hostname),
	}, nil
}

// GetContainerNetworks returns the list of networks a container is attached to
func (s *NetworkServer) GetContainerNetworks(ctx context.Context, req *pb.GetContainerNetworksRequest) (*pb.GetContainerNetworksResponse, error) {
	log.Printf("GetContainerNetworks: container_id=%s", req.ContainerId)

	s.mu.RLock()
	defer s.mu.RUnlock()

	// Search through all networks to find which ones this container is attached to
	var networkIDs []string
	for networkID, containers := range s.containerMap {
		if containers[req.ContainerId] {
			networkIDs = append(networkIDs, networkID)
		}
	}

	log.Printf("GetContainerNetworks: container %s is on networks: %v", req.ContainerId, networkIDs)

	return &pb.GetContainerNetworksResponse{
		NetworkIds: networkIDs,
	}, nil
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	// Ensure OVN environment variables are set for ovn-nbctl commands
	if name == "ovn-nbctl" || name == "ovn-sbctl" {
		cmd.Env = append(os.Environ(),
			"OVN_NB_DB=unix:/var/run/ovn/ovnnb_db.sock",
			"OVN_SB_DB=unix:/var/run/ovn/ovnsb_db.sock",
		)
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("command failed: %s %v: %v (output: %s)", name, args, err, string(output))
	}
	return nil
}

func runCommandWithOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	// Ensure OVN environment variables are set for ovn-nbctl commands
	if name == "ovn-nbctl" || name == "ovn-sbctl" {
		cmd.Env = append(os.Environ(),
			"OVN_NB_DB=unix:/var/run/ovn/ovnnb_db.sock",
			"OVN_SB_DB=unix:/var/run/ovn/ovnsb_db.sock",
		)
	}
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
