#!/bin/sh
# The encoding study behind docs/encoding.md: the canonical four-sample grid
# through the full quality search (visually-lossless) once per encoder
# setting, so every row is the size at the same SSIM target.
#
#   docs/encoding-study.sh SAMPLES_DIR OUT_DIR [SETTING...]
#
# SAMPLES_DIR holds hud-{topbottom,statsleft,statsright,corner}.avi. Results
# are appended to OUT_DIR/study.tsv; each run's log is OUT_DIR/<name>.log.
# If /home/nicolas/mtd-parity/BENCHING exists (a benchmark owns the machine),
# the next run waits for it to go.
set -eu
cd "$(dirname "$0")/.."
SAMPLES=$1
OUT=$2
shift 2
mkdir -p "$OUT"
TSV=$OUT/study.tsv
[ -f "$TSV" ] || printf 'setting\tcrf\tMB\tssim_mean\tssim_min\tsearch_s\tencode_s\ttotal_s\n' > "$TSV"

settings() {
	cat <<'EOF'
h264-veryslow
h264-slower           --preset slower
h264-tune-animation   --encoder-opt tune=animation
h264-tune-film        --encoder-opt tune=film
h264-aq2              --encoder-opt aq-mode=2
h264-aq3              --encoder-opt aq-mode=3
h264-keyint600        --encoder-opt g=600
h264-animation-g600   --encoder-opt tune=animation --encoder-opt g=600
hevc-slow             --codec hevc
av1-cpu4              --codec av1
EOF
}

settings | while read -r name args; do
	if [ $# -gt 0 ]; then
		wanted=no
		for w in "$@"; do [ "$w" = "$name" ] && wanted=yes; done
		[ $wanted = yes ] || continue
	fi
	while [ -e /home/nicolas/mtd-parity/BENCHING ]; do sleep 30; done
	log=$OUT/$name.log
	start=$(date +%s)
	# shellcheck disable=SC2086 # $args is a list of options by design
	nice -n 10 bin/tessera grid "$SAMPLES"/hud-topbottom.avi "$SAMPLES"/hud-statsleft.avi \
		"$SAMPLES"/hud-statsright.avi "$SAMPLES"/hud-corner.avi \
		--label "Top & bottom" --label "Stats left" --label "Stats right" --label Corner \
		--title "Fusefall — four HUD layouts" $args -o "$OUT/$name.mp4" > "$log" 2>&1 || {
		echo "$name failed; see $log"
		continue
	}
	total=$(($(date +%s) - start))
	line=$(grep 'whole video ssim' "$log")
	crf=$(echo "$line" | sed 's/.* crf \([0-9]*\) → .*/\1/')
	bytes=$(wc -c < "$OUT/$name.mp4")
	mb=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1e6 }')
	mean=$(echo "$line" | sed 's/.*ssim mean \([0-9.]*\),.*/\1/')
	min=$(echo "$line" | sed 's/.*, min \([0-9.]*\) (.*/\1/')
	enc=$(echo "$line" | sed 's/.*encode \([0-9.]*\) s.*/\1/')
	search=$(sed -n 's/^  crf .*(\([0-9]*\) s)$/\1/p' "$log" | awk '{ t += $1 } END { print t + 0 }')
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$crf" "$mb" "$mean" "$min" "$search" "$enc" "$total" >> "$TSV"
	echo "$name: crf $crf, $mb MB, ssim $mean / $min, search ${search}s, encode ${enc}s, total ${total}s"
done
