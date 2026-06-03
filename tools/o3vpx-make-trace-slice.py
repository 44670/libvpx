#!/usr/bin/env python3
"""Build a two-frame O3VX stream for targeted instruction tracing.

The output stream contains:
  frame 0: raw keyframe from decoded_yuv[target_frame - 1]
  frame 1: original P-frame payload for target_frame from input.o3vx

This keeps the target frame's reference state intact while avoiding a huge
qemu -d exec trace over every earlier frame in the candidate stream.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


MAGIC = b"O3VX"
HEADER = struct.Struct("<4sHHHHIIHHH")
FRAME_HEADER = struct.Struct("<HI")
FRAME_SIZE = 800 * 240 * 3 // 2
FRAME_RAW_KEY = 0
FRAME_P = 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a two-frame O3VX trace slice for one P-frame."
    )
    parser.add_argument("stream", type=Path, help="Input candidate .o3vx")
    parser.add_argument("decoded_yuv", type=Path, help="Decoded 800x240 YUV420")
    parser.add_argument("target_frame", type=int, help="Zero-based P-frame index")
    parser.add_argument("output", type=Path, help="Output trace-slice .o3vx")
    return parser.parse_args()


def read_header(data: bytes) -> tuple[tuple[int, ...], int]:
    if len(data) < HEADER.size:
        raise ValueError("stream too short for O3VX header")
    fields = HEADER.unpack_from(data, 0)
    magic, version, width, height, fps, frames, target_bps, keyint, radius, res_q = fields
    if magic != MAGIC:
        raise ValueError("bad O3VX magic")
    if (width, height, fps) != (800, 240, 24):
        raise ValueError(f"unsupported geometry/fps: {width}x{height}@{fps}")
    return (version, width, height, fps, frames, target_bps, keyint, radius, res_q), HEADER.size


def frame_payloads(data: bytes, frame_count: int, offset: int) -> list[tuple[int, bytes]]:
    frames: list[tuple[int, bytes]] = []
    pos = offset
    for frame_no in range(frame_count):
        if pos + FRAME_HEADER.size > len(data):
            raise ValueError(f"short frame header at frame {frame_no}")
        frame_type, payload_len = FRAME_HEADER.unpack_from(data, pos)
        pos += FRAME_HEADER.size
        end = pos + payload_len
        if end > len(data):
            raise ValueError(f"short payload at frame {frame_no}")
        frames.append((frame_type, data[pos:end]))
        pos = end
    if pos != len(data):
        raise ValueError(f"trailing bytes after frames: {len(data) - pos}")
    return frames


def main() -> int:
    args = parse_args()
    if args.target_frame <= 0:
        raise SystemExit("target_frame must be a P-frame index greater than 0")

    stream = args.stream.read_bytes()
    header_fields, payload_offset = read_header(stream)
    version, width, height, fps, frame_count, target_bps, keyint, radius, res_q = header_fields
    if args.target_frame >= frame_count:
        raise SystemExit(
            f"target_frame {args.target_frame} out of range for {frame_count} frames"
        )

    frames = frame_payloads(stream, frame_count, payload_offset)
    target_type, target_payload = frames[args.target_frame]
    if target_type != FRAME_P:
        raise SystemExit(f"target_frame {args.target_frame} is not a P-frame")

    decoded_size = args.decoded_yuv.stat().st_size
    expected_decoded_size = frame_count * FRAME_SIZE
    if decoded_size != expected_decoded_size:
        raise SystemExit(
            f"decoded_yuv size {decoded_size} != expected {expected_decoded_size}"
        )
    with args.decoded_yuv.open("rb") as f:
        f.seek((args.target_frame - 1) * FRAME_SIZE)
        ref_frame = f.read(FRAME_SIZE)
    if len(ref_frame) != FRAME_SIZE:
        raise SystemExit("short decoded reference frame")

    out = bytearray()
    out += HEADER.pack(
        MAGIC,
        version,
        width,
        height,
        fps,
        2,
        target_bps,
        keyint,
        radius,
        res_q,
    )
    out += FRAME_HEADER.pack(FRAME_RAW_KEY, len(ref_frame))
    out += ref_frame
    out += FRAME_HEADER.pack(FRAME_P, len(target_payload))
    out += target_payload
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(out)

    print(
        "o3vpx_trace_slice "
        f"status=pass target_frame={args.target_frame} ref_frame={args.target_frame - 1} "
        f"target_payload_bytes={len(target_payload)} output_bytes={len(out)} "
        f"output={args.output}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"o3vpx_trace_slice status=fail reason={exc}", file=sys.stderr)
        raise SystemExit(1)
