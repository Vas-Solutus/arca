.PHONY: clean clean-state clean-layers clean-containers clean-all-state clean-dist install uninstall debug release run run-with-setup setup-builder all codesign verify-entitlements help kernel install-grpc-plugin test vminit gen-grpc dist dist-pkg notarize install-service uninstall-service start-service stop-service restart-service service-status configure-shell

# Default build configuration
CONFIGURATION ?= debug

# Build directory
ifeq ($(CONFIGURATION),release)
	BUILD_DIR = .build/release
	SWIFT_BUILD_FLAGS = -c release
else
	BUILD_DIR = .build/debug
	SWIFT_BUILD_FLAGS = -c debug
endif

# Binary names
BINARY = Arca
TEST_HELPER = ArcaTestHelper

# Installation directory
INSTALL_DIR = /usr/local/bin

# LaunchAgent directory (user-local, no sudo required)
LAUNCH_AGENT_DIR = $(HOME)/Library/LaunchAgents
LAUNCH_AGENT_PLIST = com.liquescent.arca.plist

# Default socket path (user-local)
DEFAULT_SOCKET = $(HOME)/.arca/arca.sock

# Entitlements file
ENTITLEMENTS = Arca.entitlements

# Code signing identity (use "-" for adhoc, or set to your Developer ID)
# Example: CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
CODESIGN_IDENTITY ?= -

# Distribution version (from git tag or default)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Distribution directory
DIST_DIR = dist

# Source files (for dependency tracking)
SOURCES := $(shell find Sources -name '*.swift' 2>/dev/null)

# Default target
all: codesign

# Build the project - file-based target that depends on source files
$(BUILD_DIR)/$(BINARY): $(SOURCES) Package.swift
	@echo "Building $(BINARY) ($(CONFIGURATION))..."
	@swift build $(SWIFT_BUILD_FLAGS)

# Codesign the binaries with entitlements
codesign: $(BUILD_DIR)/$(BINARY) $(BUILD_DIR)/$(TEST_HELPER)
	@echo "Code signing $(BINARY) with entitlements (identity: $(CODESIGN_IDENTITY))..."
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(BINARY)
	@echo "Code signing $(TEST_HELPER) with entitlements..."
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(TEST_HELPER)
	@echo "✓ Code signing complete"

# Debug build (default)
debug:
	$(MAKE) CONFIGURATION=debug all

# Release build
release:
	$(MAKE) CONFIGURATION=release all

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	swift package clean
	rm -rf .build

# Clean state database (development)
clean-state:
	@echo "Cleaning state database..."
	@rm -f ~/.arca/state.db
	@echo "✓ State cleaned"

# Clean layer cache (development)
clean-layers:
	@echo "Cleaning layer cache..."
	@rm -rf ~/.arca/layers/*
	@echo "✓ Layer cache cleaned"

# Clean container state (development)
clean-containers:
	@echo "Cleaning container state..."
	@rm -rf ~/.arca/containers/*
	@echo "✓ Container state cleaned"

# Clean all runtime state (database, layers, containers)
clean-all-state: clean-state clean-layers clean-containers
	@echo "✓ All runtime state cleaned"

# Install to system
install: release
	@echo "Installing $(BINARY) to $(INSTALL_DIR)..."
	@sudo cp $(BUILD_DIR)/$(BINARY) $(INSTALL_DIR)/
	@echo "✓ Installed to $(INSTALL_DIR)/$(BINARY)"

# Uninstall from system
uninstall:
	@echo "Uninstalling $(BINARY) from $(INSTALL_DIR)..."
	@sudo rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "✓ Uninstalled"

# Verify entitlements
verify-entitlements: $(BUILD_DIR)/$(BINARY)
	@echo "Verifying entitlements for $(BUILD_DIR)/$(BINARY)..."
	@codesign -d --entitlements - $(BUILD_DIR)/$(BINARY)

# Run the daemon in foreground mode (debug build)
run: codesign
	@echo "Starting Arca daemon (debug)..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock

# Run the daemon in foreground mode (debug build)
run-debug: codesign
	@echo "Starting Arca daemon (debug)..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug

# Run the daemon in foreground mode (release build)
run-release:
	@$(MAKE) CONFIGURATION=release codesign
	@echo "Starting Arca daemon (release)..."
	@rm -f /tmp/arca.sock
	@.build/release/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug

# Setup buildx builder with default-load=true (run after daemon is started)
setup-builder:
	@echo "Setting up Arca buildx builder..."
	@DOCKER_HOST=unix:///tmp/arca.sock ./scripts/setup-builder.sh

# Run daemon in background and automatically setup builder
run-with-setup: codesign
	@echo "Starting Arca daemon in background (debug)..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug > /tmp/arca-daemon.log 2>&1 &
	@echo "Daemon started in background (PID: $$!)"
	@echo "Logs: tail -f /tmp/arca-daemon.log"
	@echo ""
	@DOCKER_HOST=unix:///tmp/arca.sock ./scripts/setup-builder.sh

# Build kernel with TUN support
kernel:
	@echo "Building Linux kernel with TUN support..."
	@./scripts/build-kernel.sh

# Build custom vminit with WireGuard networking extension
# The build script builds arca-wireguard-service from the vminitd submodule
vminit:
	@echo "Building custom vminit:latest with networking extensions (release)..."
	@./scripts/build-vminit.sh release

# Build custom vminit in DEBUG mode (better logging)
vminit-debug:
	@echo "Building custom vminit:latest with networking extensions (debug)..."
	@./scripts/build-vminit.sh debug

# Generate gRPC code from proto files
gen-grpc:
	@echo "Generating gRPC code from proto files..."
	@./scripts/generate-grpc.sh

# Install protoc-gen-grpc-swift plugin (v1.27.0)
install-grpc-plugin:
	@echo "Installing protoc-gen-grpc-swift v1.27.0..."
	@if [ -f /usr/local/bin/protoc-gen-grpc-swift ]; then \
		echo "protoc-gen-grpc-swift already installed at /usr/local/bin/protoc-gen-grpc-swift"; \
		/usr/local/bin/protoc-gen-grpc-swift --version 2>&1 | head -1 || echo "version unknown"; \
		echo "To reinstall, run: sudo rm /usr/local/bin/protoc-gen-grpc-swift && make install-grpc-plugin"; \
	else \
		echo "Cloning grpc-swift v1.27.0..."; \
		rm -rf /tmp/grpc-swift-plugin-build; \
		git clone --depth 1 --branch 1.27.0 https://github.com/grpc/grpc-swift.git /tmp/grpc-swift-plugin-build; \
		cd /tmp/grpc-swift-plugin-build && swift build --product protoc-gen-grpc-swift -c release; \
		echo "Installing to /usr/local/bin/ (requires sudo)..."; \
		sudo cp /tmp/grpc-swift-plugin-build/.build/release/protoc-gen-grpc-swift /usr/local/bin/; \
		sudo chmod +x /usr/local/bin/protoc-gen-grpc-swift; \
		rm -rf /tmp/grpc-swift-plugin-build; \
		echo "✓ protoc-gen-grpc-swift v1.27.0 installed"; \
	fi

# Run tests
# Ensures daemon is built and signed before running tests
# Usage: make test [FILTER=TestName]
test: codesign
	@echo "Cleaning up test database..."
	@rm -f ~/.arca/state.db
	@echo "Building tests..."
	@swift build --build-tests
	@echo "Re-signing Arca binary (swift build --build-tests may have rebuilt it)..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/Arca
	@echo "Signing ArcaTestHelper binary..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/ArcaTestHelper
	@echo "Signing test binaries..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) .build/debug/ArcaPackageTests.xctest/Contents/MacOS/ArcaPackageTests 2>/dev/null || true
	@echo "✓ All binaries signed"
	@echo "Running tests with signed binaries..."
	@if [ -n "$(FILTER)" ]; then \
		swift test --skip-build --filter $(FILTER); \
	else \
		swift test --skip-build; \
	fi

# Run helper VM integration tests (requires signing)
test-helper: codesign
	@echo "Running helper VM integration tests..."
	@$(BUILD_DIR)/$(TEST_HELPER)

# Create distribution tarball
dist: release
	@echo "Creating distribution package (version: $(VERSION))..."
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)/arca-$(VERSION)/bin
	@mkdir -p $(DIST_DIR)/arca-$(VERSION)/share/doc/arca
	@cp .build/release/$(BINARY) $(DIST_DIR)/arca-$(VERSION)/bin/
	@cp README.md $(DIST_DIR)/arca-$(VERSION)/
	@cp Documentation/OVERVIEW.md $(DIST_DIR)/arca-$(VERSION)/share/doc/arca/
	@cp Documentation/ARCHITECTURE.md $(DIST_DIR)/arca-$(VERSION)/share/doc/arca/
	@cp Documentation/LIMITATIONS.md $(DIST_DIR)/arca-$(VERSION)/share/doc/arca/
	@echo "#!/bin/bash" > $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'echo "Installing Arca to /usr/local/bin..."' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'sudo cp bin/Arca /usr/local/bin/' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'echo "✓ Arca installed successfully"' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@echo 'echo "Run: arca daemon start"' >> $(DIST_DIR)/arca-$(VERSION)/install.sh
	@chmod +x $(DIST_DIR)/arca-$(VERSION)/install.sh
	@cd $(DIST_DIR) && tar czf arca-$(VERSION)-macos-arm64.tar.gz arca-$(VERSION)
	@echo "✓ Distribution created: $(DIST_DIR)/arca-$(VERSION)-macos-arm64.tar.gz"
	@echo ""
	@echo "To install:"
	@echo "  tar xzf $(DIST_DIR)/arca-$(VERSION)-macos-arm64.tar.gz"
	@echo "  cd arca-$(VERSION)"
	@echo "  ./install.sh"

# Create macOS .pkg installer (requires productbuild)
dist-pkg: release
	@echo "Creating macOS .pkg installer (version: $(VERSION))..."
	@rm -rf $(DIST_DIR)/pkg
	@mkdir -p $(DIST_DIR)/pkg/root/usr/local/bin
	@mkdir -p $(DIST_DIR)/pkg/scripts
	@cp .build/release/$(BINARY) $(DIST_DIR)/pkg/root/usr/local/bin/
	@echo '#!/bin/bash' > $(DIST_DIR)/pkg/scripts/postinstall
	@echo 'echo "Arca installed to /usr/local/bin/Arca"' >> $(DIST_DIR)/pkg/scripts/postinstall
	@echo 'echo "Run: arca daemon start"' >> $(DIST_DIR)/pkg/scripts/postinstall
	@echo 'exit 0' >> $(DIST_DIR)/pkg/scripts/postinstall
	@chmod +x $(DIST_DIR)/pkg/scripts/postinstall
	@pkgbuild --root $(DIST_DIR)/pkg/root \
		--scripts $(DIST_DIR)/pkg/scripts \
		--identifier com.liquescent.arca \
		--version $(VERSION) \
		--install-location / \
		$(DIST_DIR)/arca-$(VERSION).pkg
	@echo "✓ Package created: $(DIST_DIR)/arca-$(VERSION).pkg"
	@if [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		echo "Signing package with $(CODESIGN_IDENTITY)..."; \
		productsign --sign "$(CODESIGN_IDENTITY)" \
			$(DIST_DIR)/arca-$(VERSION).pkg \
			$(DIST_DIR)/arca-$(VERSION)-signed.pkg; \
		mv $(DIST_DIR)/arca-$(VERSION)-signed.pkg $(DIST_DIR)/arca-$(VERSION).pkg; \
		echo "✓ Package signed"; \
	fi
	@echo ""
	@echo "To install: sudo installer -pkg $(DIST_DIR)/arca-$(VERSION).pkg -target /"

# Notarize the package (requires Apple Developer account)
notarize: dist-pkg
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "Error: Notarization requires a valid code signing identity"; \
		echo "Set CODESIGN_IDENTITY to your Developer ID Application certificate"; \
		exit 1; \
	fi
	@if [ -z "$(APPLE_ID)" ] || [ -z "$(TEAM_ID)" ]; then \
		echo "Error: Notarization requires APPLE_ID and TEAM_ID environment variables"; \
		echo "  APPLE_ID=your@email.com"; \
		echo "  TEAM_ID=YOUR_TEAM_ID"; \
		exit 1; \
	fi
	@echo "Submitting package for notarization..."
	@xcrun notarytool submit $(DIST_DIR)/arca-$(VERSION).pkg \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "@keychain:AC_PASSWORD" \
		--wait
	@echo "Stapling notarization ticket..."
	@xcrun stapler staple $(DIST_DIR)/arca-$(VERSION).pkg
	@echo "✓ Package notarized and stapled"

# Clean distribution artifacts
clean-dist:
	@echo "Cleaning distribution artifacts..."
	@rm -rf $(DIST_DIR)
	@echo "✓ Distribution artifacts cleaned"

# Install service (LaunchAgent - no sudo required)
install-service: release
	@echo "Installing Arca as a LaunchAgent service..."
	@mkdir -p $(LAUNCH_AGENT_DIR)
	@mkdir -p ~/.arca
	@cp .build/release/$(BINARY) $(INSTALL_DIR)/
	@sed "s|HOME_DIR|$(HOME)|g" $(LAUNCH_AGENT_PLIST).template > $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)
	@echo "✓ Service installed to $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)"
	@echo "✓ Binary installed to $(INSTALL_DIR)/$(BINARY)"
	@echo ""
	@echo "To start the service:"
	@echo "  make start-service"
	@echo ""
	@echo "To configure your shell (add DOCKER_HOST):"
	@echo "  make configure-shell"

# Uninstall service
uninstall-service: stop-service
	@echo "Uninstalling Arca service..."
	@rm -f $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)
	@rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "✓ Service uninstalled"
	@echo ""
	@echo "Note: Shell configuration in ~/.zshrc or ~/.bash_profile not removed"
	@echo "Remove manually: export DOCKER_HOST=unix://$(DEFAULT_SOCKET)"

# Start service
start-service:
	@echo "Starting Arca service..."
	@launchctl load -w $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST)
	@sleep 2
	@if [ -S "$(DEFAULT_SOCKET)" ]; then \
		echo "✓ Arca service started"; \
		echo "Socket: $(DEFAULT_SOCKET)"; \
		echo ""; \
		echo "Configure your shell:"; \
		echo "  export DOCKER_HOST=unix://$(DEFAULT_SOCKET)"; \
		echo "Or run: make configure-shell"; \
	else \
		echo "⚠️  Service started but socket not found"; \
		echo "Check logs: tail -f ~/.arca/arca.log"; \
	fi

# Stop service
stop-service:
	@echo "Stopping Arca service..."
	@launchctl unload $(LAUNCH_AGENT_DIR)/$(LAUNCH_AGENT_PLIST) 2>/dev/null || true
	@echo "✓ Arca service stopped"

# Restart service
restart-service: stop-service start-service

# Service status
service-status:
	@echo "Arca service status:"
	@echo ""
	@if launchctl list | grep -q com.liquescent.arca; then \
		echo "✓ Service is running"; \
		launchctl list | grep com.liquescent.arca; \
	else \
		echo "✗ Service is not running"; \
	fi
	@echo ""
	@if [ -S "$(DEFAULT_SOCKET)" ]; then \
		echo "✓ Socket exists: $(DEFAULT_SOCKET)"; \
	else \
		echo "✗ Socket not found: $(DEFAULT_SOCKET)"; \
	fi

# Configure shell environment
configure-shell:
	@echo "Configuring shell environment..."
	@if [ -n "$$ZSH_VERSION" ] || [ -f ~/.zshrc ]; then \
		SHELL_RC=~/.zshrc; \
	elif [ -n "$$BASH_VERSION" ] || [ -f ~/.bash_profile ]; then \
		SHELL_RC=~/.bash_profile; \
	else \
		SHELL_RC=~/.profile; \
	fi; \
	if grep -q "DOCKER_HOST.*arca.sock" $$SHELL_RC 2>/dev/null; then \
		echo "✓ DOCKER_HOST already configured in $$SHELL_RC"; \
	else \
		echo "" >> $$SHELL_RC; \
		echo "# Arca - Docker Engine API for Apple Containerization" >> $$SHELL_RC; \
		echo "export DOCKER_HOST=unix://$(DEFAULT_SOCKET)" >> $$SHELL_RC; \
		echo "✓ Added DOCKER_HOST to $$SHELL_RC"; \
		echo ""; \
		echo "Run: source $$SHELL_RC"; \
		echo "Or restart your terminal"; \
	fi

# Help
help:
	@echo "Arca Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make                 - Build and codesign debug binary (incremental)"
	@echo "  make debug           - Build and codesign debug binary"
	@echo "  make release         - Build and codesign release binary"
	@echo "  make run             - Build, sign, and run daemon (debug) at /tmp/arca.sock"
	@echo "  make run-with-setup  - Start daemon in background + auto-configure buildx"
	@echo "  make setup-builder   - Setup buildx builder with default-load=true"
	@echo "  make run-release     - Build, sign, and run daemon (release) at /tmp/arca.sock"
	@echo "  make test            - Run all tests"
	@echo "  make clean           - Remove all build artifacts"
	@echo "  make clean-state     - Remove state database only"
	@echo "  make clean-layers    - Remove layer cache only"
	@echo "  make clean-containers - Remove container state only"
	@echo "  make clean-all-state - Remove all runtime state (db, layers, containers)"
	@echo "  make clean-dist      - Remove distribution artifacts"
	@echo "  make install         - Install release binary to /usr/local/bin"
	@echo "  make uninstall       - Remove binary from /usr/local/bin"
	@echo ""
	@echo "Service management (no sudo required):"
	@echo "  make install-service - Install Arca as LaunchAgent service"
	@echo "  make uninstall-service - Uninstall service"
	@echo "  make start-service   - Start Arca service"
	@echo "  make stop-service    - Stop Arca service"
	@echo "  make restart-service - Restart Arca service"
	@echo "  make service-status  - Check service status"
	@echo "  make configure-shell - Add DOCKER_HOST to shell profile"
	@echo ""
	@echo "Distribution:"
	@echo "  make dist            - Create distribution tarball (.tar.gz)"
	@echo "  make dist-pkg        - Create macOS .pkg installer"
	@echo "  make notarize        - Notarize .pkg (requires Apple Developer account)"
	@echo ""
	@echo "Advanced:"
	@echo "  make kernel          - Build Linux kernel with TUN support (10-15 min)"
	@echo "  make vminit          - Build custom vminit:latest (release, production use)"
	@echo "  make vminit-debug    - Build custom vminit:latest (debug, better logging)"
	@echo "  make gen-grpc        - Generate gRPC code from proto files"
	@echo "  make install-grpc-plugin - Install protoc-gen-grpc-swift v1.27.0"
	@echo "  make verify-entitlements - Display entitlements of built binary"
	@echo ""
	@echo "Build configurations:"
	@echo "  CONFIGURATION=debug   - Debug build (default)"
	@echo "  CONFIGURATION=release - Optimized release build"
	@echo ""
	@echo "Code signing:"
	@echo "  CODESIGN_IDENTITY=\"-\"                                    - Adhoc signing (default)"
	@echo "  CODESIGN_IDENTITY=\"Developer ID Application: Name (ID)\" - Release signing"
	@echo ""
	@echo "Distribution:"
	@echo "  VERSION=1.0.0          - Set version (default: git tag or 'dev')"
	@echo "  APPLE_ID=your@email.com - Apple ID for notarization"
	@echo "  TEAM_ID=YOURTEAMID     - Team ID for notarization"
	@echo ""
	@echo "Dependencies:"
	@echo "  protoc-gen-grpc-swift v1.27.0 (run 'make install-grpc-plugin')"
	@echo ""
	@echo "Notes:"
	@echo "  - Builds are incremental: only changed files are recompiled"
	@echo "  - Binary is automatically codesigned with entitlements"
	@echo "  - For distribution, set CODESIGN_IDENTITY to your Developer ID"
