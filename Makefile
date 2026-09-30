SDK         = /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
C_MODULE    = Sources/DelucyxBPF_C/include
BIN         = build/delucyx
UI_BIN      = build/DelucyxUI
APP_BUNDLE  = build/DelucyxUI.app
APP_DEST    = $(HOME)/Applications/DelucyxUI.app
TUI_DIR     = tui
TUI_DEST    = $(HOME)/.delucyx/tui
BUN         = $(shell command -v bun 2>/dev/null || echo $(HOME)/.bun/bin/bun)
LOCAL_BIN   = $(HOME)/.local/bin/delucyx
INSTALL_BIN = /usr/local/bin/delucyx

.PHONY: all ui app install install-user install-bin install-app install-ui install-all tui tui-deps tui-test install-tui clean

# ── CLI daemon ───────────────────────────────────────────────────
all: $(BIN)

build:
	mkdir -p build

build/delucyx_bpf.o: Sources/DelucyxBPF_C/delucyx_bpf.c $(C_MODULE)/delucyx_bpf.h | build
	cc -c $< -I$(C_MODULE) -o $@

$(BIN): Sources/DelucyxBPF/DelucyxBPF.swift Sources/delucyx/*.swift build/delucyx_bpf.o | build
	swiftc Sources/DelucyxBPF/DelucyxBPF.swift Sources/delucyx/*.swift \
		build/delucyx_bpf.o \
		-I$(C_MODULE) -sdk $(SDK) \
		-o $(BIN)

# ── GUI app ──────────────────────────────────────────────────────
ui: $(UI_BIN)

$(UI_BIN): Sources/DelucyxUI/*.swift | build
	swiftc Sources/DelucyxUI/*.swift \
		-framework AppKit \
		-sdk $(SDK) \
		-o $(UI_BIN)

app: ui
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(UI_BIN) $(APP_BUNDLE)/Contents/MacOS/DelucyxUI
	cp Sources/DelucyxUI/Info.plist $(APP_BUNDLE)/Contents/Info.plist

install-app: app
	mkdir -p $(HOME)/Applications
	rm -rf $(APP_DEST)
	cp -r $(APP_BUNDLE) $(APP_DEST)
	@echo "Installed: $(APP_DEST)"
	@echo "Opening..."
	open $(APP_DEST)

# ── CLI on PATH ──────────────────────────────────────────────────
# User-level install: no sudo, works for any cwd (TUI found in ~/.delucyx/tui)
install-user: all
	@mkdir -p $(dir $(LOCAL_BIN))
	cp $(BIN) $(LOCAL_BIN)
	chmod 755 $(LOCAL_BIN)
	@echo "Installed CLI: $(LOCAL_BIN)"
	@case ":$$PATH:" in *":$(patsubst %/,%,$(dir $(LOCAL_BIN))):"*) echo "PATH ok";; *) echo "Add to PATH: export PATH=\"$(patsubst %/,%,$(dir $(LOCAL_BIN))):\$$PATH\"";; esac

# System-wide copy (asks for your password)
install-bin: all
	sudo mkdir -p $(dir $(INSTALL_BIN))
	sudo cp $(BIN) $(INSTALL_BIN)
	sudo chmod 755 $(INSTALL_BIN)
	@echo "Installed CLI: $(INSTALL_BIN)"

# Everything needed to run `delucyx` alone (no privileged daemon touched)
install: install-user install-tui
	@echo ""
	@echo "Done. Type: delucyx"
	@echo "Optional privileged daemon (TUI drives it, starts idle/held):"
	@echo "  sudo delucyx install"

# ── Upgrade daemon + restart GUI ─────────────────────────────────
install-ui: all install-app
	sudo $(BIN) upgrade

# ── Terminal UI (OpenTUI + Bun) ──────────────────────────────────
tui-deps: $(TUI_DIR)/node_modules

$(TUI_DIR)/node_modules: $(TUI_DIR)/package.json
	cd $(TUI_DIR) && $(BUN) install

tui: tui-deps
	cd $(TUI_DIR) && $(BUN) run index.ts

tui-test: tui-deps
	cd $(TUI_DIR) && $(BUN) test

# Copy the TUI to ~/.delucyx/tui (found by `delucyx` / `delucyx tui` on any path)
install-tui: tui-deps
	mkdir -p $(TUI_DEST)
	rsync -a --delete --exclude node_modules $(TUI_DIR)/ $(TUI_DEST)/
	cd $(TUI_DEST) && $(BUN) install
	@echo "Installed TUI: $(TUI_DEST)"

install-all: install install-app
	sudo $(BIN) upgrade

# ── Clean ────────────────────────────────────────────────────────
clean:
	rm -rf build
