package tessera

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
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

// codec_args are the output arguments for one encode at crf, ending before
// the output path.
codec_args :: proc(e: Encode_Settings, crf: int, output: string, allocator := context.allocator) -> []string {
	a := make([dynamic]string, allocator)
	q := fmt.aprintf("%d", crf, allocator = allocator)
	switch e.codec {
	case .H264:
		append(&a, "-c:v", "libx264", "-preset", e.preset if e.preset != "" else "veryslow", "-crf", q)
		if crf > 0 { // crf 0 is lossless, which the high profile refuses
			append(&a, "-profile:v", "high")
		}
	case .HEVC:
		append(&a, "-c:v", "libx265", "-preset", e.preset if e.preset != "" else "slow", "-crf", q, "-tag:v", "hvc1")
		append(&a, "-x265-params", "log-level=error")
	case .AV1:
		append(&a, "-c:v", "libaom-av1", "-crf", q, "-b:v", "0", "-cpu-used", e.preset if e.preset != "" else "4", "-row-mt", "1")
	}
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
	append(&cmd, ..codec_args(r.job.encode, crf, output, allocator))
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

target_for :: proc(q: Preset_Quality) -> Target {
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

CRF_LO :: 10
CRF_HI :: 40
CRF_MAX :: 51 // how far the size cap may push

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
	append(&cmd, ..codec_args(r.job.encode, crf, output, allocator))
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
	mean, min: f64, // SSIM over every sampled frame
	bytes:     i64, // the windows' total
	est_mb:    f64, // the whole video, from the windows' bitrate
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
	total_frames := 0
	for w, i in s.windows {
		p := probe(s.r.tools, paths[i]) or_return
		res := ssim_compare(s.r.tools, s.probe, w.start, p, 0, w.frames, s.workers, s.tmp) or_return
		append(&all.frames, ..res.frames[:])
		ssim_result_delete(&res)
		c.bytes += file_bytes(paths[i])
		total_frames += w.frames
		os.remove(paths[i])
	}
	ssim_summarise(&all)
	c.mean, c.min = all.mean, all.min
	c.est_mb = f64(c.bytes) * f64(s.probe.frames) / f64(max(total_frames, 1)) / 1e6
	s.tried[crf] = c
	fmt.printf("  crf %2d: ssim mean %.4f, min %.4f, ≈ %s (%.0f s)\n", crf, c.mean, c.min, size_string(c.est_mb), c.seconds)
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

Choice :: struct {
	crf:       int,
	candidate: Candidate,
	note:      string, // why, when it is not simply the search's answer
}

// choose_crf runs the search and applies the size cap. A cap that cannot be
// met without dropping below the `small` floor is an error unless forced.
choose_crf :: proc(s: ^Search, q: Preset_Quality, e: Encode_Settings) -> (ch: Choice, err: Err) {
	t := target_for(q)
	crf, found := largest_meeting(s, CRF_LO, CRF_HI, t) or_return
	if !found {
		ch.note = fmt.aprintf("even crf %d misses the %s target; using it", CRF_LO, quality_string(q))
	}
	ch.crf = crf
	ch.candidate = s.tried[crf]
	if e.max_size_mb <= 0 || ch.candidate.est_mb <= e.max_size_mb {
		return ch, nil
	}
	// Over the cap: the smallest CRF that fits, if it keeps the floor.
	fit, fits := smallest_fitting(s, crf + 1, CRF_MAX, e.max_size_mb) or_return
	floor := target_for(.Small)
	fc := s.tried[fit]
	if fits && meets(fc, floor) {
		ch.crf, ch.candidate = fit, fc
		ch.note = fmt.aprintf("raised from crf %d to fit %s", crf, size_string(e.max_size_mb))
		return ch, nil
	}
	floor_crf, floor_found := largest_meeting(s, crf, CRF_MAX, floor) or_return
	need := s.tried[floor_crf].est_mb if floor_found else ch.candidate.est_mb
	if !e.force {
		return ch, fmt.aprintf(
			"%s cannot be met without dropping below the small quality floor (ssim %.3f / %.3f): the floor needs about %s (crf %d). Raise --max-size, or pass --force to encode at crf %d anyway",
			size_string(e.max_size_mb), floor.mean, floor.min, size_string(need), floor_crf, fit,
		)
	}
	ch.crf, ch.candidate = fit, fc
	ch.note = fmt.aprintf("forced to crf %d to fit %s, below the small floor", fit, size_string(e.max_size_mb))
	return ch, nil
}

// run_child starts a child that needs no pipe: stdin and stdout closed,
// stderr in log_path.
run_child :: proc(command: []string, log_path: string) -> (c: Child, err: Err) {
	logf, lerr := os.open(log_path, {.Write, .Create, .Trunc})
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
