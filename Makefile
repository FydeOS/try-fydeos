PYTHON := $(shell test -x /opt/homebrew/bin/python3 && echo /opt/homebrew/bin/python3 || echo python3)
RUNTIME := $(PYTHON) runtime/runtime.py
JOBS ?= 8
SEED ?=
OFFLINE ?=
MAC_HOST ?= fydeos@localhost
MAC_PORT ?= 2222
MAC_DIR ?= Workspace/try-fydeos
WORKSPACE ?=
RUN_ARGS ?=
APP_ARGS ?=
DMG_ARGS ?=
EDITION ?= io
TRYFYDEOS := macos/.build/release/tryfydeos
WS_ARG = $(if $(WORKSPACE),--workspace "$(WORKSPACE)")

MAC_ONLY = @test "$$(uname -s)" = Darwin || { echo "make $@: must run on the Apple Silicon Mac (run 'make sync' here, then make $@ there)" >&2; exit 1; }

.PHONY: help sync doctor fetch runtime firmware test app-build app-test prepare run inspect icon app app-run dmg dmg-stage

help:
	@echo "EDITION=com     build the com edition (.com images and release API); default io"
	@echo "make sync       copy the tree from the workstation to the Mac"
	@echo "make doctor     check host, pins, cache, firmware and runtime (Mac)"
	@echo "make fetch      fetch and verify pinned archives and recipe (Mac; SEED=dir OFFLINE=1)"
	@echo "make runtime    build, sign and probe the QEMU runtime (Mac; JOBS=$(JOBS) OFFLINE=1)"
	@echo "make firmware   extract the pinned edk2 pair (Mac, after fetch)"
	@echo "make app-build  build the Swift launcher core and tryfydeos CLI (Mac)"
	@echo "make app-test   run the Swift unit tests (Mac)"
	@echo "make icon       render macos/Resources/TryFydeOSIcon.svg to macos/.build/TryFydeOS.icns (Mac)"
	@echo "make app        assemble and sign dist/Try FydeOS.app; the image downloads at first launch (Mac)"
	@echo "make app-run    open dist/Try FydeOS.app (Mac)"
	@echo "make dmg        package dist/Try FydeOS-<version>.dmg (Mac; DMG_ARGS='--sign-identity ID --notarize-profile P')"
	@echo "make dmg-stage  stage the DMG layout in dist/stage/ without building the DMG (Mac)"
	@echo "make prepare    download and convert the FydeOS image into the VM disk (Mac; WORKSPACE=dir)"
	@echo "make run        boot the VM with defaults (Mac; WORKSPACE=dir RUN_ARGS='--cpus 6')"
	@echo "make inspect    print the QEMU argv run would use (Mac)"
	@echo "make test       run unit tests (Python, plus Swift on the Mac)"
	@echo "make win-runtime fetch, verify and unpack the pinned Windows QEMU runtime into out/win-runtime/ (WIN_RUNTIME=own|omarchy)"
	@echo "make win-runtime-build  cross-build our Windows QEMU runtime in Docker into out/win-runtime/ + out/win-runtime-<lock sha>.zip"
	@echo "make win-build  cross-build tryfydeos.exe (CLI) and Try FydeOS.exe (GUI) into out/win-build/"
	@echo "make win-rsrc   render the icon and compile windows/versioninfo.rc into the GUI's .syso"
	@echo "make win-test   run the Go unit tests of windows/ on this host"
	@echo "make win-sync   copy both exes, spec and sources to the NUC ($(NUC_DIR))"
	@echo "make win-dist   pack dist/Try FydeOS-<version>.exe: GUI exe + runtime and spec payload"

sync:
	@test "$$(uname -s)" != Darwin || { echo "make sync: run this on the workstation" >&2; exit 1; }
	rsync -az --delete --exclude .git --exclude .cache --exclude out --exclude dist --exclude .build \
		--exclude '/factory/*.bin' --exclude '/factory/*.zst' --exclude '/firmware/*.fd' \
		-e 'ssh -p $(MAC_PORT)' ./ $(MAC_HOST):$(MAC_DIR)/

doctor:
	$(MAC_ONLY)
	$(RUNTIME) doctor

fetch:
	$(MAC_ONLY)
	$(RUNTIME) fetch $(if $(SEED),--seed $(SEED)) $(if $(OFFLINE),--offline)

runtime:
	$(MAC_ONLY)
	$(RUNTIME) build --jobs $(JOBS) $(if $(OFFLINE),--offline)

firmware:
	$(MAC_ONLY)
	$(RUNTIME) firmware

app-build:
	$(MAC_ONLY)
	cd macos && swift build -c release

app-test:
	$(MAC_ONLY)
	cd macos && swift test

icon:
	$(MAC_ONLY)
	macos/scripts/make-icon.sh

app:
	$(MAC_ONLY)
	macos/scripts/build-app.sh $(APP_ARGS)

app-run:
	$(MAC_ONLY)
	open "dist/Try FydeOS.app"

dmg:
	$(MAC_ONLY)
	macos/scripts/package-dmg.sh $(DMG_ARGS)

dmg-stage:
	$(MAC_ONLY)
	macos/scripts/package-dmg.sh --stage-only

prepare: app-build
	$(TRYFYDEOS) prepare $(WS_ARG)

run: app-build
	$(TRYFYDEOS) run $(WS_ARG) $(RUN_ARGS)

inspect: app-build
	$(TRYFYDEOS) inspect $(WS_ARG) $(RUN_ARGS)

test:
	$(PYTHON) -m unittest discover -s tests -v
	@if [ "$$(uname -s)" = Darwin ]; then cd macos && swift test; fi

NUC_HOST ?= wei@localhost
NUC_PORT ?= 2223
NUC_DIR ?= D:/try-fydeos/dev
WIN_SPEC ?= factory/amd64-vmware-$(EDITION).json
# windows/versioninfo.rc is the version's source of truth.
WIN_VERSION = $(shell sed -n 's/.*"ProductVersion", "\(.*\)".*/\1/p' windows/versioninfo.rc)
WIN_DIST = dist/Try FydeOS-$(WIN_VERSION)$(if $(filter com,$(EDITION)),-com,).exe

# own: our build pinned in windows/runtime.lock.json; omarchy: Try Omarchy's published zip.
WIN_RUNTIME ?= own

.PHONY: win-runtime win-runtime-build win-build win-rsrc win-test win-sync win-dist

win-runtime:
	windows/scripts/fetch-runtime.sh $(WIN_RUNTIME)

win-runtime-build:
	windows/runtime/build.sh

win-build:
	mkdir -p out/win-build
	cd windows && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -X tryfydeos.io/windows/internal/core.Edition=$(EDITION)" -o ../out/win-build/tryfydeos.exe ./cmd/tryfydeos
	cd windows && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-H windowsgui -s -w -X tryfydeos.io/windows/internal/core.Edition=$(EDITION)" -o "../out/win-build/Try FydeOS.exe" ./cmd/TryFydeOSApp

win-rsrc:
	windows/scripts/make-rsrc.sh

win-test:
	cd windows && go vet ./... && go test ./...

win-sync: win-build
	ssh -o BatchMode=yes -p $(NUC_PORT) $(NUC_HOST) 'New-Item -ItemType Directory -Force $(NUC_DIR) | Out-Null; if (Test-Path $(NUC_DIR)/src) { Remove-Item -Recurse -Force $(NUC_DIR)/src }'
	scp -o BatchMode=yes -P $(NUC_PORT) out/win-build/*.exe $(WIN_SPEC) $(NUC_HOST):$(NUC_DIR)/
	scp -o BatchMode=yes -r -P $(NUC_PORT) windows $(NUC_HOST):$(NUC_DIR)/src

win-dist: win-build
	@test -n "$(WIN_VERSION)" || { echo "win-dist: no ProductVersion in windows/versioninfo.rc" >&2; exit 1; }
	cd windows && go run ./cmd/tryfydeos-pack --exe "../out/win-build/Try FydeOS.exe" --runtime ../out/win-runtime \
		--spec ../$(WIN_SPEC) --out "../$(WIN_DIST)"
