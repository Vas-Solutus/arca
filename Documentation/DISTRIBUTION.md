# Arca Distribution Guide

**For Maintainers**: This guide covers creating releases, building distribution packages, and managing Arca releases on GitHub.

## Overview

Arca uses a multi-channel distribution strategy:

1. **macOS .pkg Installer** (Primary) - Self-contained package with all dependencies
2. **GitHub Releases** - Hosting for .pkg and pre-built assets
3. **Homebrew Formula** (Future) - Homebrew tap for easy installation

## Prerequisites

### Required Tools

- **Xcode 16.0+** with Command Line Tools
- **Apple Developer ID Certificate** (for code signing and notarization)
- **App Store Connect API Key** (optional, for automated notarization)
- **GitHub CLI** (`gh`) - For creating releases
- **Go 1.24+** - For building vminit extensions

### Apple Developer Account Setup

#### 1. Developer ID Certificates

You need TWO certificates:

1. **Developer ID Application** - For signing binaries
   - Used to sign `/usr/local/bin/Arca` binary
   - Certificate name: `Developer ID Application: Your Name (TEAM_ID)`

2. **Developer ID Installer** - For signing .pkg files
   - Used to sign the `.pkg` installer
   - Certificate name: `Developer ID Installer: Your Name (TEAM_ID)`

**Install certificates**:
```bash
# Download from Apple Developer portal
# Double-click to install in Keychain

# Verify installation
security find-identity -v -p codesigning
# Should show both "Developer ID Application" and "Developer ID Installer"
```

#### 2. Notarization Credentials

**Option A: Password Authentication (Simpler)**

Store password in keychain:
```bash
xcrun notarytool store-credentials \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "<app-specific-password>"

# Use profile name: AC_PASSWORD
```

**Option B: API Key Authentication (Recommended for CI/CD)**

1. Create API key at https://appstoreconnect.apple.com/access/api
2. Download `.p8` file
3. Note Key ID and Issuer ID

Set environment variables:
```bash
export NOTARY_KEY_ID="ABC123XYZ"
export NOTARY_ISSUER_ID="12345678-1234-1234-1234-123456789012"
export NOTARY_KEY_FILE="/path/to/AuthKey_ABC123XYZ.p8"
```

---

## Release Workflow

### Step 1: Prepare Release

#### 1.1 Update Version

```bash
# Update version in CHANGELOG.md
vim CHANGELOG.md

# Commit version bump
git commit -am "chore: Bump version to v1.0.0"
git push origin main
```

#### 1.2 Build Pre-Built Assets

**IMPORTANT**: Assets must be built BEFORE creating the package.

```bash
# Build kernel and vminit (takes ~20-25 minutes)
make build-assets

# Verify assets
ls -lh assets/
# Should show:
#   vmlinux-arm64.gz (~15 MB)
#   vminit-oci-arm64.tar.gz (~120 MB)
#   SHA256SUMS

# Verify checksums
cd assets && shasum -a 256 -c SHA256SUMS
cd ..
```

---

### Step 2: Build Distribution Package

#### 2.1 Set Environment Variables

```bash
# Required for code signing
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"

# Required for notarization
export APPLE_ID="your@email.com"
export TEAM_ID="YOUR_TEAM_ID"

# Version tag
export VERSION="v1.0.0"
```

#### 2.2 Build Release Binary

```bash
# Build and sign release binary
make release

# Verify binary is signed
codesign -dv .build/release/Arca
# Should show: "Developer ID Application: Your Name (TEAM_ID)"

# Verify entitlements
make verify-entitlements
# Should show virtualization and networking entitlements
```

#### 2.3 Create .pkg Installer

```bash
# Create package (requires pre-built assets)
VERSION=v1.0.0 make dist-pkg

# Output: dist/arca-v1.0.0.pkg
```

**What this does**:
1. Extracts pre-built kernel from `assets/vmlinux-arm64.gz`
2. Extracts pre-built vminit from `assets/vminit-oci-arm64.tar.gz`
3. Copies Arca binary to `/usr/local/bin/`
4. Copies assets to `/usr/local/share/arca/`
5. Adds preinstall and postinstall scripts
6. Builds .pkg with pkgbuild
7. Signs .pkg with Developer ID Installer certificate (if CODESIGN_IDENTITY set)

#### 2.4 Verify Package

```bash
# Verify package signature
pkgutil --check-signature dist/arca-v1.0.0.pkg

# Inspect package contents
pkgutil --payload-files dist/arca-v1.0.0.pkg | head -20

# Check package size
du -h dist/arca-v1.0.0.pkg
# Should be ~145 MB (ARM64 only)
```

---

### Step 3: Notarize Package

#### 3.1 Submit for Notarization

```bash
# Notarize using convenience script
make notarize

# Or manually with script
./scripts/notarize.sh dist/arca-v1.0.0.pkg
```

**Notarization process**:
1. Validates package signature
2. Submits to Apple notarization service (~5-15 minutes)
3. Waits for approval
4. Staples notarization ticket to .pkg
5. Verifies Gatekeeper acceptance

**Common issues**:
- **"Package is not signed"**: Set `CODESIGN_IDENTITY` and rebuild
- **"Notarization failed"**: Check notarization logs (script provides command)
- **"Invalid signature"**: Ensure both binary and package are signed correctly

#### 3.2 Verify Notarization

```bash
# Verify notarization ticket is stapled
xcrun stapler validate dist/arca-v1.0.0.pkg

# Verify Gatekeeper acceptance
spctl -a -vv -t install dist/arca-v1.0.0.pkg
# Should show: "accepted"
```

---

### Step 4: Create GitHub Release

#### 4.1 Tag Release

```bash
# Create and push tag
git tag -a v1.0.0 -m "Arca v1.0.0"
git push origin v1.0.0
```

#### 4.2 Upload Release Assets

**Using GitHub CLI** (recommended):

```bash
# Create release with assets
gh release create v1.0.0 \
  dist/arca-v1.0.0.pkg \
  assets/vmlinux-arm64.gz \
  assets/vminit-oci-arm64.tar.gz \
  assets/SHA256SUMS \
  scripts/uninstall.sh \
  --title "Arca v1.0.0" \
  --notes-file CHANGELOG.md
```

**Using GitHub Web UI**:

1. Go to https://github.com/liquescent-development/arca/releases/new
2. Select tag: `v1.0.0`
3. Set title: `Arca v1.0.0`
4. Copy release notes from CHANGELOG.md
5. Upload files:
   - `arca-v1.0.0.pkg` - Main installer
   - `vmlinux-arm64.gz` - Pre-built kernel (for reference)
   - `vminit-oci-arm64.tar.gz` - Pre-built vminit (for reference)
   - `SHA256SUMS` - Checksums
   - `uninstall.sh` - Uninstaller script
6. Click "Publish release"

#### 4.3 Create Latest Symlink

For users who want `Arca-latest.pkg`:

```bash
# Download the v1.0.0 pkg
curl -LO https://github.com/liquescent-development/arca/releases/download/v1.0.0/arca-v1.0.0.pkg

# Upload as "Arca-latest.pkg" to same release
gh release upload v1.0.0 arca-v1.0.0.pkg --clobber --rename Arca-latest.pkg
```

---

## Homebrew Formula (Future)

### Step 1: Create Homebrew Tap

```bash
# Create tap repository
gh repo create liquescent-development/homebrew-arca --public

# Clone locally
git clone https://github.com/liquescent-development/homebrew-arca.git
cd homebrew-arca

# Create formula directory
mkdir Formula
```

### Step 2: Create Formula

Create `Formula/arca.rb`:

```ruby
class Arca < Formula
  desc "Native container engine for macOS built on Apple's Virtualization framework"
  homepage "https://github.com/liquescent-development/arca"
  url "https://github.com/liquescent-development/arca/releases/download/v1.0.0/arca-v1.0.0.pkg"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  version "1.0.0"

  def install
    system "sudo", "installer", "-pkg", cached_download, "-target", "/"
  end

  service do
    run [opt_bin/"Arca", "daemon", "start", "--socket-path", "#{Dir.home}/.arca/arca.sock"]
    keep_alive true
    log_path var/"log/arca.log"
    error_log_path var/"log/arca.log"
  end

  test do
    system "#{HOMEBREW_PREFIX}/bin/Arca", "version"
  end
end
```

**Generate SHA256**:
```bash
shasum -a 256 dist/arca-v1.0.0.pkg
```

### Step 3: Test Formula

```bash
# Test installation
brew install --build-from-source Formula/arca.rb

# Test service
brew services start arca

# Verify
export DOCKER_HOST=unix://~/.arca/arca.sock
docker version
```

### Step 4: Publish Formula

```bash
git add Formula/arca.rb
git commit -m "Add arca v1.0.0 formula"
git push origin main
```

**Users can now install**:
```bash
brew install liquescent-development/arca/arca
```

---

## Automated Release (GitHub Actions)

### Workflow File

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

jobs:
  build-assets:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive

      - name: Install dependencies
        run: brew install go

      - name: Build assets
        run: make build-assets

      - name: Upload assets
        uses: actions/upload-artifact@v3
        with:
          name: assets
          path: assets/

  build-package:
    needs: build-assets
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Download assets
        uses: actions/download-artifact@v3
        with:
          name: assets
          path: assets/

      - name: Import certificates
        env:
          CERTIFICATE_P12: ${{ secrets.APPLE_CERTIFICATE_P12 }}
          CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
        run: |
          # Decode and import certificate
          echo "$CERTIFICATE_P12" | base64 --decode > certificate.p12
          security create-keychain -p actions build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p actions build.keychain
          security import certificate.p12 -k build.keychain -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k actions build.keychain
          rm certificate.p12

      - name: Build package
        env:
          CODESIGN_IDENTITY: ${{ secrets.CODESIGN_IDENTITY }}
        run: |
          VERSION=${GITHUB_REF#refs/tags/} make dist-pkg

      - name: Notarize package
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          TEAM_ID: ${{ secrets.TEAM_ID }}
          CODESIGN_IDENTITY: ${{ secrets.CODESIGN_IDENTITY }}
        run: |
          VERSION=${GITHUB_REF#refs/tags/}
          ./scripts/notarize.sh dist/arca-$VERSION.pkg

      - name: Create release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            dist/arca-*.pkg
            assets/vmlinux-arm64.gz
            assets/vminit-oci-arm64.tar.gz
            assets/SHA256SUMS
            scripts/uninstall.sh
```

### Required Secrets

Configure in GitHub repository settings:

```bash
# Code signing certificate (base64-encoded .p12)
APPLE_CERTIFICATE_P12=$(base64 < certificate.p12)

# Secrets to add:
APPLE_CERTIFICATE_P12       # Base64-encoded certificate
APPLE_CERTIFICATE_PASSWORD  # Certificate password
CODESIGN_IDENTITY          # "Developer ID Application: Your Name (ID)"
APPLE_ID                   # your@email.com
TEAM_ID                    # YOUR_TEAM_ID
NOTARY_KEY_ID             # App Store Connect API key ID (optional)
NOTARY_ISSUER_ID          # App Store Connect API issuer ID (optional)
```

---

## Testing Distribution Packages

### Test on Clean System

**Using macOS VM**:
```bash
# Install package
sudo installer -pkg arca-v1.0.0.pkg -target /

# Verify installation
/usr/local/bin/Arca version
launchctl list | grep arca
ls -l ~/.arca/

# Test Docker CLI
export DOCKER_HOST=unix://~/.arca/arca.sock
docker run hello-world
```

**Using GitHub Actions**:

Create `.github/workflows/test-install.yml` to test installation in CI.

### Test Upgrade Path

```bash
# Install v1.0.0
sudo installer -pkg arca-v1.0.0.pkg -target /

# Run some containers
export DOCKER_HOST=unix://~/.arca/arca.sock
docker run -d --name test nginx
docker ps

# Upgrade to v1.1.0
sudo installer -pkg arca-v1.1.0.pkg -target /

# Verify containers still exist
docker ps -a | grep test
docker start test
```

### Test Uninstall

```bash
# Install
sudo installer -pkg arca-v1.0.0.pkg -target /

# Uninstall (preserve data)
sudo ./scripts/uninstall.sh

# Verify removal
[ ! -f /usr/local/bin/Arca ] && echo "Binary removed"
[ ! -d /usr/local/share/arca ] && echo "Assets removed"
[ -d ~/.arca ] && echo "User data preserved"

# Uninstall (remove all data)
sudo ./scripts/uninstall.sh --remove-data

# Verify complete removal
[ ! -d ~/.arca ] && echo "User data removed"
```

---

## Troubleshooting Distribution Issues

### Code Signing Issues

**Error: "No identity found"**
```bash
# List available identities
security find-identity -v -p codesigning

# If empty, install certificates from Apple Developer portal
```

**Error: "Resource fork, Finder information, or similar detritus not allowed"**
```bash
# Clean extended attributes
xattr -cr .build/release/Arca
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements Arca.entitlements .build/release/Arca
```

### Notarization Issues

**Error: "The binary is not signed"**
- Ensure binary is signed BEFORE creating package
- Verify: `codesign -dv .build/release/Arca`

**Error: "Invalid notarization credentials"**
```bash
# Test credentials
xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "@keychain:AC_PASSWORD"
```

**Error: "Notarization failed"**
```bash
# Get detailed logs
SUBMISSION_ID="..." # From notarization output
xcrun notarytool log $SUBMISSION_ID --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "@keychain:AC_PASSWORD"
```

### Package Issues

**Error: "Package is empty"**
- Verify assets exist: `ls -l assets/vmlinux-arm64.gz assets/vminit-oci-arm64.tar.gz`
- Rebuild assets: `make build-assets`

**Error: "Installer script failed"**
- Test scripts manually: `sudo ./scripts/preinstall.sh && sudo ./scripts/postinstall.sh`
- Check script permissions: `chmod +x scripts/*.sh`

---

## Release Checklist

### Pre-Release

- [ ] Update CHANGELOG.md with release notes
- [ ] Build pre-built assets (`make build-assets`)
- [ ] Verify checksums (`cd assets && shasum -a 256 -c SHA256SUMS`)
- [ ] Test kernel and vminit locally
- [ ] Update version in documentation if needed

### Build

- [ ] Set environment variables (CODESIGN_IDENTITY, APPLE_ID, TEAM_ID, VERSION)
- [ ] Build release binary (`make release`)
- [ ] Verify binary signature (`codesign -dv .build/release/Arca`)
- [ ] Verify entitlements (`make verify-entitlements`)
- [ ] Create .pkg package (`make dist-pkg`)
- [ ] Verify package contents (`pkgutil --payload-files dist/arca-*.pkg`)

### Notarize

- [ ] Submit for notarization (`make notarize`)
- [ ] Wait for approval (~5-15 minutes)
- [ ] Verify stapled ticket (`xcrun stapler validate dist/arca-*.pkg`)
- [ ] Verify Gatekeeper (`spctl -a -vv -t install dist/arca-*.pkg`)

### Release

- [ ] Create git tag (`git tag -a v1.0.0 -m "..."`)
- [ ] Push tag (`git push origin v1.0.0`)
- [ ] Create GitHub release with assets
- [ ] Upload Arca-latest.pkg symlink
- [ ] Test download URL
- [ ] Update Homebrew formula (if applicable)

### Post-Release

- [ ] Test installation on clean system
- [ ] Test upgrade from previous version
- [ ] Update documentation links
- [ ] Announce release (Twitter, blog, etc.)
- [ ] Monitor for issues

---

## See Also

- [BUILDING_ASSETS.md](BUILDING_ASSETS.md) - Building kernel and vminit
- [INSTALLATION.md](INSTALLATION.md) - User installation guide
- [CHANGELOG.md](../CHANGELOG.md) - Release notes
