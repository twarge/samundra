# Builds everything Samundra is: the Mac app and the HR4000 capture
# diagnostic.
#
#   make            app + diagnostic
#   make mac        debug app        (make mac-release for optimised)
#   make cli        HR4000 capture CLI into build/
#   make icon       regenerate the app icon
#   make clean

.PHONY: all mac mac-release cli icon clean

all: mac cli

# Exactly what Xcode's own Build does — same scheme, same default
# DerivedData — so a make build and a ⌘B are the same build.
mac:
	xcodebuild -project apps/Samundra.xcodeproj -scheme Samundra \
	  -destination "platform=macOS" -allowProvisioningUpdates -quiet build
	@echo "==> Built for macOS"

mac-release:
	xcodebuild -project apps/Samundra.xcodeproj -scheme Samundra \
	  -destination "platform=macOS" -configuration Release \
	  -allowProvisioningUpdates -quiet build
	@echo "==> Built for macOS (Release)"

cli:
	./Tools/build-cli.sh

icon:
	swift apps/make-icon.swift

clean:
	rm -rf build
	xcodebuild -project apps/Samundra.xcodeproj -scheme Samundra -quiet clean
