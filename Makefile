.PHONY: test cli build-app test-app run-app xcodegen

DEVELOPER_DIR_XCODE = /Applications/Xcode.app/Contents/Developer
APP_DERIVED_DATA = App/DerivedData

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
