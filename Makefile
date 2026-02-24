.PHONY: check build-mac test-mac build-core test-core lint-swift

check: lint-swift build-mac build-core test-core

lint-swift:
	swiftlint lint --strict --config mac/.swiftlint.yml mac/PabloCompanion/
	swiftformat --lint --config mac/.swiftformat mac/PabloCompanion/

build-mac:
	xcodebuild -project mac/PabloCompanion.xcodeproj \
	  -scheme PabloCompanion \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  build | xcpretty

test-mac:
	xcodebuild -project mac/PabloCompanion.xcodeproj \
	  -scheme PabloCompanion \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  test | xcpretty

build-core:
	@if [ -f core/Cargo.toml ]; then cargo build --manifest-path core/Cargo.toml; fi

test-core:
	@if [ -f core/Cargo.toml ]; then cargo test --manifest-path core/Cargo.toml; fi
