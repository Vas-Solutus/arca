.PHONY: build clean codesign install uninstall debug release run

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

# Binary name
BINARY = Arca

# Installation directory
INSTALL_DIR = /usr/local/bin

# Entitlements file
ENTITLEMENTS = Arca.entitlements

# Default target
all: build codesign

# Build the project
build:
	@echo "Building $(BINARY) ($(CONFIGURATION))..."
	swift build $(SWIFT_BUILD_FLAGS)

# Codesign the binary with entitlements
codesign: build
	@echo "Code signing $(BINARY) with entitlements..."
	@if [ -f "$(BUILD_DIR)/$(BINARY)" ]; then \
		codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(BINARY); \
		echo "✓ Code signing complete"; \
	else \
		echo "✗ Binary not found at $(BUILD_DIR)/$(BINARY)"; \
		exit 1; \
	fi

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
verify-entitlements: codesign
	@echo "Verifying entitlements for $(BUILD_DIR)/$(BINARY)..."
	@codesign -d --entitlements - $(BUILD_DIR)/$(BINARY)

# Run the daemon in foreground mode
run: codesign
	@echo "Starting Arca daemon..."
	@rm -f /tmp/arca.sock
	@$(BUILD_DIR)/$(BINARY) daemon start --socket-path /tmp/arca.sock --log-level debug

# Help
help:
	@echo "Arca Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make              - Build debug binary and codesign with entitlements"
	@echo "  make debug        - Build debug binary (default)"
	@echo "  make release      - Build release binary"
	@echo "  make codesign     - Codesign binary with entitlements"
	@echo "  make run          - Run daemon in foreground at /tmp/arca.sock"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make install      - Install release binary to /usr/local/bin"
	@echo "  make uninstall    - Remove binary from /usr/local/bin"
	@echo "  make verify-entitlements - Display entitlements of built binary"
	@echo ""
	@echo "Build configurations:"
	@echo "  CONFIGURATION=debug   - Debug build (default)"
	@echo "  CONFIGURATION=release - Optimized release build"
