package tessera

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// --metric vmaf: VMAF through ffmpeg's libvmaf filter, when the build has
// it. Optional: SSIM (ours) is the default and needs nothing from ffmpeg.
// This is the one place ffmpeg runs a filter, and it only measures.

require_vmaf :: proc(tools: ^Tools) -> Err {
	out, err := capture({tools.ffmpeg, "-hide_banner", "-filters"})
	if err != nil {
		return err
	}
	defer delete(out)
	if !strings.contains(out, " libvmaf ") {
		return fmt.aprintf("this ffmpeg (%s) has no libvmaf filter; --metric vmaf needs a build with it (or use the default, ssim)", tools.ffmpeg)
	}
	return nil
}

// vmaf_compare scores b against the reference a (from a_start), frames
// frames (0: all of b), with libvmaf's default model.
vmaf_compare :: proc(tools: Tools, a: Probe, a_start: f64, b: Probe, frames: int, threads: int, tmp: string) -> (res: SSIM_Result, err: Err) {
	log := strings.clone(tmp_file(tmp, "vmaf.json"))
	defer delete(log)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, "-i", b.path)
	if a_start > 0 {
		append(&cmd, "-ss", fmt.tprintf("%.6f", a_start))
	}
	append(&cmd, "-i", a.path)
	// libvmaf takes the distorted stream first, the reference second, and
	// pairs frames by timestamp: an mp4's exact times and a Matroska
	// master's millisecond ones disagree, so both are renumbered by frame
	// index first. The log path goes inside a filter argument, so escape
	// what the filter syntax would read.
	filter := fmt.tprintf(
		"[0:v]setpts=N/FRAME_RATE/TB[d];[1:v]setpts=N/FRAME_RATE/TB[r];[d][r]libvmaf=log_fmt=json:log_path='%s':n_threads=%d",
		filter_escape(log), max(threads, 1),
	)
	append(&cmd, "-lavfi", filter)
	if frames > 0 {
		append(&cmd, "-frames:v", fmt.tprintf("%d", frames))
	}
	append(&cmd, "-f", "null", "-")
	child := run_child(cmd[:], tmp_file(tmp, "vmaf.log")) or_return
	finish_child(&child) or_return

	data, rerr := os.read_entire_file(log, context.allocator)
	if rerr != nil {
		return res, fmt.aprintf("vmaf: no log from ffmpeg (%v)", rerr)
	}
	defer delete(data)
	root, jerr := json.parse(data, .JSON, false)
	defer json.destroy_value(root)
	if jerr != nil {
		return res, fmt.aprintf("vmaf: the log is not JSON (%v)", jerr)
	}
	obj, _ := root.(json.Object)
	list, _ := obj["frames"].(json.Array)
	for f in list {
		fo, _ := f.(json.Object)
		m, _ := fo["metrics"].(json.Object)
		#partial switch v in m["vmaf"] {
		case json.Float:
			append(&res.frames, v)
		case json.Integer:
			append(&res.frames, f64(v))
		}
	}
	if len(res.frames) == 0 {
		return res, "vmaf: the log has no per-frame scores"
	}
	ssim_summarise(&res)
	return res, nil
}

// filter_escape quotes a path for a single-quoted filter option value.
@(private = "file")
filter_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '\'', '\\', ':':
			strings.write_rune(&b, '\\')
		}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}
