package tessera

import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
pattern_plane :: proc(w, h: int) -> []u8 {
	p := make([]u8, w * h)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p[y * w + x] = u8((x * 7 + y * 3 + (x * y) % 29) % 256)
		}
	}
	return p
}

@(test)
test_ssim_identical_is_one :: proc(t: ^testing.T) {
	a := pattern_plane(64, 48)
	defer delete(a)
	s := ssim_plane(a, a, 64, 48)
	testing.expectf(t, abs(s - 1) < 1e-6, "identical planes: %v", s)
}

@(test)
test_ssim_inverse_is_low :: proc(t: ^testing.T) {
	a := pattern_plane(64, 48)
	defer delete(a)
	b := make([]u8, len(a))
	defer delete(b)
	for v, i in a {
		b[i] = 255 - v
	}
	s := ssim_plane(a, b, 64, 48)
	testing.expectf(t, s < 0.1, "a plane against its inverse: %v", s)
}

// ffmpeg_ssim runs ffmpeg's ssim filter on two videos and returns its Y score.
@(private = "file")
ffmpeg_ssim :: proc(t: ^testing.T, tools: Tools, a, b: string) -> (y: f64, ok: bool) {
	state, out, errb, e := os.process_exec(
		os.Process_Desc{command = {tools.ffmpeg, "-nostdin", "-hide_banner", "-i", a, "-i", b, "-lavfi", "ssim", "-f", "null", "-"}},
		context.allocator,
	)
	defer delete(out)
	defer delete(errb)
	if e != nil || state.exit_code != 0 {
		testing.expectf(t, false, "ffmpeg ssim failed: %v %s", e, string(errb))
		return 0, false
	}
	text := string(errb)
	i := strings.index(text, "SSIM Y:")
	if i < 0 {
		testing.expectf(t, false, "no SSIM line in: %s", text)
		return 0, false
	}
	rest := text[i + len("SSIM Y:"):]
	end := strings.index_byte(rest, ' ')
	return strconv.parse_f64(rest[:end])
}

@(private = "file")
check_against_ffmpeg :: proc(t: ^testing.T, tools: Tools, dir, ref, dist: string) {
	pa, e1 := probe(tools, ref)
	pb, e2 := probe(tools, dist)
	testing.expect_value(t, e1, nil)
	testing.expect_value(t, e2, nil)
	w: Workers
	workers_init(&w, 4)
	defer workers_destroy(&w)
	res, err := ssim_compare(tools, pa, 0, pb, 0, 0, &w, dir)
	defer ssim_result_delete(&res)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(res.frames), 2)
	theirs, ok := ffmpeg_ssim(t, tools, dist, ref)
	if !ok {
		return
	}
	testing.expectf(t, abs(res.mean - theirs) <= 0.005, "ours %.5f, ffmpeg's %.5f (%s)", res.mean, theirs, ref)
	testing.expectf(t, res.mean < 0.999, "the distorted copy should score below 1: %.5f", res.mean)
}

@(test)
test_ssim_agrees_with_ffmpeg :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	dir := test_dir(t)
	ref := test_path(dir, "ref.mkv")
	dist := test_path(dir, "dist.mkv")
	// Two frames: a lossless reference and a lossy copy.
	if !ffmpeg_run(t, tools, "-f", "lavfi", "-i", "testsrc2=s=640x360:r=30", "-frames:v", "2", "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", ref) {
		return
	}
	if !ffmpeg_run(t, tools, "-i", ref, "-c:v", "libx264", "-crf", "30", "-preset", "veryfast", dist) {
		return
	}
	check_against_ffmpeg(t, tools, dir, ref, dist)

	// Two frames of the owner's footage when this machine has it.
	sample := "/home/nicolas/tessera-run/samples/hud-corner.avi"
	if !os.exists(sample) {
		return
	}
	sref := test_path(dir, "sref.mkv")
	sdist := test_path(dir, "sdist.mkv")
	if !ffmpeg_run(t, tools, "-ss", "12", "-i", sample, "-frames:v", "2", "-an", "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", sref) {
		return
	}
	if !ffmpeg_run(t, tools, "-i", sref, "-c:v", "libx264", "-crf", "32", "-preset", "veryfast", sdist) {
		return
	}
	check_against_ffmpeg(t, tools, dir, sref, sdist)
}
