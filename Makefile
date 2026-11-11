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
              -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ImageIO
OBJECTS := $(BUILD)/Camera.o $(BUILD)/Renderer.o $(BUILD)/Capture.o $(BUILD)/main.o

.PHONY: all app run demo setup-signing test test-gpu test-window check clean
all: $(TARGET) app

$(BUILD):
	mkdir -p $@

$(BUILD)/Shaders.inc: src/Shaders.metal | $(BUILD)
	xxd -i $< > $@

$(BUILD)/Camera.o: src/Camera.c src/Camera.h | $(BUILD)
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

check: test test-gpu test-window

clean:
	rm -rf $(BUILD)

-include $(OBJECTS:.o=.d)
