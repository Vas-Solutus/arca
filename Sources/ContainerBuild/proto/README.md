# BuildKit Protocol Buffer Definitions

This directory contains vendored protocol buffer definitions from the [BuildKit](https://github.com/moby/buildkit) project.

## Source

These `.proto` files are copied from the official BuildKit repository:
- **Repository**: https://github.com/moby/buildkit
- **License**: Apache 2.0
- **Vendored**: 2025-10-30

## Files

```
github.com/moby/buildkit/
├── api/
│   ├── services/control/
│   │   └── control.proto       # Main BuildKit Control API
│   └── types/
│       └── worker.proto         # Worker type definitions
├── solver/
│   ├── pb/
│   │   └── ops.proto           # Build operation definitions
│   └── errdefs/
│       └── errdefs.proto       # Error definitions
└── sourcepolicy/
    └── pb/
        └── policy.proto        # Source policy definitions
```

## Why Vendored?

We vendor these proto files (rather than depending on the BuildKit repository) because:

1. **No Code Dependency**: We only need the protocol specification, not BuildKit's Go code
2. **Stability**: Pin to a specific version of the API
3. **Build Simplicity**: No need to fetch external repositories during build
4. **Transparency**: Clear what API version we're using

## Usage

These proto files are compiled to Swift using `protoc` and `grpc-swift`:

```bash
./scripts/generate-grpc.sh
```

This generates:
- `Sources/ContainerBuild/Generated/*.pb.swift` - Protocol buffer messages
- `Sources/ContainerBuild/Generated/*.grpc.swift` - gRPC service clients

## API

The main API we use is the **Control Service** (`control.proto`), which provides:

- `Solve()` - Execute a build operation (main build RPC)
- `Status()` - Stream build progress updates
- `Session()` - Transfer build context files
- `ListWorkers()` - Get worker information
- `Prune()` - Clean up build cache

## Updating

To update to a newer version of BuildKit:

```bash
# Clone BuildKit
cd /tmp
git clone https://github.com/moby/buildkit.git
cd buildkit
git checkout <version-tag>

# Copy proto files
cp api/services/control/control.proto <arca>/Sources/ContainerBuild/proto/github.com/moby/buildkit/api/services/control/
cp api/types/worker.proto <arca>/Sources/ContainerBuild/proto/github.com/moby/buildkit/api/types/
cp solver/pb/ops.proto <arca>/Sources/ContainerBuild/proto/github.com/moby/buildkit/solver/pb/
cp solver/errdefs/errdefs.proto <arca>/Sources/ContainerBuild/proto/github.com/moby/buildkit/solver/errdefs/
cp sourcepolicy/pb/policy.proto <arca>/Sources/ContainerBuild/proto/github.com/moby/buildkit/sourcepolicy/pb/

# Regenerate Swift code
cd <arca>
./scripts/generate-grpc.sh

# Test
swift build
```

## License

These proto files are from BuildKit and are licensed under Apache 2.0:
https://github.com/moby/buildkit/blob/master/LICENSE
