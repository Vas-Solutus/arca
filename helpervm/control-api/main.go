package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"

	pb "arca-network-api/proto"
)

var (
	port = flag.String("port", ":9999", "TCP port to listen on")
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
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Println("Received shutdown signal, stopping server...")
		grpcServer.GracefulStop()
		cancel()
	}()

	// Listen on TCP
	// Note: grpc-swift does not support vsock transport, so we use TCP localhost
	listener, err := net.Listen("tcp", *port)
	if err != nil {
		log.Fatalf("Failed to listen on TCP port %s: %v", *port, err)
	}
	defer listener.Close()

	log.Printf("Server listening on TCP %s", *port)

	if err := grpcServer.Serve(listener); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}

	log.Println("Server stopped")
}
