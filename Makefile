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
TRYFYDEOS := macos/.build/release/tryfydeos
WS_ARG = $(if $(WORKSPACE),--workspace "$(WORKSPACE)")

MAC_ONLY = @test "$$(uname -s)" = Darwin || { echo "make $@: must run on the Apple Silicon Mac (run 'make sync' here, then make $@ there)" >&2; exit 1; }

.PHONY: help sync doctor fetch runtime firmware test app-build app-test prepare run inspect icon app app-run import-image dmg dmg-stage

help:
	@echo "make sync       copy the tree from the workstation to the Mac"
	@echo "make doctor     check host, pins, cache, firmware and runtime (Mac)"
	@echo "make fetch      fetch and verify pinned archives and recipe (Mac; SEED=dir OFFLINE=1)"
	@echo "make runtime    build, sign and probe the QEMU runtime (Mac; JOBS=$(JOBS) OFFLINE=1)"
	@echo "make firmware   extract the pinned edk2 pair (Mac, after fetch)"
	@echo "make app-build  build the Swift launcher core and tryfydeos CLI (Mac)"
	@echo "make app-test   run the Swift unit tests (Mac)"
	@echo "make icon       render macos/Resources/TryFydeOSIcon.svg to macos/.build/TryFydeOS.icns (Mac)"
	@echo "make app        assemble and sign dist/Try FydeOS.app without the image (Mac; APP_ARGS='--with-image')"
	@echo "make app-run    open dist/Try FydeOS.app (Mac)"
	@echo "make dmg        package dist/Try FydeOS-<version>.dmg with the image beside the app (Mac; DMG_ARGS='--sign-identity ID --notarize-profile P')"
	@echo "make dmg-stage  stage the DMG layout in dist/stage/ without building the DMG (Mac)"
	@echo "make import-image  copy and verify the factory image into the app's image store (Mac)"
	@echo "make prepare    clone the VM disk from the image store (Mac; WORKSPACE=dir)"
	@echo "make run        boot the VM with defaults (Mac; WORKSPACE=dir RUN_ARGS='--cpus 6')"
	@echo "make inspect    print the QEMU argv run would use (Mac)"
	@echo "make test       run unit tests (Python, plus Swift on the Mac)"

sync:
	@test "$$(uname -s)" != Darwin || { echo "make sync: run this on the workstation" >&2; exit 1; }
	rsync -az --delete --exclude .git --exclude .cache --exclude out --exclude dist --exclude .build \
		--exclude '/factory/*.bin' --exclude '/firmware/*.fd' \
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

import-image: app-build
	$(TRYFYDEOS) import-image

prepare: app-build
	$(TRYFYDEOS) prepare $(WS_ARG)

run: app-build
	$(TRYFYDEOS) run $(WS_ARG) $(RUN_ARGS)

inspect: app-build
	$(TRYFYDEOS) inspect $(WS_ARG) $(RUN_ARGS)

test:
	$(PYTHON) -m unittest discover -s tests -v
	@if [ "$$(uname -s)" = Darwin ]; then cd macos && swift test; fi
