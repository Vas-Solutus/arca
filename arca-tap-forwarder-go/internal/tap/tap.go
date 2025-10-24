// Package tap provides TAP device management for Linux
package tap

import (
	"crypto/rand"
	"fmt"
	"net"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	// /dev/net/tun device path
	tunDevice = "/dev/net/tun"

	// TAP device type
	iffTAP   = 0x0002
	iffNOPI  = 0x1000

	// Network configuration ioctls
	TUNSETIFF    = 0x400454ca
	SIOCSIFADDR  = 0x8916
	SIOCSIFNETMASK = 0x891c
	SIOCSIFFLAGS = 0x8914
	SIOCGIFFLAGS = 0x8913
	SIOCSIFHWADDR = 0x8924

	// Interface flags
	IFF_UP = 0x1
	IFF_RUNNING = 0x40

	// Hardware address type (Ethernet)
	ARPHRD_ETHER = 1
)

// ifreq structure for ioctl calls
type ifreq struct {
	ifrName  [unix.IFNAMSIZ]byte
	ifrFlags uint16
	_        [22]byte // padding to match kernel struct size
}

// ifrReqAddr structure for IP address configuration
type ifrReqAddr struct {
	ifrName [unix.IFNAMSIZ]byte
	ifrAddr unix.RawSockaddrInet4
	_       [8]byte // padding
}

// ifrReqHWAddr structure for MAC address configuration
type ifrReqHWAddr struct {
	ifrName   [unix.IFNAMSIZ]byte
	ifrHWAddr unix.RawSockaddr
	_         [8]byte // padding
}

// TAP represents a TAP network device
type TAP struct {
	file *os.File
	name string
	mac  net.HardwareAddr
}

// Create creates a new TAP device with the specified name
func Create(name string) (*TAP, error) {
	// Open /dev/net/tun in blocking mode
	// Blocking I/O is fine since we're in dedicated goroutines
	fd, err := unix.Open(tunDevice, unix.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to open %s: %w", tunDevice, err)
	}

	// Prepare ifreq structure
	var ifr ifreq
	copy(ifr.ifrName[:], name)
	ifr.ifrFlags = iffTAP | iffNOPI

	// Create TAP device via TUNSETIFF ioctl
	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(fd),
		uintptr(TUNSETIFF),
		uintptr(unsafe.Pointer(&ifr)),
	)
	if errno != 0 {
		unix.Close(fd)
		return nil, fmt.Errorf("TUNSETIFF ioctl failed: %v", errno)
	}

	// Create os.File from fd for compatibility
	file := os.NewFile(uintptr(fd), tunDevice)

	// Generate random MAC address (locally administered)
	mac := make(net.HardwareAddr, 6)
	if _, err := rand.Read(mac); err != nil {
		file.Close()
		return nil, fmt.Errorf("failed to generate MAC address: %w", err)
	}
	// Set locally administered bit, clear multicast bit
	mac[0] = (mac[0] & 0xfe) | 0x02

	tap := &TAP{
		file: file,
		name: name,
		mac:  mac,
	}

	// Set MAC address
	if err := tap.setMAC(mac); err != nil {
		tap.Close()
		return nil, fmt.Errorf("failed to set MAC address: %w", err)
	}

	return tap, nil
}

// SetIP configures the IP address and netmask for the TAP device
func (t *TAP) SetIP(ipAddr string, netmask uint32) error {
	// Parse IP address
	ip := net.ParseIP(ipAddr)
	if ip == nil {
		return fmt.Errorf("invalid IP address: %s", ipAddr)
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return fmt.Errorf("not an IPv4 address: %s", ipAddr)
	}

	// Open socket for ioctl
	sockFd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		return fmt.Errorf("failed to create socket: %w", err)
	}
	defer unix.Close(sockFd)

	// Set IP address
	var ifrAddr ifrReqAddr
	copy(ifrAddr.ifrName[:], t.name)
	ifrAddr.ifrAddr.Family = unix.AF_INET
	copy(ifrAddr.ifrAddr.Addr[:], ip4)

	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(sockFd),
		uintptr(SIOCSIFADDR),
		uintptr(unsafe.Pointer(&ifrAddr)),
	)
	if errno != 0 {
		return fmt.Errorf("SIOCSIFADDR ioctl failed: %v", errno)
	}

	// Set netmask
	mask := net.CIDRMask(int(netmask), 32)
	var ifrMask ifrReqAddr
	copy(ifrMask.ifrName[:], t.name)
	ifrMask.ifrAddr.Family = unix.AF_INET
	copy(ifrMask.ifrAddr.Addr[:], mask)

	_, _, errno = unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(sockFd),
		uintptr(SIOCSIFNETMASK),
		uintptr(unsafe.Pointer(&ifrMask)),
	)
	if errno != 0 {
		return fmt.Errorf("SIOCSIFNETMASK ioctl failed: %v", errno)
	}

	return nil
}

// BringUp brings the TAP interface up
func (t *TAP) BringUp() error {
	sockFd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		return fmt.Errorf("failed to create socket: %w", err)
	}
	defer unix.Close(sockFd)

	// Get current flags
	var ifr ifreq
	copy(ifr.ifrName[:], t.name)

	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(sockFd),
		uintptr(SIOCGIFFLAGS),
		uintptr(unsafe.Pointer(&ifr)),
	)
	if errno != 0 {
		return fmt.Errorf("SIOCGIFFLAGS ioctl failed: %v", errno)
	}

	// Set UP and RUNNING flags
	ifr.ifrFlags |= IFF_UP | IFF_RUNNING

	_, _, errno = unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(sockFd),
		uintptr(SIOCSIFFLAGS),
		uintptr(unsafe.Pointer(&ifr)),
	)
	if errno != 0 {
		return fmt.Errorf("SIOCSIFFLAGS ioctl failed: %v", errno)
	}

	return nil
}

// setMAC sets the MAC address for the TAP device
func (t *TAP) setMAC(mac net.HardwareAddr) error {
	sockFd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		return fmt.Errorf("failed to create socket: %w", err)
	}
	defer unix.Close(sockFd)

	var ifrHW ifrReqHWAddr
	copy(ifrHW.ifrName[:], t.name)
	ifrHW.ifrHWAddr.Family = ARPHRD_ETHER
	for i := 0; i < len(mac) && i < len(ifrHW.ifrHWAddr.Data); i++ {
		ifrHW.ifrHWAddr.Data[i] = int8(mac[i])
	}

	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(sockFd),
		uintptr(SIOCSIFHWADDR),
		uintptr(unsafe.Pointer(&ifrHW)),
	)
	if errno != 0 {
		return fmt.Errorf("SIOCSIFHWADDR ioctl failed: %v", errno)
	}

	return nil
}

// Read reads a packet from the TAP device using blocking I/O
func (t *TAP) Read(buf []byte) (int, error) {
	n, err := unix.Read(int(t.file.Fd()), buf)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// Write writes a packet to the TAP device using blocking I/O
func (t *TAP) Write(buf []byte) (int, error) {
	n, err := unix.Write(int(t.file.Fd()), buf)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// Name returns the TAP device name
func (t *TAP) Name() string {
	return t.name
}

// MAC returns the MAC address
func (t *TAP) MAC() net.HardwareAddr {
	return t.mac
}

// Close closes the TAP device
func (t *TAP) Close() error {
	if t.file != nil {
		return t.file.Close()
	}
	return nil
}
