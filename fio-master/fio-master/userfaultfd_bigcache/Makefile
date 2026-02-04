# Makefile for BigCache + UFFD
#
# Usage:
#   make              - Build for Linux
#   make clean        - Clean build artifacts
#   make test         - Run tests
#   make android      - Build for Android (requires NDK)

CC = gcc
CFLAGS = -Wall -Wextra -O2 -g -I./include -D_GNU_SOURCE
LDFLAGS = -lpthread -ldl

# Source files
SRC_DIR = src
INC_DIR = include
BUILD_DIR = build
TEST_DIR = test

SRCS = $(SRC_DIR)/bigcache_index.c \
       $(SRC_DIR)/bigcache_packer.c \
       $(SRC_DIR)/uffd_handler.c \
       $(SRC_DIR)/preloader.c \
       $(SRC_DIR)/main.c

OBJS = $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS))

# Main target
TARGET = $(BUILD_DIR)/bigcache

# Packer tool (standalone)
PACKER_TARGET = $(BUILD_DIR)/bigcache_packer

# Preloader library
PRELOADER_LIB = $(BUILD_DIR)/libpreloader.so

.PHONY: all clean test android install

all: $(BUILD_DIR) $(TARGET) $(PACKER_TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)
	@echo "Built: $@"

$(PACKER_TARGET): $(SRC_DIR)/bigcache_packer.c $(SRC_DIR)/bigcache_index.c
	$(CC) $(CFLAGS) -DBUILD_PACKER_TOOL $^ -o $@ $(LDFLAGS)
	@echo "Built: $@"

$(PRELOADER_LIB): $(SRC_DIR)/preloader.c $(SRC_DIR)/uffd_handler.c $(SRC_DIR)/bigcache_index.c
	$(CC) $(CFLAGS) -shared -fPIC -DENABLE_MMAP_HOOK $^ -o $@ $(LDFLAGS)
	@echo "Built: $@"

preloader: $(BUILD_DIR) $(PRELOADER_LIB)

clean:
	rm -rf $(BUILD_DIR)
	rm -f *.bin *.o

# Test targets
test: $(TARGET)
	@echo "Running tests..."
	./$(TARGET) info test/sample_bigcache.bin || true
	./$(TARGET) benchmark test/sample_bigcache.bin 100 || true

# Generate test BigCache from existing layout
test-pack: $(PACKER_TARGET)
	./$(PACKER_TARGET) ../visit_io/io_visualization_output/bigcache_layout.csv \
	                   $(BUILD_DIR)/test_bigcache.bin

# Android NDK build
ANDROID_NDK ?= $(HOME)/Android/Sdk/ndk-bundle
ANDROID_PLATFORM ?= android-26
ANDROID_ABI ?= arm64-v8a

android:
	@echo "Building for Android..."
	@if [ ! -d "$(ANDROID_NDK)" ]; then \
		echo "Error: ANDROID_NDK not found at $(ANDROID_NDK)"; \
		echo "Set ANDROID_NDK environment variable to your NDK path"; \
		exit 1; \
	fi
	$(ANDROID_NDK)/ndk-build \
		APP_BUILD_SCRIPT=./Android.mk \
		APP_PLATFORM=$(ANDROID_PLATFORM) \
		APP_ABI=$(ANDROID_ABI) \
		NDK_PROJECT_PATH=. \
		NDK_OUT=$(BUILD_DIR)/android/obj \
		NDK_LIBS_OUT=$(BUILD_DIR)/android/libs

# Install to Android device
install-android: android
	adb push $(BUILD_DIR)/android/libs/$(ANDROID_ABI)/bigcache /data/local/tmp/
	adb shell chmod 755 /data/local/tmp/bigcache

# Help
help:
	@echo "BigCache + UFFD Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build main program and packer tool"
	@echo "  preloader  - Build LD_PRELOAD library"
	@echo "  clean      - Clean build artifacts"
	@echo "  test       - Run basic tests"
	@echo "  test-pack  - Generate test BigCache from layout CSV"
	@echo "  android    - Build for Android (requires NDK)"
	@echo "  install-android - Push to Android device"
	@echo ""
	@echo "Environment variables:"
	@echo "  ANDROID_NDK      - Path to Android NDK"
	@echo "  ANDROID_PLATFORM - Target Android platform (default: android-26)"
	@echo "  ANDROID_ABI      - Target ABI (default: arm64-v8a)"
