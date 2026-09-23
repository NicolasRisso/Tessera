package tessera

import "core:os"
import "core:path/filepath"
import "core:testing"

// test_dir makes a temporary directory removed when the test ends.
test_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "tessera-test-*", context.allocator)
	testing.expectf(t, err == nil, "temp dir: %v", err)
	testing.cleanup(t, proc(p: rawptr) {
		d := (^string)(p)^
		_ = os.remove_all(d)
		delete(d)
	}, new_clone(dir))
	return dir
}

test_path :: proc(dir, name: string) -> string {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	return p
}

// test_tools finds ffmpeg the way the program does, failing the test if absent.
test_tools :: proc(t: ^testing.T) -> (Tools, bool) {
	tools, err := find_tools("")
	if err != nil {
		testing.expectf(t, false, "%s", err.?)
		return {}, false
	}
	return tools, true
}

// ffmpeg_run runs ffmpeg with args and fails the test on error.
ffmpeg_run :: proc(t: ^testing.T, tools: Tools, args: ..string) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, ..args)
	out, err := capture(cmd[:])
	delete(out)
	if err != nil {
		testing.expectf(t, false, "%s", err.?)
		return false
	}
	return true
}

@(test)
test_decoder_frame_exact :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	dir := test_dir(t)
	src := test_path(dir, "src.nut")
	ref := test_path(dir, "ref.rgb")
	// A lossless source, and ffmpeg's own RGB decode of the same frames.
	if !ffmpeg_run(t, tools, "-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=1", "-c:v", "ffv1", "-pix_fmt", "bgr0", src) {
		return
	}
	if !ffmpeg_run(t, tools, "-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=1", "-f", "rawvideo", "-pix_fmt", "rgb24", ref) {
		return
	}

	p, perr := probe(tools, src)
	testing.expectf(t, perr == nil, "probe: %v", perr)
	testing.expect_value(t, p.width, 320)
	testing.expect_value(t, p.height, 240)
	testing.expect_value(t, p.fps, Rational{30, 1})
	testing.expect_value(t, p.frames, 30)
	testing.expect(t, !p.still && !p.vfr)

	want, _ := os.read_entire_file(ref, context.allocator)
	defer delete(want)
	d, derr := decoder_open(tools, p, 0, test_path(dir, "dec.log"))
	testing.expectf(t, derr == nil, "decoder: %v", derr)
	buf := make([]u8, d.frame_bytes)
	defer delete(buf)
	n := 0
	for decoder_read(&d, buf) {
		if (n + 1) * d.frame_bytes <= len(want) {
			testing.expectf(t, string(buf) == string(want[n * d.frame_bytes:][:d.frame_bytes]), "frame %d differs", n)
		}
		n += 1
	}
	testing.expect_value(t, n, 30)
	testing.expect_value(t, decoder_close(&d), nil)
}

@(test)
test_decoder_start_offset :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	dir := test_dir(t)
	src := test_path(dir, "src.nut")
	if !ffmpeg_run(t, tools, "-f", "lavfi", "-i", "testsrc2=s=160x120:r=10:d=2", "-c:v", "ffv1", src) {
		return
	}
	p, _ := probe(tools, src)
	d, _ := decoder_open(tools, p, 0.5, test_path(dir, "dec.log"))
	buf := make([]u8, d.frame_bytes)
	defer delete(buf)
	n := 0
	for decoder_read(&d, buf) {
		n += 1
	}
	testing.expect_value(t, n, 15)
	testing.expect_value(t, decoder_close(&d), nil)
}

@(test)
test_probe_still :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	dir := test_dir(t)
	png := test_path(dir, "still.png")
	if !ffmpeg_run(t, tools, "-f", "lavfi", "-i", "color=c=blue:s=64x48", "-frames:v", "1", png) {
		return
	}
	p, err := probe(tools, png)
	testing.expectf(t, err == nil, "probe: %v", err)
	testing.expect(t, p.still, "a png is a still")
	testing.expect_value(t, p.frames, 1)
	d, _ := decoder_open(tools, p, 3, test_path(dir, "dec.log"))
	buf := make([]u8, d.frame_bytes)
	defer delete(buf)
	testing.expect(t, decoder_read(&d, buf))
	testing.expectf(t, buf[0] <= 2 && buf[1] <= 2 && buf[2] >= 253, "blue decodes as %v", buf[:3])
	testing.expect(t, !decoder_read(&d, buf))
	testing.expect_value(t, decoder_close(&d), nil)
}

@(test)
test_encoder_writes_a_video :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	testing.expect_value(t, require_encoder(&tools, "libx264"), nil)
	testing.expect(t, require_encoder(&tools, "no-such-encoder") != nil)
	dir := test_dir(t)
	out := test_path(dir, "out.mp4")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, ..encoder_input_args(64, 48, {25, 1}, context.temp_allocator))
	append(&cmd, "-c:v", "libx264", "-qp", "0", "-preset", "ultrafast", out)
	e, err := encoder_open(cmd[:], test_path(dir, "enc.log"))
	testing.expectf(t, err == nil, "encoder: %v", err)
	frame := make([]u8, 64 * 48 * 3 / 2)
	defer delete(frame)
	for i in 0 ..< 10 {
		for &v in frame {
			v = u8(16 + i * 10)
		}
		testing.expect_value(t, encoder_write(&e, frame), nil)
	}
	testing.expect_value(t, encoder_close(&e), nil)
	p, perr := probe(tools, out)
	testing.expectf(t, perr == nil, "probe: %v", perr)
	testing.expect_value(t, p.frames, 10)
	testing.expect_value(t, p.width, 64)
	testing.expect_value(t, p.fps, Rational{25, 1})
}

@(test)
test_encoder_failure_is_reported :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	dir := test_dir(t)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, ..encoder_input_args(64, 48, {25, 1}, context.temp_allocator))
	append(&cmd, "-c:v", "no-such-codec", test_path(dir, "x.mp4"))
	e, _ := encoder_open(cmd[:], test_path(dir, "enc.log"))
	frame := make([]u8, 64 * 48 * 3 / 2)
	defer delete(frame)
	failed := false
	for _ in 0 ..< 2000 {
		if encoder_write(&e, frame) != nil {
			failed = true
			break
		}
	}
	if !failed {
		failed = encoder_close(&e) != nil
	}
	testing.expect(t, failed, "a bad encoder must fail")
}

@(test)
test_parse_probe_vfr :: proc(t: ^testing.T) {
	text := `{"streams":[{"codec_name":"h264","width":640,"height":360,"pix_fmt":"yuv420p","r_frame_rate":"60/1","avg_frame_rate":"30000/1001","nb_frames":"300"}],"format":{"format_name":"mov,mp4","duration":"10.01"}}`
	p, err := parse_probe("x.mp4", text)
	testing.expect_value(t, err, nil)
	testing.expect(t, p.vfr)
	testing.expect_value(t, p.frames, 300)
	cmd := decoder_command(Tools{ffmpeg = "ffmpeg"}, p, 0, context.temp_allocator)
	found := false
	for a, i in cmd {
		if a == "-fps_mode" && cmd[i + 1] == "cfr" {
			found = true
		}
	}
	testing.expect(t, found, "a vfr source is decoded with -fps_mode cfr")
}
