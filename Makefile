# Waystage developer commands. Run `make help`.
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help bootstrap secrets project open test test-quick test-core test-gateway test-ios lint format icon screenshots upload-build create-version update-version submit-for-review release-all signing

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install tools (macOS) and git hooks, create secrets file, generate the Xcode project
	brew bundle --no-lock --file=- <<< $$'brew "xcodegen"\nbrew "swiftlint"\nbrew "swiftformat"\nbrew "node@22"'
	bundle install
	scripts/install-git-hooks.sh
	$(MAKE) secrets project

secrets: ## Create Config/Secrets.xcconfig from the template (never committed)
	@test -f Config/Secrets.xcconfig || cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
	@echo "Edit Config/Secrets.xcconfig — see docs/API_KEYS.md"

project: ## Generate Waystage.xcodeproj from project.yml
	xcodegen generate

open: project ## Generate and open the project in Xcode
	open Waystage.xcodeproj

test: ## Run every test suite available on this machine (logs to test-logs/)
	scripts/test-all.sh all

test-quick: ## Core + gateway suites (what the pre-push hook runs)
	scripts/test-all.sh quick

test-core: ## Swift package unit + integration tests
	scripts/test-all.sh core

test-gateway: ## Backend gateway lint, typecheck and tests
	scripts/test-all.sh gateway

test-ios: ## iOS package tests, app unit tests and XCUITests (macOS)
	scripts/test-all.sh ios

lint: ## SwiftLint + ESLint
	swiftlint lint --strict
	cd Backend/gateway && npm run lint

format: ## SwiftFormat
	swiftformat .

icon: ## Regenerate the App Store icon
	python3 scripts/generate_app_icon.py

screenshots: ## Capture sandbox screenshots for design review (macOS; not for the App Store)
	bundle exec fastlane screenshots

upload-build: ## Upload a build to TestFlight
	bundle exec fastlane upload_build

create-version: ## App Store Connect: + Version, then update-version
	bundle exec fastlane create_version

update-version: ## App Store Connect: the version page and App Information from the repository
	bundle exec fastlane update_version

submit-for-review: ## App Store Connect: choose the build, Submit for Review
	bundle exec fastlane submit_for_review

release-all: ## All of the above in one run
	bundle exec fastlane release_all

signing: ## Create or renew the signing certificate and App Store profile
	bundle exec fastlane signing
