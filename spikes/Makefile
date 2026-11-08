# Phase 0 spikes. Run from the project root: make -C spikes
OUT := ../build
CFLAGS := -O2 -Wall -Wextra
FW := -framework IOKit -framework CoreFoundation
BINS := $(OUT)/spike-sleepguard $(OUT)/spike-sensors $(OUT)/spike-sleepnow $(OUT)/spike-clamshell $(OUT)/spike-display $(OUT)/spike-keyboard

all: $(BINS)
$(OUT)/spike-%: %.c common.h
	@mkdir -p $(OUT)
	clang $(CFLAGS) $< -o $@ $(FW) -framework CoreGraphics -F/System/Library/PrivateFrameworks -framework DisplayServices
$(OUT)/spike-keyboard: keyboard.m
	@mkdir -p $(OUT)
	clang -O2 -fobjc-arc -Wall $< -o $@ -framework Foundation

clean:
	rm -f $(BINS)
