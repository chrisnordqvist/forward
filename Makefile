APP        := Forward
BUNDLE_ID  := co.nordqvist.forward
CONFIG     := release
BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP).app
CONTENTS   := $(APP_BUNDLE)/Contents
BIN_PATH   := $(shell swift build -c $(CONFIG) --show-bin-path)
# Where `make install` puts the app. Override for a per-user install:
#   make install DEST=$HOME
DEST       ?= /Applications
DIST_DIR   := dist
VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST_ZIP   := $(DIST_DIR)/$(APP)-$(VERSION)-arm64.zip

.PHONY: all bundle run install uninstall test clean debug dist

all: bundle

bundle:
	@swift build -c $(CONFIG) --product $(APP)
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BIN_PATH)/$(APP)" "$(CONTENTS)/MacOS/$(APP)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Ad-hoc sign. Not sandboxed: the app spawns /usr/bin/ssh.
	@codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_BUNDLE)" 2>/dev/null
	@echo "built $(APP_BUNDLE)"

debug:
	@$(MAKE) bundle CONFIG=debug

# SIGTERM triggers a clean shutdown (ssh masters exit, ports released), but that takes a
# moment. Waiting matters: `open` on a still-terminating app just reactivates the dying
# instance instead of launching the new build.
define quit_app
	@pkill -x "$(APP)" 2>/dev/null || true
	@for i in $$(seq 1 40); do \
		pgrep -x "$(APP)" >/dev/null 2>&1 || break; \
		sleep 0.25; \
	done
	@pkill -9 -x "$(APP)" 2>/dev/null || true
endef

run: bundle
	$(call quit_app)
	@open "$(APP_BUNDLE)"
	@echo "launched — look for the menu bar icon"

install: bundle
	$(call quit_app)
	@mkdir -p "$(DEST)"
	@rm -rf "$(DEST)/$(APP).app"
	@cp -R "$(APP_BUNDLE)" "$(DEST)/"
	@echo "installed to $(DEST)/$(APP).app"

uninstall:
	$(call quit_app)
	@rm -rf "$(DEST)/$(APP).app"
	@echo "removed $(DEST)/$(APP).app"

# A zip to carry to another Apple-silicon Mac.
#
# ditto (not `zip`) because it preserves the code signature and extended attributes —
# a plain `zip` mangles the bundle and the copy is rejected as damaged on arrival.
dist: bundle
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_ZIP)"
	@codesign --verify --deep --strict "$(APP_BUNDLE)"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(DIST_ZIP)"
	@cp Scripts/INSTALL.txt "$(DIST_DIR)/INSTALL.txt"
	@echo "built $(DIST_ZIP) ($$(du -h "$(DIST_ZIP)" | cut -f1)), arch: $$(lipo -archs "$(CONTENTS)/MacOS/$(APP)")"
	@echo "read $(DIST_DIR)/INSTALL.txt — the target Mac needs the quarantine flag cleared"

test:
	@swift test

clean:
	@swift package clean
	@rm -rf "$(BUILD_DIR)" .build
