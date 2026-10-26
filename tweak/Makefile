# FlowTube: Flow's on-device algorithm for YouTube on iOS.
# Build the Rust core first: (cd ../core && cargo build --release --target aarch64-apple-ios)
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

# A plain library (like YTKACE), not a Substrate tweak: it hooks with the Objective-C runtime
# only, so a sideloaded IPA needs no Substrate or ElleKit.
LIBRARY_NAME = FlowTube

CORE_LIB = $(THEOS_PROJECT_DIR)/../core/target/aarch64-apple-ios/release/libflowneuro_core.a

FlowTube_FILES = $(wildcard Sources/*.m)
FlowTube_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror=return-type -I$(THEOS_PROJECT_DIR)/../core/include
FlowTube_FRAMEWORKS = Foundation UIKit CoreFoundation CoreGraphics QuartzCore UniformTypeIdentifiers
FlowTube_LDFLAGS = -Wl,-install_name,@rpath/FlowTube.dylib $(CORE_LIB)
FlowTube_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

before-all::
	@test -f "$(CORE_LIB)" || { echo "Missing $(CORE_LIB): build ../core for aarch64-apple-ios first"; exit 1; }

after-stage::
	@cp FlowTube.plist "$(THEOS_STAGING_DIR)$(FlowTube_INSTALL_PATH)/FlowTube.plist"

after-all::
	@mkdir -p "$(THEOS_PROJECT_DIR)/dist"
	@cp "$(THEOS_OBJ_DIR)/FlowTube.dylib" "$(THEOS_PROJECT_DIR)/dist/FlowTube.dylib"
