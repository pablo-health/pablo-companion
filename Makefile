.PHONY: check build-mac test-mac lint-swift build-windows test-windows check-windows codeql

# Every mac recipe pipes xcodebuild into xcpretty, and a pipeline exits with the
# status of its LAST command — so without pipefail, xcpretty's 0 masks an
# xcodebuild failure and the recipe "passes" on code that cannot compile. That
# is not hypothetical: main shipped a broken build behind a green `make check`.
#
# `set -o pipefail` is spelled out in each recipe rather than set once via
# .SHELLFLAGS because macOS ships GNU Make 3.81 and .SHELLFLAGS landed in 3.82 —
# there it is silently ignored, which looks like a fix and changes nothing.
SHELL := /bin/bash

check: lint-swift build-mac test-mac

lint-swift:
	swiftlint lint --strict --config mac/.swiftlint.yml mac/PabloCompanion/
	swiftformat --lint --config mac/.swiftformat mac/PabloCompanion/

build-mac:
	set -o pipefail; xcodebuild -project mac/PabloCompanion.xcodeproj \
	  -scheme Pablo \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  build | xcpretty

test-mac:
	set -o pipefail; xcodebuild -project mac/PabloCompanion.xcodeproj \
	  -scheme Pablo \
	  -destination 'platform=macOS' \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  test | xcpretty

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

# ── Windows targets ──────────────────────────────────────────────────────────

build-windows:
	dotnet build windows/PabloCompanion.sln

test-windows:
	dotnet test windows/PabloCompanion.Tests/PabloCompanion.Tests.csproj

check-windows: build-windows test-windows
