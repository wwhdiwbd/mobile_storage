# Android.mk for BigCache + UFFD
#
# Build for Android using NDK

LOCAL_PATH := $(call my-dir)

# Main executable
include $(CLEAR_VARS)
LOCAL_MODULE := bigcache
LOCAL_SRC_FILES := \
    src/bigcache_index.c \
    src/bigcache_packer.c \
    src/uffd_handler.c \
    src/preloader.c \
    src/main.c

LOCAL_C_INCLUDES := $(LOCAL_PATH)/include
LOCAL_CFLAGS := -Wall -Wextra -O2 -D_GNU_SOURCE
LOCAL_LDLIBS := -llog
include $(BUILD_EXECUTABLE)

# File preheat tool (simple and effective!)
include $(CLEAR_VARS)
LOCAL_MODULE := preheat
LOCAL_SRC_FILES := src/preheat_files.c
LOCAL_CFLAGS := -Wall -Wextra -O2 -D_GNU_SOURCE
LOCAL_LDLIBS := -llog
include $(BUILD_EXECUTABLE)

# BigCache Tracer - ptrace-based syscall interception
include $(CLEAR_VARS)
LOCAL_MODULE := tracer
LOCAL_SRC_FILES := src/bigcache_tracer.c
LOCAL_CFLAGS := -Wall -Wextra -O2 -D_GNU_SOURCE
LOCAL_LDLIBS := -llog
include $(BUILD_EXECUTABLE)

# BigCache Generator - runs on device to extract real file data
include $(CLEAR_VARS)
LOCAL_MODULE := genbigcache
LOCAL_SRC_FILES := src/generate_bigcache.c
LOCAL_CFLAGS := -Wall -Wextra -O2 -D_GNU_SOURCE
LOCAL_LDLIBS := -llog
include $(BUILD_EXECUTABLE)

# Preloader shared library
include $(CLEAR_VARS)
LOCAL_MODULE := preloader
LOCAL_SRC_FILES := \
    src/bigcache_index.c \
    src/uffd_handler.c \
    src/preloader.c

LOCAL_C_INCLUDES := $(LOCAL_PATH)/include
LOCAL_CFLAGS := -Wall -Wextra -O2 -D_GNU_SOURCE -DENABLE_MMAP_HOOK
LOCAL_LDLIBS := -llog -ldl
include $(BUILD_SHARED_LIBRARY)
