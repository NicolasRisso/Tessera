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
