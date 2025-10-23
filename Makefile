.PHONY: clean install uninstall debug release run all codesign verify-entitlements help helpervm kernel install-grpc-plugin test tap-forwarder vminit gen-grpc

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

# Build helper VM image
helpervm:
	@echo "Building helper VM image..."
	@./scripts/build-helper-vm.sh

# Build kernel with TUN support
kernel:
	@echo "Building Linux kernel with TUN support..."
	@./scripts/build-kernel.sh

# Build TAP forwarder for Linux
tap-forwarder:
	@echo "Building arca-tap-forwarder for Linux..."
	@./scripts/build-tap-forwarder.sh

# Build custom vminit with arca-tap-forwarder
vminit: tap-forwarder
	@echo "Building custom vminit:latest with arca-tap-forwarder..."
	@./scripts/build-vminit.sh

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
# Helper VM tests will start the Arca daemon (which has virtualization entitlement)
# Usage: make test [FILTER=TestName]
test:
	@echo "Running tests..."
	@if [ -n "$(FILTER)" ]; then \
		swift test --filter $(FILTER); \
	else \
		swift test; \
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
	@echo "  make              - Build and codesign debug binary (incremental)"
	@echo "  make debug        - Build and codesign debug binary"
	@echo "  make release      - Build and codesign release binary"
	@echo "  make run          - Build, sign, and run daemon (debug) at /tmp/arca.sock"
	@echo "  make run-release  - Build, sign, and run daemon (release) at /tmp/arca.sock"
	@echo "  make test         - Run all tests (helper VM tests start Arca daemon)"
	@echo "  make clean        - Remove all build artifacts"
	@echo "  make install      - Install release binary to /usr/local/bin"
	@echo "  make uninstall    - Remove binary from /usr/local/bin"
	@echo "  make helpervm     - Build helper VM disk image for networking"
	@echo "  make kernel       - Build Linux kernel with TUN support (10-15 min)"
	@echo "  make tap-forwarder - Build arca-tap-forwarder for Linux (container networking)"
	@echo "  make vminit       - Build custom vminit:latest with arca-tap-forwarder"
	@echo "  make gen-grpc     - Generate gRPC code from proto files"
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
