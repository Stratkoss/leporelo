.PHONY: test cli build-app run-app

test:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cli:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product leporelo-cli

build-app:
	@echo "implemented in Task 17"

run-app:
	@echo "implemented in Task 17"
