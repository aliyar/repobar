APP      := RepoBar
SCHEME   := RepoBar
CONFIG   ?= Debug
DD       := build/DerivedData
APP_PATH := $(DD)/Build/Products/$(CONFIG)/$(APP).app
XCB      := xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath $(DD)
PKG      := Packages/RepoBarKit

.PHONY: generate spec build run stop test test-engine test-app screenshots site site-assets open logs clean release release-dry help

help:                ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

generate:            ## Generate RepoBar.xcodeproj (+ Info.plist/entitlements) from project.yml
	xcodegen generate --use-cache --quiet

spec:                ## Validate and summarize the resolved project spec
	xcodegen dump --type summary

build: generate      ## Build (CONFIG=Debug|Release)
	$(XCB) -configuration $(CONFIG) build -quiet

run: build           ## Relaunch the app (kills any running instance first)
	-pkill -x $(APP) 2>/dev/null; sleep 0.3
	open "$(APP_PATH)"

stop:                ## Quit the running app
	-pkill -x $(APP)

test: test-engine test-app   ## Run all tests

test-engine:         ## Run GitEngine package tests (headless, fast)
	swift test --package-path $(PKG)

test-app: generate   ## Run app-layer tests via xcodebuild
	$(XCB) -configuration Debug test -only-testing:RepoBarTests -quiet

site:                ## Serve the landing page locally at http://localhost:8099
	@echo "http://localhost:8099 — ctrl-c to stop"
	python3 -m http.server 8099 --directory site

site-assets:         ## Rebuild site/assets from the renders in docs/screenshots
	./Scripts/site-assets.sh

screenshots: generate ## Render README screenshots into docs/screenshots from the real views
	mkdir -p docs/screenshots build
	echo "$(abspath docs/screenshots)" > build/screenshot-dir
	$(XCB) -configuration Debug test -only-testing:RepoBarTests/ScreenshotTests -quiet; status=$$?; rm -f build/screenshot-dir; exit $$status
	@ls docs/screenshots

open: generate       ## Open the project in Xcode
	open $(APP).xcodeproj

logs:                ## Follow RepoBar OSLog output
	log stream --level debug --predicate 'subsystem == "com.aliyar.RepoBar"'

clean:               ## Remove build output and generated project files
	rm -rf build dist $(APP).xcodeproj Supporting/Info.plist Supporting/RepoBar.entitlements $(PKG)/.build

release:             ## Publish a release: make release VERSION=1.2.3 [NOTES=notes.md] [FLAGS=--draft]
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=1.2.3 [NOTES=notes.md] [FLAGS=...]"; exit 2)
	./Scripts/release.sh $(VERSION) $(if $(NOTES),--notes $(NOTES)) $(FLAGS)

release-dry:         ## Build the release artifacts into dist/ without touching git or GitHub
	@test -n "$(VERSION)" || (echo "usage: make release-dry VERSION=1.2.3"; exit 2)
	./Scripts/release.sh $(VERSION) --dry-run $(FLAGS)
