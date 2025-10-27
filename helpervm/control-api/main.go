package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mdlayher/vsock"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"

	pb "arca-network-api/proto"
)

var (
	vsockPort = flag.Uint("vsock-port", 9999, "vsock port to listen on")
	tcpPort   = flag.Uint("tcp-port", 9999, "TCP port to listen on for container connections")
)

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

	// Listen on vsock using mdlayher/vsock library
	// This provides a proper net.Listener implementation for vsock
	listener, err := vsock.Listen(uint32(*vsockPort), nil)
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
