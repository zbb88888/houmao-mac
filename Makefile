.PHONY: clean run build test install test-demo build-cli build-app

# Project configuration
APP_NAME := houmao

# Clean: kill app + clear build artifacts
clean:
	@echo "Closing old app..."
	@pkill -9 $(APP_NAME) 2>/dev/null || true
	@echo "Cleaning Swift build artifacts..."
	@swift package clean 2>/dev/null || true
	@rm -rf .build
	@echo "Clean complete"

# Run: open Package.swift in Xcode (recommended for macOS)
run:
	@echo "Opening Package.swift in Xcode..."
	@open Package.swift

# Build using Swift Package Manager (CLI)
# This produces a command-line executable in .build/debug/houmao
build-cli:
	@echo "Building command-line version using SPM..."
	@swift build

# Build the macOS App bundle using xcodebuild (requires Xcode)
# xcodebuild can resolve dependencies from Package.swift automatically.
build-app:
	@echo "Building macOS App bundle..."
	@xcodebuild -scheme $(APP_NAME) -destination 'platform=macOS' build

# Default build target
build: build-cli

# Run tests
test:
	@echo "Running Swift tests..."
	@swift test

# Run demo tests (Python-based, for comparison)
test-demo:
	@echo "Running Python demo tests..."
	@cd tests/openai_adapter && make test

# Install instruction
install:
	@echo "To install the macOS application:"
	@echo "1. Run 'make build-app' to build the .app bundle"
	@echo "2. Alternatively, open Package.swift in Xcode and use 'Product -> Archive'."
