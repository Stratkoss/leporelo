.PHONY: all help test cli build-app test-app run-app xcodegen

DEVELOPER_DIR_XCODE = /Applications/Xcode.app/Contents/Developer
APP_DERIVED_DATA = App/DerivedData

help:
	@echo "Cíle:"
	@echo "  make test       testy balíčku LeporeloCore (swift test)"
	@echo "  make cli        sestaví leporelo-cli (.build/debug/leporelo-cli)"
	@echo "  make xcodegen   vygeneruje App/Leporelo.xcodeproj z App/project.yml"
	@echo "  make build-app  sestaví aplikaci (Debug)"
	@echo "  make test-app   spustí testy aplikace"
	@echo "  make run-app    spustí sestavenou aplikaci"
	@echo "  make all        test, test-app a build-app za sebou"

all: test test-app build-app

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR_XCODE) swift test

cli:
	DEVELOPER_DIR=$(DEVELOPER_DIR_XCODE) swift build --product leporelo-cli

xcodegen:
	brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
	cd App && xcodegen

build-app: xcodegen
	cd App && DEVELOPER_DIR=$(DEVELOPER_DIR_XCODE) xcodebuild -scheme Leporelo -configuration Debug -derivedDataPath DerivedData build

test-app: xcodegen
	cd App && DEVELOPER_DIR=$(DEVELOPER_DIR_XCODE) xcodebuild -scheme Leporelo -configuration Debug -derivedDataPath DerivedData test -destination 'platform=macOS'

run-app:
	open $(APP_DERIVED_DATA)/Build/Products/Debug/Leporelo.app
