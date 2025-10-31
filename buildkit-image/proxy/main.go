package main

import (
	"io"
	"log"
	"net"
	"sync"

	"github.com/mdlayher/vsock"
)

func main() {
	vsockPort := uint32(8088)
	tcpAddr := "127.0.0.1:8088"

	// Listen on vsock using mdlayher/vsock library
	// This provides a proper net.Listener implementation for vsock
	listener, err := vsock.Listen(vsockPort, nil)
	if err != nil {
		log.Fatalf("Failed to listen on vsock port %d: %v", vsockPort, err)
	}
	defer listener.Close()

	log.Printf("Starting vsock-to-TCP proxy: vsock:%d -> %s", vsockPort, tcpAddr)

	for {
		vsockConn, err := listener.Accept()
		if err != nil {
			log.Printf("Failed to accept vsock connection: %v", err)
			continue
		}

		log.Printf("Accepted vsock connection from %s", vsockConn.RemoteAddr())
		go handleConnection(vsockConn, tcpAddr)
	}
}

func handleConnection(vsockConn net.Conn, tcpAddr string) {
	defer vsockConn.Close()

	tcpConn, err := net.Dial("tcp", tcpAddr)
	if err != nil {
		log.Printf("Failed to connect to TCP %s: %v", tcpAddr, err)
		return
	}
	defer tcpConn.Close()

	log.Printf("Proxying connection: %s <-> %s", vsockConn.RemoteAddr(), tcpAddr)

	// Bidirectional copy
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		io.Copy(tcpConn, vsockConn)
		tcpConn.(*net.TCPConn).CloseWrite()
	}()

	go func() {
		defer wg.Done()
		io.Copy(vsockConn, tcpConn)
	}()

	wg.Wait()
	log.Printf("Connection closed: %s", vsockConn.RemoteAddr())
}
