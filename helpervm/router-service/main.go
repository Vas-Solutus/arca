package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mdlayher/vsock"
	pb "github.com/Liquescent-Development/arca/helpervm/router-service/proto"
	"google.golang.org/grpc"
)

func main() {
	vsockPort := flag.Uint("vsock-port", 50052, "vsock port to listen on")
	flag.Parse()

	log.Println("Starting Arca Router Service...")

	// Create gRPC server
	grpcServer := grpc.NewServer()

	// Create and register router service
	routerServer := NewRouterServer()
	pb.RegisterRouterServiceServer(grpcServer, routerServer)

	// Listen on vsock using mdlayher/vsock library
	listener, err := vsock.Listen(uint32(*vsockPort), nil)
	if err != nil {
		log.Fatalf("Failed to listen on vsock port %d: %v", *vsockPort, err)
	}
	defer listener.Close()

	log.Printf("Router service listening on vsock port %d", *vsockPort)

	// Handle graceful shutdown
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

	// Start serving
	if err := grpcServer.Serve(listener); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}

	<-ctx.Done()
	log.Println("Router service stopped")
}
