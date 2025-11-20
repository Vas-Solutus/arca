# Arca Pre-Built Assets

This directory contains pre-built binary assets required for Arca's self-contained distribution packages.

## Contents

### Required Assets (ARM64)

1. **`vmlinux-arm64.gz`** (~15 MB)
   - Linux kernel with TUN/WireGuard support
   - Built from Apple's containerization kernel config
   - Used by all container VMs

2. **`vminit-oci-arm64.tar.gz`** (~120 MB)
   - OCI image containing vminitd + extensions
   - Components:
     - `/sbin/vminitd` - Apple's init system (Swift, ~40-50MB)
     - `/sbin/vmexec` - Exec helper (Swift, ~20-30MB)
     - `/sbin/arca-wireguard-service` - WireGuard network service (Go, ~10MB)
     - `/sbin/arca-filesystem-service` - Filesystem operations (Go, ~10MB)
   - Used as PID 1 in every container VM

3. **`SHA256SUMS`** (tracked in git)
   - Checksums for verification
   - Format: `<sha256>  <filename>`

## Building Assets

**Prerequisites:**
- macOS 15.0+ (Sequoia)
- Xcode 16.0+ with Command Line Tools
- Go 1.24+ (`brew install go`)
- Swift 6.2+ (included with Xcode)

### Quick Build (Recommended)

Build all assets with verified checksums:

```bash
# From repository root
make build-assets
```

This target:
1. Builds Linux kernel (`make kernel`)
2. Installs Swift Static Linux SDK (one-time, ~5 minutes)
3. Builds vminit OCI image (`make vminit`)
4. Compresses and moves to `assets/`
5. Generates `SHA256SUMS`

**Total time**: ~20-25 minutes (first time), ~15 minutes subsequent builds

### Manual Build

If you need to build assets individually:

#### 1. Build Linux Kernel

```bash
# From repository root
make kernel

# Compress and move
gzip -c ~/.arca/vmlinux > assets/vmlinux-arm64.gz
```

**Build time**: ~10-15 minutes

#### 2. Build vminit OCI Image

```bash
# One-time: Install Swift Static Linux SDK
cd containerization/vminitd
make cross-prep
cd ../..

# Build vminit
make vminit

# Package OCI layout
cd ~/.arca
tar czf /Users/kiener/code/arca/assets/vminit-oci-arm64.tar.gz vminit/
cd -
```

**Build time**: ~5 minutes (cross-prep), ~2-3 minutes (vminit build)

#### 3. Generate Checksums

```bash
cd assets
shasum -a 256 vmlinux-arm64.gz vminit-oci-arm64.tar.gz > SHA256SUMS
```

### Verifying Assets

```bash
cd assets
shasum -a 256 -c SHA256SUMS
```

Expected output:
```
vmlinux-arm64.gz: OK
vminit-oci-arm64.tar.gz: OK
```

## Distribution

### GitHub Releases

Pre-built assets are uploaded to GitHub Releases for each version:

```bash
# Tag and create release
git tag v1.0.0
git push origin v1.0.0

# Upload assets (automated via CI/CD or manual)
gh release create v1.0.0 \
  assets/vmlinux-arm64.gz \
  assets/vminit-oci-arm64.tar.gz \
  assets/SHA256SUMS \
  --title "Arca v1.0.0" \
  --notes "Release notes here"
```

### Package Integration

The `make dist-pkg` target downloads these assets from GitHub Releases (or uses local copies) and bundles them into the `.pkg` installer at:
- `/usr/local/share/arca/vmlinux`
- `/usr/local/share/arca/vminit/` (extracted OCI layout)

## Architecture Support

### Current: ARM64 Only

Assets are built for Apple Silicon (ARM64) only. Intel Macs can run Arca via Rosetta 2 (kernel/vminit are Linux ARM64, not affected by host architecture).

### Future: Universal Support

To support native Intel performance, build additional assets:
- `vmlinux-x86_64.gz` - x86_64 Linux kernel
- `vminit-oci-x86_64.tar.gz` - x86_64 vminit image

The package installer would detect host architecture and install the appropriate kernel/vminit.

## Troubleshooting

### Build Failures

**Kernel build fails:**
- Ensure Xcode Command Line Tools installed: `xcode-select --install`
- Check disk space (kernel build needs ~10 GB)
- See `Documentation/BUILDING_ASSETS.md` for detailed troubleshooting

**vminit build fails:**
- Ensure Swift Static Linux SDK installed: `cd containerization/vminitd && make cross-prep`
- Check Go toolchain: `go version` (needs 1.24+)
- Ensure submodule initialized: `git submodule update --init --recursive`

**Cross-compilation errors:**
- Delete SDK and reinstall: `rm -rf containerization/vminitd/.swift-static-sdk-*`
- Run `make cross-prep` again

## See Also

- `Documentation/BUILDING_ASSETS.md` - Comprehensive build guide with troubleshooting
- `Documentation/DISTRIBUTION.md` - Maintainer guide for creating releases
- `Makefile` - Build targets (`kernel`, `vminit`, `build-assets`, `dist-pkg`)
