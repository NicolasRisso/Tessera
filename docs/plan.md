# tessera — plan

**Status: Ready** 2026-09-23 — one agent executes it end to end (`~/tessera-run/prompt.md`).

> **Authority: none.** This plan says how to build the first version. The owner's words below are
> the only requirements; where the plan and they disagree, they win.

## The brief, verbatim

The owner (Nicolas), 2026-09-23, on the forge server, while commissioning a renderer comparison for
his game:

> I also want you to make a species of code to support making various videos into one, in the sense
> of like, instead of sending me 4 videos for each renderer you can just make one video and at the
> same time it shows the 4 other videos, like small windows all sharing the same screen and so on.
> Obv you cant bench all at the same. So this is one of your goals, that prob isnt smth for miniTD
> repo, but instead a separated proj to be used as a tool both here and in other pcs of mine, so you
> can code it as its own thing ,setup git and so on and I will afterwards make the github repo for
> it. […] (supporting adding text to the video is prob also cool, and cool to code it at a low level
> and to make so it can compact videos the maximum possible without losing qual).

## Decisions

| # | Decision | Source |
| --- | --- | --- |
| D1 | **Odin.** One static binary per OS; the owner's game simulation is Odin too | Owner, asked 2026-09-23 |
| D2 | **Own pipeline, ffmpeg only as the codec.** tessera writes the layout, the resampler, the compositing, the RGB→YUV conversion, a TrueType parser and rasteriser, and the quality metric (SSIM) itself. `ffmpeg`/`ffprobe` binaries decode and encode, over raw pipes, as child processes. No libav linking, no ffmpeg filtergraph doing the work (no `xstack`, no `drawtext`, no `scale` for layout) | Owner, asked 2026-09-23 ("Own pipeline, ffmpeg as codec") |
| D3 | **Name: `tessera`** — the repository, the binary, the Odin package | Owner, asked 2026-09-23 |
| D4 | **Git here, no remote.** `main`, author `ForgeCoding <309959915+ForgeCoding@users.noreply.github.com>` (repo-local config, already set). The owner creates the GitHub repository later | Owner |
| D5 | **Runs here and on the owner's other PCs, Windows included.** Portable code only: `core:os` for files, pipes and processes; no POSIX-only calls; paths through `core:path/filepath` | Owner ("both here and in other pcs of mine") |

## 1. What this is

A command-line tool that puts several videos (and stills) on one screen — a grid of windows, each
labelled — adds text (titles, captions, timed notes), and encodes the result as small as it can
without a visible loss.

**First version covers:** the `grid` command (N inputs → one video), `run` (a JSON job of scenes played
one after another), `probe`, `ssim`, `version`/`help`; grid layouts from 1 to 16 cells; per-cell
labels; timed text with outline, shadow and a background box; still images as cells; H.264 (default),
HEVC and AV1 output; a quality search that picks the highest CRF that still meets an SSIM target; a
size cap that refuses rather than wrecks the picture.

**Out of scope for v1:** audio (output has none; say so in `--help`), HDR / 10-bit, transitions
between scenes, cell animation, GPU encoders, a GUI, OpenType CFF fonts (`.otf` with CFF outlines is
refused with a clear message), right-to-left text shaping.

## 2. Context the implementer cannot derive

- **Toolchain:** `/tmp/mtd-toolchain/odin/odin` (`dev-2026-08-nightly:902106f`). It links through
  `clang`, which this host lacks — `/tmp/mtd-toolchain/bin/clang` is a shim to `gcc`; put
  `/tmp/mtd-toolchain/bin` first on `PATH`. In this Odin, the new OS layer **is** `core:os`:
  `os.process_start(Process_Desc) -> (Process, Error)` with `Process_Desc{working_dir, command: []string, env, stderr, stdout, stdin: ^File}`
  (`core/os/process.odin:329, 376`), `os.pipe() -> (r, w: ^File, err)` (`core/os/pipe.odin:24`),
  `os.process_wait` (`:528`), `os.read_full` (`core/os/file_util.odin:161`), `os.write`, `os.close`.
  Read those files before using them; the doc comments say which handles the parent must close.
- **The toolchain has no Windows files** (`core/sys/windows` is empty; the Linux release archive is
  trimmed). To type-check for Windows, clone the Odin source at the matching commit
  (`git clone https://github.com/odin-lang/Odin ~/tessera-run/odin-src && git -C ~/tessera-run/odin-src checkout 902106f`)
  and run `ODIN_ROOT=~/tessera-run/odin-src /tmp/mtd-toolchain/odin/odin check src -target:windows_amd64`.
  Linking or running a Windows build is not possible here.
- **`vendor:stb` is not usable here:** `vendor/stb/lib` ships only macOS archives and `vendor/stb/src`
  is empty in this toolchain. That is one more reason the TrueType work is our own (D2).
- **ffmpeg:** `/tmp/mtd-toolchain/ffmpeg/ffmpeg` and `ffprobe`, 7.0.2 static (johnvansickle): libx264,
  libx265, libaom-av1, libvpx-vp9, libvmaf (models in `/tmp/mtd-toolchain/ffmpeg/model`), no SVT-AV1,
  no hardware encoders. Other PCs will have other builds: tessera must find `ffmpeg` by `--ffmpeg`,
  then `TESSERA_FFMPEG`, then `PATH` (`ffmpeg.exe` on Windows), probe which encoders exist
  (`ffmpeg -hide_banner -encoders`) and fail with a sentence naming the missing one.
- **Test material:** `~/tessera-run/samples/hud-{topbottom,statsleft,statsright,corner}.avi` — four
  recordings of the same 40 s of the owner's game, MJPEG 1280×720, 60 fps, 2400 frames, with a PCM
  track. That is the job the tool exists for: four windows, one screen. Never commit them.
- **Machine:** 6 cores / 12 threads, 32 GB. Another agent may be rendering the game on the GPU at the
  same time; tessera uses no GPU. One core is busy with an unrelated crawl — leave it alone.
- **Where it will be used first:** a showcase sent to a phone over WhatsApp — H.264 in MP4,
  `yuv420p`, `+faststart`, ideally ≤ 16 MB, 1920×1080.

## 3. The design

One Odin package, `src/` (package `tessera`), files by concern. Keep each file under ~600 code lines;
split before 800.

| File | Owns |
| --- | --- |
| `main.odin` | `main`, command dispatch, exit codes (0 ok, 1 runtime failure, 2 usage) |
| `cli.odin` | argument parsing for every command → `Job` |
| `job.odin` | `Job`, `Scene`, `Cell`, `Text`, `Encode_Settings`; JSON load (`core:encoding/json`); validation with messages that name the field |
| `layout.odin` | grid dimensions, cell rectangles, aspect fit |
| `image.odin` | `Image` (RGB8), fill, blit, alpha blend of a coverage mask in a colour |
| `resample.odin` | separable resampler with precomputed weights |
| `yuv.odin` | RGB8 → YUV420P BT.709 limited range |
| `ffmpeg.odin` | discovery, `probe`, `Decoder` and `Encoder` child processes over pipes |
| `timeline.odin` | the frame loop: which source frame each cell shows at output frame *n* |
| `compose.odin` | one output frame: background, cells, labels, texts |
| `ttf.odin` | TrueType tables → glyph outlines and metrics |
| `raster.odin` | outline → anti-aliased coverage |
| `text.odin` | UTF-8 → glyphs, line layout, glyph cache, outline / shadow / box |
| `ssim.odin` | SSIM on the luma plane |
| `quality.odin` | the CRF search and the size cap |
| `font.odin` | the embedded default font (`#load`) |

### 3.1 Types (signatures are the contract; fields may be added)

```odin
Image :: struct { w, h: int, pix: []u8 }                 // RGB8, row-major, stride w*3
Rect  :: struct { x, y, w, h: int }
Color :: [4]u8                                            // sRGB + alpha

Fit :: enum { Contain, Cover }
End :: enum { Hold, Black, Loop }

Cell :: struct {
	src:   string,        // video or still image path
	label: string,        // drawn in the cell; "" for none
	start: f64,           // seconds into the source where the cell begins
	fit:   Fit,
	end:   End,           // what the cell shows after its source runs out
}

Anchor :: enum { TL, TC, TR, CL, CC, CR, BL, BC, BR }
Text :: struct {
	text:          string,    // UTF-8, '\n' breaks lines
	x, y:          Coord,     // pixels, or a fraction of the canvas ("50%")
	anchor:        Anchor,
	size:          f32,       // pixel height of the em
	color:         Color,
	outline_px:    f32, outline_color: Color,
	shadow_dx, shadow_dy, shadow_blur: f32, shadow_color: Color,
	box_color:     Color, box_pad: f32, box_radius: f32,   // box_color.a == 0: no box
	from, to:      f64,       // seconds within the scene; to <= 0 means the scene's end
	fade:          f64,       // seconds of fade in and out
}
Coord :: struct { value: f32, fraction: bool }

Layout :: struct { cols, rows: int, gap, margin: int, label_size: f32 }
Scene_Duration :: union { f64, Duration_Rule }            // Longest, Shortest
Scene :: struct { cells: []Cell, layout: Layout, duration: Scene_Duration, texts: []Text, background: Color }

Codec :: enum { H264, HEVC, AV1 }
Quality :: union { Preset_Quality, CRF }                  // Visually_Lossless, High, Small | an explicit CRF
Encode_Settings :: struct { codec: Codec, quality: Quality, max_size_mb: f64, preset: string, keep_master: bool }

Job :: struct { output: string, width, height: int, fps: Rational, scenes: []Scene, encode: Encode_Settings, font_path: string, ffmpeg: string, threads: int }
Rational :: struct { num, den: int }
```

### 3.2 The pipeline

1. **Probe** every source once: `ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,pix_fmt,codec_name:format=duration -of json`.
   A still image is a source with one frame and no duration.
2. **Decode**: one `ffmpeg` child per video cell, `-v error -ss <start> -i <src> -an -f rawvideo -pix_fmt rgb24 -`,
   stdout a pipe, stderr a log file in the job's temp directory (never an undrained pipe — that
   deadlocks). Frames are read with `os.read_full` into a reused buffer. Decoding is at the source's
   own size and rate; **tessera resamples, not ffmpeg** (D2). A variable-frame-rate source
   (`r_frame_rate != avg_frame_rate`) is the one exception: the decoder gets `-fps_mode cfr -r <avg>`
   and the log says so.
3. **Timeline** (`timeline.odin`): output frame *n* is at `t = n / fps`. A cell shows source frame
   `k = floor((t) * src_fps + 1e-6)`; the decoder is advanced by reading and discarding until frame *k*
   is current. Past the source's end: `Hold` keeps the last frame, `Black` fills the background,
   `Loop` restarts the decoder. A scene's duration is the longest cell's (default), the shortest, or
   a number of seconds; text-only scenes need a number.
4. **Compose** (`compose.odin`): fill the canvas; for each cell, resample the current source frame
   into its fitted rectangle (weights precomputed once per cell); draw the label; draw the scene's
   texts active at `t` with their fade. Rows are split across a `core:thread` pool (`--threads`,
   default the core count minus one).
5. **Convert** to YUV420P BT.709, limited range, in `yuv.odin`:
   `Y = 16 + 219·(0.2126 R + 0.7152 G + 0.0722 B)`, `Cb = 128 + 224·(B − Y′)/1.8556`,
   `Cr = 128 + 224·(R − Y′)/1.5748` on 0–1 values, chroma averaged over each 2×2 block, rounded and
   clamped. Tag the output `-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv`.
6. **Encode**: one `ffmpeg` child, `-f rawvideo -pix_fmt yuv420p -s WxH -r fps -i -`, then the codec's
   arguments (§3.5). The master (§3.6) or the final file.

### 3.3 Layout

- `grid_dims(n: int, canvas_w, canvas_h: int, cell_aspect: f32) -> (cols, rows: int)`: the grid that
  makes the cells largest for the given aspect, preferring more columns on a wide canvas. Expected for
  16:9 cells on a 16:9 canvas: 1→1×1, 2→2×1, 3–4→2×2, 5–6→3×2, 7–9→3×3, 10–12→4×3, 13–16→4×4.
- `cell_rects(canvas: Rect, cols, rows, gap, margin: int, n: int) -> []Rect`: equal cells; a short
  last row is centred.
- `fit_rect(src_w, src_h: int, cell: Rect, fit: Fit) -> (dst: Rect, crop: Rect)`: `Contain`
  letterboxes inside the cell, `Cover` crops the source's centre.
- Default canvas 1920×1080, gap 8, margin 16, background `#0B0F17`. `--size native` sizes the canvas
  so the largest cell shows its source 1:1 (capped at 3840×2160).
- Labels: inside the cell, top left, 12 px from the edges, on a translucent box — they must stay
  readable over a bright frame.

### 3.4 Resampling

Separable, two passes (horizontal into a float row buffer, then vertical), weights precomputed per
cell as `(first index, count, weights[])` per output column/row, normalised to sum to 1.
- **Downscaling** (scale < 1): exact area coverage (box of width `1/scale` in source pixels, with
  fractional weights at the ends).
- **Upscaling**: Catmull-Rom (a = −0.5).
- Values are 8-bit sRGB; accumulate in `f32`, round, clamp.
- A scale of exactly 1 with integer placement is a straight copy.

### 3.5 Codecs

| Codec | Arguments (start here; §3.7's study may change them) |
| --- | --- |
| H.264 | `-c:v libx264 -preset veryslow -crf <q> -profile:v high -pix_fmt yuv420p -movflags +faststart` |
| HEVC | `-c:v libx265 -preset slow -crf <q> -tag:v hvc1 -pix_fmt yuv420p -movflags +faststart` |
| AV1 | `-c:v libaom-av1 -crf <q> -b:v 0 -cpu-used 4 -row-mt 1 -pix_fmt yuv420p -movflags +faststart` |

**Never lower the frame rate or the resolution to meet a size** — those are the author's choices;
compaction is the encoder's job. If a cap cannot be met at the quality floor, refuse.

### 3.6 Quality — "the maximum possible without losing quality"

- **Master:** the composed video is encoded once, losslessly: `-c:v libx264 -qp 0 -preset ultrafast`
  of the same YUV420P frames, in the job's temp directory (deleted unless `--keep-master`).
- **Metric:** SSIM on the Y plane, the standard Gaussian window (σ = 1.5, 11×11, K1 = 0.01,
  K2 = 0.03, L = 255), mean over the frame; our own code (`ssim.odin`). Checked against ffmpeg's
  `ssim` filter on the same frames — the two need not be identical (ffmpeg uses 8×8 blocks with 4-pixel
  steps) but must agree within 0.005 on the samples.
- **Search:** sample windows (6 windows of 2 s spread evenly, or the whole video if under 20 s),
  encode each at a candidate CRF with the final settings, decode both the candidate and the master
  window to Y planes over pipes, compute per-frame SSIM. Bisect integer CRF in [10, 40] for the
  **largest** CRF whose windows meet the target. Then encode the whole master at it.
- **Targets** (*AI leaning*, Q2): `visually-lossless` (default): mean ≥ 0.990 and every sampled frame
  ≥ 0.980; `high`: 0.980 / 0.965; `small`: 0.965 / 0.940; `crf=N` skips the search.
- **Size cap** `--max-size MB`: if the chosen CRF overshoots, keep raising CRF until the estimate
  (from the windows' bitrate) fits; if that crosses the `small` floor, stop with exit 1 and a message
  giving the size the floor needs. `--force` encodes anyway.
- Print what was chosen: `crf 23 (ssim mean 0.9923, min 0.9851) → 11.8 MB`.
- `--metric vmaf` (optional, step 13): when the ffmpeg build has `libvmaf`, use VMAF ≥ 95 / 90 / 85
  instead. Never required.

### 3.7 The encoding study (a document, `docs/encoding.md`)

On a 2×2 grid of the four samples (40 s, 1920×1080, 60 fps): for H.264, sizes at equal SSIM for
`veryslow` vs `slower`, `-tune animation` vs none vs `-tune film`, `-aq-mode 2` vs `3` (x264's
dark-scene bias — the owner's game is mostly dark), `keyint` 250 vs 600; HEVC and AV1 at their search
result. A table of settings → CRF chosen → size → SSIM → encode time, and the defaults it justifies.
The defaults in §3.5 change only if the table says so.

### 3.8 Text

- **`ttf.odin`** parses `head` (unitsPerEm, indexToLocFormat), `maxp` (numGlyphs), `hhea`
  (ascender, descender, lineGap, numberOfHMetrics), `hmtx`, `cmap` (format 4 and 12; platform 3
  encodings 1/10, else platform 0), `loca`, `glyf` (simple glyphs with implied on-curve midpoints;
  composite glyphs with `ARGS_ARE_XY_VALUES` offsets and the three scale forms, depth ≤ 8), `kern`
  format 0 if present. Big-endian reads with bounds checks: a malformed font is an error, never a
  crash. `.otf`/CFF (`OTTO` tag) → "CFF fonts are not supported; use a TrueType (.ttf) font".
- **`raster.odin`**: quadratic Béziers flattened to lines (subdivisions from the control point's
  distance to the chord, tolerance 0.2 px); each line accumulates signed area into a `(w+2)×h` float
  buffer; a running sum along each row gives coverage `min(1, |acc|)` (the font-rs method).
- **`text.odin`**: UTF-8 decode (invalid bytes → U+FFFD), cmap lookup (missing → glyph 0), advance
  plus kerning, `\n` line breaks with the font's line height, a glyph cache keyed `(glyph, size)`.
  A rendered string is a coverage mask plus its origin; outline = the mask dilated by a disc of
  `outline_px`, shadow = the mask offset and box-blurred twice, box = rounded rectangle behind the
  text's ink bounds plus `box_pad`. Drawn in that order: box, shadow, outline, fill. Blending is plain
  alpha in sRGB space.
- **The embedded font** (`assets/`): Inter, a static SemiBold TrueType (OFL 1.1) from the official
  release, `https://github.com/rsms/inter/releases` — check it starts `00 01 00 00` (TrueType), not
  `OTTO`. Commit `OFL.txt` beside it. If no glyf-based static Inter is reachable, DejaVu Sans Bold from
  `/usr/share/fonts/truetype/dejavu/` with its licence. `--font` takes any `.ttf`.

### 3.9 The command line

```
tessera grid <input>... -o <out.mp4> [--cols N] [--rows N] [--size WxH|native] [--fps N]
             [--label TEXT]... [--title TEXT] [--caption "TEXT@FROM-TO"]... [--gap PX] [--margin PX]
             [--bg #RRGGBB] [--duration longest|shortest|SECONDS] [--end hold|black|loop]
             [--codec h264|hevc|av1] [--quality visually-lossless|high|small|crf=N]
             [--max-size MB] [--force] [--font PATH] [--ffmpeg PATH] [--threads N]
             [--keep-master] [--dry-run]
tessera run <job.json> [--dry-run]
tessera probe <input>...
tessera ssim <a> <b> [--frames N]
tessera version | help | <command> --help
```

`--fps` defaults to the highest input rate, capped at 60. `--dry-run` prints the canvas, the rects,
the fps, the duration and the ffmpeg command lines, and runs nothing. The job format is documented in
the README with a complete example (a title scene, a 2×2 scene with labels and a timed caption, a
stills scene).

## 4. Build order — one commit per step, each leaving `./build.sh && ./test.sh` green

Messages: `type: summary` (lowercase, imperative, no period; types `feat fix perf refactor test doc chore`),
the reasoning in the body. **No `Co-Authored-By` trailer, no agent attribution.** No push.

| # | Step | Commit | Verify |
| --- | --- | --- | --- |
| 1 | Skeleton: `build.sh` (`odin build src -out:bin/tessera -o:speed`), `build.bat`, `test.sh` (`odin test src` then `tests/e2e.sh` when it exists), `main.odin` with `version`/`help`, exit codes | `chore: skeleton — build and test scripts, version and help` | `bin/tessera version` |
| 2 | `image.odin`, `resample.odin` + tests | `feat: rgb images and the separable resampler — area down, catmull-rom up` | unit tests (below) |
| 3 | `layout.odin` + tests | `feat: grid layout — dimensions, cell rects, contain and cover` | unit tests |
| 4 | `ffmpeg.odin`: discovery, probe, `Decoder`, `Encoder` + tests on `lavfi` sources | `feat: ffmpeg as the codec — probe, raw decoder and encoder over pipes` | a 1 s `testsrc2` decoded frame-exact |
| 5 | `yuv.odin` + round-trip test through ffmpeg | `feat: bt709 limited-range yuv420p conversion` | ±2 per channel on the test colours |
| 6 | `timeline.odin`, `compose.odin`, `cli.odin` for `grid` without text, `tests/e2e.sh` | `feat: grid — several videos on one screen, conformed to one frame rate` | e2e: dims, fps, duration, a cell's colour |
| 7 | `ttf.odin` + tests on the embedded font | `feat: truetype parser — cmap, glyf with composites, metrics, kern` | unit tests |
| 8 | `raster.odin` + tests | `feat: glyph rasteriser — signed-area coverage` | unit tests |
| 9 | `text.odin`, labels, `--title`, `--caption` + e2e | `feat: text — labels, titles and timed captions with outline, shadow and box` | e2e + **look at a frame** |
| 10 | `job.odin` + `run`, stills as cells, per-cell `start` | `feat: job files — scenes, stills, per-cell offsets` | e2e with a 3-scene job |
| 11 | `ssim.odin` + `ssim` command, checked against ffmpeg | `feat: ssim on the luma plane, checked against ffmpeg's` | within 0.005 |
| 12 | `quality.odin` — master, search, size cap | `feat: quality search — the largest crf that keeps ssim over the target` | the samples 2×2 at `visually-lossless` |
| 13 | Threaded compositing + a measured before/after | `perf: compose rows on a thread pool` | frames/s recorded in the commit body |
| 14 | `docs/encoding.md` (§3.7) and any default it changes | `doc: encoding study on game footage — the defaults it chose` | the table |
| 15 | `--metric vmaf` (optional), GPOS pair kerning (optional) | `feat: …` each | tests |
| 16 | README: what, install (Linux, Windows), every command, the job format, how it works, limits, font licence | `doc: readme` | — |
| 17 | Windows type-check (§2) clean, any fix | `fix: …` / `chore: windows type-check clean` | `odin check … -target:windows_amd64` |

## 5. Tests owed

**Unit (`odin test src`, `core:testing`):**
- resample: a constant image stays constant through down and up scaling; every weight row sums to 1
  (±1e-5); a 2× area downscale of a 1-px checkerboard is 127/128 everywhere; identity at scale 1.
- layout: `grid_dims` for n = 1…16 as §3.3; rects inside the canvas, non-overlapping, gaps exact;
  `fit_rect` keeps aspect within 1 px.
- yuv: black → (16,128,128), white → (235,128,128), pure R/G/B → the BT.709 table values ±1.
- ttf: the embedded font parses; `unitsPerEm` > 0; 'A', 'g', 'é' (a composite in most fonts) have
  outlines; an unknown code point maps to glyph 0; a truncated font buffer returns an error.
- raster: a rectangle covering pixels exactly → coverage 1 inside, 0 outside; a rectangle offset by
  half a pixel → 0.5 on its edge column; the summed coverage of a triangle equals its area within
  0.5 %.
- text: a string's advance equals the sum of its glyph advances plus kerning; `\n` adds a line height.
- ssim: identical planes → 1.0; a plane against its inverse → < 0.1; agreement with ffmpeg's filter
  on two sample frames within 0.005.
- job: a valid job parses; each malformed field produces an error naming the field.

**End to end (`tests/e2e.sh`, inputs generated with `ffmpeg -f lavfi`):** four inputs of different
sizes, rates and lengths (`testsrc2` 1280×720@60 for 3 s, `testsrc2` 640×480@30 for 2 s,
`color=c=red` 800×600@25 for 1 s, a PNG still) → `tessera grid … -o out.mp4 --quality crf=18`;
`ffprobe` asserts 1920×1080, the requested fps, a duration of 3 s ±1 frame, h264, yuv420p, bt709
tags; a frame at 0.5 s has the red cell's centre within ±12 of (255,0,0) after decode; a frame at 2.5
s has the red cell still red (`hold`) and, with `--end black`, background-coloured. A `run` job with
a text scene: pixels inside the text's box differ from the background.

**By eye, before claiming done:** extract a frame from the samples' 2×2 output and from a job with
captions (`ffmpeg -ss 5 -i out.mp4 -frames:v 1 f.png`) and look at it — labels legible, no seams, no
colour shift against the sources.

## 6. Open questions for the owner

**Q1 — Licence.** None is chosen. *AI leaning:* MIT when the GitHub repository is created; until then
no `LICENSE` file (the embedded font's `OFL.txt` ships regardless).

**Q2 — What "without losing quality" means in numbers.** The SSIM targets in §3.6 are the plan's.
*AI leaning:* keep them; the encoding study shows what each costs in megabytes, and the owner can move
the default.

**Q3 — Audio.** v1 drops it. *AI leaning:* add `--audio <cell index>` (copy one cell's track) in v2 if
the owner wants it; mixing several makes no sense for side-by-side comparisons.

**Q4 — Default canvas.** 1920×1080 (shrinks four 720p windows to ~944×531 each) or `native`
(2576×1464 for four 720p windows, nothing resampled). *AI leaning:* 1080p — it is what a phone
shows anyway; `--size native` is there for archive copies.

## 7. What not to do

- Do not use ffmpeg filters for layout, scaling, text or stacking (`xstack`, `hstack`, `overlay`,
  `drawtext`, `scale` in the filtergraph) — D2. The decoder's `-pix_fmt rgb24` and the encoder's input
  format are the only conversions ffmpeg does.
- Do not pipe a child's stderr without draining it.
- Do not lower the fps or the resolution to fit a size.
- Do not commit the samples, `bin/`, outputs, the Odin source checkout, or anything under
  `~/tessera-run/`.
- Do not add a dependency beyond Odin's `core:` and `base:` packages and the ffmpeg binaries.
- Do not add `Co-Authored-By` or any agent attribution to a commit. Do not push; there is no remote.

## 8. What the pre-code review changed

- `vendor:stb/truetype` was the first idea for text; this toolchain ships no Linux stb archives, and
  D2 asks for low level anyway — the TrueType parser and rasteriser are ours.
- The toolchain's missing Windows files made "portable" unverifiable here; §2 adds the source-checkout
  type-check.
- The samples are the owner's real footage (four HUD layouts of the same 40 s), so the encoding
  study measures the content the tool is for.
