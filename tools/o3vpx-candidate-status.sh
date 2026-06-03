#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: tools/o3vpx-candidate-status.sh <candidate-dir> [--allow-pending-hardware]

Audits an O3VPX candidate directory against the GUIDE_v2 old3ds-8m gates.
Strict mode exits 0 only for candidate_overall=pass_hardware. With
--allow-pending-hardware, local/emu gates may pass while physical Old3DS proof
is still missing; this is useful before the device log is imported.
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

candidate_dir=$1
allow_pending=0
if [[ "${2:-}" == "--allow-pending-hardware" ]]; then
  allow_pending=1
elif [[ $# -eq 2 ]]; then
  usage >&2
  exit 1
fi

python3 - "$candidate_dir" "$allow_pending" <<'PY'
import hashlib
import json
import os
import sys

candidate_dir = sys.argv[1]
allow_pending = sys.argv[2] == "1"

EXPECTED_SOURCE_SHA = "f10d41df63bf14362f8a7a41b7ea7da570e36b3a7af1a00616e758f9eca80e7f"
EXPECTED_STREAM_SHA = "532aab0f45f108b884d7cae407579c771a8e08f71582644f1a4708311f09feca"
EXPECTED_DECODED_SHA = "b756e71ee1aed39c1c95ee9f86a12318dff8c222a233de58a3d1bfb2d2c57588"
EXPECTED_FRAMES = 201


def load_json(name):
    path = os.path.join(candidate_dir, name)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def sha256_file(name):
    h = hashlib.sha256()
    with open(os.path.join(candidate_dir, name), "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def exists(name):
    return os.path.exists(os.path.join(candidate_dir, name))


checks = []


def check(name, ok, detail=""):
    checks.append((name, bool(ok), str(detail)))


try:
    summary = load_json("summary.json")
    source = load_json("source_info.json")
    quality = load_json("quality_vs_h264.json")
    host = load_json("profile_decode_host.json")
    arm = load_json("profile_decode_arm_qemu.json")
    targeted = load_json("arm_qemu_targeted_trace.json")
    azahar = load_json("azahar_functional.json")
except Exception as exc:
    print(f"o3vpx_candidate_status status=fail reason=metadata_error detail={type(exc).__name__}:{exc}")
    sys.exit(1)

required_files = [
    "candidate.o3vx",
    "decoded_host.yuv",
    "encode.log",
    "frame_log.csv",
    "mode_counts.txt",
    "quality_psnr.log",
    "baseline_h264_psnr.log",
    "profile_decode_host.json",
    "profile_decode_arm_qemu.json",
    "arm_qemu_targeted_trace.json",
    "trace_slice_frame108.o3vx",
    "azahar_functional.json",
    "o3vpxbench.3dsx",
    "old3ds_sdcard.zip",
]
for name in required_files:
    check(f"file:{name}", exists(name), "present" if exists(name) else "missing")

window = source.get("source_window_zero_based", {})
check("source_first_frame", window.get("first_frame") == 10000, window.get("first_frame"))
check("source_last_frame", window.get("last_frame") == 10200, window.get("last_frame"))
check("source_frame_count", window.get("frame_count") == EXPECTED_FRAMES, window.get("frame_count"))
check("source_sha256", source.get("sha256") == EXPECTED_SOURCE_SHA, source.get("sha256"))
check("source_path_label", "f10000_10200" in source.get("local_yuv", ""), source.get("local_yuv"))

if exists("candidate.o3vx"):
    check("stream_sha256_file", sha256_file("candidate.o3vx") == EXPECTED_STREAM_SHA, sha256_file("candidate.o3vx"))
check("stream_sha256_summary", summary.get("stream_sha256") == EXPECTED_STREAM_SHA, summary.get("stream_sha256"))
check("stream_bytes", summary.get("stream_bytes") == 8366445, summary.get("stream_bytes"))
check("bitrate_pass", summary.get("bitrate_pass") is True and summary.get("bitrate_mbps", 99) <= 8.0, summary.get("bitrate_mbps"))
check("encode_speed_1x", summary.get("encode_speed_pass_1x") is True and summary.get("encode_fps", 0) >= 24.0, summary.get("encode_fps"))

if exists("decoded_host.yuv"):
    check("decoded_sha256_file", sha256_file("decoded_host.yuv") == EXPECTED_DECODED_SHA, sha256_file("decoded_host.yuv"))
check("decoded_sha256_summary", summary.get("decoded_host_sha256") == EXPECTED_DECODED_SHA, summary.get("decoded_host_sha256"))
check("host_decode_pass", host.get("pass_24fps") is True and host.get("fps", 0) >= 24.0, host.get("fps"))
check("host_decoded_hash", host.get("decoded_sha256") == EXPECTED_DECODED_SHA, host.get("decoded_sha256"))
check("host_decmem_hash", host.get("memory_decode_sha256") == EXPECTED_DECODED_SHA, host.get("memory_decode_sha256"))

check("quality_average_pass", quality.get("quality_average_pass") is True, quality.get("candidate_psnr_avg_db"))
check("quality_worst_frame_pass", quality.get("quality_worst_frame_pass") is True, quality.get("candidate_psnr_min_db"))
check("quality_planes_pass", quality.get("quality_planes_pass") is True, f"Y={quality.get('candidate_psnr_y_db')} Cb={quality.get('candidate_psnr_cb_db')} Cr={quality.get('candidate_psnr_cr_db')}")
check("quality_avg_vs_h264", quality.get("candidate_psnr_avg_db", 0) >= quality.get("h264_psnr_avg_db", 999), f"{quality.get('candidate_psnr_avg_db')} >= {quality.get('h264_psnr_avg_db')}")
check("quality_min_vs_h264", quality.get("candidate_psnr_min_db", 0) >= quality.get("h264_psnr_min_db", 999), f"{quality.get('candidate_psnr_min_db')} >= {quality.get('h264_psnr_min_db')}")
check("quality_y_vs_h264", quality.get("candidate_psnr_y_db", 0) >= quality.get("h264_psnr_y_db", 999), f"{quality.get('candidate_psnr_y_db')} >= {quality.get('h264_psnr_y_db')}")
check("quality_cb_vs_h264", quality.get("candidate_psnr_cb_db", 0) >= quality.get("h264_psnr_cb_db", 999), f"{quality.get('candidate_psnr_cb_db')} >= {quality.get('h264_psnr_cb_db')}")
check("quality_cr_vs_h264", quality.get("candidate_psnr_cr_db", 0) >= quality.get("h264_psnr_cr_db", 999), f"{quality.get('candidate_psnr_cr_db')} >= {quality.get('h264_psnr_cr_db')}")

check("arm_qemu_pass", arm.get("pass_24fps") is True and arm.get("fps", 0) >= 24.0, arm.get("fps"))
check("arm_qemu_cpu", arm.get("cpu") == "arm1136", arm.get("cpu"))
check("arm_qemu_armv6", arm.get("elf", {}).get("cpu_arch") == "v6", arm.get("elf", {}).get("cpu_arch"))
check("arm_qemu_non_neon", arm.get("elf", {}).get("neon") is False, arm.get("elf", {}).get("neon"))
check("arm_qemu_memory", arm.get("max_rss_kib", 999999) <= 65536, arm.get("max_rss_kib"))
proxy = arm.get("instruction_proxy", {})
check("arm_raw_key_trace", proxy.get("raw_key_trace_entries", 0) > 0, proxy.get("raw_key_trace_entries"))
check("arm_first_p_trace", proxy.get("first_p_frame_incremental_trace_entries", 0) > 0, proxy.get("first_p_frame_incremental_trace_entries"))
check("arm_trace_log1", exists(proxy.get("qemu_decnull1_exec_log", "")), proxy.get("qemu_decnull1_exec_log"))
check("arm_trace_log2", exists(proxy.get("qemu_decnull2_exec_log", "")), proxy.get("qemu_decnull2_exec_log"))

target_proxy = targeted.get("instruction_proxy", {})
check("target_trace_status", targeted.get("status") == "pass", targeted.get("status"))
check("target_trace_frame", targeted.get("target_frame_zero_based") == 108, targeted.get("target_frame_zero_based"))
check("target_trace_reconstruction", targeted.get("slice_reconstruction_verified") is True, targeted.get("slice_reconstruction_verified"))
check("target_trace_armv6", targeted.get("elf", {}).get("cpu_arch") == "v6", targeted.get("elf", {}).get("cpu_arch"))
check("target_trace_non_neon", targeted.get("elf", {}).get("neon") is False, targeted.get("elf", {}).get("neon"))
check("target_trace_memory", targeted.get("slice_decnull", {}).get("max_rss_kib", 999999) <= 65536, targeted.get("slice_decnull", {}).get("max_rss_kib"))
check("target_trace_entries", target_proxy.get("target_frame_incremental_trace_entries", 0) > 0, target_proxy.get("target_frame_incremental_trace_entries"))
check("target_trace_log1", exists(target_proxy.get("qemu_decnull1_exec_log", "")), target_proxy.get("qemu_decnull1_exec_log"))
check("target_trace_log2", exists(target_proxy.get("qemu_decnull2_exec_log", "")), target_proxy.get("qemu_decnull2_exec_log"))

check("azahar_functional_pass", azahar.get("status") == "pass", azahar.get("status"))
check("azahar_source_window", azahar.get("source_window") == "f10000_10200", azahar.get("source_window"))
check("azahar_frames", azahar.get("frames_per_iteration") == EXPECTED_FRAMES, azahar.get("frames_per_iteration"))
check("azahar_checksum", azahar.get("checksum") == "0x5b24f04225d95bc1", azahar.get("checksum"))
check("azahar_old3ds_config", azahar.get("azahar_config", {}).get("is_new_3ds") is False, azahar.get("azahar_config", {}))

hardware_path = os.path.join(candidate_dir, "old3ds_hardware.json")
hardware_status = "missing"
hardware_reason = "missing_old3ds_hardware_json"
if os.path.exists(hardware_path):
    try:
        hardware = load_json("old3ds_hardware.json")
        hardware_status = hardware.get("status", "missing")
        hardware_reason = hardware.get("reason", "")
        check("hardware_status", hardware_status == "pass", hardware_status)
        check("hardware_profile", hardware.get("profile_device") == "old3ds_268mhz_armv6_non_neon", hardware.get("profile_device"))
        check("hardware_memory", hardware.get("memory_status") == "pass", hardware.get("memory_status"))
        check("hardware_functional", hardware.get("functional_status") == "pass", hardware.get("functional_status"))
        check("hardware_timing", hardware.get("bench_status") == "pass", hardware.get("bench_status"))
    except Exception as exc:
        hardware_status = "fail"
        hardware_reason = f"hardware_json_error:{type(exc).__name__}"
        check("hardware_json", False, hardware_reason)
else:
    check("hardware_status", False, hardware_reason)

failed = [(name, detail) for name, ok, detail in checks if not ok]
local_failed = [(name, detail) for name, detail in failed if not name.startswith("hardware_")]

if local_failed:
    status = "fail"
    reason = local_failed[0][0]
    exit_code = 1
elif hardware_status == "pass":
    status = "pass_hardware"
    reason = "pass_hardware"
    exit_code = 0
else:
    status = "pending_hardware"
    reason = hardware_reason
    exit_code = 0 if allow_pending else 2

print(
    "o3vpx_candidate_status "
    f"status={status} reason={reason} candidate={os.path.basename(candidate_dir)} "
    f"local_checks={len(checks) - len(failed)} local_failures={len(local_failed)} "
    f"hardware_status={hardware_status} allow_pending_hardware={int(allow_pending)}"
)
print(
    "o3vpx_candidate_metrics "
    f"bitrate_mbps={summary.get('bitrate_mbps')} encode_fps={summary.get('encode_fps')} "
    f"host_decode_fps={host.get('fps')} arm_qemu_fps={arm.get('fps')} "
    f"arm_first_p_trace={proxy.get('first_p_frame_incremental_trace_entries')} "
    f"arm_target_frame108_trace={target_proxy.get('target_frame_incremental_trace_entries')} "
    f"azahar_functional={azahar.get('status')}"
)

if failed:
    for name, detail in failed[:20]:
        print(f"o3vpx_candidate_check status=fail name={name} detail={detail}")
else:
    print("o3vpx_candidate_check status=pass name=all detail=all_gates_pass")

sys.exit(exit_code)
PY
