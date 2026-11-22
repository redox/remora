.PHONY: generate build ci-build test preview install run release notarize staple appcast release-all release-selftest

APP_DEST := $(HOME)/Applications/Remora.app

generate:
	xcodegen generate

build: generate
	xcodebuild -project Remora.xcodeproj -scheme Remora -configuration Debug -derivedDataPath build build

ci-build: generate
	xcodebuild -project Remora.xcodeproj -scheme Remora -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

test:
	swift test --package-path Packages/RemoraKit

preview:
	python3 docs/site/build.py
	python3 -m http.server 8000 --bind 127.0.0.1 --directory dist/site

install: build
	mkdir -p $(HOME)/Applications
	ditto build/Build/Products/Debug/Remora.app $(APP_DEST)

run: install
	open $(APP_DEST)

# Release pipeline (see docs/releasing.md). notarize, staple and appcast are USER-REQUIRED.
release:
	DRY_RUN=$(DRY_RUN) scripts/release.sh build

notarize:
	DRY_RUN=$(DRY_RUN) scripts/release.sh notarize

staple:
	DRY_RUN=$(DRY_RUN) scripts/release.sh staple

appcast:
	DRY_RUN=$(DRY_RUN) scripts/release.sh appcast

release-all: release notarize staple appcast

release-selftest:
	scripts/release.sh selftest
