#!/bin/sh
# End-to-end tests: real inputs generated with ffmpeg's lavfi, the built
# binary, and ffprobe/ffmpeg to check what came out.
# Needs bin/tessera, and ffmpeg/ffprobe on PATH (or TESSERA_FFMPEG).
set -eu
cd "$(dirname "$0")/.."
TESSERA=${TESSERA:-bin/tessera}
FFMPEG=${TESSERA_FFMPEG:-ffmpeg}
FFPROBE=$(dirname "$FFMPEG")/ffprobe
[ -x "$FFPROBE" ] || FFPROBE=ffprobe
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tessera-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { # check NAME COMMAND...
	name=$1; shift
	if "$@"; then pass "$name"; else fail "$name"; fi
}

gen() { "$FFMPEG" -nostdin -v error -y "$@"; }

# Four inputs of different sizes, rates and lengths.
gen -f lavfi -i testsrc2=s=1280x720:r=60:d=3 -c:v libx264 -qp 0 -preset ultrafast "$WORK/a.mp4"
gen -f lavfi -i testsrc2=s=640x480:r=30:d=2 -c:v libx264 -qp 0 -preset ultrafast "$WORK/b.mp4"
gen -f lavfi -i color=c=red:s=800x600:r=25:d=1 -c:v libx264 -qp 0 -preset ultrafast "$WORK/red.mp4"
gen -f lavfi -i testsrc2=s=320x240 -frames:v 1 "$WORK/still.png"
INPUTS="$WORK/a.mp4 $WORK/b.mp4 $WORK/red.mp4 $WORK/still.png"

# probe_field FILE ENTRY → the value of one ffprobe entry of the video stream.
probe_field() {
	"$FFPROBE" -v error -select_streams v:0 -show_entries "$2" -of default=nw=1:nk=1 "$1" | head -n 1
}

# pixel FILE TIME X Y → "R G B" of one decoded pixel.
pixel() {
	rm -f "$WORK/px.rgb"
	"$FFMPEG" -nostdin -v error -ss "$2" -i "$1" -frames:v 1 -f rawvideo -pix_fmt rgb24 "$WORK/px.rgb"
	w=$(probe_field "$1" stream=width)
	od -An -tu1 -j $((($4 * w + $3) * 3)) -N3 "$WORK/px.rgb" | tr -s ' ' | sed 's/^ //'
}

# near "R G B" "R G B" TOL → true when every channel is within TOL.
near() {
	set -- $1 $2 "$3"
	[ $(( ($1 - $4) * ($1 - $4) <= $7 * $7 && ($2 - $5) * ($2 - $5) <= $7 * $7 && ($3 - $6) * ($3 - $6) <= $7 * $7 )) -eq 1 ]
}
far() { ! near "$@"; }

# cell_centre N → "X Y", the centre of cell N from --dry-run.
cell_centre() {
	$TESSERA grid $INPUTS -o "$WORK/plan.mp4" --dry-run |
		sed -n "s/^  cell $1 Rect{x = \([0-9]*\), y = \([0-9]*\), w = \([0-9]*\), h = \([0-9]*\)}.*/\1 \2 \3 \4/p" |
		{ read -r x y w h; echo $((x + w / 2)) $((y + h / 2)); }
}

# --- grid: layout, rate, duration, tags, colour, hold ---
OUT=$WORK/out.mp4
if $TESSERA grid $INPUTS -o "$OUT" --quality crf=18 > "$WORK/grid.log" 2>&1; then
	pass "grid runs"
else
	fail "grid runs"; cat "$WORK/grid.log"
fi
check "1920x1080" [ "$(probe_field "$OUT" stream=width)x$(probe_field "$OUT" stream=height)" = 1920x1080 ]
check "60 fps (the highest input rate)" [ "$(probe_field "$OUT" stream=r_frame_rate)" = 60/1 ]
frames=$(probe_field "$OUT" stream=nb_frames)
check "3 s ±1 frame ($frames frames)" [ "$frames" -ge 179 ] && [ "$frames" -le 181 ]
check "h264" [ "$(probe_field "$OUT" stream=codec_name)" = h264 ]
check "yuv420p" [ "$(probe_field "$OUT" stream=pix_fmt)" = yuv420p ]
check "bt709 tags" [ "$(probe_field "$OUT" stream=color_space)/$(probe_field "$OUT" stream=color_primaries)/$(probe_field "$OUT" stream=color_transfer)/$(probe_field "$OUT" stream=color_range)" = bt709/bt709/bt709/tv ]

set -- $(cell_centre 3)
RX=$1 RY=$2
p=$(pixel "$OUT" 0.5 "$RX" "$RY")
check "red cell is red at 0.5 s ($p)" near "$p" "255 0 0" 12
p=$(pixel "$OUT" 2.5 "$RX" "$RY")
check "red cell holds its last frame at 2.5 s ($p)" near "$p" "255 0 0" 12

# --- --end black: the ended cell shows the background ---
OUT2=$WORK/black.mp4
if $TESSERA grid $INPUTS -o "$OUT2" --quality crf=18 --preset veryfast --end black --fps 30 > "$WORK/black.log" 2>&1; then
	pass "grid --end black runs"
else
	fail "grid --end black runs"; cat "$WORK/black.log"
fi
check "30 fps when asked" [ "$(probe_field "$OUT2" stream=r_frame_rate)" = 30/1 ]
p=$(pixel "$OUT2" 0.5 "$RX" "$RY")
check "red cell is red at 0.5 s with --end black ($p)" near "$p" "255 0 0" 12
p=$(pixel "$OUT2" 2.5 "$RX" "$RY")
check "red cell is background at 2.5 s with --end black ($p)" near "$p" "11 15 23" 12

# --- text: a label's box and a caption's box darken the cell under them ---
gen -f lavfi -i color=c=0x808080:s=1280x720 -frames:v 1 "$WORK/grey.png"
OUT3=$WORK/text.mp4
if $TESSERA grid "$WORK/grey.png" --duration 2 --label "Grey" --caption "A CAPTION@0.5-" \
	-o "$OUT3" --quality crf=18 --preset veryfast > "$WORK/text.log" 2>&1; then
	pass "grid with a label and a caption runs"
else
	fail "grid with a label and a caption runs"; cat "$WORK/text.log"
fi
# The picture fills 16..1904 x 16..1064 (letterboxed 16:9 in a 1888x1048 cell).
set -- $($TESSERA grid "$WORK/grey.png" --duration 2 -o "$WORK/p.mp4" --dry-run |
	sed -n 's/.*→ Rect{x = \([0-9]*\), y = \([0-9]*\), .*/\1 \2/p')
LX=$(($1 + 30)) LY=$(($2 + 16)) # in the box's top padding, clear of the rounded corner
p=$(pixel "$OUT3" 1 "$LX" "$LY")
check "the label's box darkens its corner ($p)" near "$p" "43 43 43" 16
p=$(pixel "$OUT3" 1 960 540)
check "the cell's middle is untouched ($p)" near "$p" "128 128 128" 6
p=$(pixel "$OUT3" 0.2 960 1026)
check "no caption before its start ($p)" near "$p" "128 128 128" 6
p=$(pixel "$OUT3" 1.5 960 1026)
check "the caption's box is there after its fade ($p)" near "$p" "43 43 43" 16

# --- run: a 3-scene job (title, 2x2 with labels, caption and an offset, stills) ---
gen -f lavfi -i color=c=red:s=320x240:r=30:d=1 -f lavfi -i color=c=blue:s=320x240:r=30:d=1 \
	-filter_complex "[0][1]concat=n=2:v=1" -c:v libx264 -qp 0 -preset ultrafast "$WORK/redblue.mp4"
cat > "$WORK/job.json" <<'JOB'
{
	"output": "job.mp4",
	"encode": {"quality": "crf=18", "preset": "veryfast"},
	"scenes": [
		{"duration": 1, "texts": [{"text": "TITLE", "size": 120, "box_color": "#FF8800", "box_pad": 30}]},
		{
			"cells": [
				{"src": "a.mp4", "label": "A"},
				{"src": "b.mp4", "label": "B"},
				{"src": "redblue.mp4", "label": "from 1 s", "start": 1},
				"still.png",
			],
			"captions": [{"text": "a caption", "from": 0.2}],
		},
		{"duration": 1, "cells": ["still.png", "grey.png"]},
	],
}
JOB
if $TESSERA run "$WORK/job.json" > "$WORK/job.log" 2>&1; then
	pass "run a 3-scene job"
else
	fail "run a 3-scene job"; cat "$WORK/job.log"
fi
JOBOUT=$WORK/job.mp4
frames=$(probe_field "$JOBOUT" stream=nb_frames)
check "1 + 3 + 1 s ($frames frames at 60 fps)" [ "$frames" -ge 299 ] && [ "$frames" -le 301 ]
p=$(pixel "$JOBOUT" 0.5 960 540)
check "the title scene's text box is drawn ($p)" far "$p" "11 15 23" 40
set -- $($TESSERA run "$WORK/job.json" --dry-run |
	awk '/^scene 2:/ { s = 1 } /^scene 3:/ { s = 0 } s && /^  cell 3 / { print }' |
	sed -n 's/.*→ Rect{x = \([0-9]*\), y = \([0-9]*\), w = \([0-9]*\), h = \([0-9]*\)}.*/\1 \2 \3 \4/p')
OX=$(($1 + $3 / 2)) OY=$(($2 + $4 * 3 / 4))
p=$(pixel "$JOBOUT" 1.5 "$OX" "$OY")
check "a cell started 1 s in shows the source's second second, blue ($p)" near "$p" "0 0 255" 16
p=$(pixel "$JOBOUT" 4.5 480 540) # the first of two cells side by side
check "the stills scene is not the background ($p)" far "$p" "11 15 23" 12

# --- --end loop starts a source again; hold keeps its last frame ---
for end in loop hold; do
	$TESSERA grid "$WORK/a.mp4" "$WORK/redblue.mp4" --end $end --quality crf=18 --preset veryfast \
		-o "$WORK/$end.mp4" > "$WORK/$end.log" 2>&1 || { fail "grid --end $end runs"; cat "$WORK/$end.log"; }
done
set -- $($TESSERA grid "$WORK/a.mp4" "$WORK/redblue.mp4" -o "$WORK/p.mp4" --dry-run |
	sed -n 's/^  cell 2 .*→ Rect{x = \([0-9]*\), y = \([0-9]*\), w = \([0-9]*\), h = \([0-9]*\)}.*/\1 \2 \3 \4/p')
LX=$(($1 + $3 / 2)) LY=$(($2 + $4 * 3 / 4))
p=$(pixel "$WORK/loop.mp4" 2.5 "$LX" "$LY")
check "a 2 s red-then-blue cell looped is red again at 2.5 s ($p)" near "$p" "255 0 0" 16
p=$(pixel "$WORK/hold.mp4" 2.5 "$LX" "$LY")
check "held, it stays blue at 2.5 s ($p)" near "$p" "0 0 255" 16

# --- the quality search, the size cap, --force ---
Q=$WORK/q.mp4
if $TESSERA grid "$WORK/a.mp4" "$WORK/b.mp4" --size 640x360 --quality high --preset veryfast \
	-o "$Q" > "$WORK/q.log" 2>&1; then
	pass "grid --quality high runs"
else
	fail "grid --quality high runs"; cat "$WORK/q.log"
fi
line=$(grep '^crf [0-9]* (ssim mean' "$WORK/q.log" || true)
check "the search reports its choice ($line)" [ -n "$line" ]
whole=$(sed -n 's/.*whole video ssim mean \([0-9.]*\), min \([0-9.]*\).*/\1 \2/p' "$WORK/q.log")
check "the result meets high over the whole video ($whole)" awk -v m="${whole% *}" -v n="${whole#* }" 'BEGIN { exit !(m >= 0.980 && n >= 0.960) }'
set +e
$TESSERA grid "$WORK/a.mp4" "$WORK/b.mp4" --size 640x360 --quality high --preset veryfast \
	--max-size 0.001 -o "$WORK/cap.mp4" > "$WORK/cap.log" 2>&1; code=$?
set -e
check "an unreachable size cap is refused (exit $code)" [ $code -eq 1 ]
check "the refusal says what the floor needs" grep -q "the floor needs about" "$WORK/cap.log"
if $TESSERA grid "$WORK/a.mp4" "$WORK/b.mp4" --size 640x360 --quality high --preset veryfast \
	--max-size 0.001 --force -o "$WORK/forced.mp4" > "$WORK/forced.log" 2>&1 && [ -s "$WORK/forced.mp4" ]; then
	pass "--force encodes anyway"
else
	fail "--force encodes anyway"; cat "$WORK/forced.log"
fi

# --- --metric vmaf, when this ffmpeg has libvmaf ---
if "$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q ' libvmaf '; then
	if $TESSERA grid "$WORK/a.mp4" "$WORK/b.mp4" --size 640x360 --quality high --metric vmaf --preset veryfast \
		-o "$WORK/vmaf.mp4" > "$WORK/vmaf.log" 2>&1; then
		pass "grid --metric vmaf runs"
	else
		fail "grid --metric vmaf runs"; cat "$WORK/vmaf.log"
	fi
	v=$(sed -n 's/.*whole video vmaf mean \([0-9.]*\),.*/\1/p' "$WORK/vmaf.log")
	check "the result meets vmaf 90 over the whole video, within 1 ($v)" awk -v m="$v" 'BEGIN { exit !(m >= 89) }'
else
	echo "skip --metric vmaf: this ffmpeg has no libvmaf"
fi

# --- usage errors exit 2, runtime failures 1 ---
set +e
$TESSERA grid "$WORK/a.mp4" > /dev/null 2>&1; code=$?
check "no output is a usage error (exit $code)" [ $code -eq 2 ]
$TESSERA grid "$WORK/missing.mp4" -o "$WORK/x.mp4" > /dev/null 2>&1; code=$?
check "a missing input is a runtime failure (exit $code)" [ $code -eq 1 ]
set -e

if [ $failures -ne 0 ]; then
	echo "e2e: $failures failed"
	exit 1
fi
echo "e2e: all passed"
