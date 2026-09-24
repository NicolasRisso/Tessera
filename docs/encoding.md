# Encoding study: game footage, and the defaults it chose

**Question.** For the video tessera exists for (four recordings of the owner's
game side by side), which encoder settings give the smallest file at the same
quality? The plan's defaults (§3.5) change only where this table says so.

**Material.** The canonical run: `hud-{topbottom,statsleft,statsright,corner}.avi`
(MJPEG 1280×720, 60 fps, 40 s, 2400 frames) in a 2×2 grid with labels and a
title, 1920×1080, 60 fps, BT.709 4:2:0. The same composition for every row,
bit for bit: only the encoder settings change.

**Method.** Each row is a full `tessera grid` run at `--quality
visually-lossless`: a lossless master, the CRF search on six 2 s windows
(largest CRF with window SSIM mean ≥ 0.990 and every sampled frame ≥ 0.980),
the final encode of the master at that CRF, and the SSIM of the whole file
against the whole master. So every row is the size at the same quality
target. The script is [encoding-study.sh](encoding-study.sh).

Integer CRF steps are coarse (one step is 7–10 % of size here, as large as
most differences between settings), so the table also gives each setting's
size interpolated to exactly window SSIM 0.990, between the CRF the search
kept and the next one, which it tried and rejected. That column is on the
windows' scale: it cannot see a setting that works across windows, like the
keyframe interval.

The machine was shared (another agent rendering, load 7–22), so encode
times are indicative, and ±20 % between runs.

## Results

| Setting (H.264 unless named) | CRF | File | Δ | Whole-file SSIM mean / min | Size at window SSIM 0.990 | Δ | Final encode |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `-preset veryslow` (the plan's default) | 25 | 2.53 MB | — | 0.9921 / 0.9849 | 2.93 MB | — | 49 s |
| `-preset slower` | 26 | 2.35 MB | −7 % | 0.9912 / 0.9843 | 2.88 MB | −1.5 % | 32 s |
| `-tune animation` | 25 | 2.34 MB | −7.5 % | 0.9920 / 0.9849 | 2.70 MB | **−7.7 %** | 56 s |
| `-tune film` | 26 | 2.29 MB | −9 % | 0.9913 / 0.9839 | 2.85 MB | −2.5 % | 48 s |
| `-aq-mode 2` | 26 | 2.31 MB | −9 % | 0.9915 / 0.9845 | 2.86 MB | −2.3 % | 49 s |
| `-aq-mode 3` (dark-scene bias) | 26 | 2.42 MB | −4 % | 0.9918 / 0.9846 | 2.91 MB | −0.7 % | 66 s |
| keyint 600 (`-g 600`, 10 s) | 25 | 1.91 MB | **−25 %** | 0.9916 / 0.9847 | (2.93 MB) | (windows cannot see it) | 60 s |
| `-tune animation` + `-g 600` | 25 | **1.75 MB** | **−31 %** | 0.9915 / 0.9845 | 2.70 MB | −7.7 % | 50 s |
| HEVC, libx265 `-preset slow` | 27 | 2.06 MB | −19 % | 0.9905 / 0.9862 | 2.59 MB | −12 % | 98 s |
| AV1, libaom `-cpu-used 4`, search capped at 40 | 40 | 1.07 MB | −58 % | 0.9941 / 0.9884 | — (40 still passed) | | 688 s |
| AV1, libaom `-cpu-used 4`, search to 63 | 55 | 0.47 MB | −81 % | 0.9893 / 0.9774 ✗ | — | | 443 s |

Keyframes in the files: 10 at x264's default interval (250 frames), 4 at 600.

## What it says

- **The keyframe interval is the biggest lever.** This footage is mostly a
  still camera over a slowly changing board; x264's default puts an I-frame
  every 4.2 s at 60 fps, and each costs ~130 kB here. A 10 s interval takes
  25 % off at the same CRF and the same SSIM.
- **`-tune animation` is the next**: 7.7 % smaller at equal SSIM. The game
  is flat-shaded low-poly with a crisp HUD, which is what the tune's lighter
  psy-rd and stronger deblocking suit. `-tune film` gains a third of that.
- The two add up: **−31 %** together.
- `slower` against `veryslow`, `aq-mode 2` and `aq-mode 3` differ by less
  than one CRF step (±2.5 %), which is noise at this granularity. The dark-
  scene bias of aq-mode 3 buys nothing SSIM can see on this footage.
- HEVC is 12 % smaller than H.264 with the plan's settings at equal SSIM but
  twice as slow, and the tuned H.264 beats it; for a file sent to phones H.264
  is still the safe choice.
- AV1 is far smaller, and an order of magnitude slower. With the plan's
  CRF range it stopped at 40, the top, still at SSIM 0.994: libaom's scale
  runs to 63. Searched to 63 it chose 55 and made 0.47 MB, but the whole
  file scored 0.9893 / 0.9774, **below the target its windows passed**
  (0.9902 / 0.9824): libaom keeps keyframes far apart, and frames far from
  one drift lower than any 2 s window, which starts on a fresh keyframe,
  can show.

## The defaults it chose

- **H.264 gains `-tune animation` and a keyframe every 10 s** (`-g` = 10 ×
  fps: 600 at 60 fps). The rest of §3.5 stays: `veryslow`, high profile,
  default AQ. `--encoder-opt tune=…` / `--encoder-opt g=…` override both.
- **The CRF search range is per codec**: 10–40 for x264 and x265 as planned,
  10–63 for libaom, whose scale is 0–63 and which at 40 still scored 0.994.
- HEVC and AV1 keep the plan's settings: the study measured the interval and
  the tune on H.264 only.

## Caveats

- One piece of footage, one target. Content with fast motion or frequent
  cuts gains less from a long keyframe interval (x264 still puts a keyframe
  at every scene cut).
- Windows are a sample, and two things differ in the whole file. Its size:
  the estimate `--max-size` works from overshot the real file, 3.0 MB against
  1.75 MB for the tuned H.264 and 2.9 MB against 1.07 MB for AV1, because
  every 2 s window pays for a keyframe. And, with long keyframe intervals,
  its quality, as AV1 showed. After this study the estimate counts
  keyframes as the whole file will have them, and a whole file that misses
  the target is encoded again one CRF lower (the commit after this one).
- SSIM is the target, so settings whose benefit SSIM does not see (psy-rd's
  grain retention, aq-mode 3's dark detail) are judged on its terms.
