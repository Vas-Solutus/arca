# Router Service

A gRPC service that runs in the Arca helper VM to manage VLAN interfaces, routing, NAT, DNS, and port forwarding for Docker bridge networks.

## Purpose

This service enables Arca to implement Docker's bridge network driver using VLANs for network isolation while achieving native vmnet performance (5-10x faster than TAP-over-vsock).

## Features

- **CreateVLAN**: Create VLAN subinterfaces (e.g., `eth0.100` from `eth0`)
- **DeleteVLAN**: Remove VLAN subinterfaces and cleanup NAT/DNS
- **ConfigureNAT**: Set up MASQUERADE rules for outbound connectivity
- **RemoveNAT**: Remove NAT configuration
- **ConfigureDNS**: Configure dnsmasq for container name resolution
- **AddPortMapping**: Add DNAT rules for port forwarding (host → container)
- **RemovePortMapping**: Remove port forwarding rules
- **ListVLANs**: List all VLAN interfaces with status
- **GetHealth**: Service health check with uptime and metrics

## Architecture

The router service runs in the helper VM and provides:
1. VLAN interface management via netlink
2. NAT/DNAT via iptables for connectivity and port forwarding
3. DNS resolution via dnsmasq with per-network configuration
4. gRPC API over vsock (port 50052)

See `Documentation/VLAN_ROUTER_ARCHITECTURE.md` for complete architecture details.

## Implementation

- Uses `vishvananda/netlink` for direct kernel netlink communication
- Uses `os/exec` for iptables and dnsmasq management
- No external dependencies required in helper VM beyond iptables and dnsmasq
- gRPC service accessible via vsock from Arca daemon

## Building

```bash
# Generate protobuf code (if proto file changes)
protoc --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       proto/router.proto

# Build for Linux ARM64 (cross-compile from macOS)
./build.sh
```

## Usage

The service runs in the helper VM and listens on vsock port 50052.

From Arca daemon:
```swift
try await helperVM.dial(port: 50052) { connection in
    let client = RouterServiceClient(connection)
    try await client.createVLAN(
        vlanID: 100,
        subnet: "172.18.0.0/16",
        gateway: "172.18.0.1",
        networkName: "my-bridge",
        enableNAT: true
    )
}
```

## Protocol Buffer Definition

See `proto/router.proto` for the complete gRPC service definition.

## Dependencies

- Go 1.24+
- github.com/mdlayher/vsock v1.2.1
- github.com/vishvananda/netlink v1.3.1
- google.golang.org/grpc v1.76.0
- google.golang.org/protobuf v1.36.10

## Integration with Helper VM

The router service is started by the helper VM startup script alongside OVS/OVN services:

```bash
# In helper VM startup.sh
/usr/local/bin/router-service --vsock-port 50052 &
```

The service requires:
- `iptables` for NAT/DNAT rules
- `dnsmasq` for DNS resolution
- `/etc/dnsmasq.d/` directory for per-network configs
- Root privileges for netlink and iptables operations
