APP_NAME   := macSteam
BIN        := $(APP_NAME)
SRC        := spawn_client.c
BUILD      := build
APP        := $(BUILD)/$(APP_NAME).app
DEPLOY_DIR := /Applications

CC       := clang
REPO_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)
REPO_DYLIB := $(REPO_ROOT)/out/macsteam.dylib
MS_VERSION := $(shell sed -n 's/.*MACSTEAM_VERSION[[:space:]]*"\(.*\)".*/\1/p' $(REPO_ROOT)/src/version.h)
CFLAGS   := -O2 -arch arm64 -Wall -Wextra
CODESIGN := codesign -f -s -

.PHONY: all app deploy clean

all: app

$(BUILD):
	mkdir -p $(BUILD)


$(BUILD)/$(BIN): $(SRC) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(SRC)
	$(CODESIGN) $@


REPO_SIGS := $(REPO_ROOT)/signatures/macos.arm64

app: $(BUILD)/$(BIN) Info.plist macSteam.icns $(REPO_DYLIB) $(REPO_SIGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/signatures
	cp $(BUILD)/$(BIN)       $(APP)/Contents/MacOS/$(APP_NAME)
	cp Info.plist           $(APP)/Contents/Info.plist
	cp macSteam.icns        $(APP)/Contents/Resources/$(APP_NAME).icns
	cp $(REPO_DYLIB)        $(APP)/Contents/Resources/macsteam.dylib
	cp $(REPO_SIGS)/*.json  $(APP)/Contents/Resources/signatures/
	printf '%s' '$(MS_VERSION)' > $(APP)/Contents/Resources/macsteam.dylib.version
	printf 'APPL????' >    $(APP)/Contents/PkgInfo
	$(CODESIGN) $(APP)/Contents/MacOS/$(APP_NAME)
	$(CODESIGN) $(APP)
	@echo "assembled $(APP) (dylib v$(MS_VERSION))"

$(REPO_DYLIB):
	$(MAKE) -C $(REPO_ROOT)


deploy: app
	rm -rf $(DEPLOY_DIR)/$(APP_NAME).app
	cp -R $(APP) $(DEPLOY_DIR)/$(APP_NAME).app
	$(CODESIGN) $(DEPLOY_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	$(CODESIGN) $(DEPLOY_DIR)/$(APP_NAME).app
	-xattr -dr com.apple.quarantine $(DEPLOY_DIR)/$(APP_NAME).app
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(DEPLOY_DIR)/$(APP_NAME).app
	@echo "deployed to $(DEPLOY_DIR)/$(APP_NAME).app"

clean:
	rm -rf $(BUILD)
