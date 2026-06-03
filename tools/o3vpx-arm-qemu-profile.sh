#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: tools/o3vpx-arm-qemu-profile.sh <input.o3vx> [trace_frames]

Builds the O3VPX tool for ARMv6 Linux using a local rootless cross sysroot and
runs qemu-arm decoder profiling. The default trace covers three decoded frames:
raw key, first P-frame, and second P-frame. With qemu's -one-insn-per-tb, each
executed TB trace line is a guest-instruction proxy.

Expected default local toolchain layout:
  tmp/arm-cross-root/usr/bin/arm-linux-gnueabi-gcc
  tmp/arm-cross-root/usr/arm-linux-gnueabi/lib/ld-linux.so.3

Environment overrides:
  ROOT                 minicodec repository root
  LIBVPX_ROOT          libvpx source root
  BUILD_DIR            libvpx build dir containing vpx_config.h
  ARM_ROOT             extracted cross sysroot root
  ARM_CC               ARM Linux C compiler
  ARM_LD_LIBRARY_PATH  host library path for extracted binutils
  QEMU_ARM             qemu-arm executable
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

root=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
libvpx_root=${LIBVPX_ROOT:-$root/libvpx}
build_dir=${BUILD_DIR:-$root/tmp/libvpx-o3vpx-build}
arm_root=${ARM_ROOT:-$root/tmp/arm-cross-root}
arm_cc=${ARM_CC:-$arm_root/usr/bin/arm-linux-gnueabi-gcc}
arm_ld_library_path=${ARM_LD_LIBRARY_PATH:-$arm_root/usr/lib/x86_64-linux-gnu}
qemu=${QEMU_ARM:-qemu-arm}
input=$1
trace_frames=${2:-3}
out_dir=${OUT_DIR:-$root/../tmp/o3vpx-arm-qemu-profile}
arm_bin=${ARM_BIN:-$arm_root/o3vpx-armv6}
qemu_ld_prefix=$arm_root/usr/arm-linux-gnueabi

if [[ ! -f "$input" ]]; then
  echo "missing input stream: $input" >&2
  exit 1
fi
if [[ ! "$trace_frames" =~ ^[0-9]+$ || "$trace_frames" -lt 2 ]]; then
  echo "trace_frames must be an integer >= 2" >&2
  exit 1
fi
if [[ ! -x "$arm_cc" ]]; then
  echo "missing ARM compiler: $arm_cc" >&2
  exit 1
fi
if [[ ! -f "$build_dir/vpx_config.h" ]]; then
  echo "missing libvpx generated config: $build_dir/vpx_config.h" >&2
  exit 1
fi
if [[ ! -f "$qemu_ld_prefix/lib/ld-linux.so.3" ]]; then
  echo "missing ARM qemu sysroot loader: $qemu_ld_prefix/lib/ld-linux.so.3" >&2
  exit 1
fi
if ! command -v "$qemu" >/dev/null 2>&1; then
  echo "missing qemu-arm: $qemu" >&2
  exit 1
fi

mkdir -p "$out_dir"

echo "o3vpx_arm_profile_input=$input"
echo "o3vpx_arm_profile_input_sha256=$(sha256sum "$input" | awk '{ print $1; exit }')"
echo "o3vpx_arm_profile_root=$root"
echo "o3vpx_arm_profile_libvpx_root=$libvpx_root"
echo "o3vpx_arm_profile_build_dir=$build_dir"
echo "o3vpx_arm_profile_arm_root=$arm_root"
echo "o3vpx_arm_profile_qemu=$qemu"

LD_LIBRARY_PATH="$arm_ld_library_path" "$arm_cc" \
  --sysroot="$arm_root" \
  -O3 -DNDEBUG -march=armv6 -mtune=arm1136jf-s -mfloat-abi=soft \
  -fno-tree-vectorize \
  -I"$build_dir" -I"$libvpx_root" -I"$libvpx_root/vp8" \
  "$libvpx_root/tools/o3vpx.c" \
  "$libvpx_root/vp8/o3vpx.c" \
  "$libvpx_root/vp8/encoder/dct.c" \
  "$libvpx_root/vp8/common/idctllm.c" \
  "$libvpx_root/vpx_dsp/sad.c" \
  "$libvpx_root/vpx_dsp/variance.c" \
  -lm -o "$arm_bin"

file "$arm_bin"
LD_LIBRARY_PATH="$arm_ld_library_path" "$arm_root/usr/bin/arm-linux-gnueabi-readelf" \
  -A "$arm_bin" | sed 's/^/arm_elf_attr /'

echo "qemu_full_decnull_begin"
/usr/bin/time -v "$qemu" -cpu arm1136 -L "$qemu_ld_prefix" \
  "$arm_bin" decnull "$input" 2>&1 | sed 's/^/qemu_full_decnull /'
echo "qemu_full_decnull_end"

prev_count=0
for frame in $(seq 1 "$trace_frames"); do
  log="$out_dir/qemu-decnull${frame}-exec.log"
  "$qemu" -cpu arm1136 -one-insn-per-tb -d exec,nochain -D "$log" \
    -L "$qemu_ld_prefix" "$arm_bin" decnull "$input" "$frame" \
    2>&1 | sed "s/^/qemu_trace_run frame=$frame /"
  if command -v rg >/dev/null 2>&1; then
    count=$(rg -c '^Trace ' "$log")
  else
    count=$(grep -c '^Trace ' "$log")
  fi
  size=$(wc -c < "$log")
  incremental=$((count - prev_count))
  echo "qemu_instruction_proxy frame=$frame cumulative_trace_entries=$count incremental_trace_entries=$incremental log_bytes=$size log=$log"
  prev_count=$count
done
