# Triwarden — everyday commands. `make` lists them.
SHELL := /bin/bash
# Machine-specific values (dev box address) go in local.mk, which git ignores.
-include local.mk

DEV_HOST ?= devbox.local
DEV_IP   ?= 192.168.1.50
DEV_PASSWORD ?= chiikawa-dev-password
REGION   ?= us

# Always the local Debug product — never /Applications/Triwarden.app (same bundle id).
APP     := $(CURDIR)/build/Build/Products/Debug/Triwarden.app
BIN     := $(APP)/Contents/MacOS/Triwarden
XCB     := xcodebuild -project Triwarden.xcodeproj -scheme Triwarden -configuration Debug \
	-derivedDataPath $(CURDIR)/build -allowProvisioningUpdates
DEV_CA  := $(CURDIR)/DevServer/data/root.crt
# The app is sandboxed, so snapshots land in its App Group container (the only place outside the container it can
# write), and `make snapshots` copies them into build/snapshots.
SNAP_DIR := $(HOME)/Library/Group Containers/FX3VR69P5K.io.github.sinhong2011.triwarden/snapshots

.DEFAULT_GOAL := help
.PHONY: help project build run site test bench screenshots license license-keys test-dev selftest selftest-compatibility selftest-cloud snapshots dev-up dev-seed dev-status dev-logs release clean

help: ## Show this list
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[1m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

project: ## Regenerate the Xcode project from project.yml
	@xcodegen generate -q

build: project ## Build the Debug app into build/
	@mkdir -p build
	@set -o pipefail; $(XCB) build 2>&1 | tee build/build.log && test -x "$(BIN)"

run: build ## Build and open the Debug app (quits any other Triwarden first)
	@# Launch Services resolves by bundle id; an already-running /Applications copy wins over this path.
	@pkill -x Triwarden 2>/dev/null || true
	@sleep 0.2
	@echo "Opening Debug: $(APP)"
	@open -n "$(APP)"

site: ## Run the website development server
	@pnpm --dir site dev --port 4321

test: ## VaultCore unit tests (dev-server tests skip themselves)
	@cd Packages/VaultCore && swift test

test-dev: ## VaultCore tests including both dev Vaultwarden servers and SSO
	@cd Packages/VaultCore && TRIWARDEN_DEV_HOST=$(DEV_IP) TRIWARDEN_DEV_IP=$(DEV_IP) TRIWARDEN_DEV_CA=$(DEV_CA) \
		swift test

selftest: build ## In-app self-test against the dev server (isolated storage)
	@"$(BIN)" --selftest http://$(DEV_IP):18880 usagi@chiikawarden.test $(DEV_PASSWORD) \
		hachiware@chiikawarden.test $(DEV_PASSWORD) 2>&1

selftest-compatibility: build ## Offline checks for unsupported item types (synthetic data, isolated storage)
	@"$(BIN)" --selftest-compatibility

selftest-security: build ## Self-test plus the steps that sign in again (sign-in approval, password and KDF changes)
	@TRIWARDEN_SELFTEST_SECURITY=1 "$(BIN)" --selftest http://$(DEV_IP):18880 usagi@chiikawarden.test $(DEV_PASSWORD) \
		hachiware@chiikawarden.test $(DEV_PASSWORD) 2>&1

selftest-cloud: build ## Self-test against Bitwarden cloud with the account in .env (REGION=us|eu)
	@test -f .env || { echo "Create .env with BITWARDEN_ACCOUNT=… and BITWARDEN_PASSWORD=… (an empty test account)"; exit 64; }
	@set -a; . ./.env; set +a; "$(BIN)" --selftest-cloud $(REGION) 2>/dev/null

sparkle-keys: build ## One-time: create the update-signing key (kept in your keychain) and put its public half in project.yml
	@BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin; \
	"$$BIN/generate_keys" >/dev/null; \
	KEY=$$("$$BIN/generate_keys" -p); \
	sed -i '' -E "s|^( *SPARKLE_PUBLIC_KEY: )\"[^\"]*\"|\1\"$$KEY\"|" project.yml; \
	echo "Public key $$KEY written to project.yml — commit it."; \
	echo "For CI, export the private key and store it as the SPARKLE_PRIVATE_KEY secret (see docs/RELEASING.md)."

license-keys: ## One-time: create the license-signing key (kept in your keychain) and put its public half in project.yml
	@security find-generic-password -s triwarden-license-signing >/dev/null 2>&1 && { echo "A signing key already exists in your keychain."; exit 1; } || true
	@set -- $$(swift scripts/license.swift keygen); \
	security add-generic-password -s triwarden-license-signing -a triwarden -w "$$1"; \
	sed -i '' -E "s|^( *TW_LICENSE_PUBLIC_KEY: )\"[^\"]*\"|\1\"$$2\"|" project.yml; \
	echo "Public key $$2 written to project.yml — commit it. Back up the private key: security find-generic-password -s triwarden-license-signing -w"

license: ## Sign a license key: make license NAME="…" EMAIL=… ORDER=…
	@test -n "$(EMAIL)" -a -n "$(ORDER)" || { echo 'usage: make license NAME="Usagi" EMAIL=u@example.com ORDER=12345'; exit 64; }
	@TRIWARDEN_LICENSE_PRIVATE_KEY=$$(security find-generic-password -s triwarden-license-signing -w) \
		swift scripts/license.swift sign "$(NAME)" "$(EMAIL)" "$(ORDER)"

uitest: ## Click-through UI tests in --demo mode (quit any running Triwarden first)
	@xcodebuild -project Triwarden.xcodeproj -scheme Triwarden -derivedDataPath build -allowProvisioningUpdates \
		test -only-testing:TriwardenUITests

snapshots: build ## Render UI snapshots (light + dark) into build/snapshots; ONLY=login,send renders just those
	@set -e -o pipefail; dir=$$(TRIWARDEN_SNAPSHOT_ONLY="$(ONLY)" TRIWARDEN_SNAPSHOT_DIR="$(SNAP_DIR)" "$(BIN)" --snapshot | tail -1); \
		mkdir -p build/snapshots; n=$$(find "$$dir" -name '*.png' -newer "$(BIN)" | wc -l | tr -d ' '); \
		test "$$n" -gt 0 || { echo "No snapshots rendered; check ONLY and the snapshot output."; exit 1; }; \
		find "$$dir" -name '*.png' -newer "$(BIN)" -print0 | xargs -0 -I {} cp -f {} build/snapshots/; \
		echo "$$n images rendered into build/snapshots$(if $(ONLY), (only: $(ONLY)),)"

screenshots: build ## README images (docs/images) and store images (Design/Store) from the demo vault, light and dark
	@python3 scripts/screenshots.py

bench: ## Launch time, idle memory and unlock time into docs/benchmarks.md (RUNS=5; INTERACTIVE=5 adds real unlocks)
	@scripts/bench.sh --runs $(or $(RUNS),5) $(if $(INTERACTIVE),--interactive $(INTERACTIVE),)

dev-up: ## Start the dev servers on the dev box (Vaultwarden ×2, SSO + dex, Mailpit)
	@TRIWARDEN_DEV_HOST=$(DEV_HOST) TRIWARDEN_DEV_IP=$(DEV_IP) DevServer/dev.sh up

dev-seed: ## Seed test accounts and items
	@TRIWARDEN_DEV_HOST=$(DEV_HOST) TRIWARDEN_DEV_IP=$(DEV_IP) DevServer/dev.sh seed

dev-status: ## Dev server containers
	@TRIWARDEN_DEV_HOST=$(DEV_HOST) TRIWARDEN_DEV_IP=$(DEV_IP) DevServer/dev.sh status

dev-logs: ## Dev server logs (SERVICE=vaultwarden|vaultwarden-sso|dex|…)
	@TRIWARDEN_DEV_HOST=$(DEV_HOST) TRIWARDEN_DEV_IP=$(DEV_IP) DevServer/dev.sh logs $(SERVICE)

release: ## Signed, notarized release: make release VERSION=0.3.0 [ARGS=--publish]
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.3.0 [ARGS=--publish]"; exit 64; }
	@scripts/release.sh $(VERSION) $(ARGS)

clean: ## Remove build output
	@rm -rf build/Build build/Logs build/snapshots
