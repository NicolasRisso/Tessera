# tessera

Several videos (and stills) on one screen, with text, encoded as small as it
can be without a visible loss.

```
tessera grid hud-topbottom.avi hud-statsleft.avi hud-statsright.avi hud-corner.avi \
    --label "Top & bottom" --label "Stats left" --label "Stats right" --label Corner \
    --title "Fusefall — four HUD layouts" -o hud-grid.mp4
```

gives one 1920×1080 video with the four recordings in a 2×2 grid, each
labelled, a title above, conformed to one frame rate, and encoded with H.264
at the largest CRF whose SSIM against a lossless master stays over 0.990 on
average and 0.980 on every sampled frame. For the four 40 s recordings above
that is crf 25 and 1.75 MB, with SSIM 0.9915 (worst frame 0.9844) over the
whole video.

tessera does the layout, the resampling, the compositing, the colour
conversion, the text (its own TrueType parser and rasteriser) and the quality
metric itself. ffmpeg is only the codec: it decodes each input to raw RGB and
encodes raw YUV, over pipes, as child processes. There is no audio in the
output (see [Limits](#limits)).

## Install

tessera is one binary with no dependency but `ffmpeg` and `ffprobe` (any
recent build with libx264; libx265 and libaom for HEVC and AV1, libvmaf for
`--metric vmaf`). It finds ffmpeg through `--ffmpeg PATH`, then the
`TESSERA_FFMPEG` environment variable, then `PATH`; ffprobe beside it, then
on `PATH`.

Building needs the [Odin](https://odin-lang.org) compiler (developed against
`dev-2026-08-nightly`).

**Linux**

```
./build.sh          # → bin/tessera
./test.sh           # unit tests, then tests/e2e.sh (needs ffmpeg on PATH)
```

`odin` links through `clang`; any C toolchain Odin accepts will do.

**Windows**

From an "x64 Native Tools Command Prompt" (the MSVC linker), with `odin` on
`PATH`:

```
build.bat           # → bin\tessera.exe
```

Get ffmpeg from https://www.gyan.dev/ffmpeg/builds/ or
https://github.com/BtbN/FFmpeg-Builds (a "full" build has libx265, libaom and
libvmaf), and put its `bin` on `PATH` or pass `--ffmpeg C:\path\ffmpeg.exe`.
The code uses only Odin's portable `core:os` for files, pipes and processes;
the Windows build is type-checked but has not been linked or run (see
[Limits](#limits)).

## Commands

### `tessera grid <input>... -o <out.mp4> [options]`

Every input (video or still image) goes in one cell, in the order given.

| Option | |
| --- | --- |
| `--cols N`, `--rows N` | the grid; by default the one that makes the cells largest (1 → 1×1, 2 → 2×1, 3–4 → 2×2, 5–6 → 3×2, 7–9 → 3×3, 10–12 → 4×3, 13–16 → 4×4 for 16:9) |
| `--size WxH` \| `native` | the canvas, even in both directions; default 1920x1080. `native` shows the largest input 1:1 (four 720p inputs → 2600×1480), up to 3840×2160 |
| `--fit contain` \| `cover` | letterbox each input in its cell (default), or fill the cell and crop the centre |
| `--gap PX`, `--margin PX` | between cells (8) and around the grid (16) |
| `--bg #RRGGBB` | background (#0B0F17) |
| `--label TEXT` | one per input, in order, in the picture's top left on a translucent box; repeat the option, `""` leaves a cell bare |
| `--title TEXT` | a line in a band above the grid |
| `--caption "TEXT@FROM-TO"` | a timed line at the bottom centre, on a box, fading in and out; seconds, `@3-` runs to the end, no `@` is the whole video; repeatable |
| `--font PATH` | a TrueType `.ttf` (default: the embedded Inter SemiBold) |
| `--fps N` | output rate: `60`, `29.97`, `30000/1001`; default the highest input's, capped at 60 |
| `--duration longest` \| `shortest` \| `SECONDS` | the video's length (default: the longest input) |
| `--end hold` \| `black` \| `loop` | what a cell shows once its input has ended: its last frame (default), the background, or the input again |
| `-o PATH` | the output: `.mp4` (with `+faststart`), `.mkv`, `.mov` |
| `--codec h264` \| `hevc` \| `av1` | libx264 (default), libx265, libaom-av1 |
| `--quality visually-lossless` \| `high` \| `small` \| `crf=N` | see [Quality](#quality); default `visually-lossless` |
| `--metric ssim` \| `vmaf` | what the search measures (default ssim) |
| `--max-size MB` | a size cap; see [Quality](#quality) |
| `--force` | encode at the cap even below the quality floor |
| `--preset NAME` | the encoder's preset (default veryslow / slow; for AV1 the cpu-used level, 4) |
| `--encoder-opt NAME=VALUE` | passed to ffmpeg as `-NAME VALUE` after the defaults, e.g. `tune=animation`, `aq-mode=3`, `g=600` |
| `--keep-master` | keep the lossless master as `<out>.master.mkv` |
| `--threads N` | threads for compositing and SSIM (default: cores − 1) |
| `--ffmpeg PATH` | the ffmpeg binary |
| `--dry-run` | print the canvas, every cell's rectangle, the durations and every ffmpeg command line, and encode nothing |

### `tessera run <job.json> [-o OUT] [--ffmpeg PATH] [--dry-run]`

Plays a job's scenes one after another into one video: a title card, a grid,
a page of stills. See [The job format](#the-job-format).

### `tessera probe <input>...`

What tessera sees in each input: size, frame rate, frame count, duration,
codec and pixel format; whether it is a still, and whether its frame rate is
variable (such inputs are decoded at their average rate).

### `tessera ssim <a> <b> [--frames N] [--threads N]`

SSIM between two videos of the same size, luma plane, frame by frame from the
start: the mean and the worst frame. The same code the quality search uses.

### `tessera version`, `tessera help`, `tessera <command> --help`

Exit codes: 0 done, 1 something failed while doing it (a missing input, an
ffmpeg error, a size cap that cannot be met), 2 the command line or the job
file is wrong.

## Quality

"As small as possible without losing quality" is measured, not guessed:

1. The composed video is encoded once, losslessly (x264 `-qp 0`, the same
   4:2:0 frames the final encode gets): the master.
2. Six 2-second windows spread evenly through it (the whole video when it is
   under 20 s) are encoded at a candidate CRF with the final settings, decoded,
   and scored against the master with SSIM on the luma plane.
3. Bisection over CRF 10–40 (10–63 for AV1, whose scale is longer) finds the
   largest CRF whose windows meet the target.
4. The master is encoded once at it, and the whole result is scored against
   the whole master; that is the SSIM reported. Windows are a sample: if the
   whole file misses the target, it is encoded again one CRF lower.

| `--quality` | SSIM mean | every sampled frame | VMAF (`--metric vmaf`) |
| --- | --- | --- | --- |
| `visually-lossless` | ≥ 0.990 | ≥ 0.980 | ≥ 95 |
| `high` | ≥ 0.980 | ≥ 0.965 | ≥ 90 |
| `small` | ≥ 0.965 | ≥ 0.940 | ≥ 85 |
| `crf=N` | no search: encode at N | | |

`--max-size MB` raises the CRF until the estimate (the windows' bitrate)
fits. If that would fall below the `small` target, tessera stops with exit 1
and says what size the floor needs; `--force` encodes anyway. It never
lowers the frame rate or the resolution to meet a size: those are yours.

The size estimate comes from the windows' packets, with keyframes counted
as the whole file will have them (every window starts on one; the file has
one every 10 s with H.264). If the real file still lands over the cap, it is
encoded again one CRF higher.

The H.264 defaults are the plan's (`-preset veryslow -profile:v high`) plus
`-tune animation` and a keyframe every 10 s, which together made the game
footage 31 % smaller at the same SSIM: [docs/encoding.md](docs/encoding.md)
is the study. HEVC is `-preset slow -tag:v hvc1`, AV1 `-cpu-used 4 -row-mt 1`.
`--encoder-opt` overrides any of them.

## The job format

A JSON file (comments and trailing commas allowed). Paths are relative to
the job file. Every error names the field: `job.json: scenes[1].cells[0].start:
-1 is outside 0..86400`.

```jsonc
{
	"output": "showcase.mp4",
	"size": "1920x1080",          // or "native"
	"fps": 60,                    // default: the highest input's, max 60
	"font": "fonts/MyFont.ttf",   // default: Inter SemiBold, embedded
	"encode": {
		"codec": "h264",          // h264 | hevc | av1
		"quality": "visually-lossless", // | high | small | crf=N
		"max_size_mb": 16,
		"options": {"g": 300},     // -g 300: a keyframe every 5 s at 60 fps
	},
	"scenes": [
		// A title card: text only, so it needs a duration.
		{
			"duration": 3,
			"texts": [
				{"text": "Fusefall", "size": 120, "y": "42%",
				 "shadow_dy": 4, "shadow_blur": 6, "shadow_color": "#000000C0", "fade": 0.4},
				{"text": "four HUD layouts, one run", "size": 44, "y": "58%",
				 "color": "#9FB3C8", "from": 0.5, "fade": 0.4},
			],
		},
		// A 2×2 grid with labels and a timed caption.
		{
			"cells": [
				{"src": "clips/hud-topbottom.avi", "label": "Top & bottom", "start": 5},
				{"src": "clips/hud-statsleft.avi", "label": "Stats left", "start": 5},
				{"src": "clips/hud-statsright.avi", "label": "Stats right", "start": 5},
				{"src": "clips/hud-corner.avi", "label": "Corner", "start": 5, "end": "loop"},
			],
			"layout": {"cols": 2, "rows": 2, "title": "Wave 1"},
			"duration": "longest",
			"captions": [{"text": "The same seed in all four", "from": 1, "to": 6}],
		},
		// Stills: a cell can be just a path.
		{
			"duration": 4,
			"cells": ["shots/before.png", "shots/after.png"],
			"texts": [{"text": "Before / after", "anchor": "BR", "x": "97%", "y": "95%",
			           "size": 40, "outline_px": 3, "outline_color": "#000000"}],
		},
	],
}
```

| Object | Field | |
| --- | --- | --- |
| job | `output` | required |
| | `size`, `fps`, `font`, `ffmpeg`, `threads` | as the grid options |
| | `encode` | `codec`, `quality`, `metric`, `max_size_mb`, `preset`, `keep_master`, `force`, `options` (an object of encoder options) |
| | `scenes` | one or more, played in order |
| scene | `cells` | up to 16; a cell is a path or an object |
| | `layout` | `cols`, `rows`, `gap`, `margin`, `label_size` (px; default 5 % of the picture height), `title` |
| | `duration` | `"longest"` (default), `"shortest"`, or seconds; required without cells |
| | `texts` | text objects, below |
| | `captions` | `{"text", "from", "to"}` in the house style (bottom centre, on a box) |
| | `background` | `#RRGGBB` |
| cell | `src` | required: a video or an image |
| | `label` | drawn in the picture's top left |
| | `start` | seconds into the source where the cell begins |
| | `fit` | `contain` (default) or `cover` |
| | `end` | `hold` (default), `black`, `loop` |
| text | `text` | required; `\n` breaks lines |
| | `x`, `y` | pixels (`120`) or a fraction of the canvas (`"50%"`); default the centre |
| | `anchor` | which point of the text sits at (x, y): `TL TC TR CL CC CR BL BC BR` (default `CC`) |
| | `size` | pixel height of the em (default 48) |
| | `color` | `#RRGGBB` or `#RRGGBBAA` (default white) |
| | `outline_px`, `outline_color` | an outline around the letters |
| | `shadow_dx`, `shadow_dy`, `shadow_blur`, `shadow_color` | a drop shadow |
| | `box_color`, `box_pad`, `box_radius` | a rounded box behind the text (none while `box_color` is transparent) |
| | `from`, `to` | seconds within the scene; `to` 0 is the scene's end |
| | `fade` | seconds of fade in and out |

## How it works

```
 inputs ──ffprobe──▶ plan: canvas, grid, cell rects, frame rate, durations
   │
   ├─ ffmpeg -i in -f rawvideo -pix_fmt rgb24 -  (one per video, read ahead)
   ▼
 frame n at t = n/fps: each cell shows source frame ⌊t·fps_src⌋
   → resample (area down, Catmull-Rom up; weights precomputed per cell)
   → background, cells, labels, texts (our TrueType rasteriser)
   → RGB → YUV 4:2:0, BT.709 limited range            (rows on a thread pool)
   ▼
 ffmpeg -f rawvideo -pix_fmt yuv420p -i - …  (lossless master, or the output)
   ▼
 CRF search on windows of the master (SSIM, ours) → final encode → whole-file SSIM
```

| File | |
| --- | --- |
| `src/main.odin`, `cli.odin`, `execute.odin` | commands, options, running a job |
| `src/job.odin` | the job types and the JSON loader |
| `src/layout.odin` | grid dimensions, cell rects, contain / cover |
| `src/image.odin`, `resample.odin`, `yuv.odin` | pixels, the separable resampler, BT.709 conversion |
| `src/ffmpeg.odin` | finding ffmpeg, probing, decoders and encoders over pipes |
| `src/timeline.odin`, `compose.odin`, `parallel.odin` | the frame loop, one frame, the threads |
| `src/ttf.odin`, `gpos.odin`, `raster.odin`, `text.odin`, `font.odin` | TrueType outlines and kerning, coverage, text layout and effects, the embedded font |
| `src/ssim.odin`, `quality.odin`, `vmaf.odin` | the metric, the search, the optional VMAF |

## Limits

- **No audio.** The output has no sound track. (A v2 could copy one cell's
  track with `--audio N`; mixing several makes no sense for comparisons.)
- 8-bit 4:2:0 SDR only: no HDR, no 10-bit.
- No transitions between scenes, no animation of cells.
- Software encoders only (libx264, libx265, libaom-av1); no GPU encoding.
- Fonts: TrueType outlines (`glyf`) only. An OpenType font with CFF outlines
  (`.otf`, starting `OTTO`) is refused. Kerning comes from GPOS pair
  adjustment (or an old `kern` table); there is no shaping: no ligatures, no
  right-to-left text, no complex scripts.
- Windows: the code is portable and type-checks for `windows_amd64`, but it
  has not been linked or run there yet.
- Only this machine's ffmpeg (7.0.2, static) has been tested; other builds
  should work if they have the encoders asked for, and tessera says which one
  is missing if not.

## Licence

The code has no licence yet. The embedded font is
[Inter](https://github.com/rsms/inter) 4.1 SemiBold by The Inter Project
Authors, under the SIL Open Font License 1.1: [assets/OFL.txt](assets/OFL.txt).
