.PHONY: check build-mac test-mac build-core test-core generate-bindings lint-swift

check: lint-swift build-core test-core build-mac

lint-swift:
	swiftlint lint --strict --config mac/.swiftlint.yml mac/PabloCompanion/
	swiftformat --lint --config mac/.swiftformat mac/PabloCompanion/

build-mac:
	xcodebuild -project mac/PabloCompanion.xcodeproj \
	  -scheme Pablo \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  build | xcpretty

test-mac:
	xcodebuild -project mac/PabloCompanion.xcodeproj \
	  -scheme Pablo \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  test | xcpretty

build-core:
	cargo build --manifest-path core/Cargo.toml

test-core:
	cargo test --manifest-path core/Cargo.toml

# Re-generate Swift bindings after UDL changes.
# Run this whenever core/uniffi/pablo_core.udl changes, then commit the output.
generate-bindings: build-core
	cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen generate \
	  core/uniffi/pablo_core.udl \
	  --language swift \
	  --out-dir mac/PabloCompanion/Generated/
