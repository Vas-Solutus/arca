# vminitd Quick Reference Guide

## The TL;DR

**vminitd is NOT a traditional init system.** It's a gRPC-based process manager running as PID 1 inside container VMs.

- ✅ Starts when VM boots
- ✅ Responds to gRPC requests from Arca daemon (host)
- ✅ Executes processes via `vmexec` binary
- ✅ Handles process lifecycle (signal, reap, cleanup)
- ❌ Does NOT auto-start services
- ❌ Does NOT read configuration files
- ❌ Does NOT have init.d/systemd support
- ❌ Does NOT respawn crashed daemons

## Architecture at a Glance

```
Arca (macOS host)
    ↓ gRPC over vsock
vminitd (Linux VM PID 1)
    ├─ ProcessSupervisor (SIGCHLD handler)
    ├─ Container State (tracks containers/execs)
    └─ gRPC API Handlers
```

## Container Startup Flow

1. **Arca calls `createProcess()` gRPC**
   - Sends OCI runtime spec (JSON)
   - Spec includes: args, env, user, cwd, terminal

2. **vminitd processes request**
   - Creates OCI bundle directory
   - Creates cgroup
   - Instantiates `ManagedProcess`

3. **Arca calls `startProcess()` gRPC**
   - ProcessSupervisor spawns `vmexec` process
   - vmexec forks and execs actual container process
   - vminitd returns PID

4. **Container runs**
   - ProcessSupervisor listens for SIGCHLD
   - When process exits, notifies any waiters
   - Auto-reaps zombies

## Configuration Points

### OCI Runtime Spec (The Only Configuration Source)

```json
{
  "process": {
    "args": ["/bin/sh", "-c", "command"],
    "env": ["PATH=/bin:/usr/bin", "VAR=value"],
    "cwd": "/tmp",
    "user": {
      "uid": 1000,
      "gid": 1000,
      "username": "user"
    },
    "terminal": false,
    "capabilities": {},
    "rlimits": []
  }
}
```

### Post-Processing (ociAlterations)

After receiving OCI spec, vminitd automatically:
1. Resolves `username` to UID/GID via `/etc/passwd` and `/etc/group`
2. Adds `HOME=/home/user` if not present
3. Adds `TERM=xterm` if terminal requested
4. Sets default cwd to `/` if empty
5. Sets default cgroup path to `/container/{id}` if empty

## Key Files and Line Numbers

| File | Lines | Purpose |
|------|-------|---------|
| `Application.swift` | 69-122 | Entry point, gRPC server setup |
| `Server.swift` | 89-119 | gRPC server configuration |
| `Server+GRPC.swift` | 421-513 | createProcess() gRPC handler |
| `Server+GRPC.swift` | 571-608 | startProcess() gRPC handler |
| `Server+GRPC.swift` | 1100-1155 | ociAlterations() post-processing |
| `ProcessSupervisor.swift` | 21-113 | Process management, signal handling |
| `ManagedContainer.swift` | 37-84 | Container creation and init process |
| `ManagedProcess.swift` | 154-250 | vmexec execution |
| `Spec.swift` | 21-123 | OCI Runtime Spec structures |

## gRPC API Summary

### Core Lifecycle Methods

- `createProcess()` - Create container or exec process
- `startProcess()` - Start process via vmexec
- `killProcess()` - Send signal (SIGTERM, SIGKILL, etc.)
- `deleteProcess()` - Clean up container or exec
- `waitProcess()` - Wait for process exit (returns exit code)

### Container vs Exec

**Container (Init Process)**:
```
createProcess(containerID=X, id=X, config=spec)
startProcess(containerID=X, id=X)
```

**Exec (Child Process)**:
```
createProcess(containerID=X, id=Y, config=spec)  // id != containerID
startProcess(containerID=X, id=Y)
killProcess(containerID=X, id=Y, signal=SIGTERM)
deleteProcess(containerID=X, id=Y)
```

### Additional Methods

- `proxyVsock()` - Setup vsock ↔ Unix socket proxy
- `mount()` / `umount()` - Manage filesystem mounts
- `sysctl()` - Configure kernel parameters
- `mkdir()` / `writeFile()` - File operations
- `ipLinkSet()` / `ipAddrAdd()` - Network configuration

## Process Termination

When init process (PID 1) exits:
1. Linux kernel shuts down the container VM
2. All child processes are forcefully terminated
3. No graceful shutdown of child processes

Execs are children of init:
- When init dies, all execs die automatically
- Can be individually signaled before init dies

## Environment Variables

Environment variables come from **OCI spec only**:

```json
{
  "process": {
    "env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "LANG=C.UTF-8",
      "CUSTOM_VAR=value"
    ]
  }
}
```

vminitd will ADD to this list (not replace):
- `HOME=/home/{user}` (if not present and user has home in /etc/passwd)
- `TERM=xterm` (if terminal requested and not present)

## For Auto-Starting Background Services

**vminitd provides NO native mechanism.**

Options:

1. **Custom Init Wrapper (RECOMMENDED)**
   - Embed init script in container image
   - Script launches background service, then execs main process
   - No vminitd or Arca changes needed

2. **Exec API**
   - Start container normally
   - Arca calls createProcess() with forwarder spec
   - Forwarder runs as background exec process

3. **Modify Container Spec**
   - Arca prepends forwarder to process.args
   - Forwarder starts, execs to real process
   - Requires Arca code changes

## Common Operations

### Starting a Container

```go
// Host (Arca daemon) calls:
createProcess(
  containerID: "abc123",
  id: "abc123",
  config: ociSpec,
  stdin: 5000,   // vsock port for stdin
  stdout: 5001,  // vsock port for stdout
  stderr: 5002   // vsock port for stderr
)

startProcess(
  containerID: "abc123",
  id: "abc123"
)
// Returns: PID of init process
```

### Running a Command Inside Container

```go
// While container is running:
createProcess(
  containerID: "abc123",
  id: "exec-123",  // Different ID
  config: execSpec,
  owningPid: 1     // Child of init
)

startProcess(
  containerID: "abc123",
  id: "exec-123"
)
// Returns: PID of exec process
```

### Stopping Container

```go
killProcess(
  containerID: "abc123",
  id: "abc123",
  signal: 15  // SIGTERM
)

// Wait for exit:
waitProcess(
  containerID: "abc123",
  id: "abc123"
)
// Returns: exit code + timestamp

deleteProcess(
  containerID: "abc123",
  id: "abc123"
)
```

## Signal Numbers

- SIGTERM (15): Graceful shutdown
- SIGKILL (9): Forced termination
- SIGCHLD (17): Automatic zombie reaping
- SIGPIPE: Ignored globally in vminitd

## Cgroups

Container cgroups default to `/container/{containerID}`:

```swift
// In ociAlterations:
if ociSpec.linux!.cgroupsPath.isEmpty {
    ociSpec.linux!.cgroupsPath = "/container/\(id)"
}
```

Can be overridden in OCI spec's `linux.cgroupsPath`.

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

Bundles created fresh for each container.
Cleaned up when container is deleted.

## Error Handling

vminitd returns gRPC errors:
- `INVALID_ARGUMENT` - Bad OCI spec, missing fields
- `NOT_FOUND` - Container/exec not found
- `ALREADY_EXISTS` - Container/exec already exists
- `INTERNAL_ERROR` - System call failures
- `UNAVAILABLE` - vsock not available

## Useful Facts

- vminitd is 100% async (Swift concurrency)
- All gRPC methods are async functions
- IO is handled via vsock ports (not shared memory)
- stdin/stdout/stderr are separate vsock ports
- PTY is supported for interactive processes
- Process exit codes are captured and returned
- Exit timestamps are recorded in UTC

## Resources

- Full architecture: `Documentation/VMINITD_ARCHITECTURE.md`
- Source code: `.build/checkouts/containerization/vminitd/Sources/`
- OCI Runtime Spec: https://github.com/opencontainers/runtime-spec
- Containerization framework: https://github.com/apple/swift-containerization

