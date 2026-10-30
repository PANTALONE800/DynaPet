SHELL := /bin/sh
ARCH ?= $(shell uname -m)
MACOS_MIN ?= 14.0
SIGN_IDENTITY ?= -
VARIANT ?= full
ifeq ($(filter $(VARIANT),full layered),)
$(error VARIANT must be full or layered)
endif
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
BUILD := $(ROOT)/.build/app/$(ARCH)
MODULES := $(BUILD)/modules
APP := $(ROOT)/dist/$(ARCH)/$(if $(filter full,$(VARIANT)),DynaPet.app,DynaPet-layered.app)
CONTENTS := $(APP)/Contents
FRAMEWORKS := $(CONTENTS)/Frameworks
RESOURCES := $(CONTENTS)/Resources
MACOS := $(CONTENTS)/MacOS
EXECUTABLE := $(MACOS)/DynaPet
BRIDGE := $(ROOT)/MacPlatform/Bridge/PetBridge
BRIDGE_ARTIFACT := $(ROOT)/.build/petbridge/$(ARCH)/Frameworks/libpetbridge.dylib
OVERLAY := $(BUILD)/toolchain-overlay.json
CLANG := xcrun --sdk macosx clang
SWIFTC := xcrun --sdk macosx swiftc
SWIFT_FLAGS = -O -swift-version 5 -target $(ARCH)-apple-macos$(MACOS_MIN) -sdk "$(SDK)" -vfsoverlay "$(OVERLAY)" -module-cache-path "$(BUILD)/module-cache"
LINK_FLAGS = -I"$(MODULES)" -L"$(FRAMEWORKS)"
LIB_RPATH = -Xlinker -rpath -Xlinker '@loader_path'
EXE_RPATH = -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
DOMAIN_SOURCES := $(wildcard $(ROOT)/SharedSpec/Swift/PetCore/*.swift)
CORE_SOURCES := $(wildcard $(ROOT)/SharedSpec/Swift/Core/*.swift)
WINDOW_SOURCES := $(wildcard $(ROOT)/MacPlatform/AppKit/*.swift)
APP_SOURCES := $(wildcard $(ROOT)/MacPlatform/Runtime/App/*.swift)
LAYERED_LIBRARIES := libPetCore.dylib libIPCProtocol.dylib libMacIPCTransport.dylib libMacPetWindowing.dylib libpetbridge.dylib

LIBRARIES := $(if $(filter full,$(VARIANT)),libpetbridge.dylib,$(LAYERED_LIBRARIES))
FULL_ROOT := $(abspath $(ROOT)/../DynaPet)
FULL_SOURCES := $(wildcard $(FULL_ROOT)/*.swift) $(ROOT)/../DynaPetNative/Sources/PetCore/PetLogic.swift $(ROOT)/../DynaPetNative/Sources/PetCore/WindowManager.swift $(ROOT)/../DynaPetNative/Sources/Windowing/AppKitWindowManager.swift

ifeq ($(filter $(ARCH),arm64 x86_64),)
$(error ARCH must be arm64 or x86_64)
endif

.PHONY: all app package resources icon plist verify bridge-test zip print-config
all: app

$(BUILD) $(MODULES) $(FRAMEWORKS) $(RESOURCES) $(MACOS):
	mkdir -p "$@"

$(OVERLAY): $(BRIDGE)/tools/prepare_overlay.py | $(BUILD)
	python3 "$<" "$(BUILD)"

$(FRAMEWORKS)/libpetbridge.dylib: $(BRIDGE)/src/pet_bridge.m $(BRIDGE)/include/pet_bridge.h $(BRIDGE)/Makefile | $(FRAMEWORKS)
	$(MAKE) -C "$(BRIDGE)" ARCH=$(ARCH) MACOS_MIN=$(MACOS_MIN) "$(BRIDGE_ARTIFACT)"
	cp -p "$(BRIDGE_ARTIFACT)" "$@"

$(FRAMEWORKS)/libPetCore.dylib: $(DOMAIN_SOURCES) $(OVERLAY) $(ROOT)/Makefile | $(MODULES) $(FRAMEWORKS)
	$(SWIFTC) $(SWIFT_FLAGS) -emit-library -emit-module -module-name PetCore $(DOMAIN_SOURCES) \
		-emit-module-path "$(MODULES)/PetCore.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libPetCore.dylib' $(LIB_RPATH) -o "$@"

$(FRAMEWORKS)/libIPCProtocol.dylib: $(CORE_SOURCES) $(FRAMEWORKS)/libPetCore.dylib $(ROOT)/Makefile
	$(SWIFTC) $(SWIFT_FLAGS) $(LINK_FLAGS) -lPetCore -emit-library -emit-module -module-name IPCProtocol $(CORE_SOURCES) \
		-emit-module-path "$(MODULES)/IPCProtocol.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libIPCProtocol.dylib' $(LIB_RPATH) -o "$@"

$(BUILD)/lifecycle.o: $(ROOT)/MacPlatform/Bridge/CSystem/lifecycle.c $(ROOT)/MacPlatform/Bridge/CSystem/include/CSystem.h | $(BUILD)
	$(CLANG) -arch $(ARCH) -isysroot "$(SDK)" -mmacosx-version-min=$(MACOS_MIN) -std=c11 -D_POSIX_C_SOURCE=200809L -pthread -Wall -Wextra -Werror \
		-I"$(ROOT)/MacPlatform/Bridge/CSystem/include" -c "$<" -o "$@"

$(FRAMEWORKS)/libMacIPCTransport.dylib: $(ROOT)/MacPlatform/Transport/StreamIO.swift $(FRAMEWORKS)/libIPCProtocol.dylib $(BUILD)/lifecycle.o $(ROOT)/Makefile
	$(SWIFTC) $(SWIFT_FLAGS) $(LINK_FLAGS) -I"$(ROOT)/MacPlatform/Bridge/CSystem/include" -lIPCProtocol -lPetCore \
		-emit-library -emit-module -module-name MacIPCTransport "$<" "$(BUILD)/lifecycle.o" \
		-emit-module-path "$(MODULES)/MacIPCTransport.swiftmodule" -Xlinker -install_name -Xlinker '@rpath/libMacIPCTransport.dylib' $(LIB_RPATH) -o "$@"

$(FRAMEWORKS)/libMacPetWindowing.dylib: $(WINDOW_SOURCES) $(FRAMEWORKS)/libIPCProtocol.dylib $(ROOT)/Makefile
	$(SWIFTC) $(SWIFT_FLAGS) $(LINK_FLAGS) -lIPCProtocol -lPetCore -emit-library -emit-module -module-name MacPetWindowing $(WINDOW_SOURCES) \
		-emit-module-path "$(MODULES)/MacPetWindowing.swiftmodule" -framework AppKit -framework IOKit -framework ApplicationServices -framework ImageIO \
		-Xlinker -install_name -Xlinker '@rpath/libMacPetWindowing.dylib' $(LIB_RPATH) -o "$@"

ifeq ($(VARIANT),full)
$(EXECUTABLE): $(FULL_SOURCES) $(OVERLAY) $(FRAMEWORKS)/libpetbridge.dylib $(ROOT)/Makefile | $(MACOS)
	$(SWIFTC) $(SWIFT_FLAGS) $(FULL_SOURCES) -L"$(FRAMEWORKS)" -lpetbridge $(EXE_RPATH) \
		-framework AppKit -framework SwiftUI -framework IOKit -framework ApplicationServices \
		-framework ServiceManagement -framework ScreenCaptureKit -framework Vision -framework CoreImage -o "$@"
else
$(EXECUTABLE): $(APP_SOURCES) $(addprefix $(FRAMEWORKS)/,$(LIBRARIES)) $(ROOT)/Makefile | $(MACOS)
	$(SWIFTC) $(SWIFT_FLAGS) $(LINK_FLAGS) -I"$(ROOT)/MacPlatform/Bridge/CSystem/include" -I"$(BRIDGE)/include" \
		-lPetCore -lIPCProtocol -lMacIPCTransport -lMacPetWindowing -lpetbridge $(APP_SOURCES) \
		-framework AppKit $(EXE_RPATH) -o "$@"

endif

$(BUILD)/make-icon: $(ROOT)/MacPlatform/Packaging/MakeIcon.swift $(OVERLAY) | $(BUILD)
	$(SWIFTC) $(SWIFT_FLAGS) "$<" -framework AppKit -framework ImageIO -o "$@"

icon: $(BUILD)/make-icon | $(RESOURCES)
	mkdir -p "$(BUILD)/DynaPet.iconset"
	"$(BUILD)/make-icon" "$(ROOT)/../Branding/DynaPet.png" "$(BUILD)/icon-1024.png"
	for n in 16 32 128 256 512; do \
		sips -z $$n $$n "$(BUILD)/icon-1024.png" --out "$(BUILD)/DynaPet.iconset/icon_$${n}x$${n}.png" >/dev/null; \
		double=$$((n * 2)); \
		sips -z $$double $$double "$(BUILD)/icon-1024.png" --out "$(BUILD)/DynaPet.iconset/icon_$${n}x$${n}@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(BUILD)/DynaPet.iconset" -o "$(RESOURCES)/DynaPet.icns"

resources: | $(RESOURCES)
	mkdir -p "$(RESOURCES)/DemoTheme"
	cp -p "$(ROOT)/../DemoTheme"/*.png "$(RESOURCES)/DemoTheme/"
	cp -p "$(ROOT)/../DemoTheme/manifest.json" "$(ROOT)/../DemoTheme/NOTICE.md" "$(RESOURCES)/DemoTheme/"
	cp -p "$(if $(filter full,$(VARIANT)),$(FULL_ROOT)/使用说明.md,$(ROOT)/MacPlatform/Packaging/使用说明.md)" "$(RESOURCES)/使用说明.md"
	cp -p "$(ROOT)/../LICENSE" "$(RESOURCES)/LICENSE"
	cp -p "$(ROOT)/../LICENSE_SCOPE.md" "$(RESOURCES)/LICENSE_SCOPE.md"

plist: | $(CONTENTS)
	cp -p "$(ROOT)/MacPlatform/Packaging/$(if $(filter full,$(VARIANT)),FullInfo.plist,Info.plist)" "$(CONTENTS)/Info.plist"
	plutil -lint "$(CONTENTS)/Info.plist"

$(CONTENTS):
	mkdir -p "$@"

app: $(EXECUTABLE) resources plist icon
	for lib in $(LIBRARIES); do codesign --force --sign "$(SIGN_IDENTITY)" "$(FRAMEWORKS)/$$lib"; done
	codesign --force --sign "$(SIGN_IDENTITY)" "$(EXECUTABLE)"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	@echo "Built: $(APP)"

# Build the native GUI bundle, including MacOS/, Frameworks/ and Info.plist.
# Keep build artifacts in place so incremental builds remain usable.
package: app

verify: app
	xcrun lipo -info "$(EXECUTABLE)"
	xcrun lipo -info "$(FRAMEWORKS)/libpetbridge.dylib"
	xcrun otool -L "$(EXECUTABLE)"
	xcrun otool -l "$(EXECUTABLE)" | sed -n '/LC_RPATH/,+3p'

bridge-test:
	$(MAKE) VARIANT=layered app
	"$(ROOT)/dist/$(ARCH)/DynaPet-layered.app/Contents/MacOS/DynaPet" --bridge-self-test

zip: app
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ROOT)/dist/DynaPet-$(VARIANT)-macOS-$(ARCH).zip"

print-config:
	@echo "ARCH=$(ARCH)"
	@echo "APP=$(APP)"
	@echo "EXECUTABLE=$(EXECUTABLE)"
	@echo "FRAMEWORKS=$(FRAMEWORKS)"
