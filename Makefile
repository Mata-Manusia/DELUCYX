SDK         = /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
C_MODULE    = Sources/NetcutxBPF_C/include
BIN         = build/netcutx
UI_BIN      = build/NetcutxUI
APP_BUNDLE  = build/NetcutxUI.app
APP_DEST    = $(HOME)/Applications/NetcutxUI.app

.PHONY: all ui app install-app install-ui clean

# ── CLI daemon ───────────────────────────────────────────────────
all: $(BIN)

build:
	mkdir -p build

build/netcutx_bpf.o: Sources/NetcutxBPF_C/netcutx_bpf.c $(C_MODULE)/netcutx_bpf.h | build
	cc -c $< -I$(C_MODULE) -o $@

$(BIN): Sources/NetcutxBPF/NetcutxBPF.swift Sources/netcutx/*.swift build/netcutx_bpf.o | build
	swiftc Sources/NetcutxBPF/NetcutxBPF.swift Sources/netcutx/*.swift \
		build/netcutx_bpf.o \
		-I$(C_MODULE) -sdk $(SDK) \
		-lsqlite3 \
		-o $(BIN)

# ── GUI app ──────────────────────────────────────────────────────
ui: $(UI_BIN)

$(UI_BIN): Sources/NetcutxUI/*.swift | build
	swiftc Sources/NetcutxUI/*.swift \
		-framework AppKit \
		-sdk $(SDK) \
		-o $(UI_BIN)

app: ui
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(UI_BIN) $(APP_BUNDLE)/Contents/MacOS/NetcutxUI
	cp Sources/NetcutxUI/Info.plist $(APP_BUNDLE)/Contents/Info.plist

install-app: app
	mkdir -p $(HOME)/Applications
	rm -rf $(APP_DEST)
	cp -r $(APP_BUNDLE) $(APP_DEST)
	@echo "Installed: $(APP_DEST)"
	@echo "Opening..."
	open $(APP_DEST)

# ── Upgrade daemon + restart GUI ─────────────────────────────────
install-ui: all install-app
	sudo $(BIN) upgrade

# ── Clean ────────────────────────────────────────────────────────
clean:
	rm -rf build
