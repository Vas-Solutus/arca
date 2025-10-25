package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/vishvananda/netlink"
	pb "github.com/Liquescent-Development/arca/helpervm/router-service/proto"
	"google.golang.org/grpc"
)

// RouterServer implements the RouterService gRPC service
type RouterServer struct {
	pb.UnimplementedRouterServiceServer
	mu          sync.RWMutex
	vlans       map[uint32]*VLANInfo // vlan_id -> VLANInfo
	dnsEntries  map[uint32]map[string]string // vlan_id -> hostname -> IP
	startTime   time.Time
}

// VLANInfo tracks information about a VLAN interface
type VLANInfo struct {
	VlanID        uint32
	InterfaceName string
	Gateway       string
	Subnet        string
	NetworkName   string
	NATEnabled    bool
	Domain        string
	CreatedAt     time.Time
}

// getParentInterface finds the first real physical/virtual network interface to use as the parent for VLANs
// Skips pseudo-interfaces like loopback, tunnels, bridges, traffic shaping queues
func (s *RouterServer) getParentInterface() (netlink.Link, error) {
	links, err := netlink.LinkList()
	if err != nil {
		return nil, fmt.Errorf("failed to list network interfaces: %w", err)
	}

	log.Printf("Found %d network interfaces:", len(links))
	for _, link := range links {
		attrs := link.Attrs()
		log.Printf("  - %s: type=%s, flags=%s, mtu=%d",
			attrs.Name, link.Type(), attrs.Flags.String(), attrs.MTU)
	}

	// Pseudo-interface names to skip (traffic shaping, tunnels, etc.)
	pseudoInterfaces := map[string]bool{
		"teql0":      true, // Traffic shaping queue
		"tunl0":      true, // IP-in-IP tunnel
		"sit0":       true, // IPv6-in-IPv4 tunnel
		"ip6tnl0":    true, // IPv6 tunnel
		"gre0":       true, // GRE tunnel
		"gretap0":    true, // GRE tap tunnel
		"erspan0":    true, // ERSPAN tunnel
		"ip_vti0":    true, // VTI tunnel
		"ip6_vti0":   true, // IPv6 VTI tunnel
		"ovs-netdev": true, // OVS internal port
		"ovs-system": true, // OVS system device
	}

	// Pseudo-interface types to skip
	pseudoTypes := map[string]bool{
		"ipip":    true, // IP-in-IP tunnel
		"sit":     true, // IPv6-in-IPv4 tunnel
		"ip6tnl":  true, // IPv6 tunnel
		"gre":     true, // GRE tunnel
		"gretap":  true, // GRE tap tunnel
		"erspan":  true, // ERSPAN tunnel
		"vti":     true, // VTI tunnel
		"tuntap":  true, // TAP/TUN (OVS creates these)
	}

	// Find first real interface (physical or vmnet virtual)
	for _, link := range links {
		attrs := link.Attrs()
		linkType := link.Type()

		// Skip loopback
		if attrs.Flags&net.FlagLoopback != 0 {
			log.Printf("Skipping loopback interface: %s", attrs.Name)
			continue
		}

		// Skip VLAN interfaces (they contain a dot)
		if strings.Contains(attrs.Name, ".") {
			log.Printf("Skipping VLAN interface: %s", attrs.Name)
			continue
		}

		// Skip bridge interfaces (OVS bridges, Linux bridges)
		if strings.HasPrefix(attrs.Name, "br-") || attrs.Name == "br-int" || strings.HasPrefix(attrs.Name, "virbr") {
			log.Printf("Skipping bridge interface: %s", attrs.Name)
			continue
		}

		// Skip known pseudo-interfaces by name
		if pseudoInterfaces[attrs.Name] {
			log.Printf("Skipping pseudo-interface: %s (type=%s)", attrs.Name, linkType)
			continue
		}

		// Skip known pseudo-interface types
		if pseudoTypes[linkType] {
			log.Printf("Skipping pseudo-interface type: %s (type=%s)", attrs.Name, linkType)
			continue
		}

		// At this point, we should have a real interface (en0, eth0, ens0, etc.)
		// These typically have type "device" or "veth" and are real network interfaces
		log.Printf("Selected parent interface: %s (type=%s)", attrs.Name, linkType)
		return link, nil
	}

	return nil, fmt.Errorf("no suitable parent interface found (need physical or vmnet interface, found only pseudo-interfaces)")
}

// CreateVLAN creates a VLAN interface on the helper VM
func (s *RouterServer) CreateVLAN(ctx context.Context, req *pb.CreateVLANRequest) (*pb.CreateVLANResponse, error) {
	log.Printf("CreateVLAN: vlanID=%d subnet=%s gateway=%s network=%s",
		req.VlanId, req.Subnet, req.Gateway, req.NetworkName)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Validate VLAN ID
	if req.VlanId < 100 || req.VlanId > 4094 {
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("invalid VLAN ID %d (must be 100-4094)", req.VlanId),
		}, nil
	}

	// Check if VLAN already exists
	if _, exists := s.vlans[req.VlanId]; exists {
		log.Printf("VLAN %d already exists, will recreate", req.VlanId)
		// Delete and recreate for clean state
		s.deleteVLANLocked(req.VlanId)
	}

	// Get parent interface (first non-loopback interface)
	parent, err := s.getParentInterface()
	if err != nil {
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to find parent interface: %v", err),
		}, nil
	}
	parentName := parent.Attrs().Name

	// Create VLAN interface name (e.g., en0.100 or eth0.100)
	vlanName := fmt.Sprintf("%s.%d", parentName, req.VlanId)

	// Create VLAN subinterface
	vlan := &netlink.Vlan{
		LinkAttrs: netlink.LinkAttrs{
			Name:        vlanName,
			ParentIndex: parent.Attrs().Index,
		},
		VlanId: int(req.VlanId),
	}

	// Set MTU if specified
	if req.Mtu > 0 {
		vlan.MTU = int(req.Mtu)
	}

	// Create the VLAN interface
	if err := netlink.LinkAdd(vlan); err != nil {
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to create VLAN interface: %v", err),
		}, nil
	}

	log.Printf("Created VLAN interface %s", vlanName)

	// Get the created interface
	vlanLink, err := netlink.LinkByName(vlanName)
	if err != nil {
		netlink.LinkDel(vlan)
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to retrieve created VLAN interface: %v", err),
		}, nil
	}

	// Parse and configure gateway IP with subnet mask from subnet
	_, ipnet, err := net.ParseCIDR(req.Subnet)
	if err != nil {
		netlink.LinkDel(vlanLink)
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("invalid subnet %s: %v", req.Subnet, err),
		}, nil
	}

	maskSize, _ := ipnet.Mask.Size()
	addr, err := netlink.ParseAddr(fmt.Sprintf("%s/%d", req.Gateway, maskSize))
	if err != nil {
		netlink.LinkDel(vlanLink)
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("invalid gateway IP %s: %v", req.Gateway, err),
		}, nil
	}

	if err := netlink.AddrAdd(vlanLink, addr); err != nil {
		netlink.LinkDel(vlanLink)
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to add gateway IP: %v", err),
		}, nil
	}

	log.Printf("Configured gateway IP %s/%d on %s", req.Gateway, maskSize, vlanName)

	// Bring interface up
	if err := netlink.LinkSetUp(vlanLink); err != nil {
		netlink.LinkDel(vlanLink)
		return &pb.CreateVLANResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to bring interface up: %v", err),
		}, nil
	}

	log.Printf("Brought up VLAN interface %s", vlanName)

	// Log detailed network state for debugging
	s.logNetworkState(vlanName)

	// Configure NAT if enabled (default: true unless explicitly disabled)
	enableNAT := true
	if req.EnableNat {
		enableNAT = req.EnableNat
	}

	if enableNAT && req.Subnet != "" {
		if err := s.configureNATLocked(req.VlanId, req.Subnet); err != nil {
			log.Printf("Warning: failed to configure NAT: %v", err)
		}
	}

	// Store VLAN info
	s.vlans[req.VlanId] = &VLANInfo{
		VlanID:        req.VlanId,
		InterfaceName: vlanName,
		Gateway:       req.Gateway,
		Subnet:        req.Subnet,
		NetworkName:   req.NetworkName,
		NATEnabled:    enableNAT,
		CreatedAt:     time.Now(),
	}

	// Initialize DNS entries map for this VLAN
	s.dnsEntries[req.VlanId] = make(map[string]string)

	// Get actual MAC address
	macAddr := vlanLink.Attrs().HardwareAddr.String()

	return &pb.CreateVLANResponse{
		Success:       true,
		InterfaceName: vlanName,
		MacAddress:    macAddr,
	}, nil
}

// DeleteVLAN removes a VLAN interface
func (s *RouterServer) DeleteVLAN(ctx context.Context, req *pb.DeleteVLANRequest) (*pb.DeleteVLANResponse, error) {
	log.Printf("DeleteVLAN: vlanID=%d", req.VlanId)

	s.mu.Lock()
	defer s.mu.Unlock()

	return s.deleteVLANResponseLocked(req.VlanId), nil
}

// deleteVLANLocked deletes a VLAN (must hold lock)
func (s *RouterServer) deleteVLANLocked(vlanID uint32) error {
	// Get parent interface to construct VLAN name
	parent, err := s.getParentInterface()
	if err != nil {
		log.Printf("Warning: failed to get parent interface for VLAN deletion: %v", err)
		// Try common names as fallback
		for _, name := range []string{"en0", "eth0", "ens0"} {
			vlanName := fmt.Sprintf("%s.%d", name, vlanID)
			if link, err := netlink.LinkByName(vlanName); err == nil {
				parent = link
				break
			}
		}
		if parent == nil {
			return fmt.Errorf("failed to find VLAN interface for deletion: %w", err)
		}
	}
	parentName := parent.Attrs().Name
	vlanName := fmt.Sprintf("%s.%d", parentName, vlanID)

	// Get VLAN info
	vlanInfo, exists := s.vlans[vlanID]

	// Remove NAT if it was enabled
	if exists && vlanInfo.NATEnabled && vlanInfo.Subnet != "" {
		if err := s.removeNATLocked(vlanID, vlanInfo.Subnet); err != nil {
			log.Printf("Warning: failed to remove NAT: %v", err)
		}
	}

	// Remove dnsmasq config
	if err := s.removeDnsmasqConfigLocked(vlanID); err != nil {
		log.Printf("Warning: failed to remove dnsmasq config: %v", err)
	}

	// Get interface
	link, err := netlink.LinkByName(vlanName)
	if err != nil {
		// Interface doesn't exist - consider it success
		log.Printf("VLAN interface %s not found (already deleted?)", vlanName)
		delete(s.vlans, vlanID)
		delete(s.dnsEntries, vlanID)
		return nil
	}

	// Delete the interface
	if err := netlink.LinkDel(link); err != nil {
		return fmt.Errorf("failed to delete interface: %v", err)
	}

	log.Printf("Deleted VLAN interface %s", vlanName)

	// Remove from tracking
	delete(s.vlans, vlanID)
	delete(s.dnsEntries, vlanID)

	return nil
}

// deleteVLANResponseLocked returns a DeleteVLANResponse (must hold lock)
func (s *RouterServer) deleteVLANResponseLocked(vlanID uint32) *pb.DeleteVLANResponse {
	if err := s.deleteVLANLocked(vlanID); err != nil {
		return &pb.DeleteVLANResponse{
			Success: false,
			Error:   err.Error(),
		}
	}
	return &pb.DeleteVLANResponse{
		Success: true,
	}
}

// ConfigureNAT configures NAT (MASQUERADE) for a network
func (s *RouterServer) ConfigureNAT(ctx context.Context, req *pb.ConfigureNATRequest) (*pb.ConfigureNATResponse, error) {
	log.Printf("ConfigureNAT: vlanID=%d subnet=%s", req.VlanId, req.SourceSubnet)

	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.configureNATLocked(req.VlanId, req.SourceSubnet); err != nil {
		return &pb.ConfigureNATResponse{
			Success: false,
			Error:   err.Error(),
		}, nil
	}

	// Update VLAN info
	if vlanInfo, exists := s.vlans[req.VlanId]; exists {
		vlanInfo.NATEnabled = true
	}

	return &pb.ConfigureNATResponse{
		Success: true,
	}, nil
}

// configureNATLocked configures NAT (must hold lock)
func (s *RouterServer) configureNATLocked(vlanID uint32, sourceSubnet string) error {
	// Add MASQUERADE rule for outbound traffic from this subnet
	cmd := exec.Command("iptables", "-t", "nat", "-A", "POSTROUTING",
		"-s", sourceSubnet,
		"-j", "MASQUERADE",
		"-m", "comment", "--comment", fmt.Sprintf("vlan-%d", vlanID))

	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to configure NAT: %v, output: %s", err, string(output))
	}

	log.Printf("Configured NAT for subnet %s (VLAN %d)", sourceSubnet, vlanID)

	return nil
}

// RemoveNAT removes NAT configuration for a network
func (s *RouterServer) RemoveNAT(ctx context.Context, req *pb.RemoveNATRequest) (*pb.RemoveNATResponse, error) {
	log.Printf("RemoveNAT: vlanID=%d subnet=%s", req.VlanId, req.SourceSubnet)

	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.removeNATLocked(req.VlanId, req.SourceSubnet); err != nil {
		return &pb.RemoveNATResponse{
			Success: false,
			Error:   err.Error(),
		}, nil
	}

	// Update VLAN info
	if vlanInfo, exists := s.vlans[req.VlanId]; exists {
		vlanInfo.NATEnabled = false
	}

	return &pb.RemoveNATResponse{
		Success: true,
	}, nil
}

// removeNATLocked removes NAT (must hold lock)
func (s *RouterServer) removeNATLocked(vlanID uint32, sourceSubnet string) error {
	// Remove MASQUERADE rule
	cmd := exec.Command("iptables", "-t", "nat", "-D", "POSTROUTING",
		"-s", sourceSubnet,
		"-j", "MASQUERADE",
		"-m", "comment", "--comment", fmt.Sprintf("vlan-%d", vlanID))

	if output, err := cmd.CombinedOutput(); err != nil {
		// Don't fail if rule doesn't exist
		if !strings.Contains(string(output), "does a matching rule exist") {
			return fmt.Errorf("failed to remove NAT: %v, output: %s", err, string(output))
		}
	}

	log.Printf("Removed NAT for subnet %s (VLAN %d)", sourceSubnet, vlanID)

	return nil
}

// ConfigureDNS configures dnsmasq for a VLAN network
// This uses the same dnsmasq approach as the OVS control-api
func (s *RouterServer) ConfigureDNS(ctx context.Context, req *pb.ConfigureDNSRequest) (*pb.ConfigureDNSResponse, error) {
	log.Printf("ConfigureDNS: vlanID=%d domain=%s gateway=%s hosts=%d",
		req.VlanId, req.Domain, req.Gateway, len(req.Hosts))

	s.mu.Lock()
	defer s.mu.Unlock()

	// Update VLAN info with domain
	if vlanInfo, exists := s.vlans[req.VlanId]; exists {
		vlanInfo.Domain = req.Domain
	}

	// Store DNS entries
	if s.dnsEntries[req.VlanId] == nil {
		s.dnsEntries[req.VlanId] = make(map[string]string)
	}
	for hostname, ip := range req.Hosts {
		s.dnsEntries[req.VlanId][hostname] = ip
	}

	// Write dnsmasq configuration
	if err := s.writeDnsmasqConfigLocked(req.VlanId); err != nil {
		return &pb.ConfigureDNSResponse{
			Success: false,
			Error:   err.Error(),
		}, nil
	}

	return &pb.ConfigureDNSResponse{
		Success: true,
	}, nil
}

// writeDnsmasqConfigLocked writes dnsmasq config for a VLAN (must hold lock)
// This mirrors the approach in helpervm/control-api/server.go
func (s *RouterServer) writeDnsmasqConfigLocked(vlanID uint32) error {
	vlanInfo := s.vlans[vlanID]
	if vlanInfo == nil {
		return fmt.Errorf("VLAN %d not found", vlanID)
	}

	configFile := fmt.Sprintf("/etc/dnsmasq.d/vlan-%d.conf", vlanID)

	// Build dnsmasq configuration
	var config strings.Builder

	// Listen only on the VLAN gateway IP
	// This makes dnsmasq bind specifically to this network's DNS service
	config.WriteString(fmt.Sprintf("listen-address=%s\n", vlanInfo.Gateway))

	// Add host records for all containers on this network
	if entries := s.dnsEntries[vlanID]; entries != nil {
		for hostname, ip := range entries {
			if hostname != "" {
				config.WriteString(fmt.Sprintf("host-record=%s,%s\n", hostname, ip))
			}
		}
	}

	// Write config file
	if err := os.WriteFile(configFile, []byte(config.String()), 0644); err != nil {
		return fmt.Errorf("failed to write dnsmasq config: %v", err)
	}

	log.Printf("Wrote dnsmasq config for VLAN %d with %d entries", vlanID, len(s.dnsEntries[vlanID]))

	// Test config before applying
	cmd := exec.Command("dnsmasq", "--conf-file=/etc/dnsmasq.conf", "--test")
	if output, err := cmd.CombinedOutput(); err != nil {
		log.Printf("ERROR: dnsmasq config test failed: %v, output: %s", err, string(output))
		return fmt.Errorf("dnsmasq config test failed: %v", err)
	}

	// Restart dnsmasq to apply changes
	// Kill existing dnsmasq processes
	exec.Command("killall", "-9", "dnsmasq").Run()
	time.Sleep(1 * time.Second)

	// Start dnsmasq
	cmd = exec.Command("dnsmasq", "--conf-file=/etc/dnsmasq.conf", "--log-queries")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to start dnsmasq: %v, output: %s", err, string(output))
	}

	log.Printf("dnsmasq restarted successfully for VLAN %d", vlanID)

	return nil
}

// removeDnsmasqConfigLocked removes dnsmasq config for a VLAN (must hold lock)
func (s *RouterServer) removeDnsmasqConfigLocked(vlanID uint32) error {
	configFile := fmt.Sprintf("/etc/dnsmasq.d/vlan-%d.conf", vlanID)

	if err := os.Remove(configFile); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove dnsmasq config: %v", err)
	}

	// Restart dnsmasq
	exec.Command("killall", "-HUP", "dnsmasq").Run()

	return nil
}

// AddPortMapping adds a port forwarding rule (DNAT)
func (s *RouterServer) AddPortMapping(ctx context.Context, req *pb.AddPortMappingRequest) (*pb.AddPortMappingResponse, error) {
	log.Printf("AddPortMapping: %s:%d -> %s:%d (vlan %d)",
		"0.0.0.0", req.HostPort, req.ContainerIp, req.ContainerPort, req.VlanId)

	protocol := strings.ToLower(req.Protocol)
	if protocol != "tcp" && protocol != "udp" {
		return &pb.AddPortMappingResponse{
			Success: false,
			Error:   fmt.Sprintf("invalid protocol %s (must be tcp or udp)", req.Protocol),
		}, nil
	}

	// Add DNAT rule for incoming traffic
	cmd := exec.Command("iptables", "-t", "nat", "-A", "PREROUTING",
		"-p", protocol,
		"--dport", fmt.Sprintf("%d", req.HostPort),
		"-j", "DNAT",
		"--to-destination", fmt.Sprintf("%s:%d", req.ContainerIp, req.ContainerPort),
		"-m", "comment", "--comment", fmt.Sprintf("port-%d-vlan-%d", req.HostPort, req.VlanId))

	if output, err := cmd.CombinedOutput(); err != nil {
		return &pb.AddPortMappingResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to add port mapping: %v, output: %s", err, string(output)),
		}, nil
	}

	log.Printf("Added port mapping %s:%d -> %s:%d",
		protocol, req.HostPort, req.ContainerIp, req.ContainerPort)

	return &pb.AddPortMappingResponse{
		Success: true,
	}, nil
}

// RemovePortMapping removes a port forwarding rule
func (s *RouterServer) RemovePortMapping(ctx context.Context, req *pb.RemovePortMappingRequest) (*pb.RemovePortMappingResponse, error) {
	log.Printf("RemovePortMapping: %s:%d", req.Protocol, req.HostPort)

	protocol := strings.ToLower(req.Protocol)
	if protocol != "tcp" && protocol != "udp" {
		return &pb.RemovePortMappingResponse{
			Success: false,
			Error:   fmt.Sprintf("invalid protocol %s (must be tcp or udp)", req.Protocol),
		}, nil
	}

	// List all PREROUTING rules to find the one to delete
	cmd := exec.Command("iptables", "-t", "nat", "-L", "PREROUTING", "--line-numbers", "-n")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return &pb.RemovePortMappingResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to list iptables rules: %v", err),
		}, nil
	}

	// Parse output to find rule number for this port
	lines := strings.Split(string(output), "\n")
	var ruleNum string
	targetPort := fmt.Sprintf("dpt:%d", req.HostPort)

	for _, line := range lines {
		if strings.Contains(line, protocol) && strings.Contains(line, targetPort) {
			fields := strings.Fields(line)
			if len(fields) > 0 {
				ruleNum = fields[0]
				break
			}
		}
	}

	if ruleNum == "" {
		// Rule not found - consider it success
		log.Printf("Port mapping %s:%d not found (already deleted?)", protocol, req.HostPort)
		return &pb.RemovePortMappingResponse{
			Success: true,
		}, nil
	}

	// Delete the rule by number
	cmd = exec.Command("iptables", "-t", "nat", "-D", "PREROUTING", ruleNum)
	if output, err := cmd.CombinedOutput(); err != nil {
		return &pb.RemovePortMappingResponse{
			Success: false,
			Error:   fmt.Sprintf("failed to remove port mapping: %v, output: %s", err, string(output)),
		}, nil
	}

	log.Printf("Removed port mapping %s:%d", protocol, req.HostPort)

	return &pb.RemovePortMappingResponse{
		Success: true,
	}, nil
}

// ListVLANs lists all VLAN interfaces
func (s *RouterServer) ListVLANs(ctx context.Context, req *pb.ListVLANsRequest) (*pb.ListVLANsResponse, error) {
	log.Printf("ListVLANs: filter=%d", req.VlanId)

	s.mu.RLock()
	defer s.mu.RUnlock()

	var vlans []*pb.VLANInterface

	for _, vlanInfo := range s.vlans {
		// Apply filter if requested
		if req.VlanId > 0 && vlanInfo.VlanID != req.VlanId {
			continue
		}

		// Get current interface status
		link, err := netlink.LinkByName(vlanInfo.InterfaceName)
		if err != nil {
			log.Printf("Warning: VLAN %d interface not found: %v", vlanInfo.VlanID, err)
			continue
		}

		attrs := link.Attrs()
		vlan := &pb.VLANInterface{
			VlanId:        vlanInfo.VlanID,
			InterfaceName: vlanInfo.InterfaceName,
			Gateway:       vlanInfo.Gateway,
			Subnet:        vlanInfo.Subnet,
			MacAddress:    attrs.HardwareAddr.String(),
			Mtu:           uint32(attrs.MTU),
			IsUp:          attrs.Flags&net.FlagUp != 0,
			NatEnabled:    vlanInfo.NATEnabled,
		}

		vlans = append(vlans, vlan)
	}

	log.Printf("Listed %d VLANs", len(vlans))

	return &pb.ListVLANsResponse{
		Vlans: vlans,
	}, nil
}

// GetHealth returns health status
func (s *RouterServer) GetHealth(ctx context.Context, req *pb.HealthRequest) (*pb.HealthResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	uptime := uint64(time.Since(s.startTime).Seconds())

	return &pb.HealthResponse{
		Healthy:       true,
		Status:        "running",
		ActiveVlans:   uint32(len(s.vlans)),
		UptimeSeconds: uptime,
	}, nil
}

// logNetworkState logs detailed network configuration for debugging
func (s *RouterServer) logNetworkState(vlanName string) {
	log.Printf("=== Network State Dump ===")

	// Get all interfaces
	links, err := netlink.LinkList()
	if err != nil {
		log.Printf("ERROR: Failed to list interfaces: %v", err)
		return
	}

	// Log interface information
	log.Printf("Active network interfaces:")
	for _, link := range links {
		attrs := link.Attrs()
		log.Printf("  Interface: %s", attrs.Name)
		log.Printf("    Type: %s", link.Type())
		log.Printf("    Flags: %s", attrs.Flags.String())
		log.Printf("    MTU: %d", attrs.MTU)
		log.Printf("    MAC: %s", attrs.HardwareAddr.String())

		// Get addresses
		addrs, err := netlink.AddrList(link, 0) // 0 = all address families
		if err != nil {
			log.Printf("    ERROR getting addresses: %v", err)
			continue
		}
		if len(addrs) > 0 {
			log.Printf("    IP Addresses:")
			for _, addr := range addrs {
				log.Printf("      - %s", addr.IPNet.String())
			}
		}

		// Get routes for this interface
		routes, err := netlink.RouteList(link, 0) // 0 = all address families
		if err != nil {
			log.Printf("    ERROR getting routes: %v", err)
		} else if len(routes) > 0 {
			log.Printf("    Routes:")
			for _, route := range routes {
				dst := "default"
				if route.Dst != nil {
					dst = route.Dst.String()
				}
				gw := "direct"
				if route.Gw != nil {
					gw = route.Gw.String()
				}
				log.Printf("      - dst=%s gw=%s", dst, gw)
			}
		}
	}

	// Log all routes in system
	allRoutes, err := netlink.RouteList(nil, 0) // 0 = all address families
	if err != nil {
		log.Printf("ERROR: Failed to list routes: %v", err)
	} else {
		log.Printf("System routing table:")
		for _, route := range allRoutes {
			dst := "default"
			if route.Dst != nil {
				dst = route.Dst.String()
			}
			gw := "direct"
			if route.Gw != nil {
				gw = route.Gw.String()
			}

			// Get interface name
			ifName := "unknown"
			if link, err := netlink.LinkByIndex(route.LinkIndex); err == nil {
				ifName = link.Attrs().Name
			}

			log.Printf("  - dst=%s gw=%s dev=%s", dst, gw, ifName)
		}
	}

	// Log iptables NAT rules
	cmd := exec.Command("iptables", "-t", "nat", "-L", "-n", "-v")
	if output, err := cmd.CombinedOutput(); err != nil {
		log.Printf("ERROR: Failed to get iptables NAT rules: %v", err)
	} else {
		log.Printf("iptables NAT rules:\n%s", string(output))
	}

	// Log IP forwarding status
	cmd = exec.Command("sysctl", "net.ipv4.ip_forward")
	if output, err := cmd.CombinedOutput(); err != nil {
		log.Printf("ERROR: Failed to get IP forwarding status: %v", err)
	} else {
		log.Printf("IP forwarding: %s", strings.TrimSpace(string(output)))
	}

	log.Printf("=== End Network State Dump ===")
}

// NewRouterServer creates a new router server instance
func NewRouterServer() *RouterServer {
	return &RouterServer{
		vlans:      make(map[uint32]*VLANInfo),
		dnsEntries: make(map[uint32]map[string]string),
		startTime:  time.Now(),
	}
}

// StartServer starts the gRPC server
func StartServer(port int) error {
	// Enable IP forwarding
	if err := exec.Command("sysctl", "-w", "net.ipv4.ip_forward=1").Run(); err != nil {
		log.Printf("Warning: failed to enable IP forwarding: %v", err)
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return fmt.Errorf("failed to listen on port %d: %v", port, err)
	}

	grpcServer := grpc.NewServer()
	pb.RegisterRouterServiceServer(grpcServer, NewRouterServer())

	log.Printf("Router service listening on port %d", port)
	return grpcServer.Serve(lis)
}
