package main

import (
	"crypto/md5"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"

	"github.com/mdlayher/vsock"
	"golang.org/x/sys/unix"
)

// TAPRelayManager manages vsock listeners for TAP packet relay
type TAPRelayManager struct {
	mu        sync.RWMutex
	listeners map[uint32]*vsock.Listener // port -> listener
	relays    map[uint32]chan struct{}   // port -> stop channel
}

// NewTAPRelayManager creates a new TAP relay manager
func NewTAPRelayManager() *TAPRelayManager {
	return &TAPRelayManager{
		listeners: make(map[uint32]*vsock.Listener),
		relays:    make(map[uint32]chan struct{}),
	}
}

// StartRelay starts a vsock listener for TAP packet relay
// This is called when a container is attached to a network
func (m *TAPRelayManager) StartRelay(port uint32, networkID string, containerID string, macAddress string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Check if already running
	if _, exists := m.listeners[port]; exists {
		return fmt.Errorf("relay already running on port %d", port)
	}

	log.Printf("Starting TAP relay on vsock port %d for container %s on network %s", port, containerID, networkID)

	// Create vsock listener
	listener, err := vsock.Listen(port, nil)
	if err != nil {
		return fmt.Errorf("failed to create vsock listener: %w", err)
	}

	// Track listener
	m.listeners[port] = listener
	stopChan := make(chan struct{})
	m.relays[port] = stopChan

	// Start accepting connections in background
	go func() {
		defer listener.Close()
		defer func() {
			m.mu.Lock()
			delete(m.listeners, port)
			delete(m.relays, port)
			m.mu.Unlock()
		}()

		for {
			select {
			case <-stopChan:
				log.Printf("Stopping TAP relay on port %d", port)
				return
			default:
				// Accept connection from Arca host relay
				conn, err := listener.Accept()
				if err != nil {
					if !isClosedError(err) {
						log.Printf("Error accepting vsock connection on port %d: %v", port, err)
					}
					return
				}

				log.Printf("Accepted vsock connection on port %d", port)

				// Handle this connection in a separate goroutine
				go m.handleConnection(conn, networkID, containerID, macAddress, port)
			}
		}
	}()

	log.Printf("TAP relay started on vsock port %d", port)
	return nil
}

// StopRelay stops a vsock relay
func (m *TAPRelayManager) StopRelay(port uint32) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	stopChan, exists := m.relays[port]
	if !exists {
		return fmt.Errorf("no relay running on port %d", port)
	}

	close(stopChan)
	return nil
}

// handleConnection handles a single vsock connection for TAP packet relay
func (m *TAPRelayManager) handleConnection(conn net.Conn, networkID string, containerID string, macAddress string, port uint32) {
	defer conn.Close()

	log.Printf("Handling TAP relay connection for container %s on network %s (port %d)", containerID, networkID, port)

	// Get bridge name from network ID
	bridgeName := getBridgeName(networkID)

	// Create OVS internal port for this container
	// Format: port-{short-container-id}
	portName := fmt.Sprintf("port-%s", containerID[:12])

	// Add internal port to OVS bridge
	if err := addOVSInternalPort(bridgeName, portName); err != nil {
		log.Printf("Failed to add OVS internal port: %v", err)
		return
	}
	defer deleteOVSPort(bridgeName, portName)

	// Bring the port interface up
	if err := bringInterfaceUp(portName); err != nil {
		log.Printf("Failed to bring port up: %v", err)
		return
	}

	// Open the OVS port as a TAP interface
	// OVS internal ports appear as network interfaces that can be opened
	tapFile, err := openTAPDevice(portName)
	if err != nil {
		log.Printf("Failed to open TAP device: %v", err)
		return
	}
	defer tapFile.Close()

	log.Printf("Started packet relay: vsock port %d <-> OVS port %s on bridge %s", port, portName, bridgeName)

	// Relay packets bidirectionally
	done := make(chan struct{}, 2)

	// vsock -> TAP (packets from container to bridge)
	go func() {
		defer func() { done <- struct{}{} }()
		buffer := make([]byte, 65536)
		for {
			n, err := conn.Read(buffer)
			if err != nil {
				if !isClosedError(err) {
					log.Printf("Error reading from vsock: %v", err)
				}
				return
			}
			if _, err := tapFile.Write(buffer[:n]); err != nil {
				log.Printf("Error writing to TAP: %v", err)
				return
			}
		}
	}()

	// TAP -> vsock (packets from bridge to container)
	go func() {
		defer func() { done <- struct{}{} }()
		buffer := make([]byte, 65536)
		for {
			n, err := tapFile.Read(buffer)
			if err != nil {
				if !isClosedError(err) {
					log.Printf("Error reading from TAP: %v", err)
				}
				return
			}
			if _, err := conn.Write(buffer[:n]); err != nil {
				log.Printf("Error writing to vsock: %v", err)
				return
			}
		}
	}()

	// Wait for either direction to complete
	<-done

	log.Printf("TAP relay connection closed for container %s (port %d)", containerID, port)
}

// Helper functions

func addOVSInternalPort(bridgeName, portName string) error {
	// Add internal port to OVS bridge
	// Internal ports appear as network interfaces that can be used for packet I/O
	cmd := exec.Command("ovs-vsctl", "add-port", bridgeName, portName, "--", "set", "interface", portName, "type=internal")
	return cmd.Run()
}

func deleteOVSPort(bridgeName, portName string) error {
	cmd := exec.Command("ovs-vsctl", "del-port", bridgeName, portName)
	return cmd.Run()
}

func bringInterfaceUp(ifName string) error {
	cmd := exec.Command("ip", "link", "set", ifName, "up")
	return cmd.Run()
}

func openTAPDevice(ifName string) (*os.File, error) {
	// For OVS internal ports, we need to use raw sockets
	// Get interface index
	iface, err := net.InterfaceByName(ifName)
	if err != nil {
		return nil, fmt.Errorf("failed to get interface %s: %w", ifName, err)
	}

	// Create raw socket (AF_PACKET, ETH_P_ALL)
	// This allows us to send/receive raw Ethernet frames
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(htons(unix.ETH_P_ALL)))
	if err != nil {
		return nil, fmt.Errorf("failed to create raw socket: %w", err)
	}

	// Bind to the interface
	addr := unix.SockaddrLinklayer{
		Protocol: htons(unix.ETH_P_ALL),
		Ifindex:  iface.Index,
	}
	if err := unix.Bind(fd, &addr); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("failed to bind socket to interface: %w", err)
	}

	// Wrap in os.File for easier I/O
	return os.NewFile(uintptr(fd), ifName), nil
}

// htons converts uint16 to network byte order
func htons(v uint16) uint16 {
	return (v << 8) | (v >> 8)
}

func isClosedError(err error) bool {
	if err == nil {
		return false
	}
	// Check for common "closed" errors
	errStr := err.Error()
	return errStr == "use of closed network connection" || errStr == "EOF"
}
