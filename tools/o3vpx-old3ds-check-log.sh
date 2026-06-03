#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: tools/o3vpx-old3ds-check-log.sh <old3ds-log> [expected_frames] [target_us]

Checks an O3VPX Old3DS harness log for the current 201-frame proof stream.
This validates the log contents and timing result. It does not by itself prove
that the file came from a physical Old3DS; the caller must import it from the
device SD card.

Defaults:
  expected_frames  201
  target_us        41666
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

log=${1:?missing old3ds log}
expected_frames=${2:-201}
target_us=${3:-41666}

if [[ ! -f "$log" ]]; then
  echo "missing log: $log" >&2
  exit 1
fi
if [[ ! "$expected_frames" =~ ^[0-9]+$ || "$expected_frames" == 0 ]]; then
  echo "expected_frames must be a positive integer" >&2
  exit 1
fi
if [[ ! "$target_us" =~ ^[0-9]+$ || "$target_us" == 0 ]]; then
  echo "target_us must be a positive integer" >&2
  exit 1
fi

last_line() {
  local prefix=$1
  grep "^${prefix} " "$log" | tail -1 || true
}

kv_value() {
  local line=$1
  local key=$2
  tr ' ' '\n' <<<"$line" | sed -n "s/^${key}=//p" | tail -1
}

fail() {
  printf 'o3vpx_old3ds_log status=fail reason=%s log=%s\n' "$1" "$log"
  exit 1
}

profile_line=$(last_line profile_report)
memory_line=$(last_line memory_report)
functional_line=$(last_line functional_result)
bench_line=$(last_line bench_result)

[[ -n "$profile_line" ]] || fail missing_profile_report
[[ -n "$memory_line" ]] || fail missing_memory_report
[[ -n "$functional_line" ]] || fail missing_functional_result
[[ -n "$bench_line" ]] || fail missing_bench_result

profile_status=$(kv_value "$profile_line" status)
profile_device=$(kv_value "$profile_line" device_profile)
profile_new3ds=$(kv_value "$profile_line" new3ds)
memory_status=$(kv_value "$memory_line" status)
functional_status=$(kv_value "$functional_line" status)
functional_frames=$(kv_value "$functional_line" frames_per_iteration)
functional_window=$(kv_value "$functional_line" source_window)
bench_status=$(kv_value "$bench_line" status)
bench_frames=$(kv_value "$bench_line" frames_per_iteration)
bench_worst_us=$(kv_value "$bench_line" worst_us)
bench_target_us=$(kv_value "$bench_line" target_us)

[[ "$profile_status" == pass ]] || fail profile_${profile_status:-missing}
[[ "$profile_device" == old3ds_268mhz_armv6_non_neon ]] \
  || fail profile_device_${profile_device:-missing}
[[ "$profile_new3ds" == 0 ]] || fail profile_new3ds_${profile_new3ds:-missing}
[[ "$memory_status" == pass ]] || fail memory_${memory_status:-missing}
[[ "$functional_status" == pass ]] \
  || fail functional_${functional_status:-missing}
[[ "$functional_frames" == "$expected_frames" ]] \
  || fail functional_frames_${functional_frames:-missing}
[[ "$functional_window" == f10000_10200 ]] \
  || fail source_window_${functional_window:-missing}
[[ "$bench_status" == pass ]] || fail bench_${bench_status:-missing}
[[ "$bench_frames" == "$expected_frames" ]] \
  || fail bench_frames_${bench_frames:-missing}
[[ -n "$bench_worst_us" ]] || fail missing_bench_worst_us
[[ -n "$bench_target_us" ]] || fail missing_bench_target_us

if (( bench_target_us != target_us )); then
  fail bench_target_${bench_target_us}
fi
if (( bench_worst_us > target_us )); then
  fail bench_worst_${bench_worst_us}
fi

printf 'o3vpx_old3ds_log status=pass log=%s profile=%s frames=%s worst_us=%s target_us=%s checksum=%s\n' \
  "$log" "$profile_device" "$bench_frames" "$bench_worst_us" "$target_us" \
  "$(kv_value "$bench_line" checksum)"
