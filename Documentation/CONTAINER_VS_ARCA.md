# Comparison: Apple's `container` CLI vs Arca Persistence

A detailed comparison of persistence approaches between Apple's official `container` CLI and Arca's Docker-compatible implementation.

---

## Architecture Differences

### Apple's Approach
```
CLI (thin client)
  ↓ XPC messages
Daemon (background service)
  ↓ Plugin system
Runtime helpers (crun, runc, etc.)
  ↓ Apple Containerization API
```

### Arca's Approach
```
Docker CLI
  ↓ HTTP/Unix socket
Arca Daemon (SwiftNIO server)
  ↓ Direct calls
Apple Containerization API
```

---

## Persistence Comparison

| Aspect | Apple `container` | Arca |
|--------|-------------------|------|
| **Storage** | Filesystem (JSON files) | SQLite database |
| **Structure** | One directory per container | Single DB with tables |
| **Container State** | `~/.container/containers/{id}/entity.json` | `~/.arca/state.db` (containers table) |
| **Metadata Format** | JSON files | SQL columns + JSON blobs |
| **Indexing** | In-memory `[String: ContainerState]` | SQL indexes + in-memory cache |
| **Loading** | Scan directories at boot | SQL `SELECT` at boot |
| **Networks** | Part of container JSON | Separate table with foreign keys |

---

## Apple's EntityStore Pattern

### Structure
```swift
public actor FilesystemEntityStore<T> {
    private var index: [String: T]  // In-memory cache

    // Each container gets:
    // ~/.container/containers/{id}/
    //   ├── entity.json        (metadata)
    //   ├── options.json       (creation options)
    //   ├── container-root/    (filesystem)
    //   └── bootlog            (logs)
}
```

### Pros
- ✅ Simple - just JSON files
- ✅ Easy to inspect (`cat entity.json`)
- ✅ No database dependencies
- ✅ Generic pattern for any `Codable` type

### Cons
- ❌ No transactions
- ❌ No complex queries (must scan all files)
- ❌ No foreign keys/relationships
- ❌ Race conditions possible without careful locking

---

## Arca's SQLite Pattern

### Structure
```swift
public actor StateStore {
    // Single database: ~/.arca/state.db
    // Tables: containers, network_attachments, schema_version
    // Relationships via foreign keys
}
```

### Pros
- ✅ ACID transactions
- ✅ Complex queries (`WHERE`, `JOIN`, etc.)
- ✅ Foreign keys enforce referential integrity
- ✅ Indexes for fast lookups
- ✅ Schema migrations built-in

### Cons
- ❌ Harder to inspect (need SQL client)
- ❌ Database dependency
- ❌ More complex error handling

---

## Container Recreation: Key Difference!

### Apple's Approach
**Uses persistent launchd services:**

```swift
// They keep runtime helpers running via launchd
// Container "stop" = stop VM, keep helper
// Container "start" = tell existing helper to start
static func registerService(plugin, configuration, path) {
    try loader.registerWithLaunchd(
        plugin: plugin,
        args: ["start", "--root", path, "--uuid", id],
        instanceId: id
    )
}
```

**Each container gets a persistent launchd service that survives daemon restarts!**

### Arca's Approach
**Recreates Container objects on demand:**

```swift
// We recreate Container objects on demand
if nativeContainers[dockerID] == nil {
    // Container only in database - recreate it
    try await manager.delete(dockerID)  // Clean orphaned storage
    let container = try await createNativeContainer(config)
    nativeContainers[dockerID] = container
}
```

**We recreate from scratch each time, matching Docker's behavior.**

---

## What We Learned

### 1. Apple uses launchd persistence!
- Each container registers as a launchd service
- Services survive daemon crashes
- This is why they don't need "recreation" logic

### 2. File-based vs Database trade-offs
- **Files:** Simple, inspectable, no dependencies
- **Database:** Powerful queries, transactions, relationships

### 3. Our approach is more Docker-like
- Docker also recreates containers on restart
- Docker also uses a database (BoltDB/SQLite)
- Apple's CLI is more macOS-native (XPC, launchd)

### 4. Both approaches are valid
- **Apple:** macOS-native, plugin-based, distributed
- **Arca:** Docker-compatible, monolithic, database-driven

---

## Should We Change Anything?

### No! Our approach is correct for our goals:
- ✅ We want Docker API compatibility (not Apple's CLI)
- ✅ SQLite gives us complex queries Docker needs (filters, labels, etc.)
- ✅ Container recreation matches Docker's behavior exactly
- ✅ Single database is simpler than filesystem scanning

### What we could learn from them:
- 📝 Their in-memory index pattern is good (we do this too)
- 📝 EntityStore's generic pattern could be useful for other entities
- 📝 launchd integration could help with daemon lifecycle

---

## Conclusion

**Bottom line:** Apple's `container` CLI and Arca solve different problems with different approaches, and both are architecturally sound! 🎉

### Key Takeaways

| Aspect | Apple | Arca |
|--------|-------|------|
| **Goal** | macOS-native container tool | Docker-compatible engine for macOS |
| **Persistence** | JSON files + launchd | SQLite + recreation |
| **Architecture** | Distributed (XPC, plugins) | Monolithic (single daemon) |
| **Container Lifecycle** | Helper survives restarts | Recreate on demand |
| **Best For** | macOS workflows | Docker compatibility |

---

**References:**
- Apple's `container` CLI: [github.com/apple/container](https://github.com/apple/container)
- EntityStore implementation: [Sources/ContainerPersistence/EntityStore.swift](https://github.com/apple/container/blob/main/Sources/ContainerPersistence/EntityStore.swift)
- Arca's StateStore: [Sources/ContainerBridge/StateStore.swift](../Sources/ContainerBridge/StateStore.swift)
- Arca's Container Recreation: [Sources/ContainerBridge/ContainerManager.swift#L826-L894](../Sources/ContainerBridge/ContainerManager.swift)

---

**Last Updated:** 2025-10-27 (Phase 3.7 Task 2 - Container Recreation)
