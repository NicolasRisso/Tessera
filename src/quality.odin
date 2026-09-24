package tessera

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// Encoder settings per codec (plan §3.5; the encoding study may change them).

codec_encoder :: proc(c: Codec) -> string {
	switch c {
	case .H264:
		return "libx264"
	case .HEVC:
		return "libx265"
	case .AV1:
		return "libaom-av1"
	}
	return ""
}

codec_name :: proc(c: Codec) -> string {
	switch c {
	case .H264:
		return "h264"
	case .HEVC:
		return "hevc"
	case .AV1:
		return "av1"
	}
	return ""
}

// H264_KEYINT_SECONDS: x264's default keyframe interval is 250 frames (4.2 s
// at 60 fps). On the study's game footage a 10 s interval made the file 25 %
// smaller at the same CRF and SSIM (docs/encoding.md); seeking lands within
// 10 s, which a showcase does not mind.
H264_KEYINT_SECONDS :: 10

// codec_args are the output arguments for one encode at crf, ending before
// the output path. The defaults are §3.5's plus what docs/encoding.md
// measured: for H.264, -tune animation and a 10 s keyframe interval.
codec_args :: proc(e: Encode_Settings, crf: int, output: string, fps: Rational, allocator := context.allocator) -> []string {
	a := make([dynamic]string, allocator)
	q := fmt.aprintf("%d", crf, allocator = allocator)
	switch e.codec {
	case .H264:
		append(&a, "-c:v", "libx264", "-preset", e.preset if e.preset != "" else "veryslow", "-crf", q)
		if crf > 0 { // crf 0 is lossless, which the high profile refuses
			append(&a, "-profile:v", "high")
		}
		keyint := max(int(rational_f64(fps) * H264_KEYINT_SECONDS + 0.5), 1)
		append(&a, "-tune", "animation", "-g", fmt.aprintf("%d", keyint, allocator = allocator))
	case .HEVC:
		append(&a, "-c:v", "libx265", "-preset", e.preset if e.preset != "" else "slow", "-crf", q, "-tag:v", "hvc1")
		append(&a, "-x265-params", "log-level=error")
	case .AV1:
		append(&a, "-c:v", "libaom-av1", "-crf", q, "-b:v", "0", "-cpu-used", e.preset if e.preset != "" else "4", "-row-mt", "1")
	}
	append(&a, ..e.options[:]) // after the defaults: ffmpeg keeps the last of a repeated option
	append(&a, "-pix_fmt", "yuv420p")
	append(&a, ..COLOR_TAGS)
	if wants_faststart(output) {
		append(&a, "-movflags", "+faststart")
	}
	return a[:]
}

wants_faststart :: proc(output: string) -> bool {
	ext := strings.to_lower(filepath.ext(output), context.temp_allocator)
	return ext == ".mp4" || ext == ".mov" || ext == ".m4v"
}

// encode_command is the whole ffmpeg command that reads our raw frames and
// writes output at crf.
encode_command :: proc(r: ^Resolved, crf: int, output: string, allocator := context.allocator) -> []string {
	cmd := make([dynamic]string, allocator)
	append(&cmd, r.tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, ..encoder_input_args(r.w, r.h, r.fps, allocator))
	append(&cmd, ..codec_args(r.job.encode, crf, output, r.fps, allocator))
	append(&cmd, output)
	return cmd[:]
}

// ---- The quality search ----
//
// The composed video is encoded once, losslessly (the master). Sample
// windows of it are encoded at candidate CRFs with the final settings and
// scored against the master with SSIM; bisection finds the largest CRF whose
// windows meet the target. The master is then encoded once at that CRF.

Target :: struct {
	mean, min: f64, // every sampled frame >= min, their mean >= mean
}

// target_for gives the preset's threshold in the job's metric. VMAF has a
// mean threshold only (95 / 90 / 85), no per-frame floor.
target_for :: proc(q: Preset_Quality, metric := Metric.SSIM) -> Target {
	if metric == .VMAF {
		switch q {
		case .Visually_Lossless:
			return {95, 0}
		case .High:
			return {90, 0}
		case .Small:
			return {85, 0}
		}
	}
	switch q {
	case .Visually_Lossless:
		return {0.990, 0.980}
	case .High:
		return {0.980, 0.965}
	case .Small:
		return {0.965, 0.940}
	}
	return {0.990, 0.980}
}

// crf_range is where the search looks (lo ..= hi) and how far a size cap may
// push (top). The plan's 10..40 is x264's scale (x265's is the same);
// libaom's runs to 63 and at 40 it still scored SSIM 0.995 on the samples,
// so AV1 searches up to 63.
crf_range :: proc(c: Codec) -> (lo, hi, top: int) {
	switch c {
	case .H264, .HEVC:
		return 10, 40, 51
	case .AV1:
		return 10, 63, 63
	}
	return 10, 40, 51
}

// master_command encodes the raw frames losslessly (x264 qp 0, 4:2:0, the
// same frames the final encode will get).
master_command :: proc(r: ^Resolved, path: string, allocator := context.allocator) -> []string {
	cmd := make([dynamic]string, allocator)
	append(&cmd, r.tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, ..encoder_input_args(r.w, r.h, r.fps, allocator))
	append(&cmd, "-c:v", "libx264", "-qp", "0", "-preset", "ultrafast", "-pix_fmt", "yuv420p")
	append(&cmd, ..COLOR_TAGS)
	append(&cmd, path)
	return cmd[:]
}

// transcode_command encodes frames [start, start+frames) of the master (all
// of it when frames == 0) at crf into output.
transcode_command :: proc(r: ^Resolved, master: string, start: f64, frames, crf: int, output: string, allocator := context.allocator) -> []string {
	cmd := make([dynamic]string, allocator)
	append(&cmd, r.tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	if start > 0 {
		append(&cmd, "-ss", fmt.aprintf("%.6f", start, allocator = allocator))
	}
	append(&cmd, "-i", master, "-an")
	if frames > 0 {
		append(&cmd, "-frames:v", fmt.aprintf("%d", frames, allocator = allocator))
	}
	append(&cmd, ..codec_args(r.job.encode, crf, output, r.fps, allocator))
	append(&cmd, output)
	return cmd[:]
}

Window :: struct {
	start:  f64, // seconds, on a frame boundary
	frames: int,
}

WINDOWS :: 6
WINDOW_SECONDS :: 2.0
WHOLE_BELOW_SECONDS :: 20.0

// plan_windows spreads six 2 s windows evenly, or takes the whole video when
// it is under 20 s.
plan_windows :: proc(total_frames: int, fps: Rational, allocator := context.allocator) -> []Window {
	rate := rational_f64(fps)
	duration := f64(total_frames) / rate
	if duration < WHOLE_BELOW_SECONDS {
		w := make([]Window, 1, allocator)
		w[0] = Window{0, total_frames}
		return w
	}
	n := int(WINDOW_SECONDS * rate + 0.5)
	w := make([]Window, WINDOWS, allocator)
	for i in 0 ..< WINDOWS {
		centre := duration * (f64(i) + 0.5) / WINDOWS
		first := clamp(int(math.round((centre - WINDOW_SECONDS / 2) * rate)), 0, total_frames - n)
		w[i] = Window{f64(first) / rate, n}
	}
	return w
}

Candidate :: struct {
	crf:       int,
	mean, min: f64, // the metric over every sampled frame
	bytes:     i64, // the windows' total
	est_mb:    f64, // the whole video, from the windows' packets (estimate_bytes)
	seconds:   f64, // wall time to encode the windows
}

Search :: struct {
	r:       ^Resolved,
	master:  string,
	probe:   Probe,
	windows: []Window,
	tmp:     string,
	workers: ^Workers,
	tried:   map[int]Candidate,
}

meets :: proc(c: Candidate, t: Target) -> bool {
	return c.mean >= t.mean && c.min >= t.min
}

// evaluate encodes every window at crf (concurrently) and scores them.
evaluate :: proc(s: ^Search, crf: int) -> (c: Candidate, err: Err) {
	if done, ok := s.tried[crf]; ok {
		return done, nil
	}
	c.crf = crf
	started := time.tick_now()
	paths := make([]string, len(s.windows), context.temp_allocator)
	children := make([]Child, len(s.windows), context.temp_allocator)
	for w, i in s.windows {
		paths[i] = tmp_file(s.tmp, fmt.tprintf("window%d-crf%d.mkv", i, crf))
		cmd := transcode_command(s.r, s.master, w.start, w.frames, crf, paths[i], context.temp_allocator)
		children[i] = run_child(cmd, tmp_file(s.tmp, fmt.tprintf("window%d-crf%d.log", i, crf))) or_return
	}
	for &ch in children {
		finish_child(&ch) or_return
	}
	c.seconds = time.duration_seconds(time.tick_since(started))
	all: SSIM_Result
	defer ssim_result_delete(&all)
	packets: Packet_Stats
	for w, i in s.windows {
		p := probe(s.r.tools, paths[i]) or_return
		res := score(s.r, s.probe, w.start, p, w.frames, s.workers, s.tmp) or_return
		append(&all.frames, ..res.frames[:])
		ssim_result_delete(&res)
		c.bytes += file_bytes(paths[i])
		ps := packet_stats(s.r.tools, paths[i]) or_return
		packets.key_bytes += ps.key_bytes
		packets.keys += ps.keys
		packets.other_bytes += ps.other_bytes
		packets.others += ps.others
		os.remove(paths[i])
	}
	ssim_summarise(&all)
	c.mean, c.min = all.mean, all.min
	keyint := file_keyint(s.r.job.encode, s.r.fps)
	c.est_mb = estimate_bytes(packets, len(s.windows), s.probe.frames, keyint) / 1e6
	s.tried[crf] = c
	fmt.printf("  crf %2d: %s, ≈ %s (%.0f s)\n", crf, score_string(s.r.job.encode.metric, c.mean, c.min), size_string(c.est_mb), c.seconds)
	return c, nil
}

// largest_meeting bisects [lo, hi] for the largest CRF meeting t, assuming
// quality falls as CRF rises. found is false when even lo misses.
largest_meeting :: proc(s: ^Search, lo, hi: int, t: Target) -> (crf: int, found: bool, err: Err) {
	lo, hi := lo, hi
	first := evaluate(s, lo) or_return
	if !meets(first, t) {
		return lo, false, nil
	}
	for lo < hi {
		mid := (lo + hi + 1) / 2
		c := evaluate(s, mid) or_return
		if meets(c, t) {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo, true, nil
}

// smallest_fitting bisects [lo, hi] for the smallest CRF whose estimate fits
// under cap_mb, assuming size falls as CRF rises. found is false when even
// hi does not fit.
smallest_fitting :: proc(s: ^Search, lo, hi: int, cap_mb: f64) -> (crf: int, found: bool, err: Err) {
	lo, hi := lo, hi
	last := evaluate(s, hi) or_return
	if last.est_mb > cap_mb {
		return hi, false, nil
	}
	for lo < hi {
		mid := (lo + hi) / 2
		c := evaluate(s, mid) or_return
		if c.est_mb <= cap_mb {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo, true, nil
}

// Packet_Stats splits an encode's video bytes into keyframes and the rest.
Packet_Stats :: struct {
	key_bytes, other_bytes: i64,
	keys, others:           int,
}

packet_stats :: proc(tools: Tools, path: string) -> (ps: Packet_Stats, err: Err) {
	out := capture({tools.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=size,flags", "-of", "csv=p=0", path}) or_return
	defer delete(out)
	it := out
	for line in strings.split_lines_iterator(&it) {
		comma := strings.index_byte(line, ',')
		if comma < 0 {
			continue
		}
		size, ok := strconv.parse_i64(line[:comma])
		if !ok {
			continue
		}
		if strings.contains_rune(line[comma + 1:], 'K') {
			ps.key_bytes += size
			ps.keys += 1
		} else {
			ps.other_bytes += size
			ps.others += 1
		}
	}
	return ps, nil
}

// file_keyint is the keyframe interval the whole file will have, in frames
// (0: none but the first): an explicit -g, else the codec's default as
// ffmpeg drives it (ours for x264, x265's 250, one for libaom).
file_keyint :: proc(e: Encode_Settings, fps: Rational) -> int {
	for i := 0; i + 1 < len(e.options); i += 2 {
		if e.options[i] == "-g" {
			if g, ok := strconv.parse_int(e.options[i + 1]); ok {
				return max(g, 0)
			}
		}
	}
	switch e.codec {
	case .H264:
		return max(int(rational_f64(fps) * H264_KEYINT_SECONDS + 0.5), 1)
	case .HEVC:
		return 250
	case .AV1:
		return 0
	}
	return 250
}

// estimate_bytes turns the windows' packets into the whole file's size.
// Every window starts on a keyframe the file will mostly not have, so the
// bytes are counted apart: keyframes as the file will place them (its
// interval, plus the windows' own scene cuts at their rate), everything
// else at the windows' rate per frame.
estimate_bytes :: proc(ps: Packet_Stats, windows, total_frames: int, keyint: int) -> f64 {
	frames := ps.keys + ps.others
	if frames == 0 {
		return 0
	}
	key_size := f64(ps.key_bytes) / f64(max(ps.keys, 1))
	other_size := f64(ps.other_bytes) / f64(max(ps.others, 1))
	cuts := f64(max(ps.keys - windows, 0)) / f64(frames) // scene cuts per frame
	keys := 1 + cuts * f64(total_frames)
	if keyint > 0 {
		keys += f64((total_frames - 1) / keyint)
	}
	keys = min(keys, f64(total_frames))
	return key_size * keys + other_size * (f64(total_frames) - keys)
}

Choice :: struct {
	crf:       int,
	candidate: Candidate,
	note:      string, // why, when it is not simply the search's answer
	hold:      Target, // what the whole file must meet: the target, or the floor under a cap
	forced:    bool, // --force took it below the floor: nothing to hold
}

// choose_crf runs the search and applies the size cap. A cap that cannot be
// met without dropping below the `small` floor is an error unless forced.
choose_crf :: proc(s: ^Search, q: Preset_Quality, e: Encode_Settings) -> (ch: Choice, err: Err) {
	t := target_for(q, e.metric)
	lo, hi, top := crf_range(e.codec)
	crf, found := largest_meeting(s, lo, hi, t) or_return
	if !found {
		ch.note = fmt.aprintf("even crf %d misses the %s target; using it", lo, quality_string(q))
	}
	ch.crf = crf
	ch.candidate = s.tried[crf]
	ch.hold = t
	if e.max_size_mb <= 0 || ch.candidate.est_mb <= e.max_size_mb {
		return ch, nil
	}
	// Over the cap: the smallest CRF that fits, if it keeps the floor.
	fit, fits := smallest_fitting(s, min(crf + 1, top), top, e.max_size_mb) or_return
	floor := target_for(.Small, e.metric)
	fc := s.tried[fit]
	if fits && meets(fc, floor) {
		ch.crf, ch.candidate = fit, fc
		ch.hold = floor
		ch.note = fmt.aprintf("raised from crf %d to fit %s", crf, size_string(e.max_size_mb))
		return ch, nil
	}
	floor_crf, floor_found := largest_meeting(s, crf, top, floor) or_return
	need := s.tried[floor_crf].est_mb if floor_found else ch.candidate.est_mb
	if !e.force {
		return ch, fmt.aprintf(
			"%s cannot be met without dropping below the small quality floor (%s): the floor needs about %s (crf %d). Raise --max-size, or pass --force to encode at crf %d anyway",
			size_string(e.max_size_mb), target_string(e.metric, floor), size_string(need), floor_crf, fit,
		)
	}
	ch.crf, ch.candidate = fit, fc
	ch.forced = true
	ch.note = fmt.aprintf("forced to crf %d to fit %s, below the small floor", fit, size_string(e.max_size_mb))
	return ch, nil
}

// run_child starts a child that needs no pipe: stdin and stdout closed,
// stderr in log_path.
run_child :: proc(command: []string, log_path: string) -> (c: Child, err: Err) {
	logf, lerr := os.open(log_path, {.Write, .Create, .Trunc, .Inheritable}) // see start_child
	if lerr != nil {
		return {}, fmt.aprintf("cannot create %s: %v", log_path, lerr)
	}
	defer os.close(logf)
	p, serr := os.process_start(os.Process_Desc{command = command, stderr = logf})
	if serr != nil {
		return {}, fmt.aprintf("cannot start %s: %v", command[0], serr)
	}
	return Child{process = p, log_path = strings.clone(log_path), running = true}, nil
}

tmp_file :: proc(tmp, name: string) -> string {
	p, _ := filepath.join({tmp, name}, context.temp_allocator)
	return p
}

file_bytes :: proc(path: string) -> i64 {
	f, err := os.open(path)
	if err != nil {
		return 0
	}
	defer os.close(f)
	n, _ := os.file_size(f)
	return n
}

// size_string shows megabytes (10^6 bytes) with the precision they deserve.
size_string :: proc(mb: f64, allocator := context.temp_allocator) -> string {
	if mb < 1 {
		return fmt.aprintf("%.0f kB", mb * 1000, allocator = allocator)
	}
	return fmt.aprintf("%.1f MB", mb, allocator = allocator)
}

// score measures b against the master from a_start in the job's metric.
score :: proc(r: ^Resolved, master: Probe, a_start: f64, b: Probe, frames: int, w: ^Workers, tmp: string) -> (res: SSIM_Result, err: Err) {
	if r.job.encode.metric == .VMAF {
		return vmaf_compare(r.tools, master, a_start, b, frames, w.threads, tmp)
	}
	return ssim_compare(r.tools, master, a_start, b, 0, frames, w, tmp)
}

score_string :: proc(m: Metric, mean, low: f64) -> string {
	if m == .VMAF {
		return fmt.tprintf("vmaf mean %.2f, min %.2f", mean, low)
	}
	return fmt.tprintf("ssim mean %.4f, min %.4f", mean, low)
}

target_string :: proc(m: Metric, t: Target) -> string {
	if m == .VMAF {
		return fmt.tprintf("vmaf mean ≥ %.0f", t.mean)
	}
	return fmt.tprintf("ssim mean ≥ %.3f, every frame ≥ %.3f", t.mean, t.min)
}
