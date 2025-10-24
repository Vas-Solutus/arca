// Package forwarder provides packet forwarding between TAP devices and vsock connections
package forwarder

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"

	"github.com/mdlayher/vsock"
	"github.com/vas-solutus/arca-tap-forwarder/internal/tap"
)

// NetworkAttachment represents an active network interface with forwarding
type NetworkAttachment struct {
	Device    string
	VsockPort uint32
	IPAddress string
	Gateway   string
	MAC       string

	tap        *tap.TAP
	vsockConn  net.Conn
	cancel     context.CancelFunc
	stats      Stats
	statsLock  sync.RWMutex
}

// Stats tracks packet statistics
type Stats struct {
	PacketsSent     atomic.Uint64
	PacketsReceived atomic.Uint64
	BytesSent       atomic.Uint64
	BytesReceived   atomic.Uint64
	SendErrors      atomic.Uint64
	ReceiveErrors   atomic.Uint64
}

// Forwarder manages multiple network attachments
type Forwarder struct {
	attachments map[string]*NetworkAttachment
	mu          sync.RWMutex
}

// New creates a new Forwarder
func New() *Forwarder {
	return &Forwarder{
		attachments: make(map[string]*NetworkAttachment),
	}
}

// AttachNetwork creates a TAP device and starts forwarding packets to/from vsock
func (f *Forwarder) AttachNetwork(device string, vsockPort uint32, ipAddress string, gateway string, netmask uint32) (*NetworkAttachment, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	// Check if already attached
	if _, exists := f.attachments[device]; exists {
		return nil, fmt.Errorf("device %s already attached", device)
	}

	// Create TAP device
	tapDev, err := tap.Create(device)
	if err != nil {
		return nil, fmt.Errorf("failed to create TAP device: %w", err)
	}

	// Configure IP address and netmask
	if err := tapDev.SetIP(ipAddress, netmask); err != nil {
		tapDev.Close()
		return nil, fmt.Errorf("failed to set IP address: %w", err)
	}

	// Bring interface up
	if err := tapDev.BringUp(); err != nil {
		tapDev.Close()
		return nil, fmt.Errorf("failed to bring interface up: %w", err)
	}

	// Configure DNS to use gateway as nameserver (for the first interface only)
	// This ensures containers can resolve DNS names through the helper VM
	if device == "eth0" {
		if err := configureDNS(gateway); err != nil {
			log.Printf("Warning: Failed to configure DNS: %v", err)
			// Don't fail - networking will work, just DNS resolution won't
		}
	}

	// Listen on vsock port for host connection
	listener, err := vsock.Listen(vsockPort, nil)
	if err != nil {
		tapDev.Close()
		return nil, fmt.Errorf("failed to listen on vsock port %d: %w", vsockPort, err)
	}

	// Create attachment (vsockConn will be set when host connects)
	ctx, cancel := context.WithCancel(context.Background())
	attachment := &NetworkAttachment{
		Device:    device,
		VsockPort: vsockPort,
		IPAddress: ipAddress,
		Gateway:   gateway,
		MAC:       tapDev.MAC().String(),
		tap:       tapDev,
		vsockConn: nil, // Will be set when host connects
		cancel:    cancel,
	}

	// Accept connection from host in background
	go func() {
		log.Printf("Waiting for host connection on vsock port %d for device %s", vsockPort, device)
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("Failed to accept vsock connection on port %d: %v", vsockPort, err)
			cancel()
			return
		}

		attachment.vsockConn = conn
		log.Printf("Host connected to vsock port %d for device %s", vsockPort, device)

		// Start bidirectional forwarding now that we have the connection
		go attachment.forwardTAPtoVsock(ctx)
		go attachment.forwardVsockToTAP(ctx)
	}()

	f.attachments[device] = attachment

	log.Printf("Network attached: device=%s vsock_port=%d ip=%s mac=%s",
		device, vsockPort, ipAddress, attachment.MAC)

	return attachment, nil
}

// DetachNetwork stops forwarding and destroys the TAP device
func (f *Forwarder) DetachNetwork(device string) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	attachment, exists := f.attachments[device]
	if !exists {
		return fmt.Errorf("device %s not found", device)
	}

	// Stop forwarding
	attachment.cancel()

	// Close connections
	if attachment.vsockConn != nil {
		attachment.vsockConn.Close()
	}
	if attachment.tap != nil {
		attachment.tap.Close()
	}

	delete(f.attachments, device)

	log.Printf("Network detached: device=%s", device)

	return nil
}

// GetAttachment returns the attachment for a device
func (f *Forwarder) GetAttachment(device string) (*NetworkAttachment, bool) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	attachment, exists := f.attachments[device]
	return attachment, exists
}

// ListAttachments returns all active attachments
func (f *Forwarder) ListAttachments() []*NetworkAttachment {
	f.mu.RLock()
	defer f.mu.RUnlock()

	result := make([]*NetworkAttachment, 0, len(f.attachments))
	for _, attachment := range f.attachments {
		result = append(result, attachment)
	}
	return result
}

// GetTotalStats returns aggregated statistics across all attachments
func (f *Forwarder) GetTotalStats() Stats {
	f.mu.RLock()
	defer f.mu.RUnlock()

	var total Stats
	for _, attachment := range f.attachments {
		attachment.statsLock.RLock()
		total.PacketsSent.Add(attachment.stats.PacketsSent.Load())
		total.PacketsReceived.Add(attachment.stats.PacketsReceived.Load())
		total.BytesSent.Add(attachment.stats.BytesSent.Load())
		total.BytesReceived.Add(attachment.stats.BytesReceived.Load())
		total.SendErrors.Add(attachment.stats.SendErrors.Load())
		total.ReceiveErrors.Add(attachment.stats.ReceiveErrors.Load())
		attachment.statsLock.RUnlock()
	}
	return total
}

// forwardTAPtoVsock forwards packets from TAP device to vsock
func (a *NetworkAttachment) forwardTAPtoVsock(ctx context.Context) {
	buf := make([]byte, 65536) // Max Ethernet frame size

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Read from TAP device
		n, err := a.tap.Read(buf)
		if err != nil {
			if err != io.EOF {
				a.stats.ReceiveErrors.Add(1)
				log.Printf("TAP read error on %s: %v", a.Device, err)
			}
			return
		}

		a.stats.PacketsReceived.Add(1)
		a.stats.BytesReceived.Add(uint64(n))

		// Log first few packets for debugging
		if a.stats.PacketsReceived.Load() <= 5 {
			log.Printf("TAP->vsock: device=%s bytes=%d packet=%d", a.Device, n, a.stats.PacketsReceived.Load())
		}

		// Write to vsock
		_, err = a.vsockConn.Write(buf[:n])
		if err != nil {
			a.stats.SendErrors.Add(1)
			log.Printf("vsock write error on %s: %v", a.Device, err)
			return
		}

		a.stats.PacketsSent.Add(1)
		a.stats.BytesSent.Add(uint64(n))
	}
}

// forwardVsockToTAP forwards packets from vsock to TAP device
func (a *NetworkAttachment) forwardVsockToTAP(ctx context.Context) {
	buf := make([]byte, 65536) // Max Ethernet frame size
	var reversePackets atomic.Uint64

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Read from vsock
		n, err := a.vsockConn.Read(buf)
		if err != nil {
			if err != io.EOF {
				a.stats.ReceiveErrors.Add(1)
				log.Printf("vsock read error on %s: %v", a.Device, err)
			}
			return
		}

		reversePackets.Add(1)

		// Log first few packets for debugging
		if reversePackets.Load() <= 5 {
			log.Printf("vsock->TAP: device=%s bytes=%d packet=%d", a.Device, n, reversePackets.Load())
		}

		a.stats.PacketsReceived.Add(1)
		a.stats.BytesReceived.Add(uint64(n))

		// Write to TAP device
		_, err = a.tap.Write(buf[:n])
		if err != nil {
			a.stats.SendErrors.Add(1)
			log.Printf("TAP write error on %s: %v", a.Device, err)
			return
		}

		a.stats.PacketsSent.Add(1)
		a.stats.BytesSent.Add(uint64(n))
	}
}

// GetStats returns a copy of the current statistics
func (a *NetworkAttachment) GetStats() Stats {
	a.statsLock.RLock()
	defer a.statsLock.RUnlock()

	// Create new Stats with current values
	var stats Stats
	stats.PacketsSent.Store(a.stats.PacketsSent.Load())
	stats.PacketsReceived.Store(a.stats.PacketsReceived.Load())
	stats.BytesSent.Store(a.stats.BytesSent.Load())
	stats.BytesReceived.Store(a.stats.BytesReceived.Load())
	stats.SendErrors.Store(a.stats.SendErrors.Load())
	stats.ReceiveErrors.Store(a.stats.ReceiveErrors.Load())

	return stats
}

// configureDNS updates /etc/resolv.conf to use the network gateway as nameserver
// This allows containers to resolve DNS names via the helper VM's dnsmasq
func configureDNS(gateway string) error {
	// Create resolv.conf content with gateway as nameserver
	resolvConf := fmt.Sprintf("nameserver %s\n", gateway)

	// Write to /etc/resolv.conf with proper permissions (0644)
	if err := os.WriteFile("/etc/resolv.conf", []byte(resolvConf), 0644); err != nil {
		return fmt.Errorf("failed to write /etc/resolv.conf: %w", err)
	}

	log.Printf("Configured DNS: nameserver=%s", gateway)
	return nil
}
