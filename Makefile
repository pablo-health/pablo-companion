.PHONY: check build-mac test-mac build-core test-core generate-bindings lint-swift codeql

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

codeql:
	@which codeql > /dev/null 2>&1 || (echo "CodeQL CLI not found. Install with: brew install codeql" && exit 1)
	@echo "Creating CodeQL database (this builds the project)..."
	codeql database create /tmp/pablo-codeql-db \
	  --language=swift \
	  --command='xcodebuild -project mac/PabloCompanion.xcodeproj \
	    -scheme Pablo \
	    -destination platform=macOS \
	    -clonedSourcePackagesDirPath mac/SourcePackages \
	    CODE_SIGN_IDENTITY= \
	    CODE_SIGNING_REQUIRED=NO \
	    CODE_SIGNING_ALLOWED=NO \
	    ONLY_ACTIVE_ARCH=YES \
	    build' \
	  --overwrite
	@echo "Ensuring query packs are downloaded..."
	codeql pack download codeql/swift-queries 2>/dev/null || true
	@echo "Running security-extended queries..."
	codeql database analyze /tmp/pablo-codeql-db \
	  --format=sarif-latest \
	  --output=/tmp/pablo-codeql-results.sarif \
	  --download \
	  codeql/swift-queries:codeql-suites/swift-security-extended.qls
	@echo "Results written to /tmp/pablo-codeql-results.sarif"
	@echo ""
	@python3 -c "\
	import json, sys; \
	data = json.load(open('/tmp/pablo-codeql-results.sarif')); \
	results = [r for run in data.get('runs',[]) for r in run.get('results',[])]; \
	[print(f\"[{r.get('level','?').upper()}] {r['message']['text']} — {r['locations'][0]['physicalLocation']['artifactLocation']['uri']}:{r['locations'][0]['physicalLocation']['region']['startLine']}\") for r in results] if results else print('No issues found.')"

# Re-generate Swift bindings after UDL changes.
# Run this whenever core/uniffi/pablo_core.udl changes, then commit the output.
generate-bindings: build-core
	cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen generate \
	  core/uniffi/pablo_core.udl \
	  --language swift \
	  --out-dir mac/PabloCompanion/Generated/
