package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	pb "github.com/Liquescent-Development/arca/helpervm/router-service/proto"
	"google.golang.org/grpc"
)

func main() {
	port := flag.Int("port", 50052, "gRPC server port")
	flag.Parse()

	// Create gRPC server
	grpcServer := grpc.NewServer()

	// Create and register router service
	routerServer := NewRouterServer()
	pb.RegisterRouterServiceServer(grpcServer, routerServer)

	// Listen on TCP port
	listenAddr := fmt.Sprintf("0.0.0.0:%d", *port)
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("Failed to listen on %s: %v", listenAddr, err)
	}

	log.Printf("Router service listening on %s", listenAddr)

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
