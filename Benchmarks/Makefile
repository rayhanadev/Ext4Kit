# Builds the Ext4Kit benchmark harness against the vendored lwext4 with the
# same CONFIG defines as the Xcode target. The block cache size is a
# compile-time knob:
#
#   make CACHE=8      # lwext4 default (what the extension shipped with)
#   make CACHE=2048   # candidate value
#   ./bench-cache8 /tmp/bench.img --verify
#
# Object files are rebuilt per CACHE value (suffix on the build dir).

LWEXT4 := ../Vendor/lwext4
CACHE  ?= 8
BUILD  := build-cache$(CACHE)
BIN    := bench-cache$(CACHE)

CC      ?= cc
DEFINES := -DCONFIG_USE_DEFAULT_CFG=1 -DCONFIG_DEBUG_PRINTF=0 \
           -DCONFIG_HAVE_OWN_ERRNO=0 -DCONFIG_BLOCK_DEV_CACHE_SIZE=$(CACHE)
CFLAGS  := -O2 -w $(DEFINES) \
           -I$(LWEXT4)/include -I$(LWEXT4)/include/misc \
           -I$(LWEXT4)/blockdev/linux

LW_SRC  := $(wildcard $(LWEXT4)/src/*.c)
SRC     := $(LW_SRC) $(LWEXT4)/blockdev/linux/file_dev.c bench.c
OBJ     := $(patsubst %.c,$(BUILD)/%.o,$(notdir $(SRC)))

VPATH   := $(LWEXT4)/src:$(LWEXT4)/blockdev/linux:.

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ)

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf build-cache* bench-cache*

.PHONY: clean
