ifeq ($(strip $(DEVKITPRO)),)
$(error DEVKITPRO is not set)
endif
ifeq ($(strip $(DEVKITARM)),)
$(error DEVKITARM is not set)
endif

TOPDIR ?= $(CURDIR)
export TOPDIR
include $(DEVKITPRO)/devkitARM/3ds_rules

TARGET := o3vpxbench
BUILD := build

LIBVPX_ROOT := $(abspath $(CURDIR)/..)
GENHDR_DIR ?= $(abspath $(CURDIR)/../../tmp/libvpx-o3vpx-build)

ARCH := -march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft
O3VPX_TARGET_US ?= 41666
O3VPX_BENCH_ITERATIONS ?= 4
O3VPX_SD_STREAM_PATH ?= sdmc:/o3vpxbench.o3vx

CFLAGS := -g -Wall -O3 -std=gnu99 -mword-relocations -ffunction-sections -fdata-sections $(ARCH)
CFLAGS += $(INCLUDE) -D__3DS__ -DO3VPX_TARGET_US=$(O3VPX_TARGET_US)ULL
CFLAGS += -DO3VPX_BENCH_ITERATIONS=$(O3VPX_BENCH_ITERATIONS)
CFLAGS += -DO3VPX_SD_STREAM_PATH=\"$(O3VPX_SD_STREAM_PATH)\"
CXXFLAGS := $(CFLAGS) -fno-rtti -fno-exceptions
ASFLAGS := -g $(ARCH)
LDFLAGS = -specs=3dsx.specs -g $(ARCH) -Wl,--gc-sections -Wl,-Map,$(notdir $*.map)

LIBS := -lctru -lm
LIBDIRS := $(CTRULIB)

ifneq ($(BUILD),$(notdir $(CURDIR)))

export OUTPUT := $(CURDIR)/$(BUILD)/$(TARGET)
export VPATH := $(CURDIR)/source $(LIBVPX_ROOT)/vp8 $(LIBVPX_ROOT)/vp8/common $(LIBVPX_ROOT)/vp8/encoder
export DEPSDIR := $(CURDIR)/$(BUILD)

CFILES := main.c o3vpx.c idctllm.c dct.c
OFILES := $(CFILES:.c=.o)

export INCLUDE := -I$(CURDIR)/source -I$(LIBVPX_ROOT) -I$(GENHDR_DIR) \
  $(foreach dir,$(LIBDIRS),-I$(dir)/include)
export LIBPATHS := $(foreach dir,$(LIBDIRS),-L$(dir)/lib)
export OFILES := $(OFILES)

.PHONY: all clean $(BUILD)

all: $(BUILD)

$(BUILD):
	@[ -d $@ ] || mkdir -p $@
	@$(MAKE) --no-print-directory -C $(BUILD) -f $(CURDIR)/Makefile

clean:
	@echo clean ...
	@rm -fr $(BUILD)

else

.PHONY: all

all: $(OUTPUT).3dsx

$(OUTPUT).3dsx: $(OUTPUT).elf

$(OUTPUT).elf: $(OFILES)

%.elf:
	@echo linking $(notdir $@)
	@$(CC) $(LDFLAGS) $(OFILES) $(LIBPATHS) $(LIBS) -o $@

%.o: %.c
	@echo $(notdir $<)
	@$(CC) $(CFLAGS) -MMD -MP -MF $(DEPSDIR)/$*.d -c $< -o $@

-include $(DEPSDIR)/*.d

endif
