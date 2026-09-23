package tessera

import "core:fmt"
import "core:path/filepath"
import "core:strings"

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

// PLACEHOLDER_CRF stands in for the quality search until it exists.
PLACEHOLDER_CRF :: 18

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
