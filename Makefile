.PHONY: clean clean-state install uninstall debug release run run-with-setup setup-builder all codesign verify-entitlements help kernel install-grpc-plugin test vminit gen-grpc

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

# Entitlements file
ENTITLEMENTS = Arca.entitlements

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
	@echo "Code signing $(BINARY) with entitlements..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(BINARY)
	@echo "Code signing $(TEST_HELPER) with entitlements..."
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(TEST_HELPER)
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
	@echo "  make clean-state     - Remove state database (fresh start)"
	@echo "  make install         - Install release binary to /usr/local/bin"
	@echo "  make uninstall       - Remove binary from /usr/local/bin"
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
	@echo "Dependencies:"
	@echo "  protoc-gen-grpc-swift v1.27.0 (run 'make install-grpc-plugin')"
	@echo ""
	@echo "Notes:"
	@echo "  - Builds are incremental: only changed files are recompiled"
	@echo "  - Binary is automatically codesigned with entitlements"
