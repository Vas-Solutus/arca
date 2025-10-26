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
	containerMap  map[string]map[string]bool // networkID -> containerID -> exists
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

// NewNetworkServer creates a new NetworkServer
func NewNetworkServer() *NetworkServer {
	return &NetworkServer{
		bridges:       make(map[string]*BridgeMetadata),
		containerMap:  make(map[string]map[string]bool),
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

	// TODO: Add OVN DHCP configuration here
	// - Create logical switch port via ovn-nbctl lsp-add
	// - Set port addresses to "dynamic" or specific MAC+IP for reservations
	// - Link DHCP options to port via ovn-nbctl lsp-set-dhcpv4-options
	// - Add DNS record via ovn-nbctl set logical_switch dns_records
	// OVN will track IP allocations in its Northbound database

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

	// TODO: Remove OVN DNS record here
	// - Remove DNS record via ovn-nbctl remove logical_switch dns_records
	// - Delete logical switch port via ovn-nbctl lsp-del
	// OVN will automatically release IP allocation when port is deleted

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
