PROJECT = ClingBar.xcodeproj
SCHEME = ClingBar
CONFIG ?= Debug
DERIVED = build

.PHONY: build run open clean release

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build

release:
	$(MAKE) build CONFIG=Release

run: build
	open "$(DERIVED)/Build/Products/$(CONFIG)/ClingBar.app"

open:
	open $(PROJECT)

clean:
	rm -rf $(DERIVED)
