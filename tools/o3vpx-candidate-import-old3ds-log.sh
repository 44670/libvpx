#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: tools/o3vpx-candidate-import-old3ds-log.sh <candidate-dir> <old3ds-log> [expected_frames] [target_us]

Copies an O3VPX physical Old3DS harness log into a candidate directory, runs
the strict O3VPX Old3DS log checker, and writes old3ds_hardware.json.

The input log must be copied from the physical device's sdmc:/o3yvbench.log.
Azahar logs are useful for functional smoke, but they are not final hardware
evidence and should not be imported with this tool.

Defaults:
  expected_frames  201
  target_us        41666
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

candidate_dir=$1
source_log=$2
expected_frames=${3:-201}
target_us=${4:-41666}

tool_dir=$(cd "$(dirname "$0")" && pwd)
checker="$tool_dir/o3vpx-old3ds-check-log.sh"
dest_log="$candidate_dir/old3ds-bench.log"
json_out="$candidate_dir/old3ds_hardware.json"

if [[ ! -d "$candidate_dir" ]]; then
  echo "missing candidate directory: $candidate_dir" >&2
  exit 1
fi
if [[ ! -f "$source_log" ]]; then
  echo "missing source log: $source_log" >&2
  exit 1
fi
if [[ ! -x "$checker" ]]; then
  echo "missing checker: $checker" >&2
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

cp "$source_log" "$dest_log"

last_line() {
  local prefix=$1
  grep "^${prefix} " "$dest_log" | tail -1 || true
}

kv_value() {
  local line=$1
  local key=$2
  tr ' ' '\n' <<<"$line" | sed -n "s/^${key}=//p" | tail -1
}

profile_line=$(last_line profile_report)
memory_line=$(last_line memory_report)
functional_line=$(last_line functional_result)
bench_line=$(last_line bench_result)

set +e
checker_output=$("$checker" "$dest_log" "$expected_frames" "$target_us" 2>&1)
checker_rc=$?
set -e

checker_line=$(grep '^o3vpx_old3ds_log ' <<<"$checker_output" | tail -1 || true)
status=$(kv_value "$checker_line" status)
reason=$(kv_value "$checker_line" reason)
status=${status:-fail}
reason=${reason:-unknown}

profile_status=$(kv_value "$profile_line" status)
profile_device=$(kv_value "$profile_line" device_profile)
profile_new3ds=$(kv_value "$profile_line" new3ds)
memory_status=$(kv_value "$memory_line" status)
memory_runtime_bytes=$(kv_value "$memory_line" runtime_bytes)
memory_budget_bytes=$(kv_value "$memory_line" budget_bytes)
functional_status=$(kv_value "$functional_line" status)
functional_frames=$(kv_value "$functional_line" frames_per_iteration)
functional_checksum=$(kv_value "$functional_line" checksum)
bench_status=$(kv_value "$bench_line" status)
bench_frames=$(kv_value "$bench_line" frames_per_iteration)
bench_worst_us=$(kv_value "$bench_line" worst_us)
bench_target_us=$(kv_value "$bench_line" target_us)
bench_checksum=$(kv_value "$bench_line" checksum)
log_sha256=$(sha256sum "$dest_log" | awk '{ print $1; exit }')

cat >"$json_out" <<JSON
{
  "status": "$status",
  "reason": "$reason",
  "log": "old3ds-bench.log",
  "log_sha256": "$log_sha256",
  "checker": "libvpx/tools/o3vpx-old3ds-check-log.sh",
  "checker_exit_code": $checker_rc,
  "expected_frames": $expected_frames,
  "target_us": $target_us,
  "profile_status": "${profile_status:-missing}",
  "profile_device": "${profile_device:-missing}",
  "profile_new3ds": "${profile_new3ds:-missing}",
  "memory_status": "${memory_status:-missing}",
  "memory_runtime_bytes": "${memory_runtime_bytes:-missing}",
  "memory_budget_bytes": "${memory_budget_bytes:-missing}",
  "functional_status": "${functional_status:-missing}",
  "functional_frames_per_iteration": "${functional_frames:-missing}",
  "functional_checksum": "${functional_checksum:-missing}",
  "bench_status": "${bench_status:-missing}",
  "bench_frames_per_iteration": "${bench_frames:-missing}",
  "bench_worst_us": "${bench_worst_us:-missing}",
  "bench_target_us": "${bench_target_us:-missing}",
  "bench_checksum": "${bench_checksum:-missing}"
}
JSON

printf '%s\n' "$checker_output"
printf 'o3vpx_hardware_import status=%s json=%s log=%s\n' \
  "$status" "$json_out" "$dest_log"

exit "$checker_rc"
