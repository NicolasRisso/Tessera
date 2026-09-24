# tessera — plan v2: labels outside the picture

**Status: Ready** 2026-09-24 — the review of v1 (`a426a12`…`defd3f7`).

> **Authority: none.** As [`plan.md`](plan.md).

## Why

v1 draws a cell's label inside the picture, top left (`compose.odin:37`, `LABEL_INSET`). On game
footage that corner is the game's own HUD — in the canonical run "Top & bottom" and "Stats left" sit
over the health bar — and the first real use of tessera is exactly that: four renderers of the same
game, where the HUD is part of what is compared. v1's result.md named it too ("a `--label-pos` option
would be a small v2 addition").

## The work

1. **`Label_Pos :: enum { Above, Below, Inside }`** on `Layout` (`job.odin`), JSON field
   `label_pos` (`"above" | "below" | "inside"`, added to `LAYOUT_FIELDS`, errors naming the field as
   the other fields do), CLI `--label-pos above|below|inside`. **Default `Above`** — a label must not
   cover the picture unless asked to; `Inside` is v1's behaviour, unchanged pixel for pixel.
2. **Layout reserves the strip.** For `Above`/`Below`, when any cell in the scene has a label, each
   cell's rectangle gives a strip of `label_h` to the label and fits the picture in the rest
   (`fit_rect` on the reduced rect), so a picture is never covered and never overlaps a neighbour.
   `label_h` = the label's line height plus a small pad, from `label_size` (or the automatic size v1
   derives — derive it from the picture's height as v1 does, before the strip is taken, so it does not
   shrink itself). A cell without a label keeps the strip empty in a labelled scene, so rows stay
   aligned.
3. **Drawing.** `Above`: the label sits in its strip, left-aligned with the picture's left edge,
   vertically centred in the strip, on the same translucent box as v1 (or none — the strip is the
   background; keep the box off for `Above`/`Below` unless a test shows legibility needs it). `Below`:
   the same under the picture.
4. **`--dry-run`** prints the label rects too.
5. **README**: the option, its default, and one sentence on why labels default to outside.

## Tests owed

- Unit: with `Above`, every picture rect lies inside its cell and below its label strip; the strips of
  one row share a `y`; `Inside` yields v1's rects exactly.
- e2e: a 2×2 grid with labels, `--label-pos above` — the top 60 % of the label strip region above the
  top-left picture differs from the background (ink), and the picture's own first rows are the
  source's colour (not covered); `--label-pos inside` reproduces v1's output byte for byte (compare
  with a file made from v1 at `defd3f7`, or with a hash recorded before the change).
- **Look at** a frame of the canonical run (samples, 2×2) with the default: labels above each picture,
  no HUD covered.

## Build order

1. `feat: labels above or below the picture — --label-pos, above by default` (+ tests, README).
2. Re-run the canonical run; record size/SSIM in the commit body.

No `Co-Authored-By` or any attribution; ForgeCoding; no push.
