# ============================================================
# RedditEnhancer — Theos Makefile (GitHub Actions / local)
# Target: Reddit 2026.46.0  (com.reddit.Reddit / RedditApp)
#
# IMPORTANT: This builds a PLAIN DYLIB for TrollStore injection.
#            It uses library.mk (NOT tweak.mk) on purpose: the code
#            hooks via the raw Objective-C runtime and has ZERO
#            dependency on Cydia Substrate / ElleKit. A tweak.mk
#            build would add a libsubstrate.dylib dependency and
#            fail to load in TrollStore.
# ============================================================

# 16.5 exists in theos/sdks (verified). Deployment target 13.0 is
# safe for all TrollStore-supported iOS versions.
TARGET := iphone:clang:16.5:13.0
ARCHS  := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = RedditEnhancer

RedditEnhancer_FILES      = Tweak.m
RedditEnhancer_FRAMEWORKS = Foundation UIKit
RedditEnhancer_CFLAGS     = -fobjc-arc -Wno-unknown-warning-option \
                            -Wno-deprecated-declarations \
                            -Wno-unused-but-set-variable \
                            -Wno-unused-variable

# Where the dylib will live inside the injected app. Azule/optool add the
# matching LC_LOAD_DYLIB entry to the RedditApp binary. For library.mk the
# correct variable is *_INSTALL_PATH (it controls LC_ID_DYLIB); *_INSTALL_NAME
# is silently ignored by this makefile.
RedditEnhancer_INSTALL_PATH = @executable_path/Frameworks
TWEAK_INSTALL_PATH = @executable_path/Frameworks

include $(THEOS_MAKE_PATH)/library.mk
