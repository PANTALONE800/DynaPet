SHELL := /bin/sh
ARCH ?= $(shell uname -m)
MACOS_MIN ?= 14.0
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
SOURCE_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_ROOT := $(abspath $(SOURCE_ROOT)/../../..)
BUILD := $(PROJECT_ROOT)/.build/petbridge/$(ARCH)
FRAMEWORKS := $(BUILD)/Frameworks
BIN := $(BUILD)/bin
DYLIB := $(FRAMEWORKS)/libpetbridge.dylib
SMOKE := $(BIN)/petbridge-smoke
HEADER := $(SOURCE_ROOT)/include/pet_bridge.h
MODULEMAP := $(SOURCE_ROOT)/include/module.modulemap
OVERLAY := $(BUILD)/toolchain-overlay.json
CLANG := xcrun --sdk macosx clang
SWIFTC := xcrun --sdk macosx swiftc

ifeq ($(filter $(ARCH),arm64 x86_64),)
$(error ARCH must be arm64 or x86_64)
endif

.PHONY: all verify smoke stress leaks print-config
all: $(DYLIB) $(SMOKE)

$(FRAMEWORKS) $(BIN):
	mkdir -p "$@"

$(OVERLAY): $(SOURCE_ROOT)/tools/prepare_overlay.py
	python3 "$<" "$(BUILD)"

$(DYLIB): $(SOURCE_ROOT)/src/pet_bridge.m $(HEADER) $(SOURCE_ROOT)/Makefile | $(FRAMEWORKS)
	$(CLANG) -arch $(ARCH) -isysroot "$(SDK)" -mmacosx-version-min=$(MACOS_MIN) \
		-std=c11 -fobjc-arc -Wall -Wextra -Werror -fvisibility=hidden \
		-I"$(SOURCE_ROOT)/include" -dynamiclib "$<" -framework AppKit \
		-Wl,-install_name,@rpath/libpetbridge.dylib -o "$@"

$(SMOKE): $(SOURCE_ROOT)/tests/main.swift $(DYLIB) $(MODULEMAP) $(OVERLAY) $(SOURCE_ROOT)/tests/debug.entitlements $(SOURCE_ROOT)/Makefile | $(BIN)
	$(SWIFTC) -swift-version 5 -target $(ARCH)-apple-macos$(MACOS_MIN) -sdk "$(SDK)" \
		-vfsoverlay "$(OVERLAY)" -module-cache-path "$(BUILD)/module-cache" \
		-I"$(SOURCE_ROOT)/include" -L"$(FRAMEWORKS)" -lpetbridge \
		-Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
		"$<" -o "$@"
	codesign --force --sign - --entitlements "$(SOURCE_ROOT)/tests/debug.entitlements" "$@"

verify: all
	xcrun lipo -info "$(DYLIB)"
	xcrun lipo -info "$(SMOKE)"
	xcrun otool -D "$(DYLIB)"
	xcrun otool -L "$(SMOKE)"
	xcrun otool -l "$(SMOKE)" | sed -n '/LC_RPATH/,+3p'
	xcrun nm -gU "$(DYLIB)" | grep ' _bridge_'

smoke: all
	"$(SMOKE)"

stress: all
	"$(SMOKE)" --stress

leaks: all
	MallocStackLogging=1 /usr/bin/leaks --atExit -- "$(SMOKE)"

print-config:
	@echo "ARCH=$(ARCH)"
	@echo "SDK=$(SDK)"
	@echo "DYLIB=$(DYLIB)"
	@echo "SWIFT_TEST=$(SMOKE)"
	@echo 'RUNPATH=@executable_path/../Frameworks'
