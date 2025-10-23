# vminitd Documentation Index

This directory contains comprehensive documentation about Apple's vminitd init system, which runs as PID 1 inside Arca container VMs.

## Documents Overview

### 1. [VMINITD_QUICK_REFERENCE.md](VMINITD_QUICK_REFERENCE.md) - START HERE
**When**: Need quick answers or API reference during development
**Content**: 
- TL;DR summary
- Architecture diagram
- Container startup flow
- gRPC API method signatures
- Common operations with examples
- Key files and line numbers

**Best for**: Quick lookup, developer reference

### 2. [VMINITD_EXPLORATION_SUMMARY.txt](VMINITD_EXPLORATION_SUMMARY.txt)
**When**: Want executive summary of research findings
**Content**:
- Answer to Question 1: How does vminitd start processes?
- Answer to Question 2: Does it have auto-start mechanisms?
- Answer to Question 3: Configuration files or environment variables?
- Answer to Question 4: Main process vs background services?
- Answer to Question 5: Hooks/extension points?
- Architecture summary
- Recommendations for arca-tap-forwarder

**Best for**: Understanding research findings, decision-making

### 3. [VMINITD_ARCHITECTURE.md](VMINITD_ARCHITECTURE.md)
**When**: Need complete deep-dive into design and implementation
**Content**:
- Full entry point and initialization details
- Process supervisor architecture with code
- Container creation and init process flow
- Process configuration and OCI spec structure
- OCI alterations (post-processing)
- Process startup mechanism via vmexec
- Auto-start mechanism analysis
- Configuration and customization points
- Hook and extension points for services
- Process termination and cleanup
- Key implementation files table

**Best for**: Understanding internals, architecture decisions, code navigation

## Key Findings Summary

### What is vminitd?

vminitd is **NOT a traditional init system** like systemd, runit, or OpenRC.

Instead, it's a **gRPC-based process manager** that:
- Runs as PID 1 inside Linux container VMs
- Responds to gRPC requests from Arca daemon (host)
- Manages container and process lifecycle
- Uses POSIX signals for process supervision
- Executes processes via `vmexec` binary

### Architecture

```
Arca Daemon (macOS)
        ↓ (gRPC over vsock port 1024)
vminitd (PID 1 in Linux VM)
    ├─ ProcessSupervisor (SIGCHLD handler)
    ├─ Container State (tracks containers/execs)
    └─ gRPC API Handlers
```

### Does it auto-start services?

**NO**. vminitd has:
- ✗ No /etc/init.d support
- ✗ No systemd/OpenRC support
- ✗ No configuration files it reads
- ✗ No boot scripts
- ✗ No daemon respawn

Everything is request-driven via gRPC from Arca.

### Configuration mechanism?

**OCI Runtime Spec only** - passed as JSON in gRPC requests.

```json
{
  "process": {
    "args": ["/bin/sh"],
    "env": ["VAR=value"],
    "cwd": "/",
    "user": { "uid": 0, "gid": 0 },
    "terminal": false
  }
}
```

Post-processing (ociAlterations) adds:
- HOME environment variable (if missing)
- TERM environment variable (if terminal requested)
- Default cgroup path
- Default working directory

### How to start background services?

**Option 1: Custom Init Wrapper** (RECOMMENDED)
- Create shell script in container image
- Script launches background service, then execs main process
- No code changes needed anywhere

**Option 2: Exec API**
- Start container normally
- Arca calls createProcess() with forwarder spec
- Runs as background process alongside main process

**Option 3: Modify Container Spec**
- Arca prepends forwarder to process.args
- Forwarder starts, execs to real process
- Requires Arca code changes

**Option 4: Vsock Proxy**
- Use proxyVsock() API for network proxying
- Run forwarder listening on proxied socket

## Important Code References

### Process Creation Flow
- `createProcess()`: `/vminitd/Sources/vminitd/Server+GRPC.swift` (lines 421-513)
- `startProcess()`: `/vminitd/Sources/vminitd/Server+GRPC.swift` (lines 571-608)
- `ociAlterations()`: `/vminitd/Sources/vminitd/Server+GRPC.swift` (lines 1100-1155)

### Core Components
- `Application.swift` (lines 69-122): Entry point
- `Server.swift` (lines 89-119): gRPC server setup
- `ProcessSupervisor.swift` (lines 21-113): Signal handling
- `ManagedContainer.swift` (lines 37-84): Container lifecycle
- `ManagedProcess.swift` (lines 154-250): Process execution

### OCI Configuration
- `Spec.swift` (lines 21-123): OCI runtime spec structures
- `Process` struct: Contains args, env, cwd, user, terminal, etc.

## For arca-tap-forwarder Implementation

**Recommended approach**: Custom init wrapper in container image

1. Create `/usr/local/bin/init-wrapper`:
   ```bash
   #!/bin/sh
   /usr/local/bin/arca-tap-forwarder &
   exec "$@"
   ```

2. Set as container entrypoint:
   ```dockerfile
   ENTRYPOINT ["/usr/local/bin/init-wrapper"]
   ```

3. Pass main command as CMD/args normally

**Benefits**:
- Works with any container
- No vminitd changes needed
- No Arca changes needed
- Forwarder in same namespace as container
- Auto-cleanup when container stops
- Compatible with OCI spec flow

## gRPC API Summary

### Core Methods
- `createProcess()` - Create container or exec process
- `startProcess()` - Start process via vmexec
- `killProcess()` - Send signal to process
- `deleteProcess()` - Cleanup container/exec
- `waitProcess()` - Wait for process exit

### Network/System Methods
- `proxyVsock()` - Setup vsock ↔ Unix socket proxy
- `mount()` / `umount()` - Manage filesystem mounts
- `sysctl()` - Configure kernel parameters
- `mkdir()` / `writeFile()` - File operations
- `ipLinkSet()` / `ipAddrAdd()` - Network configuration

## Container vs Exec

**Container (Init Process)**:
- ID matches container ID
- Runs as PID 1
- Death triggers VM shutdown
- All execs are children

**Exec (Child Process)**:
- Different ID than container
- Child of init process
- Can be signaled independently
- Dies with init

## Process Termination

- Exec processes: Can be individually signaled
- Init process: When it dies, VM shuts down, all children killed
- Automatic cleanup: ProcessSupervisor reaps zombies via SIGCHLD

## Environment Variables

Sourced from OCI spec `process.env`:
- Passed through as-is
- vminitd adds `HOME` (if missing)
- vminitd adds `TERM=xterm` (if terminal requested)

## IO Handling

IO is handled via vsock ports, not shared memory:
- stdin: vsock port
- stdout: vsock port  
- stderr: vsock port
- PTY: Supported for interactive processes

## Bundle Directory Structure

```
/run/container/{containerID}/
├── config.json        // OCI runtime config
├── rootfs/            // Container filesystem
└── execs/
    ├── exec-1/
    │   └── process.json
    └── exec-2/
        └── process.json
```

## Error Handling

gRPC error codes:
- `INVALID_ARGUMENT` - Bad OCI spec
- `NOT_FOUND` - Container/exec not found
- `ALREADY_EXISTS` - Container/exec already exists
- `INTERNAL_ERROR` - System call failures
- `UNAVAILABLE` - vsock not available

## Technical Details

- **Language**: Swift 6.2+
- **Concurrency**: 100% async/await
- **RPC**: gRPC with Protocol Buffers
- **Transport**: vsock (virtual sockets)
- **Signal handling**: POSIX signals, epoll
- **Cgroups**: cgroup v2 for resource management
- **Filesystem**: OCI bundle format

## Source Code Location

All vminitd source: `/Users/kiener/code/arca/.build/checkouts/containerization/vminitd/Sources/`

Main components:
- `vminitd/` - Container management and gRPC API
- `vmexec/` - Process execution tool
- `Cgroup/` - cgroup v2 management

## References

- [OCI Runtime Specification](https://github.com/opencontainers/runtime-spec)
- [Apple Containerization Framework](https://github.com/apple/swift-containerization)
- [vsock Documentation](https://man7.org/linux/man-pages/man7/vsock.7.html)
- [cgroup v2 Documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)

---

**Last Updated**: October 23, 2025
**Exploration Method**: Code analysis of vminitd sources
**Key Finding**: vminitd is a minimal gRPC process manager, not a traditional init system
