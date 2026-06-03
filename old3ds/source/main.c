#include <3ds.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vp8/o3vpx.h"

#define LOG_PATH "sdmc:/o3yvbench.log"
#define MAX_BENCH_SAMPLES 32768
#define PLAYBACK_TARGET_FPS 24ULL
#define PLAYBACK_TARGET_US (1000000ULL / PLAYBACK_TARGET_FPS)
#define MEMORY_BUDGET_BYTES (64ULL * 1024ULL * 1024ULL)
#define RGB565_EYE_BYTES (O3VPX_EYE_WIDTH * O3VPX_EYE_HEIGHT * 2)
#define TOP_RGB565_FRAMEBUFFER_BYTES (RGB565_EYE_BYTES * 2ULL)

#ifndef O3VPX_TARGET_US
#define O3VPX_TARGET_US 41666ULL
#endif

#ifndef O3VPX_BENCH_ITERATIONS
#define O3VPX_BENCH_ITERATIONS 4
#endif

#ifndef O3VPX_SD_STREAM_PATH
#define O3VPX_SD_STREAM_PATH "sdmc:/o3vpxbench.o3vx"
#endif

static FILE *g_log_file;
static u64 g_samples[MAX_BENCH_SAMPLES];

static void bench_log(const char *fmt, ...) {
  char buffer[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);
  fputs(buffer, stdout);
  if (g_log_file) {
    fputs(buffer, g_log_file);
    fflush(g_log_file);
  }
}

static u64 ticks_to_us(u64 ticks) {
  return (ticks * 1000000ULL) / (u64)SYSCLOCK_ARM11;
}

static u64 us_to_ticks(u64 us) {
  return (us * (u64)SYSCLOCK_ARM11) / 1000000ULL;
}

static int compare_u64(const void *a, const void *b) {
  const u64 av = *(const u64 *)a;
  const u64 bv = *(const u64 *)b;
  if (av < bv) return -1;
  if (av > bv) return 1;
  return 0;
}

static u64 percentile_ticks(const u64 *samples, u32 count, u32 pct) {
  const u32 rank = ((pct * count) + 99) / 100;
  return samples[rank == 0 ? 0 : rank - 1];
}

static void checksum_update_byte(u64 *state, u8 byte) {
  *state ^= (u64)byte;
  *state *= 1099511628211ULL;
}

static void checksum_update_u32(u64 *state, u32 value) {
  checksum_update_byte(state, (u8)(value & 0xff));
  checksum_update_byte(state, (u8)((value >> 8) & 0xff));
  checksum_update_byte(state, (u8)((value >> 16) & 0xff));
  checksum_update_byte(state, (u8)((value >> 24) & 0xff));
}

static void checksum_update_bytes(u64 *state, const u8 *bytes, size_t len) {
  for (size_t i = 0; i < len; i++) checksum_update_byte(state, bytes[i]);
}

static void checksum_update_frame(
    u64 *state, const O3vpxFrameInfo *info, const u8 *left,
    const u8 *right, size_t eye_bytes) {
  checksum_update_u32(state, info->frame_no);
  checksum_update_byte(state, (u8)info->frame_type);
  checksum_update_bytes(state, left, eye_bytes);
  checksum_update_bytes(state, right, eye_bytes);
}

static void print_profile_report(void) {
  bool is_new3ds = false;
  const Result rc = APT_CheckNew3DS(&is_new3ds);
  const int check_ok = R_SUCCEEDED(rc);
  bench_log("profile_report status=%s reason=%s "
            "device_profile=%s required_profile=old3ds_268mhz_armv6_non_neon "
            "new3ds=%u cpu_mhz=268 arm=armv6 neon=0 check_rc=0x%08lX\n",
            check_ok && !is_new3ds ? "pass" : "fail",
            check_ok ? (is_new3ds ? "new3ds_not_old3ds" : "pass")
                     : "check_failed",
            check_ok ? (is_new3ds ? "new3ds_armv6_non_neon"
                                  : "old3ds_268mhz_armv6_non_neon")
                     : "unknown",
            check_ok && is_new3ds ? 1U : 0U, (unsigned long)rc);
}

static u64 align_up_u64(u64 value, u64 align) {
  const u64 rem = value % align;
  return rem == 0 ? value : value + (align - rem);
}

static void print_memory_report(size_t stream_size, size_t decoder_size,
                                size_t eye_bytes) {
  const u64 stream_alloc = align_up_u64((u64)stream_size, 0x80);
  const u64 decoder_alloc = align_up_u64((u64)decoder_size, 0x80);
  const u64 decoder_internal = (u64)vp8_o3vpx_decoder_internal_bytes();
  const u64 eye_alloc = align_up_u64((u64)eye_bytes, 0x80) * 2ULL;
  const u64 timing_bytes = sizeof(g_samples);
  const u64 runtime = stream_alloc + decoder_alloc + decoder_internal +
                      eye_alloc + timing_bytes + TOP_RGB565_FRAMEBUFFER_BYTES;
  bench_log("memory_report status=%s memory_schema=1 budget_bytes=%llu "
            "runtime_bytes=%llu stream_storage=sd_file stream_bytes=%lu "
            "stream_alloc_bytes=%llu decoder_bytes=%lu "
            "decoder_alloc_bytes=%llu decoder_internal_bytes=%llu "
            "output_buffers_bytes=%llu timing_arrays_bytes=%llu "
            "gfx_top_framebuffer_bytes=%llu\n",
            runtime <= MEMORY_BUDGET_BYTES ? "pass" : "fail",
            (unsigned long long)MEMORY_BUDGET_BYTES,
            (unsigned long long)runtime, (unsigned long)stream_size,
            (unsigned long long)stream_alloc, (unsigned long)decoder_size,
            (unsigned long long)decoder_alloc,
            (unsigned long long)decoder_internal,
            (unsigned long long)eye_alloc,
            (unsigned long long)timing_bytes,
            (unsigned long long)TOP_RGB565_FRAMEBUFFER_BYTES);
}

static int load_stream(const char *path, u8 **stream, size_t *stream_size) {
  FILE *file = fopen(path, "rb");
  long size;
  if (!file) return -1;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return -2;
  }
  size = ftell(file);
  if (size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return -3;
  }
  *stream = (u8 *)linearMemAlign((size_t)size, 0x80);
  if (!*stream) {
    fclose(file);
    return -4;
  }
  if (fread(*stream, 1, (size_t)size, file) != (size_t)size) {
    fclose(file);
    return -5;
  }
  fclose(file);
  *stream_size = (size_t)size;
  return 0;
}

static u8 clip_i32_to_u8(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return (u8)value;
}

static void put_yuv_pixel_rgb565(u8 *fb, int x, int y, u8 y_sample,
                                 int cb, int cr) {
  int yy = (int)y_sample - 16;
  if (yy < 0) yy = 0;
  const int r = (19077 * yy + 29372 * cr + 8192) >> 14;
  const int g = (19077 * yy - 3494 * cb - 8739 * cr + 8192) >> 14;
  const int b = (19077 * yy + 34610 * cb + 8192) >> 14;
  const u32 pixel = RGB8_to_565(clip_i32_to_u8(r), clip_i32_to_u8(g),
                                clip_i32_to_u8(b));
  const u32 dst = (u32)((O3VPX_EYE_HEIGHT - 1 - y) + x * O3VPX_EYE_HEIGHT) * 2u;
  fb[dst] = (u8)(pixel & 0xffu);
  fb[dst + 1] = (u8)(pixel >> 8);
}

static void render_eye_rgb565(const u8 *eye, gfx3dSide_t side) {
  u8 *fb = gfxGetFramebuffer(GFX_TOP, side, NULL, NULL);
  const u8 *y_plane = eye;
  const u8 *cb_plane = eye + O3VPX_EYE_WIDTH * O3VPX_EYE_HEIGHT;
  const u8 *cr_plane =
      cb_plane + (O3VPX_EYE_WIDTH / 2) * (O3VPX_EYE_HEIGHT / 2);
  if (!fb) return;
  for (int y = 0; y < O3VPX_EYE_HEIGHT; y += 2) {
    const u8 *y_row0 = y_plane + y * O3VPX_EYE_WIDTH;
    const u8 *y_row1 = y_row0 + O3VPX_EYE_WIDTH;
    const u8 *cb_row = cb_plane + (y / 2) * (O3VPX_EYE_WIDTH / 2);
    const u8 *cr_row = cr_plane + (y / 2) * (O3VPX_EYE_WIDTH / 2);
    for (int x = 0; x < O3VPX_EYE_WIDTH; x += 2) {
      const int cx = x / 2;
      const int cb = (int)cb_row[cx] - 128;
      const int cr = (int)cr_row[cx] - 128;
      put_yuv_pixel_rgb565(fb, x, y, y_row0[x], cb, cr);
      put_yuv_pixel_rgb565(fb, x + 1, y, y_row0[x + 1], cb, cr);
      put_yuv_pixel_rgb565(fb, x, y + 1, y_row1[x], cb, cr);
      put_yuv_pixel_rgb565(fb, x + 1, y + 1, y_row1[x + 1], cb, cr);
    }
  }
}

static void render_frame(const u8 *left, const u8 *right) {
  render_eye_rgb565(left, GFX_LEFT);
  render_eye_rgb565(right, GFX_RIGHT);
  gfxFlushBuffers();
  gfxSwapBuffers();
}

static void pace_frame(u64 frame_start_ticks) {
  const u64 target_ticks = us_to_ticks(PLAYBACK_TARGET_US);
  const u64 elapsed = svcGetSystemTick() - frame_start_ticks;
  if (elapsed >= target_ticks) return;
  const u64 remain_us = ticks_to_us(target_ticks - elapsed);
  if (remain_us > 1000ULL) {
    svcSleepThread((s64)((remain_us - 500ULL) * 1000ULL));
  }
  gspWaitForVBlank();
}

static int run_bench(void *decoder, u8 *left, u8 *right, size_t eye_bytes) {
  u32 total_frames = 0;
  u32 frames_per_iteration = 0;
  u32 sample_count = 0;
  u64 total_ticks = 0;
  u64 total_decode_ticks = 0;
  u64 total_output_ticks = 0;
  u64 min_ticks = ~0ULL;
  u64 worst_ticks = 0;
  u64 worst_decode_ticks = 0;
  u64 worst_output_ticks = 0;
  u32 worst_iter = 0;
  u32 worst_frame_index = 0;
  O3vpxFrameInfo worst_info = {0, 0, 0};
  u64 checksum = 14695981039346656037ULL;

  for (int iter = 0; iter < O3VPX_BENCH_ITERATIONS; iter++) {
    int rc = vp8_o3vpx_decoder_reset(decoder);
    if (rc != 0) {
      bench_log("bench_result status=fail reason=reset rc=%ld\n", (long)rc);
      return rc;
    }
    u32 iter_frames = 0;
    for (;;) {
      O3vpxFrameInfo info;
      const u64 start = svcGetSystemTick();
      rc = vp8_o3vpx_decoder_next_frame(decoder, &info);
      const u64 after_decode = svcGetSystemTick();
      if (rc == 0) break;
      if (rc < 0) {
        bench_log("bench_result status=fail reason=decode rc=%ld\n", (long)rc);
        return rc;
      }
      rc = vp8_o3vpx_decoder_write_current_yuv420p(
          decoder, left, eye_bytes, right, eye_bytes);
      const u64 after_output = svcGetSystemTick();
      if (rc != 0) {
        bench_log("bench_result status=fail reason=split rc=%ld\n", (long)rc);
        return rc;
      }
      if (sample_count >= MAX_BENCH_SAMPLES) {
        bench_log("bench_result status=fail reason=too_many_samples\n");
        return -1;
      }
      const u64 decode_ticks = after_decode - start;
      const u64 output_ticks = after_output - after_decode;
      const u64 elapsed = after_output - start;
      g_samples[sample_count++] = elapsed;
      total_frames++;
      total_ticks += elapsed;
      total_decode_ticks += decode_ticks;
      total_output_ticks += output_ticks;
      if (elapsed < min_ticks) min_ticks = elapsed;
      if (decode_ticks > worst_decode_ticks) worst_decode_ticks = decode_ticks;
      if (output_ticks > worst_output_ticks) worst_output_ticks = output_ticks;
      if (elapsed > worst_ticks) {
        worst_ticks = elapsed;
        worst_iter = (u32)iter;
        worst_frame_index = iter_frames;
        worst_info = info;
      }
      checksum_update_frame(&checksum, &info, left, right, eye_bytes);
      iter_frames++;
    }
    if (iter == 0) {
      frames_per_iteration = iter_frames;
    } else if (iter_frames != frames_per_iteration) {
      bench_log("bench_result status=fail reason=frame_count_changed "
                "first=%lu iter_%d=%lu\n",
                (unsigned long)frames_per_iteration, iter,
                (unsigned long)iter_frames);
      return -1;
    }
  }

  if (total_frames == 0 || sample_count == 0) {
    bench_log("bench_result status=fail reason=no_frames\n");
    return -1;
  }
  qsort(g_samples, sample_count, sizeof(g_samples[0]), compare_u64);
  const u64 mean_us = ticks_to_us(total_ticks) / total_frames;
  const u64 decode_mean_us = ticks_to_us(total_decode_ticks) / total_frames;
  const u64 output_mean_us = ticks_to_us(total_output_ticks) / total_frames;
  const u64 min_us = ticks_to_us(min_ticks);
  const u64 median_us = ticks_to_us(percentile_ticks(g_samples, sample_count, 50));
  const u64 p95_us = ticks_to_us(percentile_ticks(g_samples, sample_count, 95));
  const u64 worst_us = ticks_to_us(worst_ticks);
  const u64 worst_decode_us = ticks_to_us(worst_decode_ticks);
  const u64 worst_output_us = ticks_to_us(worst_output_ticks);
  const int pass = worst_us <= O3VPX_TARGET_US;
  bench_log("functional_result status=pass codec=o3vpx iterations=%d "
            "frames=%lu frames_per_iteration=%lu source_window=f10000_10200 "
            "output_mode=split_copy checksum=0x%016llx\n",
            O3VPX_BENCH_ITERATIONS, (unsigned long)total_frames,
            (unsigned long)frames_per_iteration,
            (unsigned long long)checksum);
  bench_log("bench_result status=%s codec=o3vpx iterations=%d frames=%lu "
            "frames_per_iteration=%lu output_mode=split_copy min_us=%llu "
            "mean_us=%llu decode_mean_us=%llu output_mean_us=%llu "
            "median_us=%llu p95_us=%llu worst_us=%llu "
            "worst_decode_us=%llu worst_output_us=%llu target_us=%llu "
            "worst_iter=%lu worst_frame_index=%lu worst_frame_no=%lu "
            "worst_frame_type=%lu worst_frame_size_bytes=%lu "
            "checksum=0x%016llx\n",
            pass ? "pass" : "fail", O3VPX_BENCH_ITERATIONS,
            (unsigned long)total_frames, (unsigned long)frames_per_iteration,
            (unsigned long long)min_us, (unsigned long long)mean_us,
            (unsigned long long)decode_mean_us,
            (unsigned long long)output_mean_us,
            (unsigned long long)median_us, (unsigned long long)p95_us,
            (unsigned long long)worst_us,
            (unsigned long long)worst_decode_us,
            (unsigned long long)worst_output_us,
            (unsigned long long)O3VPX_TARGET_US,
            (unsigned long)worst_iter, (unsigned long)worst_frame_index,
            (unsigned long)worst_info.frame_no,
            (unsigned long)worst_info.frame_type,
            (unsigned long)worst_info.frame_size_bytes,
            (unsigned long long)checksum);
  return pass ? 0 : -1;
}

static int play_one_pass(void *decoder, u8 *left, u8 *right,
                         size_t eye_bytes, int collect_stats) {
  u32 frames = 0;
  u32 late_frames = 0;
  u64 total_work_ticks = 0;
  u64 total_decode_ticks = 0;
  u64 total_output_ticks = 0;
  u64 total_render_ticks = 0;
  u64 worst_work_ticks = 0;
  u64 worst_decode_ticks = 0;
  u64 worst_output_ticks = 0;
  u64 worst_render_ticks = 0;
  int rc = vp8_o3vpx_decoder_reset(decoder);
  if (rc != 0) return rc;
  while (aptMainLoop()) {
    hidScanInput();
    if (hidKeysDown() & KEY_START) return 0;
    O3vpxFrameInfo info;
    const u64 frame_start = svcGetSystemTick();
    rc = vp8_o3vpx_decoder_next_frame(decoder, &info);
    const u64 after_decode = svcGetSystemTick();
    if (rc == 0) break;
    if (rc < 0) return rc;
    rc = vp8_o3vpx_decoder_write_current_yuv420p(
        decoder, left, eye_bytes, right, eye_bytes);
    const u64 after_output = svcGetSystemTick();
    if (rc != 0) return rc;
    render_frame(left, right);
    const u64 after_render = svcGetSystemTick();
    const u64 decode_ticks = after_decode - frame_start;
    const u64 output_ticks = after_output - after_decode;
    const u64 render_ticks = after_render - after_output;
    const u64 work_ticks = decode_ticks + output_ticks + render_ticks;
    total_work_ticks += work_ticks;
    total_decode_ticks += decode_ticks;
    total_output_ticks += output_ticks;
    total_render_ticks += render_ticks;
    if (work_ticks > worst_work_ticks) worst_work_ticks = work_ticks;
    if (decode_ticks > worst_decode_ticks) worst_decode_ticks = decode_ticks;
    if (output_ticks > worst_output_ticks) worst_output_ticks = output_ticks;
    if (render_ticks > worst_render_ticks) worst_render_ticks = render_ticks;
    if (ticks_to_us(work_ticks) > PLAYBACK_TARGET_US) late_frames++;
    frames++;
    pace_frame(frame_start);
  }
  if (collect_stats) {
    if (frames == 0) {
      bench_log("playback_result status=fail reason=no_frames\n");
      return -1;
    }
    bench_log("playback_result status=%s frames=%lu fps=%llu "
              "renderer=software_rgb565 output_mode=split_copy "
              "target_frame_us=%llu mean_work_us=%llu mean_decode_us=%llu "
              "mean_output_us=%llu mean_render_us=%llu worst_work_us=%llu "
              "worst_decode_us=%llu worst_output_us=%llu "
              "worst_render_us=%llu late_frames=%lu\n",
              late_frames == 0 ? "pass" : "fail", (unsigned long)frames,
              (unsigned long long)PLAYBACK_TARGET_FPS,
              (unsigned long long)PLAYBACK_TARGET_US,
              (unsigned long long)(ticks_to_us(total_work_ticks) / frames),
              (unsigned long long)(ticks_to_us(total_decode_ticks) / frames),
              (unsigned long long)(ticks_to_us(total_output_ticks) / frames),
              (unsigned long long)(ticks_to_us(total_render_ticks) / frames),
              (unsigned long long)ticks_to_us(worst_work_ticks),
              (unsigned long long)ticks_to_us(worst_decode_ticks),
              (unsigned long long)ticks_to_us(worst_output_ticks),
              (unsigned long long)ticks_to_us(worst_render_ticks),
              (unsigned long)late_frames);
  }
  return 0;
}

static void playback_loop(void *decoder, u8 *left, u8 *right,
                          size_t eye_bytes) {
  bench_log("playback: top stereo software_rgb565, %llu fps, START exits\n",
            (unsigned long long)PLAYBACK_TARGET_FPS);
  (void)play_one_pass(decoder, left, right, eye_bytes, 1);
  bench_log("playback_loop: looping until START\n");
  while (aptMainLoop()) {
    if (play_one_pass(decoder, left, right, eye_bytes, 0) != 0) break;
  }
}

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;

  gfxInit(GSP_RGB565_OES, GSP_BGR8_OES, false);
  gfxSet3D(true);
  consoleInit(GFX_BOTTOM, NULL);
  g_log_file = fopen(LOG_PATH, "w");

  bench_log("O3VPX Old3DS decoder bench\n");
  bench_log("stream path: %s\n", O3VPX_SD_STREAM_PATH);
  bench_log("source_window: f10000_10200\n");
  bench_log("log_path: %s\n", g_log_file ? LOG_PATH : "unavailable");
  print_profile_report();

  u8 *stream = NULL;
  size_t stream_size = 0;
  int rc = load_stream(O3VPX_SD_STREAM_PATH, &stream, &stream_size);
  if (rc != 0) {
    bench_log("stream_load_failed path=%s rc=%ld\n", O3VPX_SD_STREAM_PATH,
              (long)rc);
    goto wait_exit;
  }
  bench_log("stream bytes: %lu\n", (unsigned long)stream_size);

  const size_t decoder_size = vp8_o3vpx_decoder_size();
  const size_t decoder_align = vp8_o3vpx_decoder_align() < 0x80
                                   ? 0x80
                                   : vp8_o3vpx_decoder_align();
  const size_t eye_bytes = vp8_o3vpx_eye_frame_bytes();
  print_memory_report(stream_size, decoder_size, eye_bytes);

  void *decoder = linearMemAlign(decoder_size, decoder_align);
  u8 *left = (u8 *)linearMemAlign(eye_bytes, 0x80);
  u8 *right = (u8 *)linearMemAlign(eye_bytes, 0x80);
  if (!decoder || !left || !right) {
    bench_log("allocation failed decoder=%p left=%p right=%p\n", decoder, left,
              right);
    goto wait_exit;
  }
  memset(decoder, 0, decoder_size);
  rc = vp8_o3vpx_decoder_init(decoder, decoder_size, stream, stream_size);
  if (rc != 0) {
    bench_log("decoder_init_failed rc=%ld\n", (long)rc);
    goto wait_exit;
  }
  rc = run_bench(decoder, left, right, eye_bytes);
  bench_log("bench_complete rc=%ld\n", (long)rc);
  playback_loop(decoder, left, right, eye_bytes);

wait_exit:
  bench_log("Press START to exit.\n");
  while (aptMainLoop()) {
    hidScanInput();
    if (hidKeysDown() & KEY_START) break;
    gfxFlushBuffers();
    gfxSwapBuffers();
    gspWaitForVBlank();
  }
  if (g_log_file) fclose(g_log_file);
  gfxExit();
  return 0;
}
