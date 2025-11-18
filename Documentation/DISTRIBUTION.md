# Distribution & Release Guide

This guide covers how to create distributable packages of Arca for sharing with users, including code signing and notarization for macOS.

## Overview

Arca provides three distribution commands:

- `make dist` - Create a tarball (`.tar.gz`) with install script
- `make dist-pkg` - Create a macOS `.pkg` installer
- `make notarize` - Notarize the `.pkg` for distribution outside the App Store

## Quick Start (No Code Signing)

For internal testing or development builds, you can create unsigned packages:

```bash
# Create tarball distribution
make dist

# Output: dist/arca-{version}-macos-arm64.tar.gz
```

This creates a simple tarball that users can extract and install manually. No Apple Developer account required.

## Distribution Methods Comparison

| Method | Command | Requires Developer Account | Gatekeeper | Best For |
|--------|---------|----------------------------|------------|----------|
| **Tarball** | `make dist` | No | ⚠️ Users see warning | Internal testing, developers |
| **Signed .pkg** | `make dist-pkg` | Yes (free) | ⚠️ Users see warning | Team distribution |
| **Notarized .pkg** | `make notarize` | Yes (paid $99/year) | ✅ No warning | Public distribution |

## Prerequisites

### For All Distribution Methods

1. **Xcode Command Line Tools**
   ```bash
   xcode-select --install
   ```

2. **Git tags** (optional, for versioning)
   ```bash
   # Create a version tag
   git tag v1.0.0

   # Or set version manually
   make dist VERSION=1.0.0
   ```

### For Signed Packages (`make dist-pkg`)

1. **Apple Developer Account** (free)
   - Sign up at https://developer.apple.com
   - No paid membership required for development signing

2. **Developer ID Application Certificate**

   **Option A: Free Development Certificate**
   ```bash
   # Uses adhoc signing (default)
   make dist-pkg
   ```

   **Option B: Paid Developer ID Certificate**
   - Requires Apple Developer Program membership ($99/year)
   - Allows distribution outside the App Store
   - See "Obtaining Certificates" section below

### For Notarization (`make notarize`)

1. **Apple Developer Program** membership ($99/year)
   - Required for notarization
   - Sign up at https://developer.apple.com/programs/

2. **Developer ID Application certificate** (obtained automatically with membership)

3. **App-Specific Password** for notarization
   - See "Notarization Setup" section below

## Obtaining Certificates

### Free Development Certificate (Adhoc Signing)

No setup needed - this is the default:

```bash
# Uses adhoc signing (CODESIGN_IDENTITY="-")
make dist-pkg
```

**Limitations:**
- Package shows Gatekeeper warning when opened
- Cannot be notarized
- Good for internal testing only

### Paid Developer ID Certificate

Required for public distribution and notarization.

#### Step 1: Join Apple Developer Program

1. Go to https://developer.apple.com/programs/
2. Enroll ($99/year)
3. Complete enrollment (may take 24-48 hours)

#### Step 2: Create Certificate

1. **In Xcode:**
   - Open Xcode → Preferences → Accounts
   - Click `+` to add your Apple ID
   - Select your Apple ID → Click "Manage Certificates"
   - Click `+` → Select "Developer ID Application"
   - Certificate will be created and installed in Keychain

2. **Or via Developer Portal:**
   - Go to https://developer.apple.com/account/resources/certificates
   - Click `+` to create new certificate
   - Select "Developer ID Application"
   - Follow the CSR generation instructions
   - Download and install the certificate

#### Step 3: Find Your Certificate Identity

```bash
# List available code signing identities
security find-identity -v -p codesigning

# Look for a line like:
# 1) ABC123... "Developer ID Application: Your Name (TEAMID123)"
```

Copy the full identity string (in quotes).

#### Step 4: Use Certificate for Signing

```bash
# Set identity for one command
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID123)" make dist-pkg

# Or export for session
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID123)"
make dist-pkg
```

## Notarization Setup

Notarization submits your package to Apple for automated security scanning. Once notarized, macOS Gatekeeper will not show warnings when users install your app.

### Step 1: Create App-Specific Password

1. Go to https://appleid.apple.com/account/manage
2. Sign in with your Apple ID
3. Under "Security" → "App-Specific Passwords", click "Generate Password"
4. Label it "Arca Notarization"
5. Copy the generated password (format: `xxxx-xxxx-xxxx-xxxx`)

### Step 2: Store Password in Keychain

```bash
# Store the app-specific password in Keychain
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "your@email.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

**Find your Team ID:**
- Go to https://developer.apple.com/account
- Click "Membership" in the sidebar
- Your Team ID is shown under "Team ID"

### Step 3: Run Notarization

```bash
# Set required environment variables
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="your@email.com"
export TEAM_ID="YOURTEAMID"

# Create and notarize package
make notarize
```

This will:
1. Build the release binary
2. Sign it with your Developer ID
3. Create a `.pkg` installer
4. Sign the package
5. Submit to Apple for notarization (5-10 minutes)
6. Wait for approval
7. Staple the notarization ticket to the package

**Output:** `dist/arca-{version}.pkg` (fully signed and notarized)

## Usage Examples

### Example 1: Development Build (No Signing)

```bash
# Create unsigned tarball for internal testing
make dist

# Share with developers
# Users extract and run: ./install.sh
```

### Example 2: Team Distribution (Signed Package)

```bash
# Get your Developer ID certificate (see "Obtaining Certificates")
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

# Create signed package
make dist-pkg

# Share dist/arca-{version}.pkg with your team
# Users will see "unidentified developer" warning but can install
```

### Example 3: Public Distribution (Notarized)

```bash
# Complete notarization setup (one-time)
# 1. Join Apple Developer Program ($99/year)
# 2. Create Developer ID certificate
# 3. Store notarization credentials (see "Notarization Setup")

# Set environment variables
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="your@email.com"
export TEAM_ID="YOURTEAMID"

# Create notarized package
make notarize

# Share dist/arca-{version}.pkg publicly
# Users install with no warnings
```

### Example 4: Custom Version Number

```bash
# Override git tag version
VERSION=1.0.0-beta.1 make dist

# Or
VERSION=1.0.0-beta.1 \
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
make dist-pkg
```

## Makefile Variables Reference

Set these as environment variables or on the command line:

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | git tag or "dev" | Version string for package name |
| `CODESIGN_IDENTITY` | `"-"` (adhoc) | Code signing certificate identity |
| `APPLE_ID` | (none) | Apple ID email for notarization |
| `TEAM_ID` | (none) | Apple Developer Team ID for notarization |

## Troubleshooting

### "No identity found" Error

**Problem:** `make dist-pkg` fails with certificate error

**Solution:**
```bash
# Check if you have any code signing certificates
security find-identity -v -p codesigning

# If empty, you need to create a certificate (see "Obtaining Certificates")
# Or use adhoc signing (default)
CODESIGN_IDENTITY="-" make dist-pkg
```

### Notarization Fails with "Invalid Credentials"

**Problem:** `make notarize` fails with authentication error

**Solution:**
```bash
# Re-store credentials in Keychain
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "your@email.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"

# Verify credentials work
xcrun notarytool history \
  --apple-id "your@email.com" \
  --team-id "YOURTEAMID" \
  --keychain-profile "AC_PASSWORD"
```

### Notarization Rejected by Apple

**Problem:** Package submitted but Apple rejects it

**Solution:**
```bash
# Check notarization log
xcrun notarytool log <submission-id> \
  --apple-id "your@email.com" \
  --team-id "YOURTEAMID" \
  --keychain-profile "AC_PASSWORD"

# Common issues:
# - Binary not properly signed (check entitlements)
# - Package contains unsigned components
# - Hardened runtime issues
```

### Gatekeeper Warning Still Appears

**Problem:** Users see warning even after notarization

**Solution:**
```bash
# Verify notarization ticket is stapled
xcrun stapler validate dist/arca-{version}.pkg

# If not stapled, staple it manually
xcrun stapler staple dist/arca-{version}.pkg

# Verify signature
pkgutil --check-signature dist/arca-{version}.pkg
```

### Binary Won't Run After Installation

**Problem:** "Arca" is damaged and can't be opened

**Solution:**
```bash
# Check if binary is properly signed
codesign -v /usr/local/bin/Arca

# Check entitlements
codesign -d --entitlements - /usr/local/bin/Arca

# Remove quarantine attribute (development only)
xattr -d com.apple.quarantine /usr/local/bin/Arca
```

## Distribution Checklist

Before releasing a new version:

### Pre-Release
- [ ] Update version in code if needed
- [ ] Create git tag: `git tag v1.0.0`
- [ ] Build and test locally: `make release && make test`
- [ ] Verify entitlements: `make verify-entitlements`

### Build Distribution
- [ ] Set code signing identity
- [ ] Create package: `make dist-pkg` or `make notarize`
- [ ] Test installation on clean macOS system
- [ ] Verify binary runs and connects to Docker CLI

### Documentation
- [ ] Update OVERVIEW.md with new features
- [ ] Update LIMITATIONS.md if behavior changed
- [ ] Update CHANGELOG.md (if exists)

### Release
- [ ] Upload package to GitHub Releases
- [ ] Include installation instructions
- [ ] Note system requirements (macOS version, architecture)
- [ ] Provide SHA256 checksum:
  ```bash
  shasum -a 256 dist/arca-1.0.0.pkg
  ```

## Advanced Topics

### Signing with Hardware Security Module (HSM)

If your organization uses an HSM for code signing:

```bash
# List identities from HSM
security find-identity -v -p codesigning

# Use HSM identity
CODESIGN_IDENTITY="Developer ID Application: Company Name (TEAMID)" make dist-pkg
```

### Continuous Integration (CI)

For automated builds in CI:

```bash
# Install certificate in CI (base64 encoded)
echo "$CERT_BASE64" | base64 --decode > cert.p12
security import cert.p12 -P "$CERT_PASSWORD" -T /usr/bin/codesign

# Store notarization credentials
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD"

# Build and notarize
CODESIGN_IDENTITY="$CERT_IDENTITY" \
APPLE_ID="$APPLE_ID" \
TEAM_ID="$TEAM_ID" \
make notarize
```

### Custom Package Layouts

To customize the package structure, edit the Makefile targets or create a custom script:

```bash
# Example: Include additional files in package
make dist-pkg
# Then manually add files to dist/pkg/root/ before running pkgbuild
```

## Security Best Practices

1. **Never commit certificates or passwords to git**
   - Use environment variables
   - Store in CI secrets

2. **Rotate app-specific passwords periodically**
   - Create new password every 6-12 months
   - Revoke old passwords

3. **Verify packages before distribution**
   ```bash
   # Check signature
   spctl --assess --verbose dist/arca-1.0.0.pkg

   # Check notarization
   xcrun stapler validate dist/arca-1.0.0.pkg
   ```

4. **Keep signing keys secure**
   - Use Keychain Access Control Lists
   - Enable two-factor authentication on Apple ID
   - Limit access to signing certificates

## Support

For issues with:
- **Code signing:** https://developer.apple.com/support/code-signing/
- **Notarization:** https://developer.apple.com/support/notarization/
- **Arca distribution:** Open an issue at https://github.com/your-org/arca/issues

---

Last updated: 2025-01-17
