PREFIX ?= /usr/local

SIGN_ID ?= Developer ID Application: LI GUO (6ZPXG4KVVS)
NOTARY_PROFILE ?= thermo
NOTARY_KEYCHAIN ?= $(HOME)/Library/Keychains/login.keychain-db
# Where releases/appcast.xml will be served from; empty = build without auto-update.
ARCHS ?= arm64 x86_64
APPCAST_URL ?= https://thermo-updates.pages.dev/appcast.xml

.PHONY: build release publish icon debug test bench install uninstall clean

build:
	scripts/build.sh

# Developer ID signed + notarized + stapled.
release:
	SIGN_ID="$(SIGN_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" NOTARY_KEYCHAIN="$(NOTARY_KEYCHAIN)" \
	APPCAST_URL="$(APPCAST_URL)" ARCHS="$(ARCHS)" scripts/build.sh

# Upload releases/ to Cloudflare Pages (static only).
publish:
	scripts/publish.sh

icon:
	swift scripts/make-icon.swift Resources

debug:
	swift build

test:
	swift test

bench: build
	dist/thermo bench

# Installs the CLI (+ helper binary next to it, used by `thermo helper install`)
# and copies Thermo.app to /Applications.
install: build
	install -d $(PREFIX)/bin
	install -m 755 dist/thermo dist/thermo-helper $(PREFIX)/bin/
	rm -rf /Applications/Thermo.app && cp -R dist/Thermo.app /Applications/

uninstall:
	rm -f $(PREFIX)/bin/thermo $(PREFIX)/bin/thermo-helper
	rm -rf /Applications/Thermo.app

clean:
	rm -rf .build dist
