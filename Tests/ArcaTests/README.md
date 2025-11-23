# Arca Test Suite

Comprehensive integration tests for Arca's Docker Engine API implementation using the Swift Testing framework.

## Overview

These tests validate Arca's core functionality by running real Docker CLI commands against the Arca daemon. All tests use the `.serialized` trait to run sequentially, avoiding race conditions with the helper VM and container state.

## Test Suites

### 1. ContainerRecreationTests ✨ **NEW - Phase 3.7**
**Purpose:** Validates that containers can be recreated from persisted state after daemon restart.

**Critical Tests:**
- `containerStartAfterRestart` - Verifies `docker start` recreates Container objects from the database
- `containerRemoveAfterRestart` - Verifies `docker rm` works on database-only containers

**What This Tests:**
- Container object recreation from SQLite database
- Orphaned storage cleanup via `manager.delete()`
- Database-only container removal (when Container not in framework)
- State transitions: running → exited after daemon restart

**Implementation Details:**
- Extracted `createNativeContainer()` helper method (reusable creation logic)
- Modified `startContainer()` to detect missing Container objects and recreate them
- Modified `removeContainer()` to handle containers that only exist in database
- Fixed state loading to mark running containers as exited after restart

**Run:**
```bash
make test FILTER=ContainerRecreationTests
```

**Expected Duration:** ~120 seconds (2 tests × ~60s each)

---

### 2. ContainerPersistenceTests 📦 **Phase 3.7**
**Purpose:** Validates that container metadata persists to SQLite database across daemon restarts.

**Tests:**
- `containerMetadataPersists` - Container metadata (name, image, state) persists
- `containerStartPersists` - Can start containers that were persisted
- `multipleContainersPersist` - Multiple containers persist correctly
- `containerRemovalPersists` - Container removal reflected in database
- `containerExitCodePersists` - Exit codes persist correctly
- `databaseHasCorrectSchema` - SQLite schema validation

**What This Tests:**
- StateStore CRUD operations (create, read, update, delete)
- Container metadata serialization (config, hostConfig to JSON)
- Network attachment persistence (foreign keys, relationships)
- Database schema versioning and migrations

**Run:**
```bash
make test FILTER=ContainerPersistenceTests
```

**Expected Duration:** ~420 seconds (7 tests × ~60s each)

---

### 3. RestartPolicyTests 🔄 **Phase 3.7**
**Purpose:** Validates Docker restart policies work correctly after daemon restart.

**Tests:**
- `restartAlways` - `--restart always` auto-restarts on daemon startup
- `restartUnlessStoppedManual` - `--restart unless-stopped` respects manual stops
- `restartUnlessStoppedNatural` - `--restart unless-stopped` restarts on crashes
- `restartOnFailureSuccess` - `--restart on-failure` doesn't restart on exit 0
- `restartOnFailureFailure` - `--restart on-failure` restarts on exit 1
- `restartNo` - `--restart no` never auto-restarts (default)
- `mixedRestartPolicies` - Multiple containers with different policies
- `restartPolicyPersists` - Restart policy persists in database

**What This Tests:**
- Restart policy application on daemon startup
- Container recreation for `--restart always/unless-stopped/on-failure`
- Exit code tracking for `on-failure` policy
- Manual stop detection for `unless-stopped` policy
- Restart policy persistence in database

**Dependencies:** Requires Task 2 (Container Recreation) to be complete.

**Run:**
```bash
make test FILTER=RestartPolicyTests
```

**Expected Duration:** ~480 seconds (8 tests × ~60s each)

---

### 4. Phase1IntegrationTests 🚀 **Phase 1 - MVP**
**Purpose:** Original integration tests for basic container lifecycle.

**Tests:** Basic create, start, stop, remove, logs, attach, exec operations.

**Run:**
```bash
make test FILTER=Phase1IntegrationTests
```

---

## Running Tests

### Quick Start
```bash
# Run all tests
make test

# Run specific test suite
make test FILTER=ContainerRecreationTests

# Run specific test
make test FILTER=containerStartAfterRestart
```

### Important Notes

1. **Code Signing Required**: Tests need virtualization entitlements. The Makefile handles this automatically:
   ```bash
   make test  # Builds, signs, then runs tests
   ```

2. **Serial Execution**: All test suites use `.serialized` trait to avoid race conditions with:
   - Helper VM startup (~20-30 seconds)
   - Container state in Apple's Containerization framework
   - SQLite database locks

3. **Test Isolation**: Each test suite uses its own socket path:
   - `ContainerRecreationTests`: `/tmp/arca-test-recreation.sock`
   - `ContainerPersistenceTests`: `/tmp/arca-test-persistence.sock`
   - `RestartPolicyTests`: `/tmp/arca-test-restart-policy.sock`

4. **Database Cleanup**: `make test` automatically cleans `~/.arca/state.db` before running.

---

## Test Validation Plan

### For Phase 3.7 Task 2 (Container Recreation)

Run tests in this recommended order:

#### 1. Core Recreation (CRITICAL)
```bash
make test FILTER=ContainerRecreationTests
```
**Validates:** Container objects can be recreated from persisted state.

#### 2. Restart Policies (NOW WORKS!)
```bash
make test FILTER=RestartPolicyTests
```
**Validates:** Restart policies work now that recreation is implemented.

#### 3. Persistence (Prerequisites)
```bash
make test FILTER=ContainerPersistenceTests
```
**Validates:** Persistence infrastructure still works correctly.

#### 4. Full Suite (Everything)
```bash
make test
```
**Validates:** Nothing broke in the broader codebase.

---

## Manual Verification

For hands-on validation, you can test the recreation flow manually:

### Terminal 1: Start Daemon
```bash
make run
```

### Terminal 2: Test Container Recreation
```bash
export DOCKER_HOST=unix:///tmp/arca.sock

# Create and start a container
docker run -d --name test-recreation alpine sleep 300
docker ps  # Should show running

# Kill daemon (Ctrl+C in Terminal 1)

# Restart daemon (in Terminal 1)
make run

# Back in Terminal 2
docker ps -a  # Container exists but state=Exited
docker start test-recreation  # THE MAGIC: Recreates Container object!
docker ps  # Should show running again!
docker logs test-recreation  # Should work
docker rm -f test-recreation  # Should work (database-only removal)
```

---

## What To Look For In Logs

### During Daemon Startup (After Restart)
```
info: Loaded containers from database count=1
info: Found persisted containers count=1
debug: Restored container from state id=... status=running
info: Container state recovery complete restored=1
```

**Key:** Container status changes from `running` → `exited` (VMs are gone after restart).

### During `docker start` (Recreation)
```
info: Recreating container from persisted state id=... state=exited
debug: Cleaning up orphaned container storage id=...
debug: Cleaned up orphaned storage via manager.delete()
debug: Retrieving image for recreation image=alpine
info: Creating LinuxContainer with Containerization API
info: Container VM created successfully
info: Container recreated successfully from persisted state
info: Starting container with Containerization API
info: Container started successfully
```

**Key:** Container is recreated from scratch using persisted config.

### During `docker rm` (Database-Only Removal)
```
info: Removing database-only container (not in framework) id=... state=created
info: Container removed successfully
```

**Key:** No error when native container doesn't exist - just removes from database.

---

## Troubleshooting

### Test Fails with "Invalid virtual machine configuration"
**Cause:** Binary not signed with entitlements.

**Fix:**
```bash
make clean
make test  # Don't use `swift test` directly!
```

### Test Fails with "socket did not appear within timeout"
**Cause:** Helper VM taking longer than 30 seconds to start.

**Fix:** Increase timeout in `Tests/ArcaTests/TestHelpers.swift:62-64`.

### Test Fails with "Cannot connect to the Docker daemon"
**Cause:** Daemon crashed during test or socket path conflict.

**Fix:**
```bash
pkill -f "Arca daemon"
rm -f /tmp/arca-test-*.sock
make test
```

### Test Fails with "no such table: containers"
**Cause:** Database schema not created (StateStore bug).

**Fix:** Already fixed in `Sources/ContainerBridge/StateStore.swift:124` (operator precedence issue).

### Database Lock Errors
**Cause:** Multiple tests trying to access database simultaneously.

**Fix:** Tests should have `.serialized` trait. Check test suite declaration.

---

## Test Infrastructure

### Helper Functions (`TestHelpers.swift`)

#### `startDaemon(socketPath:logFile:) -> Int32`
Starts Arca daemon in background with:
- Custom socket path (avoids conflicts)
- Debug logging to file
- Waits up to 60 attempts (30 seconds) for socket
- Returns daemon PID for cleanup

#### `stopDaemon(pid:)`
Kills daemon process gracefully.

#### `docker(_ args:socketPath:) -> String`
Executes Docker CLI command and returns output.
Uses specified socket path via `DOCKER_HOST` environment variable.

### Test Lifecycle

```
1. startDaemon()  # Background process
2. docker("run -d alpine")  # CLI integration
3. stopDaemon()  # Cleanup
4. startDaemon()  # Restart (simulates crash)
5. docker("ps -a")  # Verify persistence
6. docker("start")  # Test recreation
7. stopDaemon()  # Final cleanup
```

---

## Architecture Notes

### Why Container Recreation Is Needed

**Problem:** Apple's `Containerization.Container` objects are ephemeral (in-memory only).
- When daemon stops → All Container objects destroyed
- Only metadata persists in database
- This matches how `runc`/`containerd` work

**Solution:** Recreate Container objects on `docker start`:
1. Load metadata from database ✅
2. Clean up orphaned storage ✅
3. Create fresh Container from image + config ✅
4. Start the recreated Container ✅

This is **exactly** how Docker works with containerd!

### Comparison with Docker

| Operation | Docker (containerd) | Arca |
|-----------|---------------------|------|
| Container create | Metadata to DB | Metadata to SQLite |
| Container start | Recreate from metadata | Recreate from metadata ✅ |
| Daemon restart | All containers destroyed | All Container objects destroyed ✅ |
| Container start after restart | Recreate from DB | Recreate from SQLite ✅ |

---

## Contributing

When adding new tests:

1. **Use `.serialized` trait** for test suites
2. **Use unique socket paths** to avoid conflicts
3. **Clean up in `defer` blocks** to prevent orphaned daemons
4. **Wait for helper VM** (30 second timeout minimum)
5. **Document what you're testing** in comments
6. **Follow naming conventions**: `testDescribesWhatItDoes`

Example:
```swift
@Suite("My Feature Tests", .serialized)
struct MyFeatureTests {
    static let socketPath = "/tmp/arca-test-myfeature.sock"
    static let logFile = "/tmp/arca-myfeature-test.log"

    @Test("Feature works after daemon restart")
    func featureWorksAfterRestart() async throws {
        let pid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: pid) }

        // Your test logic here
    }
}
```

---

## References

- **Implementation Plan**: [Documentation/IMPLEMENTATION_PLAN.md](../../Documentation/IMPLEMENTATION_PLAN.md#L1949-L2305)
- **StateStore**: [Sources/ContainerBridge/StateStore.swift](../../Sources/ContainerBridge/StateStore.swift)
- **ContainerManager**: [Sources/ContainerBridge/ContainerManager.swift](../../Sources/ContainerBridge/ContainerManager.swift)
- **Docker API Spec**: [Documentation/DOCKER_ENGINE_v1.51.yaml](../../Documentation/DOCKER_ENGINE_v1.51.yaml)

---

**Last Updated:** 2025-10-27 (Phase 3.7 Task 2 - Container Recreation)
