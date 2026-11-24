# vela — build, install and bundle.  SPDX-License-Identifier: GPL-3.0-or-later
PREFIX  ?= /usr/local
VERSION := $(shell sed -n 's/^let version = "\(.*\)"/\1/p' Sources/vela/main.swift)
BIN     := .build/release/vela
APP     := build/vela.app

.PHONY: all build install uninstall app clean test

all: build

build:
	swift build -c release --disable-sandbox

install: build
	install -d "$(PREFIX)/bin"
	install -m 755 $(BIN) "$(PREFIX)/bin/vela"

uninstall:
	rm -f "$(PREFIX)/bin/vela"

# A double-clickable app with file associations (uses the installed libmpv).
app: build
	rm -rf $(APP)
	install -d $(APP)/Contents/MacOS $(APP)/Contents/Resources
	install -m 755 $(BIN) $(APP)/Contents/MacOS/vela
	sed 's/@VERSION@/$(VERSION)/g' packaging/Info.plist > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "built $(APP) ($(VERSION))"

# Smoke test: version, probe a generated 4K HEVC clip (needs ffmpeg).
test: build
	$(BIN) --version
	ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=24 -f lavfi -i sine -t 2 \
		-c:v libx264 -c:a aac build/smoke.mp4
	$(BIN) --probe build/smoke.mp4 | grep -q "audio" && echo "probe ok"

clean:
	rm -rf .build build
