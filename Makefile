APP_NAME    := FreeWhisper
BUNDLE_ID   := dev.freewhisper.FreeWhisper
CONFIG      ?= debug
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN_DIR     := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)

# MLX runs the on-device summarizer on the GPU, and SwiftPM cannot compile Metal
# shaders — mlx-swift says so itself. So the kernels come from a one-off
# xcodebuild of the same package, which produces them as a resource bundle we
# copy next to the SwiftPM binaries. Cached: it is only rebuilt when mlx-swift
# changes, which is what keeps `make build` fast after the first run.
#
# Keyed by configuration. A release bundle must not ship debug kernels, and
# giving each configuration its own product directory means neither invalidates
# the other's cache.
XC_DERIVED  := .build/xcode
ifeq ($(CONFIG),release)
XC_CONFIG   := Release
else
XC_CONFIG   := Debug
endif
MLX_BUNDLE  := mlx-swift_Cmlx.bundle
MLX_BUILT   := $(XC_DERIVED)/Build/Products/$(XC_CONFIG)/$(MLX_BUNDLE)

ICON_SRC    := Resources/AppIcon.png
ICON_OUT    := Resources/AppIcon.icns
ICONSET     := $(BUILD_DIR)/AppIcon.iconset

# --- version ----------------------------------------------------------------
# The marketing version is the git tag. v0.2.0 -> 0.2.0; so does v0.2.0-4-gabc1234
# (an untagged commit past a tag), because CFBundleShortVersionString only accepts
# dotted integers. CI passes VERSION explicitly from the tag ref.
GIT_DESCRIBE := $(shell git describe --tags --match 'v[0-9]*' 2>/dev/null)
VERSION      ?= $(patsubst v%,%,$(firstword $(subst -, ,$(GIT_DESCRIBE))))
ifeq ($(strip $(VERSION)),)
VERSION := 0.0.0
endif

# CFBundleVersion must increase monotonically forever, independently of the
# marketing version, or LaunchServices and SMAppService disagree about which copy
# of the app is newer. Commit count is monotonic on a linear main and needs no
# state outside the repo — but it does need a full clone, hence fetch-depth: 0
# in CI and the fallback below.
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null)
ifeq ($(strip $(BUILD_NUMBER)),)
BUILD_NUMBER := 0
endif

# --- signing ----------------------------------------------------------------
# TCC keys off the code signing identity. Ad-hoc signing produces a new identity
# on every rebuild, so macOS re-prompts for microphone/audio-capture access each
# time. Prefer a real Development cert; fall back to ad-hoc so the build still
# works on a machine without one.
DEV_CODESIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $$2}')
ifeq ($(strip $(DEV_CODESIGN_ID)),)
DEV_CODESIGN_ID := -
endif

# Release builds need a Developer ID Application cert, and deliberately have no
# fallback. An ad-hoc or Development-signed artifact is accepted by codesign and
# then rejected by the notary service twenty minutes later, once you have stopped
# watching — so fail here instead, in two seconds.
RELEASE_CODESIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | awk '{print $$2}')

SIGN_MODE ?= dev
ifeq ($(SIGN_MODE),release)
CODESIGN_ID    := $(RELEASE_CODESIGN_ID)
# A secure timestamp is mandatory for notarization. Dev builds skip it because it
# costs a round trip to Apple's timestamp server on every single rebuild.
TIMESTAMP_FLAG := --timestamp
else
CODESIGN_ID    := $(DEV_CODESIGN_ID)
TIMESTAMP_FLAG := --timestamp=none
endif

# --- distribution -----------------------------------------------------------
DIST_DIR := $(BUILD_DIR)/dist
ZIP      := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip
DMG      := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
STAGE    := $(BUILD_DIR)/dmg-stage
VOL_NAME := $(APP_NAME) $(VERSION)

# notarytool auth. CI exports AC_API_KEY_PATH and authenticates with an App Store
# Connect API key; a laptop that has run `notarytool store-credentials` uses the
# stored keychain profile instead.
NOTARY_PROFILE ?= freewhisper
ifdef AC_API_KEY_PATH
NOTARY_AUTH := --key "$(AC_API_KEY_PATH)" --key-id "$(AC_API_KEY_ID)" --issuer "$(AC_API_ISSUER_ID)"
else
NOTARY_AUTH := --keychain-profile "$(NOTARY_PROFILE)"
endif

.PHONY: all build app sign run test clean fwctl release identity help metal icon \
        zip notarize-app staple-app dmg notarize-dmg staple-dmg verify dist

all: app

help:
	@echo "make build     - swift build, plus MLX's Metal kernels"
	@echo "make metal     - compile MLX's Metal kernels only"
	@echo "make icon      - regenerate $(ICON_OUT) from $(ICON_SRC)"
	@echo "make app       - build + assemble + sign $(APP)"
	@echo "make run       - app, then launch it (kills any running copy first)"
	@echo "make fwctl     - build the headless CLI, print its path"
	@echo "make test      - swift test"
	@echo "make release   - CONFIG=release build + zipped app"
	@echo "make dist      - release build, notarized and stapled, .dmg + .zip"
	@echo "make verify    - check signature, Gatekeeper and staple on the output"
	@echo "make identity  - show which signing identity will be used"
	@echo "make clean     - remove build artifacts"

identity:
	@echo "VERSION      = $(VERSION) ($(BUILD_NUMBER))"
	@echo "SIGN_MODE    = $(SIGN_MODE)"
	@echo "CODESIGN_ID  = $(CODESIGN_ID)"
	@echo ""
	@security find-identity -v -p codesigning 2>/dev/null || true

build: metal
	swift build -c $(CONFIG)
	@# SwiftPM looks for a target's resources next to the binary, so staging the
	@# bundle here is what makes `swift run fwctl` and the app find the kernels.
	@cp -R "$(MLX_BUILT)" "$(BIN_DIR)/"

metal: $(MLX_BUILT)

$(MLX_BUILT):
	@xcrun metal --version >/dev/null 2>&1 || { \
		echo "The Metal toolchain isn't installed — MLX needs it to compile its"; \
		echo "GPU kernels. Xcode 26 ships it as a separate download:"; \
		echo ""; \
		echo "    xcodebuild -downloadComponent MetalToolchain"; \
		echo ""; \
		exit 1; }
	@echo "compiling MLX's Metal kernels ($(XC_CONFIG), slow, but only when mlx-swift changes)…"
	@xcodebuild build -scheme FreeWhisperKit -destination 'platform=macOS' \
		-derivedDataPath "$(XC_DERIVED)" -configuration $(XC_CONFIG) \
		-skipMacroValidation -quiet

# Regenerate the .icns from the 1024px master. The result is committed, so this
# only needs running when the artwork changes — `make app` and CI just copy it.
icon:
	@test -f "$(ICON_SRC)" || { echo "missing $(ICON_SRC) (1024x1024 png)"; exit 1; }
	@rm -rf "$(ICONSET)" && mkdir -p "$(ICONSET)"
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$(ICON_SRC)" --out "$(ICONSET)/icon_$${s}x$${s}.png" >/dev/null; \
		d=$$((s * 2)); \
		sips -z $$d $$d "$(ICON_SRC)" --out "$(ICONSET)/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	@iconutil -c icns "$(ICONSET)" -o "$(ICON_OUT)"
	@rm -rf "$(ICONSET)"
	@echo "wrote $(ICON_OUT)"

# Assemble a real .app bundle. SwiftPM only gives us bare executables, so the
# bundle structure, Info.plist and signing are done here.
app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BIN_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp "$(BIN_DIR)/fwctl" "$(CONTENTS)/MacOS/fwctl"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if [ -f "$(ICON_OUT)" ]; then \
		cp "$(ICON_OUT)" "$(CONTENTS)/Resources/AppIcon.icns"; \
	else \
		echo "warning: no $(ICON_OUT) — run 'make icon'; shipping without an icon"; \
	fi
	@# The committed plist carries placeholder versions; the real ones come from
	@# the git tag. Rewriting the copy keeps Resources/Info.plist a valid plist.
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"
	@# SwiftPM emits resource bundles next to the binary; carry them along.
	@for b in "$(BIN_DIR)"/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" "$(CONTENTS)/Resources/" || true; \
	done
	@$(MAKE) --no-print-directory sign
	@echo "built $(APP) — $(VERSION) ($(BUILD_NUMBER))"

IDENTITY_STAMP := $(BUILD_DIR)/.last-codesign-identity

sign:
	@test -n "$(CODESIGN_ID)" || { \
		echo "no signing identity for SIGN_MODE=$(SIGN_MODE)."; \
		echo "release builds need a 'Developer ID Application' certificate."; \
		security find-identity -v -p codesigning; exit 1; }
	@# macOS binds every TCC grant to the app's designated requirement, which is
	@# derived from the signing certificate. Re-sign the same bundle with a
	@# different identity — say, `make run` (Apple Development) after `make dist`
	@# (Developer ID) — and every permission silently stops applying, while
	@# System Settings happily goes on showing the app toggled on. That failure
	@# looks exactly like a bug in the app and is miserable to diagnose, so say
	@# so at the moment it happens.
	@if [ -f "$(IDENTITY_STAMP)" ] && [ "$$(cat $(IDENTITY_STAMP))" != "$(CODESIGN_ID)" ]; then \
		echo ""; \
		echo "  ⚠  signing identity changed for $(APP)"; \
		echo "     was: $$(cat $(IDENTITY_STAMP))"; \
		echo "     now: $(CODESIGN_ID)"; \
		echo ""; \
		echo "     macOS ties privacy permissions to the signing identity, so the"; \
		echo "     grants you already gave this app no longer apply and it will"; \
		echo "     report them as denied — even though System Settings still shows"; \
		echo "     it switched on. To recover:"; \
		echo ""; \
		echo "         tccutil reset ScreenCapture dev.freewhisper.FreeWhisper"; \
		echo "         tccutil reset Accessibility dev.freewhisper.FreeWhisper"; \
		echo ""; \
		echo "     then grant them again. Sticking to one of SIGN_MODE=dev or"; \
		echo "     SIGN_MODE=release avoids this."; \
		echo ""; \
	fi
	@mkdir -p "$(BUILD_DIR)" && printf '%s' "$(CODESIGN_ID)" > "$(IDENTITY_STAMP)"
	@# Inside out. Most of the SwiftPM resource bundles are flat directories of
	@# data and seal correctly as ordinary resources, but mlx-swift's carries a
	@# Contents/Info.plist and a compiled default.metallib, which makes it a real
	@# nested bundle that needs its own signature — without one, notarization
	@# rejects the app. Detected by the Info.plist rather than by name so the next
	@# dependency shaped like this is covered too. No --entitlements here:
	@# entitlements belong to executables, not resource bundles.
	@for b in "$(CONTENTS)/Resources"/*.bundle; do \
		[ -f "$$b/Contents/Info.plist" ] || continue; \
		codesign --force --options runtime $(TIMESTAMP_FLAG) \
			--sign "$(CODESIGN_ID)" "$$b" || exit 1; \
	done
	@# Nothing ships a loose Mach-O today, but codesign will not warn if one
	@# appears, and the notary service will.
	@find "$(CONTENTS)/Resources" -type f -perm -u+x -print0 2>/dev/null | \
		xargs -0 -I{} sh -c 'file -b "{}" | grep -q Mach-O && \
			codesign --force --options runtime $(TIMESTAMP_FLAG) \
				--sign "$(CODESIGN_ID)" "{}"' || true
	@codesign --force --options runtime $(TIMESTAMP_FLAG) \
		--entitlements Resources/$(APP_NAME).entitlements \
		--sign "$(CODESIGN_ID)" \
		"$(CONTENTS)/MacOS/fwctl"
	@codesign --force --options runtime $(TIMESTAMP_FLAG) \
		--entitlements Resources/$(APP_NAME).entitlements \
		--sign "$(CODESIGN_ID)" \
		"$(APP)"
	@codesign --verify --deep --strict "$(APP)" && echo "signed with: $(CODESIGN_ID)"

# Killing a running instance leaves it registered with LaunchServices for a
# moment after the process is gone. Opening into that window fails with -600
# (procNotFound), so wait for the old process to exit and then retry past the
# residual lag. Only bites when an instance was actually running, which is why
# the first `make run` on a machine always looks fine.
run: app
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@n=0; while pgrep -x "$(APP_NAME)" >/dev/null 2>&1 && [ $$n -lt 100 ]; do \
		sleep 0.1; n=$$((n+1)); \
	done
	@for i in 1 2 3 4 5; do \
		open "$(APP)" 2>/dev/null && exit 0; \
		sleep 0.3; \
	done; \
	open "$(APP)"
	@echo "launched. logs: log stream --predicate 'subsystem == \"$(BUNDLE_ID)\"' --level debug"

# fwctl lives inside the bundle so it inherits the app's TCC identity rather than
# Terminal's. The shim keeps it reachable from the repo root.
fwctl: app
	@printf '#!/bin/sh\nexec "$$(dirname "$$0")/$(APP)/Contents/MacOS/fwctl" "$$@"\n' > "$(BUILD_DIR)/../fw"
	@chmod +x "$(BUILD_DIR)/../fw"
	@echo "./fw -> $(APP)/Contents/MacOS/fwctl"

test:
	swift test

release:
	@$(MAKE) --no-print-directory CONFIG=release app
	@$(MAKE) --no-print-directory zip

# --sequesterRsrc --keepParent is the archive shape notarytool expects.
zip:
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(ZIP)"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@echo "packaged $(ZIP)"

notarize-app: zip
	@# No echo: NOTARY_AUTH carries the key id and issuer on the command line.
	@xcrun notarytool submit "$(ZIP)" $(NOTARY_AUTH) --wait --timeout 30m

staple-app:
	@xcrun stapler staple "$(APP)"

dmg:
	@mkdir -p "$(DIST_DIR)"
	@rm -rf "$(STAGE)" && mkdir -p "$(STAGE)"
	@# ditto rather than cp -R: it is the only copy that reliably preserves
	@# everything a signed bundle seals, including the stapled ticket.
	@ditto "$(APP)" "$(STAGE)/$(APP_NAME).app"
	@ln -s /Applications "$(STAGE)/Applications"
	@# An optional committed .DS_Store gives the mounted window its layout and
	@# background. Produce it once locally with create-dmg and commit it — do not
	@# call create-dmg from here: it positions icons by driving Finder over
	@# AppleScript, which needs a logged-in GUI session and therefore hangs or
	@# fails with -1743 on a headless CI runner.
	@[ -f Resources/dmg/DS_Store ] && cp Resources/dmg/DS_Store "$(STAGE)/.DS_Store" || true
	@rm -f "$(DMG)"
	@hdiutil create -volname "$(VOL_NAME)" -srcfolder "$(STAGE)" \
		-fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$(DMG)" >/dev/null
	@rm -rf "$(STAGE)"
	@codesign --force $(TIMESTAMP_FLAG) --sign "$(CODESIGN_ID)" "$(DMG)"
	@echo "packaged $(DMG)"

notarize-dmg:
	@xcrun notarytool submit "$(DMG)" $(NOTARY_AUTH) --wait --timeout 30m

staple-dmg:
	@xcrun stapler staple "$(DMG)"

verify:
	@echo "== signature =="
	@codesign --verify --deep --strict --verbose=2 "$(APP)"
	@codesign -dvv "$(APP)" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' || true
	@echo "== nested MLX bundle (unsigned here means notarization will fail) =="
	@codesign -dv "$(CONTENTS)/Resources/$(MLX_BUNDLE)" 2>&1 | grep -E 'Signature|Authority' || true
	@echo "== entitlements (get-task-allow here means a debug build leaked in) =="
	@codesign -d --entitlements - --xml "$(APP)" 2>/dev/null | plutil -p - || true
	@echo "== architecture =="
	@lipo -info "$(CONTENTS)/MacOS/$(APP_NAME)"
	@echo "== gatekeeper =="
	@spctl -a -vvv -t exec "$(APP)" || true
	@xcrun stapler validate "$(APP)" || true
	@if [ -f "$(DMG)" ]; then \
		echo "== dmg =="; \
		spctl -a -vvv -t open --context context:primary-signature "$(DMG)" || true; \
		xcrun stapler validate "$(DMG)" || true; \
	fi

# The full release chain. Two notarization submissions, deliberately: submitting
# only the DMG does notarize its contents, but `stapler` writes a ticket into
# whatever you hand it, so the app dragged out to /Applications would carry none
# of its own. Its first launch would then depend on an online Gatekeeper check,
# which fails offline or behind a captive portal with "FreeWhisper is damaged".
# So: notarize the zip, staple the app, build the DMG from the stapled app, then
# notarize and staple the DMG. Both artifacts validate offline.
dist:
	@$(MAKE) --no-print-directory CONFIG=release SIGN_MODE=release VERSION=$(VERSION) app
	@$(MAKE) --no-print-directory SIGN_MODE=release VERSION=$(VERSION) notarize-app
	@$(MAKE) --no-print-directory SIGN_MODE=release VERSION=$(VERSION) staple-app
	@$(MAKE) --no-print-directory SIGN_MODE=release VERSION=$(VERSION) zip
	@$(MAKE) --no-print-directory SIGN_MODE=release VERSION=$(VERSION) dmg
	@$(MAKE) --no-print-directory SIGN_MODE=release VERSION=$(VERSION) notarize-dmg
	@$(MAKE) --no-print-directory SIGN_MODE=release VERSION=$(VERSION) staple-dmg
	@$(MAKE) --no-print-directory CONFIG=release SIGN_MODE=release VERSION=$(VERSION) verify
	@echo ""
	@shasum -a 256 "$(DMG)" "$(ZIP)"

# Note this also removes .build/xcode, i.e. MLX's compiled Metal kernels — the
# slowest part of a cold build. Intentional for `clean`, but it is why the next
# `make build` after one takes minutes rather than seconds.
clean:
	swift package clean
	rm -rf "$(BUILD_DIR)" .build ./fw
