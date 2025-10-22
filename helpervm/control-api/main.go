package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
	"unsafe"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"

	pb "arca-network-api/proto"
)

const (
	// vsock constants from linux/vm_sockets.h
	AF_VSOCK        = 40
	VMADDR_CID_ANY  = 0xFFFFFFFF // Any CID
	VMADDR_PORT_ANY = 0xFFFFFFFF // Any port
)

// vsockAddr represents a vsock address structure
type vsockAddr struct {
	Family uint16
	_      uint16 // Reserved
	Port   uint32
	Cid    uint32
}

var (
	vsockPort = flag.Uint("vsock-port", 9999, "vsock port to listen on")
)

// createVsockListener creates a listener for vsock connections
func createVsockListener(port uint32) (net.Listener, error) {
	// Create vsock socket
	fd, err := syscall.Socket(AF_VSOCK, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to create vsock socket: %w", err)
	}

	// Set socket options
	if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("failed to set SO_REUSEADDR: %w", err)
	}

	// Bind to vsock address (listen on any CID, specific port)
	addr := vsockAddr{
		Family: AF_VSOCK,
		Port:   port,
		Cid:    VMADDR_CID_ANY,
	}

	_, _, errno := syscall.Syscall(
		syscall.SYS_BIND,
		uintptr(fd),
		uintptr(unsafe.Pointer(&addr)),
		unsafe.Sizeof(addr),
	)
	if errno != 0 {
		syscall.Close(fd)
		return nil, fmt.Errorf("failed to bind vsock: %v", errno)
	}

	// Listen
	if err := syscall.Listen(fd, syscall.SOMAXCONN); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("failed to listen: %w", err)
	}

	// Convert fd to net.Listener
	file := os.NewFile(uintptr(fd), "vsock")
	listener, err := net.FileListener(file)
	if err != nil {
		file.Close()
		return nil, fmt.Errorf("failed to create listener from fd: %w", err)
	}
	file.Close() // FileListener duplicates the fd, so we can close the original

	return listener, nil
}

func main() {
	flag.Parse()

	log.Println("Starting Arca Network Control API server...")

	// Initialize the network server
	networkServer := NewNetworkServer()

	// Create gRPC server
	grpcServer := grpc.NewServer(
		grpc.ConnectionTimeout(time.Second * 10),
	)

	// Register services
	pb.RegisterNetworkControlServer(grpcServer, networkServer)

	// Register health check service
	healthServer := health.NewServer()
	grpc_health_v1.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)

	// Setup graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Println("Received shutdown signal, stopping server...")
		grpcServer.GracefulStop()
	}()

	// Listen on vsock
	listener, err := createVsockListener(uint32(*vsockPort))
	if err != nil {
		log.Fatalf("Failed to listen on vsock port %d: %v", *vsockPort, err)
	}
	defer listener.Close()

	log.Printf("Server listening on vsock port %d", *vsockPort)

	if err := grpcServer.Serve(listener); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}

	log.Println("Server stopped")
}
