# Building a Custom Kernel with TUN Support

## Overview

Arca requires a Linux kernel with TUN/TAP support enabled (`CONFIG_TUN=y`) for the helper VM's OVS userspace networking to function. Apple's containerization project provides an optimized kernel configuration, but the pre-built kernels may not always have TUN support enabled.

This guide explains how to build a custom kernel with TUN support.

## Quick Start

```bash
# Build the kernel (takes 10-15 minutes)
make kernel

# Rebuild helper VM with new kernel
make helpervm

# Test that OVS networking works
make test-helper
```

## Why is TUN Support Needed?

Open vSwitch (OVS) in userspace mode requires the TUN/TAP device (`/dev/net/tun`) to create virtual network interfaces for the netdev datapath. Without TUN support:

- OVS cannot create bridges with `datapath_type=netdev`
- The helper VM fails to initialize networking
- You see errors like: `opening "/dev/net/tun" failed: No such device`

## Prerequisites

### Required Tools

1. **Apple's `container` tool** (v1.0.0+)
   - Download from: https://github.com/apple/container/releases
   - Verify: `container --version`

2. **Sufficient disk space**
   - Kernel source: ~150MB
   - Build artifacts: ~2GB
   - Final kernel: ~14MB

3. **Time**
   - Initial build: 10-15 minutes
   - Subsequent builds (if needed): 10-15 minutes

### System Requirements

- macOS 26.0+ (Sequoia)
- Apple Silicon or Intel with Virtualization framework
- 8GB+ RAM (16GB recommended for faster builds)
- 4+ CPU cores

## Building the Kernel

### Method 1: Using Make (Recommended)

```bash
cd /path/to/arca
make kernel
```

This script follows Apple's documented build process:
1. Downloads Apple's kernel build configuration (Makefile, build.sh, Dockerfile)
2. Modifies `config-arm64` to enable `CONFIG_TUN=y`
3. Runs Apple's `make` command which:
   - Downloads Linux kernel source (v6.14.9)
   - Builds the kernel build container image (Ubuntu Focal with cross-compilation tools)
   - Compiles the kernel inside the container
4. Installs the kernel to `~/.arca/vmlinux`

**Build location**: `~/.arca/kernel-build/kernel/`

### Method 2: Manual Build

If you need more control, follow Apple's exact process:

```bash
# Create work directory
mkdir -p ~/.arca/kernel-build
cd ~/.arca/kernel-build

# Clone Apple's containerization repo
git clone --depth 1 https://github.com/apple/containerization.git
cd containerization/kernel

# Enable CONFIG_TUN in the kernel config
sed -i.bak 's/^# CONFIG_TUN is not set$/CONFIG_TUN=y/' config-arm64

# Run Apple's build process (this does everything)
make

# Install the kernel
cp vmlinux ~/.arca/vmlinux
```

That's it! Apple's Makefile handles:
- Building the container image with build tools
- Downloading kernel source
- Cross-compiling the kernel
- Producing the final `vmlinux` file

## Verifying TUN Support

After building and installing the kernel, you can verify TUN support is enabled:

```bash
# Start the helper VM
make helpervm
make run  # In one terminal

# In another terminal, check the kernel config
export DOCKER_HOST=unix:///tmp/arca.sock
docker exec arca-network-helper zcat /proc/config.gz | grep CONFIG_TUN

# Should output:
# CONFIG_TUN=y
# # CONFIG_TUN_VNET_CROSS_LE is not set
```

Or run the integration tests:

```bash
make test-helper
```

If TUN is working, you should see:
- ✓ Health check passed
- ✓ Bridge creation succeeded
- ✓ Bridge deletion succeeded

## Troubleshooting

### Build Fails: "container: command not found"

**Problem**: The Apple `container` tool is not installed.

**Solution**: Download and install it from https://github.com/apple/container/releases

```bash
# Download the latest release
curl -SsL -o /tmp/container.pkg \
    "https://github.com/apple/container/releases/download/v1.0.0/container.pkg"

# Install
sudo installer -pkg /tmp/container.pkg -target /

# Verify
container --version
```

### Build Fails: "container system not running"

**Problem**: The container system service is not started.

**Solution**: Start the container system:

```bash
container system start
```

### Build Fails: "No space left on device"

**Problem**: Insufficient disk space for kernel build.

**Solution**: Free up at least 3GB of disk space:

```bash
# Clean up old kernel builds
rm -rf /tmp/arca-kernel-build

# Clean up Docker/container images
container image prune -a
```

### Kernel Build Succeeds but TUN Still Missing

**Problem**: The kernel config changed or doesn't have TUN enabled.

**Solution**: Verify the config has TUN enabled:

```bash
# Check the downloaded config
grep CONFIG_TUN ~/.arca/kernel-build/kernel/config-arm64

# Should show:
# CONFIG_TUN=y
```

If `CONFIG_TUN=y` is missing, manually enable it:

```bash
# Edit the config
cd ~/.arca/kernel-build/kernel
sed -i.bak 's/^# CONFIG_TUN is not set$/CONFIG_TUN=y/' config-arm64

# Or add it if it doesn't exist at all
echo "CONFIG_TUN=y" >> config-arm64

# Rebuild using Apple's Makefile
make
cp vmlinux ~/.arca/vmlinux
```

### Tests Still Fail After Building Kernel

**Problem**: Helper VM is still using the old kernel.

**Solution**: Rebuild the helper VM to pick up the new kernel:

```bash
# Rebuild helper VM
make helpervm

# Restart Arca daemon
pkill -f "Arca daemon"
make run  # In one terminal

# Run tests in another terminal
make test-helper
```

## Kernel Configuration Details

### Base Configuration

Arca uses Apple's optimized kernel configuration from:
https://github.com/apple/containerization/blob/main/kernel/config-arm64

This configuration is optimized for:
- Fast boot times
- Minimal memory footprint
- Container workloads
- Apple's Virtualization framework

### TUN/TAP Settings

The kernel is built with these TUN-related settings:

```
CONFIG_TUN=y                      # Enable TUN/TAP driver
# CONFIG_TUN_VNET_CROSS_LE is not set  # Cross-endian vnet headers (not needed)
```

### Other Networking Features

The kernel also includes:

```
CONFIG_VETH=y           # Virtual Ethernet pairs
CONFIG_VIRTIO_NET=y     # VirtIO network device
CONFIG_BRIDGE=y         # Bridge support (for future use)
```

## Advanced Topics

### Customizing the Kernel Config

If you need to enable additional kernel features:

1. Download the base config:
   ```bash
   curl -SsL -o /tmp/config-custom \
       "https://raw.githubusercontent.com/apple/containerization/main/kernel/config-arm64"
   ```

2. Edit the config:
   ```bash
   nano /tmp/config-custom
   ```

3. Build with custom config:
   ```bash
   # Copy your custom config to the build directory
   cp /tmp/config-custom /tmp/arca-kernel-build/config-arm64

   # Build
   make kernel
   ```

### Using a Different Kernel Version

The default kernel version is 6.14.9. To use a different version:

1. Edit `scripts/build-kernel.sh`:
   ```bash
   nano scripts/build-kernel.sh
   ```

2. Change `KERNEL_VERSION`:
   ```bash
   KERNEL_VERSION="6.12.0"  # or whatever version you want
   ```

3. Rebuild:
   ```bash
   make kernel
   ```

### Keeping Multiple Kernels

You can keep multiple kernel versions:

```bash
# Kernels are stored with version numbers
ls -l ~/.arca/vmlinux-*

# Switch between kernels
ln -sf vmlinux-6.14.9-tun ~/.arca/vmlinux    # Use 6.14.9
ln -sf vmlinux-6.12.0-custom ~/.arca/vmlinux # Use 6.12.0

# Remember to rebuild helper VM after switching
make helpervm
```

## Performance Considerations

### Build Time

Typical build times on different hardware:

- **Apple M3 Max (14-core)**: 8-10 minutes
- **Apple M2 Pro (12-core)**: 10-12 minutes
- **Apple M1 (8-core)**: 12-15 minutes
- **Intel (4-core)**: 15-20 minutes

### Disk Space

- Source tarball: ~150MB
- Extracted source: ~1.2GB
- Build artifacts: ~800MB
- Final kernel: ~14MB
- Total required: ~3GB

### Memory Usage

The kernel build uses:
- Peak memory: ~4GB
- Recommended: 16GB total system RAM
- Minimum: 8GB total system RAM

## References

- [Apple Containerization Project](https://github.com/apple/containerization)
- [Apple Containerization Kernel Config](https://github.com/apple/containerization/blob/main/kernel/config-arm64)
- [Linux Kernel Archives](https://www.kernel.org/)
- [OVS Userspace Networking](https://docs.openvswitch.org/en/latest/intro/install/userspace/)
- [TUN/TAP Documentation](https://www.kernel.org/doc/Documentation/networking/tuntap.txt)
