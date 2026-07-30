PROJECT = ClingBar.xcodeproj
SCHEME = ClingBar
CONFIG ?= Debug
DERIVED = build
DIST = dist

.PHONY: build run open clean release dmg dist

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build

release:
	$(MAKE) build CONFIG=Release

run: build
	open "$(DERIVED)/Build/Products/$(CONFIG)/ClingBar.app"

open:
	open $(PROJECT)

# Release .app → dist/ClingBar-<version>.dmg (drag app to Applications).
dmg: release
	DERIVED=$(DERIVED) CONFIG=Release DIST_DIR=$(DIST) bash Scripts/make-dmg.sh

# Alias for packaging a downloadable disk image.
dist: dmg

clean:
	rm -rf $(DERIVED) $(DIST)
