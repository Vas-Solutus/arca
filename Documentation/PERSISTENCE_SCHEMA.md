# Arca Persistence Schema

This document defines the SQLite database schema used for persisting container and network state across daemon restarts.

## Why SQLite?

- **Atomic transactions**: All state changes are atomic
- **Query flexibility**: Easy to query containers by label, network, state, etc.
- **Performance**: Faster than parsing dozens of JSON files
- **Data integrity**: Foreign keys, constraints, triggers
- **Standard format**: Well-understood, mature, battle-tested
- **Single file**: `~/.arca/state.db` - easy to backup/restore
- **Better than JSON**: No need to parse entire file to update one field

## What Gets Persisted?

### Managed by Arca (SQLite)
- ✅ Container metadata and state
- ✅ Network metadata and state
- ✅ Network attachments (which containers on which networks)
- ✅ Subnet allocation state

### Managed by Apple Containerization Framework
- ✅ **Images**: `ImageStore` handles OCI image persistence automatically
  - Default location: System-managed
  - We just call `ImageStore.default` or `ImageStore(path:)`
  - Images persist across daemon restarts automatically
  - No action needed from us

### Managed by OVN (in Control Plane VM)
- ✅ **OVN network config**: Persisted in `/etc/ovn/ovnnb_db.db` (ovsdb format)
  - Logical switches, DHCP options, DNS records
  - Mounted as volume: `~/.arca/control-plane/ovn-data` → `/etc/ovn`
  - OVN is source of truth for network configuration
  - We reconcile our metadata with OVN on startup

### Not Persisted (Ephemeral)
- ❌ Container logs - remain in `~/.arca/containers/{id}/logs/` (not in DB)
- ❌ Temporary exec sessions - recreated on demand

## Directory Structure

```
~/.arca/
├── state.db                      # SQLite database (containers + networks)
├── control-plane/
│   └── ovn-data/                 # OVN database (mounted as volume in control plane)
│       ├── ovnnb_db.db           # OVN northbound database
│       └── ovnsb_db.db           # OVN southbound database
└── containers/
    └── {container-id}/
        └── logs/                 # Container logs (stdout/stderr)

Note: Images stored by ImageStore (location managed by Apple's framework)
```

## Database Schema

**File**: `~/.arca/state.db`

### Table: schema_version

Tracks schema version for migrations.

```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO schema_version (version) VALUES (1);
```

### Table: containers

Stores all container configuration and state.

```sql
CREATE TABLE containers (
    id TEXT PRIMARY KEY,                    -- 64-char Docker ID
    name TEXT UNIQUE NOT NULL,              -- Container name (unique)
    image TEXT NOT NULL,                    -- Image reference (nginx:latest)
    image_id TEXT NOT NULL,                 -- Image digest (sha256:...)
    created_at TEXT NOT NULL,               -- ISO 8601 timestamp

    -- State
    status TEXT NOT NULL DEFAULT 'created', -- created|running|exited|dead
    running INTEGER NOT NULL DEFAULT 0,     -- Boolean (0/1)
    paused INTEGER NOT NULL DEFAULT 0,      -- Boolean
    restarting INTEGER NOT NULL DEFAULT 0,  -- Boolean
    pid INTEGER DEFAULT 0,                  -- Process ID (always 1 in VM)
    exit_code INTEGER DEFAULT 0,            -- Exit code from last run
    started_at TEXT,                        -- ISO 8601 timestamp (null if never started)
    finished_at TEXT,                       -- ISO 8601 timestamp (null if running)
    stopped_by_user INTEGER NOT NULL DEFAULT 0, -- Boolean: true if user stopped

    -- Runtime config (JSON blobs for flexibility)
    config_json TEXT NOT NULL,              -- JSON: env, cmd, workingDir, labels, etc.
    host_config_json TEXT NOT NULL,         -- JSON: restart policy, volumes, ports, etc.

    CHECK (status IN ('created', 'running', 'paused', 'restarting', 'exited', 'dead'))
);

CREATE INDEX idx_containers_name ON containers(name);
CREATE INDEX idx_containers_status ON containers(status);
CREATE INDEX idx_containers_image ON containers(image);
CREATE INDEX idx_containers_running ON containers(running);
```

**config_json structure**:
```json
{
  "hostname": "my-container",
  "user": "",
  "env": ["PATH=/usr/bin", "MY_VAR=value"],
  "cmd": ["/bin/sh", "-c", "nginx"],
  "workingDir": "/app",
  "entrypoint": null,
  "labels": {
    "com.example.version": "1.0",
    "com.arca.internal": "true"
  }
}
```

**host_config_json structure**:
```json
{
  "restartPolicy": {
    "name": "always",
    "maximumRetryCount": 0
  },
  "networkMode": "bridge",
  "volumeMounts": [
    {
      "type": "bind",
      "source": "/host/path",
      "destination": "/container/path",
      "readOnly": false
    }
  ]
}
```

### Table: networks

Stores all network configuration.

```sql
CREATE TABLE networks (
    id TEXT PRIMARY KEY,                    -- 64-char network ID
    name TEXT UNIQUE NOT NULL,              -- Network name (unique)
    driver TEXT NOT NULL,                   -- bridge|overlay|vmnet
    scope TEXT NOT NULL DEFAULT 'local',    -- local|global
    created_at TEXT NOT NULL,               -- ISO 8601 timestamp

    -- Network config
    subnet TEXT NOT NULL,                   -- CIDR (172.18.0.0/16)
    gateway TEXT NOT NULL,                  -- Gateway IP (172.18.0.1)
    ip_range TEXT,                          -- Restricted IP range (optional)

    -- Metadata (JSON blobs)
    options_json TEXT,                      -- JSON: driver-specific options
    labels_json TEXT,                       -- JSON: user labels

    is_default INTEGER NOT NULL DEFAULT 0,  -- Boolean: true for default bridge

    CHECK (driver IN ('bridge', 'overlay', 'vmnet'))
);

CREATE INDEX idx_networks_name ON networks(name);
CREATE INDEX idx_networks_driver ON networks(driver);
```

### Table: network_attachments

Tracks which containers are attached to which networks.

```sql
CREATE TABLE network_attachments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_id TEXT NOT NULL,
    network_id TEXT NOT NULL,

    -- Attachment details
    ip_address TEXT NOT NULL,               -- Assigned IP (172.18.0.5)
    mac_address TEXT NOT NULL,              -- MAC address
    aliases_json TEXT,                      -- JSON array: ["web", "frontend"]

    attached_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (container_id) REFERENCES containers(id) ON DELETE CASCADE,
    FOREIGN KEY (network_id) REFERENCES networks(id) ON DELETE CASCADE,
    UNIQUE (container_id, network_id)
);

CREATE INDEX idx_attachments_container ON network_attachments(container_id);
CREATE INDEX idx_attachments_network ON network_attachments(network_id);
```

### Table: subnet_allocation

Tracks subnet allocation state for auto-generated subnets.

```sql
CREATE TABLE subnet_allocation (
    id INTEGER PRIMARY KEY CHECK (id = 1), -- Singleton (only 1 row)
    next_subnet_byte INTEGER NOT NULL DEFAULT 18, -- Next for 172.X.0.0/16

    CHECK (next_subnet_byte BETWEEN 18 AND 31)
);

INSERT INTO subnet_allocation (id, next_subnet_byte) VALUES (1, 18);
```

## Common Queries

### List running containers (docker ps)

```sql
SELECT id, name, image, status
FROM containers
WHERE running = 1
    AND (json_extract(config_json, '$.labels."com.arca.internal"') IS NULL
         OR json_extract(config_json, '$.labels."com.arca.internal"') != 'true')
ORDER BY created_at DESC;
```

### Get container with network attachments

```sql
SELECT
    c.*,
    n.name as network_name,
    na.ip_address,
    na.mac_address
FROM containers c
LEFT JOIN network_attachments na ON c.id = na.container_id
LEFT JOIN networks n ON na.network_id = n.id
WHERE c.id = ?;
```

### Containers needing restart on startup

```sql
SELECT id, name, status, exit_code,
       json_extract(host_config_json, '$.restartPolicy.name') as policy
FROM containers
WHERE status = 'exited'
    AND (
        json_extract(host_config_json, '$.restartPolicy.name') = 'always'
        OR (json_extract(host_config_json, '$.restartPolicy.name') = 'unless-stopped'
            AND stopped_by_user = 0)
        OR (json_extract(host_config_json, '$.restartPolicy.name') = 'on-failure'
            AND exit_code != 0)
    );
```

## Swift Integration

### SQLite Library: SQLite.swift

Type-safe Swift wrapper: `https://github.com/stephencelis/SQLite.swift`

**Add to Package.swift**:
```swift
.package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")

// In target dependencies:
.product(name: "SQLite", package: "SQLite.swift")
```

### Example Usage

```swift
import SQLite
import Foundation

public actor StateStore {
    private let db: Connection
    private let logger: Logger

    // Tables
    private let containers = Table("containers")
    private let networks = Table("networks")
    private let networkAttachments = Table("network_attachments")

    // Columns
    private let id = Expression<String>("id")
    private let name = Expression<String>("name")
    private let status = Expression<String>("status")
    private let running = Expression<Bool>("running")
    private let configJSON = Expression<String>("config_json")

    public init(path: String, logger: Logger) throws {
        self.logger = logger
        self.db = try Connection(path)
        try initializeSchema()
    }

    public func saveContainer(_ container: ContainerInfo) throws {
        let configData = try JSONEncoder().encode(container.config)

        try db.run(containers.insert(or: .replace,
            id <- container.id,
            name <- container.name,
            status <- container.state,
            running <- (container.state == "running"),
            configJSON <- String(data: configData, encoding: .utf8)!
        ))
    }

    public func loadAllContainers() throws -> [ContainerInfo] {
        var result: [ContainerInfo] = []

        for row in try db.prepare(containers) {
            let config = try JSONDecoder().decode(
                ContainerConfig.self,
                from: row[configJSON].data(using: .utf8)!
            )

            result.append(ContainerInfo(
                id: row[id],
                name: row[name],
                state: row[status],
                config: config
            ))
        }

        return result
    }
}
```

## Reconciliation on Startup

### 1. Load Containers & Networks from DB

```swift
// Load all containers
let containers = try await stateStore.loadAllContainers()

// Load all networks
let networks = try await stateStore.loadAllNetworks()
```

### 2. Reconcile Networks with OVN

OVN is the source of truth for network configuration:

```swift
// Query OVN for existing networks
let ovnBridges = try await ovnClient.listBridges()

// Reconcile
for bridge in ovnBridges {
    if let dbNetwork = networks[bridge.networkID] {
        // Network exists in both - merge (OVN config wins)
        network.subnet = bridge.subnet  // OVN is truth for config
        network.gateway = bridge.gateway
        // Keep our metadata (name, labels, options)
    } else {
        // Network exists in OVN but not DB - import it
        let newNetwork = NetworkMetadata(
            id: bridge.networkID,
            subnet: bridge.subnet,
            gateway: bridge.gateway
        )
        try await stateStore.saveNetwork(newNetwork)
    }
}

// Remove stale networks (in DB but not OVN)
for (id, network) in networks {
    if !ovnBridges.contains(where: { $0.networkID == id }) {
        logger.warning("Stale network in DB, removing", metadata: ["id": "\(id)"])
        try await stateStore.deleteNetwork(id)
    }
}
```

### 3. Update Subnet Allocation

```swift
// Find highest used subnet byte
let maxSubnetByte = networks.values
    .compactMap { parseSubnetByte(from: $0.subnet) }
    .max() ?? 17

// Update counter to avoid collisions
try await stateStore.updateSubnetAllocation(nextByte: maxSubnetByte + 1)
```

### 4. Restart Containers Based on Policy

```sql
-- Query containers needing restart
SELECT * FROM containers
WHERE status = 'exited' AND (
    -- Always
    json_extract(host_config_json, '$.restartPolicy.name') = 'always'

    -- Unless-stopped (not manually stopped)
    OR (json_extract(host_config_json, '$.restartPolicy.name') = 'unless-stopped'
        AND stopped_by_user = 0)

    -- On-failure (non-zero exit)
    OR (json_extract(host_config_json, '$.restartPolicy.name') = 'on-failure'
        AND exit_code != 0)
);
```

```swift
for container in containersToRestart {
    do {
        try await containerManager.startContainer(id: container.id)
        logger.info("Auto-restarted container", metadata: [
            "id": "\(container.id)",
            "policy": "\(container.restartPolicy.name)"
        ])
    } catch {
        logger.error("Failed to auto-restart container", metadata: [
            "id": "\(container.id)",
            "error": "\(error)"
        ])
    }
}
```

## Transactions

All state changes wrapped in transactions for atomicity:

```swift
try await db.transaction {
    // Update container state
    try db.run(containers.filter(id == containerID)
        .update(status <- "running", running <- true))

    // Add network attachment
    try db.run(networkAttachments.insert(
        container_id <- containerID,
        network_id <- networkID,
        ip_address <- ip
    ))
}
```

## Performance

- **Container save**: < 1ms
- **Container load**: < 1ms per container
- **Startup with 100 containers**: < 100ms (DB queries only)
- **Database size (100 containers, 50 networks)**: < 1 MB

## Security

### File Permissions

```bash
chmod 600 ~/.arca/state.db      # rw-------
chmod 700 ~/.arca/               # rwx------
```

### Sensitive Data

Container configs may contain secrets in environment variables. Use Docker secrets API for sensitive data instead.

## References

- SQLite.swift: `https://github.com/stephencelis/SQLite.swift`
- SQLite JSON functions: `https://www.sqlite.org/json1.html`
