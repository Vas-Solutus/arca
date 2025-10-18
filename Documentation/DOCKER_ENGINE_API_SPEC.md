# Docker Engine API v1.51 - Essential Reference

## API Basics
- **Base Path**: `/v1.51`
- **Content-Type**: `application/json` (default), `application/x-tar` (archives)
- **Versioning**: Include version in URL path (e.g., `/v1.51/containers/json`)
- **Error Format**: `{"message": "error description"}`
- **HTTP Status Codes**: 200/201/204 (success), 400 (bad param), 404 (not found), 409 (conflict), 500 (server error)

## Authentication
- **Registry Auth Header**: `X-Registry-Auth` - base64url-encoded JSON: `{"username":"","password":"","serveraddress":""}`
- **Registry Config Header**: `X-Registry-Config` - base64url-encoded JSON map of registry auth configs

## Core Endpoints by Resource

### Containers
- `GET /containers/json` - List (filters: status, name, label, network, volume)
- `POST /containers/create?name={name}` - Create from ContainerConfig + HostConfig + NetworkingConfig
- `GET /containers/{id}/json?size=bool` - Inspect
- `GET /containers/{id}/top?ps_args=string` - List processes
- `GET /containers/{id}/logs?follow&stdout&stderr&timestamps&tail` - Get logs (streaming)
- `GET /containers/{id}/stats?stream=bool` - Get stats (streaming)
- `POST /containers/{id}/start` - Start (204 success, 304 already started)
- `POST /containers/{id}/stop?t=seconds&signal=SIGTERM` - Stop
- `POST /containers/{id}/restart?t=seconds` - Restart
- `POST /containers/{id}/kill?signal=SIGKILL` - Kill
- `POST /containers/{id}/pause` - Pause
- `POST /containers/{id}/unpause` - Unpause
- `POST /containers/{id}/wait?condition=not-running` - Wait (returns exit code)
- `DELETE /containers/{id}?v&force` - Remove
- `POST /containers/{id}/attach?stream&stdin&stdout&stderr` - Attach (hijacks connection)
- `GET /containers/{id}/attach/ws` - Attach websocket
- `PUT /containers/{id}/archive?path=` - Extract archive to path
- `GET /containers/{id}/archive?path=` - Get archive from path
- `POST /containers/prune?filters` - Delete stopped

### Images
- `GET /images/json?all&filters&digests&manifests` - List
- `POST /images/create?fromImage&tag&platform` - Pull/import (streaming)
- `GET /images/{name}/json?manifests=bool` - Inspect
- `GET /images/{name}/history?platform` - Get history
- `POST /images/{name}/push?tag&platform` - Push (streaming, requires X-Registry-Auth)
- `POST /images/{name}/tag?repo&tag` - Tag
- `DELETE /images/{name}?force&noprune&platforms` - Remove
- `GET /images/search?term&limit&filters` - Search Docker Hub
- `POST /images/prune?filters` - Delete unused
- `GET /images/{name}/get?platform` - Export as tarball
- `GET /images/get?names&platform` - Export multiple as tarball
- `POST /images/load?quiet&platform` - Import from tarball
- `POST /build?dockerfile&t&buildargs&platform&target` - Build image (streaming)
- `POST /build/prune?filters&all` - Delete build cache

### Networks
- `GET /networks?filters` - List
- `GET /networks/{id}?verbose&scope` - Inspect
- `POST /networks/create` - Create (body: Name, Driver, IPAM, Options, Labels)
- `POST /networks/{id}/connect` - Connect container (body: Container, EndpointConfig)
- `POST /networks/{id}/disconnect` - Disconnect container (body: Container, Force)
- `DELETE /networks/{id}` - Remove
- `POST /networks/prune?filters` - Delete unused

### Volumes
- `GET /volumes?filters` - List
- `POST /volumes/create` - Create (body: Name, Driver, DriverOpts, Labels)
- `GET /volumes/{name}` - Inspect
- `PUT /volumes/{name}?version` - Update (Swarm cluster volumes only)
- `DELETE /volumes/{name}?force` - Remove
- `POST /volumes/prune?filters` - Delete unused

### Exec
- `POST /containers/{id}/exec` - Create exec instance (body: Cmd, Env, User, WorkingDir, AttachStdin/out/err, Tty)
- `POST /exec/{id}/start` - Start exec (body: Detach, Tty) - hijacks if not detached
- `POST /exec/{id}/resize?h&w` - Resize TTY
- `GET /exec/{id}/json` - Inspect exec

### System
- `GET /info` - System info (daemon config, resources, swarm status)
- `GET /version` - Version info
- `GET /_ping` - Health check
- `POST /auth` - Validate credentials (body: AuthConfig)
- `GET /events?since&until&filters` - Monitor events (streaming)
- `GET /system/df?type` - Disk usage

### Swarm (when enabled)
- `GET /swarm` - Inspect swarm
- `POST /swarm/init` - Initialize swarm
- `POST /swarm/join` - Join swarm
- `POST /swarm/leave?force` - Leave swarm
- `POST /swarm/update?version&rotateWorkerToken&rotateManagerToken` - Update swarm

### Services (Swarm)
- `GET /services?filters&status` - List
- `POST /services/create` - Create (body: ServiceSpec)
- `GET /services/{id}?insertDefaults` - Inspect
- `POST /services/{id}/update?version` - Update
- `DELETE /services/{id}` - Delete
- `GET /services/{id}/logs?follow&stdout&stderr&timestamps&tail` - Get logs

### Tasks (Swarm)
- `GET /tasks?filters` - List
- `GET /tasks/{id}` - Inspect
- `GET /tasks/{id}/logs` - Get logs

### Nodes (Swarm)
- `GET /nodes?filters` - List
- `GET /nodes/{id}` - Inspect
- `POST /nodes/{id}/update?version` - Update
- `DELETE /nodes/{id}?force` - Delete

## Key Data Structures

### ContainerConfig
```json
{
  "Image": "string",
  "Cmd": ["string"],
  "Env": ["VAR=value"],
  "WorkingDir": "/path",
  "Entrypoint": ["string"],
  "Labels": {"key": "value"},
  "ExposedPorts": {"80/tcp": {}},
  "Volumes": {"/path": {}}
}
```

### HostConfig (container runtime config)
```json
{
  "Binds": ["volume:/path:ro"],
  "NetworkMode": "bridge|host|none|container:<id>",
  "PortBindings": {"80/tcp": [{"HostPort": "8080"}]},
  "RestartPolicy": {"Name": "always|unless-stopped|on-failure", "MaximumRetryCount": 0},
  "Mounts": [{"Type": "bind|volume|tmpfs", "Source": "", "Target": ""}],
  "Resources": {
    "Memory": 0,
    "NanoCpus": 0,
    "CpuShares": 0
  }
}
```

### NetworkingConfig
```json
{
  "EndpointsConfig": {
    "network-name": {
      "IPAMConfig": {"IPv4Address": "172.20.0.1"},
      "Aliases": ["alias"]
    }
  }
}
```

## Special Behaviors

### Connection Hijacking
Endpoints that hijack the HTTP connection for streaming I/O:
- `/containers/{id}/attach` - Interactive terminal
- `/containers/{id}/attach/ws` - WebSocket variant
- `/exec/{id}/start` - Exec interactive session

Client sends `Upgrade: tcp` / `Connection: Upgrade` headers.
Server responds with `101 UPGRADED` then raw bidirectional stream.

### Stream Multiplexing
When TTY=false, stdout/stderr are multiplexed with 8-byte headers:
```
[stream_type, 0, 0, 0, size_byte1, size_byte2, size_byte3, size_byte4][payload]
```
- stream_type: 0=stdin, 1=stdout, 2=stderr
- size: uint32 big-endian payload length

### Filters
Query param format: JSON-encoded `map[string][]string`
Example: `?filters={"status":["running"],"label":["key=value"]}`

### Common Filters
- **Containers**: status, name, id, label, network, volume, ancestor
- **Images**: dangling, label, before, since, reference
- **Volumes**: dangling, label, driver, name
- **Networks**: dangling, driver, id, label, name, scope, type

## Critical Notes
1. **Never use localStorage/sessionStorage** - Not supported in Claude artifacts
2. **Version param required** for update operations (optimistic locking)
3. **Registry auth** required for push/pull operations
4. **Platform selection** uses JSON: `{"os":"linux","architecture":"amd64"}`
5. **Streaming endpoints** return `Content-Type: application/vnd.docker.raw-stream`
6. **Container names** must match: `/?[a-zA-Z0-9][a-zA-Z0-9_.-]+`
7. **Image references**: `name[:tag]` or `name@digest`