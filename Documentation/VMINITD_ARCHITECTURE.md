# vminitd Init System Architecture Analysis

## Overview

vminitd is Apple's init system (PID 1) that runs inside Linux VMs managed by the Containerization framework. It serves as a gRPC server that handles container and process lifecycle management.

## 1. How vminitd Starts Processes on Boot

### Entry Point and Initialization

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/Application.swift`

```swift
@main
struct Application {
    static func main() async throws {
        // ... initialization code ...
        let eg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = Initd(log: log, group: eg)
        
        try await server.serve(port: vsockPort)  // Vsock port 1024
    }
}
```

**Key Points**:
1. vminitd runs as PID 1 in the container's Linux VM
2. On startup, it mounts critical filesystems: `/proc`, `/run`, `/sys`
3. Initializes a gRPC server on vsock port 1024 for remote procedure calls
4. Uses Swift concurrency (async/await) for all operations

### Process Supervisor Architecture

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/ProcessSupervisor.swift`

```swift
actor ProcessSupervisor {
    private var processes = [ManagedProcess]()
    private let source: DispatchSourceSignal  // SIGCHLD signal handling
    
    func start(process: ManagedProcess) throws -> Int32 {
        self.processes.append(process)
        return try process.start()
    }
}
```

**Key Points**:
1. Singleton `ProcessSupervisor` manages all processes
2. Uses POSIX signals (SIGCHLD) to detect process exits
3. Automatically reaps zombie processes via `waitpid()` 
4. Notifies waiters when processes exit (via Swift Continuations)

## 2. Container Creation and Init Process Start

### Container Creation Flow

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/Server+GRPC.swift:421-513`

```swift
func createProcess(
    request: Com_Apple_Containerization_Sandbox_V3_CreateProcessRequest,
    context: GRPC.GRPCAsyncServerCallContext
) async throws -> Com_Apple_Containerization_Sandbox_V3_CreateProcessResponse {
    // Decode the OCI runtime spec
    var ociSpec = try JSONDecoder().decode(
        ContainerizationOCI.Spec.self,
        from: request.configuration
    )
    
    // Apply alterations (user mapping, environment variables, etc.)
    try ociAlterations(id: request.id, ociSpec: &ociSpec)
    
    // For new containers (not execs), create ManagedContainer
    let ctr = try ManagedContainer(
        id: request.id,
        stdio: stdioPorts,
        spec: ociSpec,
        log: self.log
    )
    try await self.state.add(container: ctr)
}
```

### ManagedContainer and Init Process

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/ManagedContainer.swift:37-84`

```swift
actor ManagedContainer {
    let id: String
    let initProcess: ManagedProcess
    
    init(
        id: String,
        stdio: HostStdio,
        spec: ContainerizationOCI.Spec,
        log: Logger
    ) throws {
        // Create OCI bundle from spec
        let bundle = try ContainerizationOCI.Bundle.create(
            path: Self.craftBundlePath(id: id),
            spec: spec
        )
        
        // Create cgroup
        let cgManager = Cgroup2Manager(...)
        try cgManager.create()
        
        // Create init process from OCI spec
        let initProcess = try ManagedProcess(
            id: id,
            stdio: stdio,
            bundle: bundle,
            cgroupManager: cgManager,
            owningPid: nil,  // nil for init, set for exec processes
            log: log
        )
        
        self.initProcess = initProcess
    }
}
```

### Start Process

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/Server+GRPC.swift:571-608`

```swift
func startProcess(
    request: Com_Apple_Containerization_Sandbox_V3_StartProcessRequest,
    context: GRPCAsyncServerCallContext
) async throws -> Com_Apple_Containerization_Sandbox_V3_StartProcessResponse {
    let ctr = try await self.state.get(container: request.containerID)
    let pid = try await ctr.start(execID: request.id)  // execID == containerID for init
    
    return .with { $0.pid = pid }
}
```

**In ManagedContainer**:
```swift
func start(execID: String) async throws -> Int32 {
    let proc = try self.getExecOrInit(execID: execID)
    return try await ProcessSupervisor.default.start(process: proc)
}
```

The init process is started via `vmexec` binary which actually executes the container process.

## 3. Process Configuration and Environment

### OCI Runtime Spec Structure

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/Sources/ContainerizationOCI/Spec.swift:21-123`

The OCI spec contains all process configuration:

```swift
public struct Spec: Codable, Sendable {
    public var process: Process?
    // ... other fields
}

public struct Process: Codable, Sendable {
    public var args: [String]           // Command + arguments
    public var env: [String]            // Environment variables
    public var cwd: String              // Working directory
    public var terminal: Bool           // TTY allocation
    public var user: User               // UID/GID
    // ... capabilities, rlimits, etc.
}
```

### OCI Alterations (Post-Processing)

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/Server+GRPC.swift:1100-1155`

```swift
func ociAlterations(id: String, ociSpec: inout ContainerizationOCI.Spec) throws {
    guard var process = ociSpec.process else { throw ... }
    
    // 1. Set default cgroup path
    if ociSpec.linux!.cgroupsPath.isEmpty {
        ociSpec.linux!.cgroupsPath = "/container/\(id)"
    }
    
    // 2. Set default working directory
    if process.cwd.isEmpty {
        process.cwd = "/"
    }
    
    // 3. Resolve username/groups from container's /etc/passwd and /etc/group
    let username = process.user.username.isEmpty 
        ? "\(process.user.uid):\(process.user.gid)" 
        : process.user.username
    let parsedUser = try User.getExecUser(
        userString: username,
        passwdPath: ...,
        groupPath: ...
    )
    process.user.uid = parsedUser.uid
    process.user.gid = parsedUser.gid
    
    // 4. Set HOME if not present
    if !process.env.contains(where: { $0.hasPrefix("HOME=") }) {
        process.env.append("HOME=\(parsedUser.home)")
    }
    
    // 5. Set TERM if terminal requested
    if process.terminal && !process.env.contains(where: { $0.hasPrefix("TERM=") }) {
        process.env.append("TERM=xterm")
    }
    
    ociSpec.process = process
}
```

## 4. Process Startup Mechanism

### ManagedProcess Execution

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/ManagedProcess.swift:154-250`

```swift
final class ManagedProcess: Sendable {
    private let process: Command
    
    func start() throws -> Int32 {
        // 1. Construct command: /sbin/vmexec run --bundle-path <path>
        var process = Command(
            "/sbin/vmexec",
            arguments: ["run", "--bundle-path", bundle.path.path],
            extraFiles: [syncPipe.fileHandleForWriting, ackPipe.fileHandleForReading]
        )
        
        // 2. Setup IO (stdin/stdout/stderr or PTY)
        try io.start(process: &process)
        
        // 3. Fork and exec vmexec
        try process.start()
        
        // 4. Read PID from sync pipe
        let piddata = try syncPipe.fileHandleForReading.read(upToCount: size)
        let pid = piddata.withUnsafeBytes { ptr in ptr.load(as: Int32.self) }
        
        // 5. Acknowledge PID
        try ackPipe.fileHandleForWriting.write(contentsOf: Self.ackPid.data(using: .utf8)!)
        
        // 6. If terminal, wait for PTY FD and attach
        if terminal {
            let ptyFd = try syncPipe.fileHandleForReading.read(upToCount: size)
            try io.attach(pid: pid, fd: ...)
            try ackPipe.fileHandleForWriting.write(contentsOf: Self.ackConsole.data(using: .utf8)!)
        }
        
        return pid
    }
}
```

## 5. Does vminitd Have Auto-Start Mechanisms?

**NO - vminitd does NOT have built-in auto-start service mechanisms.**

Key findings:
1. **No init.d or systemd**: vminitd is NOT a traditional init system (like systemd, runit, or OpenRC)
2. **No service files**: No support for reading `/etc/init.d`, `/etc/systemd/system`, or equivalent
3. **No daemon respawn**: No automatic restart of crashed daemons
4. **No boot scripts**: No `/etc/rc*.d` or similar boot sequence support
5. **Request-based only**: All process execution is triggered by gRPC requests from the host

## 6. Configuration and Customization Points

### Input: OCI Runtime Spec

The ONLY way to configure container startup is via the OCI runtime spec passed to `createProcess()`:

```json
{
  "process": {
    "args": ["/bin/sh"],
    "env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "CUSTOM_VAR=custom_value"
    ],
    "cwd": "/",
    "user": {
      "uid": 0,
      "gid": 0
    },
    "terminal": false
  }
}
```

### Environment Variables

**Supported through OCI spec `process.env`**:

```swift
// In ociAlterations, environment variables are:
// 1. Passed through as-is from the spec
// 2. Augmented with HOME (if missing)
// 3. Augmented with TERM (if terminal requested)

process.env.append("HOME=\(parsedUser.home)")
if process.terminal {
    process.env.append("TERM=xterm")
}
```

## 7. Hook and Extension Points for Background Services

### Available Mechanisms

#### 1. **Command in args**
Pass a background service launcher as the container process:

```json
{
  "process": {
    "args": ["/usr/bin/service-launcher", "arca-tap-forwarder"],
    "env": [...],
  }
}
```

#### 2. **Exec API for Background Processes**
After container starts, launch additional processes via `createProcess()` with `owningPid` set to init PID:

```swift
// In createProcess() with container already running
if let container = await self.state.containers[request.containerID] {
    try await container.createExec(
        id: request.id,
        stdio: stdioPorts,
        process: process
    )
    // Then call startProcess() to execute it
}
```

#### 3. **Custom Init in Container**
Include a custom init script in the container rootfs that:
- Starts arca-tap-forwarder in background
- Then execs to the main container process

```bash
#!/bin/sh
# Start forwarder in background
/usr/local/bin/arca-tap-forwarder &

# Exec main process (PID 1 becomes main process)
exec "$@"
```

#### 4. **Vsock Proxy API**
Leverage vminitd's built-in vsock proxy capability for network services:

**File**: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/vminitd/Server+GRPC.swift:155-193`

```swift
func proxyVsock(
    request: Com_Apple_Containerization_Sandbox_V3_ProxyVsockRequest,
    context: GRPC.GRPCAsyncServerCallContext
) async throws -> Com_Apple_Containerization_Sandbox_V3_ProxyVsockResponse {
    let proxy = VsockProxy(
        id: request.id,
        action: request.action == .into ? .dial : .listen,
        port: request.vsockPort,
        path: URL(fileURLWithPath: request.guestPath),
        udsPerms: request.guestSocketPermissions,
        log: log
    )
    try await proxy.start()
    try await state.add(proxy: proxy)
}
```

This allows proxying between vsock ports and Unix domain sockets.

## 8. Process Termination and Cleanup

### Signal Handling

```swift
func kill(signal: Int32) throws {
    guard Foundation.kill(pid, signal) == 0 else {
        throw POSIXError.fromErrno()
    }
}
```

Common signals:
- SIGTERM (15): Graceful shutdown
- SIGKILL (9): Forced termination
- SIGCHLD: Automatic zombie reaping via ProcessSupervisor

### Container Deletion

```swift
func delete() throws {
    try self.bundle.delete()
    try self.cgroupManager.delete(force: true)
}
```

## 9. Key Implementation Files

| File | Purpose |
|------|---------|
| `Application.swift` | Entry point, system initialization |
| `Server.swift` | gRPC server setup |
| `Server+GRPC.swift` | gRPC handler implementations |
| `Initd.swift` | Container/process state management |
| `ProcessSupervisor.swift` | Signal handling, zombie reaping |
| `ManagedContainer.swift` | Container lifecycle |
| `ManagedProcess.swift` | Process execution via vmexec |
| `Spec.swift` | OCI runtime spec structures |

## Summary: Best Approaches for arca-tap-forwarder Auto-Start

### Option 1: Custom Init Wrapper (RECOMMENDED)
Create a shell script wrapper that:
1. Launches arca-tap-forwarder in background
2. Execs to the container's actual process

Place in container image and set as entrypoint.

### Option 2: Modify Container spec at Creation Time
When Arca creates the container, inject startup commands:
- Prepend to `process.args` to run forwarder setup before main process
- OR add forwarder to `process.env` with special handling

### Option 3: Use Exec API
After container starts, call Exec API to launch forwarder:
- Container runs normally
- Host calls gRPC `createProcess()` with new process spec
- Runs forwarder in background alongside main process

### Option 4: Leverage vsock Proxying
Use vminitd's built-in `proxyVsock()` to:
- Proxy a vsock port to a Unix socket
- Run forwarder listening on that socket

**Conclusion**: vminitd is **NOT a traditional service init system**. It's a minimal process manager that responds to gRPC requests. To auto-start background services, you must either:
1. Embed them in the container's init process
2. Launch them via the Exec API after container starts
3. Pass them as the container's main process with proper signal forwarding
