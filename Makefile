CC = xcrun clang
BUILD := build
APP := $(BUILD)/Boomer.app
TARGET := $(BUILD)/boomer
# Optional Apple Development / Developer ID identity. Otherwise use the
# project-local identity from make setup-signing, falling back to ad-hoc.
CODESIGN_IDENTITY ?=
CPPFLAGS := -Isrc -I$(BUILD)
CFLAGS := -std=c11 -O2 -g -Wall -Wextra -Wpedantic -Werror -mmacosx-version-min=14.0
OBJCFLAGS := $(CFLAGS) -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
              -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ImageIO -framework Carbon
OBJECTS := $(BUILD)/Camera.o $(BUILD)/Timing.o $(BUILD)/Renderer.o $(BUILD)/Capture.o $(BUILD)/HotKey.o $(BUILD)/ShortcutSettings.o $(BUILD)/main.o
CLANG_FORMAT ?= clang-format
CLANG_TIDY ?= clang-tidy
SDKROOT ?= $(shell xcrun --show-sdk-path)
LINT_C_SOURCES := $(wildcard src/*.c tests/*.c)
LINT_OBJC_SOURCES := $(wildcard src/*.m tests/*.m)
FORMAT_SOURCES := $(sort $(wildcard src/*.c src/*.h src/*.m src/*.metal tests/*.c tests/*.h tests/*.m))

.PHONY: all app run demo setup-signing format format-check lint test test-gpu test-window test-hotkey test-capture check clean
all: $(TARGET) app

$(BUILD):
	mkdir -p $@

$(BUILD)/Shaders.inc: src/Shaders.metal | $(BUILD)
	xxd -i $< > $@

$(BUILD)/%.o: src/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

$(BUILD)/%.o: src/%.m $(BUILD)/Shaders.inc | $(BUILD)
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) -MMD -MP -c $< -o $@

$(TARGET): $(OBJECTS)
	$(CC) -mmacosx-version-min=14.0 $^ $(FRAMEWORKS) -o $@

app: $(TARGET) resources/Info.plist scripts/build-app.sh
	sh scripts/build-app.sh "$(TARGET)" "$(APP)" "$(CODESIGN_IDENTITY)"

setup-signing:
	sh scripts/setup-signing.sh

run: app
	open $(APP)

demo: app
	open $(APP) --args --demo --windowed

format:
	$(CLANG_FORMAT) --style=file --fail-on-incomplete-format -i $(FORMAT_SOURCES)

format-check:
	$(CLANG_FORMAT) --style=file --fail-on-incomplete-format --dry-run --Werror $(FORMAT_SOURCES)

lint: $(BUILD)/Shaders.inc
	$(CLANG_TIDY) $(LINT_C_SOURCES) -- $(CPPFLAGS) $(CFLAGS) -isysroot "$(SDKROOT)"
	$(CLANG_TIDY) $(LINT_OBJC_SOURCES) -- $(CPPFLAGS) $(OBJCFLAGS) -isysroot "$(SDKROOT)"

$(BUILD)/test-camera: tests/test_camera.c src/Camera.c src/Camera.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -fsanitize=address,undefined tests/test_camera.c src/Camera.c -o $@

test: $(BUILD)/test-camera $(TARGET)
	$(BUILD)/test-camera
	sh tests/test_cli.sh $(TARGET)

test-gpu: $(TARGET)
	$(TARGET) --self-test

$(BUILD)/test-window: tests/test_window.m src/main.m src/Camera.h src/Renderer.h src/Capture.h $(filter-out $(BUILD)/main.o,$(OBJECTS))
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) $< $(filter-out $(BUILD)/main.o,$(OBJECTS)) $(FRAMEWORKS) -o $@

test-window: $(BUILD)/test-window
	$(BUILD)/test-window

$(BUILD)/test-hotkey: tests/test_hotkey.m src/HotKey.m src/HotKey.h $(BUILD)/ShortcutSettings.o | $(BUILD)
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) $< $(BUILD)/ShortcutSettings.o -framework Cocoa -framework Carbon -o $@

test-hotkey: $(BUILD)/test-hotkey
	$(BUILD)/test-hotkey

$(BUILD)/test-capture: tests/test_capture.m src/Capture.m src/Capture.h $(BUILD)/Timing.o
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) $< $(BUILD)/Timing.o $(FRAMEWORKS) -o $@

test-capture: $(BUILD)/test-capture
	$(BUILD)/test-capture

check: format-check lint test test-gpu test-window test-hotkey test-capture

clean:
	rm -rf $(BUILD)

-include $(OBJECTS:.o=.d)
