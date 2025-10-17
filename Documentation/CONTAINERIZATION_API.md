# Apple Containerization API Reference

## Overview

This document provides a practical reference for Apple's Containerization framework APIs that Arca will use to implement the Docker Engine API. The Containerization framework uses Swift and Apple's Virtualization.framework to run each Linux container in its own lightweight VM.

**Key Architectural Concepts:**
- Each container runs in its own lightweight VM (not shared)
- Sub-second startup times with optimized Linux kernel
- Each container gets its own dedicated IP address
- VM-level isolation for enhanced security
- Built-in DNS service for container name resolution

**Official Resources:**
- Full API Documentation: https://apple.github.io/containerization/documentation/
- Source Code: https://github.com/apple/containerization
- Example Tool (cctl): https://github.com/apple/containerization/tree/main/Sources/cctl
- Container CLI Reference: https://github.com/apple/container

---

## Package Structure

The Containerization framework consists of multiple Swift packages:

- **Containerization** - Core container runtime and VM management
- **ContainerizationOCI** - OCI image format support and registry operations
- **ContainerizationEXT4** - EXT4 filesystem creation and manipulation
- **ContainerizationNetlink** - Network configuration
- **ContainerizationOS** - OS-level utilities

---

## Core APIs for Arca

### 1. Container Lifecycle Management

#### Creating and Running Containers

```swift
import Containerization
import ContainerizationOCI

// Initialize a container manager with kernel
let kernel = Kernel(
    path: URL(fileURLWithPath: "/path/to/vmlinux"),
    platform: .linuxArm  // or .linuxX86_64
)

var manager = try await ContainerManager(
    kernel: kernel,
    initfsReference: "vminit:latest"
)

// Create container configuration
var config = ContainerConfig()
config.image = ociImage  // OCI image reference
config.command = ["/bin/sh", "-c", "echo hello"]
config.workingDirectory = "/"
config.environment = ["PATH=/usr/local/bin:/usr/bin:/bin"]

// Add mounts
let mount = Mount.share(
    source: "/host/path",
    destination: "/container/path"
)
config.mounts.append(mount)

// Create and start container
let container = try await manager.createContainer(config: config)
try await container.start()

// Wait for container to complete
let exitCode = try await container.wait()

// Stop container
try await container.stop()
```

#### Container State and Inspection

```swift
// Get container status
let status = try await container.status()
// Returns: running, stopped, paused, etc.

// Get container metadata
let metadata = try await container.metadata()
// Includes: ID, created time, image info, etc.
```

### 2. Image Management

#### Pulling Images from Registry

```swift
import ContainerizationOCI

// Create registry client
let client = RegistryClient()

// Parse image reference
let reference = try Reference.parse("docker.io/library/nginx:latest")

// Pull image with optional authentication
let auth = Authentication(
    username: "user",
    password: "pass"
)

let image = try await client.pullImage(
    reference: reference,
    authentication: auth  // Optional
)
```

#### Managing Local Images

```swift
// Initialize image store
let store = ImageStore()

// List all local images
let images = try await store.list()
// Returns array of image metadata

// Get specific image
let image = try await store.get(reference: "nginx:latest")

// Inspect image details
let manifest = try await image.manifest()
let config = try await image.config()

// Delete image
try await store.delete(reference: "nginx:latest")
```

#### Image Store Operations

```swift
// Tag an image
try await store.tag(
    source: "nginx:latest",
    target: "myapp:v1.0"
)

// Push image to registry
try await client.pushImage(
    reference: Reference.parse("registry.example.com/myapp:v1.0"),
    authentication: auth
)
```

### 3. Process Execution (Exec)

#### Running Commands in Containers

```swift
import Containerization

// Create process configuration
var processConfig = ProcessConfig()
processConfig.executable = "/bin/sh"
processConfig.arguments = ["-c", "ls -la /"]
processConfig.workingDirectory = "/"
processConfig.environment = ["TERM=xterm"]

// Spawn process in running container
let process = try await container.spawn(config: processConfig)

// Handle I/O streams
let stdout = process.stdout
let stderr = process.stderr
let stdin = process.stdin

// Wait for process to complete
let exitCode = try await process.wait()
```

#### Interactive Process (TTY)

```swift
// Configure for TTY
processConfig.tty = true
processConfig.interactive = true

// Spawn interactive process
let process = try await container.spawn(config: processConfig)

// Handle terminal resize
process.resize(width: 80, height: 24)

// Send signals
try await process.signal(.interrupt)  // SIGINT
try await process.signal(.terminate)  // SIGTERM
```

### 4. Networking

#### Container Network Configuration

```swift
// Configure networking during container creation
config.network = NetworkConfig(
    hostname: "mycontainer",
    domainname: "example.local",
    dns: ["8.8.8.8", "8.8.4.4"]
)

// Each container automatically gets:
// - Dedicated IP address
// - DNS name resolution
// - No port forwarding needed
```

#### Network Information

```swift
// Get container network details
let networkInfo = try await container.networkInfo()
// Returns: IP address, hostname, DNS servers, etc.

// Containers are accessible via DNS:
// mycontainer.example.local
// Or via their assigned IP address
```

### 5. Volume and Filesystem Management

#### Mounting Host Directories

```swift
// Mount host directory into container
let mount = Mount.share(
    source: "/Users/me/data",
    destination: "/data"
)
config.mounts.append(mount)

// Read-only mount
let roMount = Mount.share(
    source: "/Users/me/config",
    destination: "/config",
    readOnly: true
)
config.mounts.append(roMount)
```

#### Creating EXT4 Filesystems

```swift
import ContainerizationEXT4

// Create EXT4 filesystem for container root
let fsBuilder = EXT4Builder()
try await fsBuilder.create(
    at: URL(fileURLWithPath: "/path/to/rootfs.img"),
    size: 4 * 1024 * 1024 * 1024  // 4GB
)

// Populate filesystem from OCI image layers
try await fsBuilder.populate(
    from: ociImage,
    overlay: true  // Enable write overlay
)
```

### 6. Logging and Output

#### Container Logs

```swift
// Stream container logs
let logStream = try await container.logs(
    stdout: true,
    stderr: true,
    follow: true,  // Stream continuously
    timestamps: true
)

for try await logLine in logStream {
    print(logLine)
}

// Get historical logs
let logs = try await container.logs(
    stdout: true,
    stderr: true,
    tail: 100  // Last 100 lines
)
```

### 7. Container Resource Management

#### Memory and CPU Limits

```swift
// Set resource limits
config.resources = ResourceConfig(
    memory: 2 * 1024 * 1024 * 1024,  // 2GB
    cpus: 4,
    cpuShares: 1024
)
```

---

## Key Types and Structures

### ContainerConfig

```swift
struct ContainerConfig {
    var image: OCIImage
    var command: [String]
    var arguments: [String]
    var workingDirectory: String
    var environment: [String]
    var user: String?
    var mounts: [Mount]
    var network: NetworkConfig
    var resources: ResourceConfig
    var hostname: String?
}
```

### Mount

```swift
enum Mount {
    case share(source: String, destination: String, readOnly: Bool = false)
    case block(device: URL, destination: String)
    case tmpfs(destination: String, size: Int)
}
```

### NetworkConfig

```swift
struct NetworkConfig {
    var hostname: String
    var domainname: String?
    var dns: [String]
    var dnsSearch: [String]
}
```

### ProcessConfig

```swift
struct ProcessConfig {
    var executable: String
    var arguments: [String]
    var workingDirectory: String
    var environment: [String]
    var user: String?
    var tty: Bool
    var interactive: Bool
}
```

---

## Common Patterns for Docker API Translation

### Container Lifecycle: Docker → Containerization

```swift
// Docker: POST /containers/create
// -> Containerization: ContainerManager.createContainer()

// Docker: POST /containers/{id}/start
// -> Containerization: container.start()

// Docker: POST /containers/{id}/stop
// -> Containerization: container.stop()

// Docker: DELETE /containers/{id}
// -> Containerization: container.remove()
```

### Image Operations: Docker → Containerization

```swift
// Docker: POST /images/create (pull)
// -> Containerization: RegistryClient.pullImage()

// Docker: GET /images/json (list)
// -> Containerization: ImageStore.list()

// Docker: GET /images/{name}/json (inspect)
// -> Containerization: ImageStore.get() + image.manifest()

// Docker: DELETE /images/{name}
// -> Containerization: ImageStore.delete()
```

### Exec Operations: Docker → Containerization

```swift
// Docker: POST /containers/{id}/exec
// -> Containerization: container.spawn(config)

// Docker: POST /exec/{id}/start
// -> Already started by spawn, manage process object

// Docker: GET /exec/{id}/json
// -> Track process state internally
```

---

## Important Differences from Docker

### 1. **Networking Model**
- **Docker**: Bridge networks, port forwarding, network isolation
- **Containerization**: Flat network, each container gets dedicated IP and DNS name
- **Implication**: No port mapping needed, but network isolation works differently

### 2. **Volume Mounts**
- **Docker**: Various mount types, permissions managed by Docker daemon
- **Containerization**: VirtioFS with limitations (chmod/chown restrictions)
- **Implication**: Some database containers that modify volume permissions may fail

### 3. **Container ID Format**
- **Docker**: 64-character hexadecimal string
- **Containerization**: Likely UUID-based
- **Implication**: Need ID mapping layer for Docker API compatibility

### 4. **One VM Per Container**
- **Docker (on macOS)**: Shared VM for all containers
- **Containerization**: Dedicated lightweight VM per container
- **Implication**: Better isolation, slightly higher overhead per container

---

## Example: Running nginx Container

```swift
import Containerization
import ContainerizationOCI

// Initialize
let kernel = Kernel(path: kernelURL, platform: .linuxArm)
let manager = try await ContainerManager(kernel: kernel, initfsReference: "vminit:latest")

// Pull nginx image
let client = RegistryClient()
let image = try await client.pullImage(reference: try Reference.parse("nginx:latest"))

// Configure container
var config = ContainerConfig()
config.image = image
config.command = ["nginx", "-g", "daemon off;"]
config.network = NetworkConfig(hostname: "nginx-web", dns: ["8.8.8.8"])

// Create and start
let container = try await manager.createContainer(config: config)
try await container.start()

// Container is now accessible at nginx-web.test (or similar DNS name)
print("Container running at: \(try await container.networkInfo().ipAddress)")

// Graceful shutdown
try await container.stop(timeout: 10)
```

---

## Error Handling

```swift
import ContainerizationError

do {
    let container = try await manager.createContainer(config: config)
    try await container.start()
} catch let error as ContainerizationError {
    switch error.code {
    case .invalidArgument:
        print("Invalid configuration: \(error.message)")
    case .notFound:
        print("Resource not found: \(error.message)")
    case .permissionDenied:
        print("Permission error: \(error.message)")
    default:
        print("Error: \(error.message)")
    }
}
```

---

## Testing with cctl Examples

The `cctl` tool in the Containerization repo provides excellent usage examples:

- **RunCommand.swift**: Container creation and execution
- **ImageCommand.swift**: Image pull, push, list, inspect
- **LoginCommand.swift**: Registry authentication

Study these files in the Containerization repo for real-world patterns:
https://github.com/apple/containerization/tree/main/Sources/cctl

---

## Additional Resources

### Linux Kernel
Containerization requires a Linux kernel. Options:

1. **Kata Containers Kernel** (Recommended):
   ```bash
   # Download from: https://github.com/kata-containers/kata-containers/releases
   # Extract vmlinux.container
   ```

2. **Build Custom Kernel**:
   ```bash
   # See: https://github.com/apple/containerization/tree/main/kernel
   ```

### vminitd Init System

- Written entirely in Swift
- Runs as PID 1 inside each VM
- Provides gRPC API over vsock
- Handles: IP assignment, filesystem mounting, process supervision

### Authentication

```swift
// Store credentials in macOS Keychain
let keychain = KeychainHelper(id: "com.apple.container.registry")
try await keychain.store(
    username: "user",
    password: "pass",
    for: "registry.example.com"
)

// Retrieve for registry operations
let auth = try await keychain.authentication(for: "registry.example.com")
```

---

## Notes for Arca Implementation

1. **Start Simple**: Implement basic container lifecycle first (create, start, stop, remove)
2. **ID Mapping**: Create bidirectional mapping between Docker IDs and Containerization IDs
3. **State Tracking**: Maintain state for containers, processes, networks, volumes
4. **Networking Translation**: Map Docker's networking concepts to Containerization's DNS-based model
5. **Error Translation**: Convert ContainerizationError to Docker API error responses
6. **Async/Await**: All Containerization APIs are async - use Swift concurrency throughout

---

## Quick Reference: Common Operations

| Operation | Containerization API |
|-----------|---------------------|
| Create container | `ContainerManager.createContainer(config:)` |
| Start container | `container.start()` |
| Stop container | `container.stop(timeout:)` |
| Remove container | `container.remove()` |
| Pull image | `RegistryClient.pullImage(reference:authentication:)` |
| List images | `ImageStore.list()` |
| Exec in container | `container.spawn(config:)` |
| Get logs | `container.logs(stdout:stderr:follow:)` |
| Container status | `container.status()` |
| Network info | `container.networkInfo()` |

---

*This document will be updated as we discover more API patterns during Arca development.*