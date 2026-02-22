.PHONY: clean run build test install

# Project configuration
PROJECT := mac/houmao/houmao.xcodeproj
SCHEME := houmao
CONFIGURATION := Debug
APP_NAME := houmao

# Clean: kill app + clear Xcode cache
clean:
	@echo "Closing old app..."
	@pkill -9 $(APP_NAME) 2>/dev/null || true
	@echo "Cleaning Xcode cache..."
	@rm -rf ~/Library/Developer/Xcode/DerivedData
	@echo "Clean complete"

# Run: clean + open Xcode
run: clean
	@echo "Opening Xcode..."
	@open $(PROJECT)

# Build (for CI or command-line builds)
build:
	@echo "Building project..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		build

# Build Release and install to /Applications
install:
	@echo "Building Release version..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		clean build
	@echo "Installing to /Applications..."
	@sudo rm -rf /Applications/$(APP_NAME).app
	@sudo cp -R ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Release/$(APP_NAME).app /Applications/
	@echo "Install complete! Launch from Spotlight or Applications folder"
	@echo "Note: First launch requires Accessibility permission"

# Run tests
test:
	@echo "Running tests..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		test
