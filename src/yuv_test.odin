package tessera

import "core:testing"

@(private = "file")
yuv_of :: proc(c: [3]u8) -> [3]u8 {
	img := image_make(2, 2)
	defer image_delete(&img)
	for i := 0; i < len(img.pix); i += 3 {
		img.pix[i], img.pix[i + 1], img.pix[i + 2] = c[0], c[1], c[2]
	}
	out: [6]u8
	rgb_to_yuv420p(img, out[:], 0, 2)
	return {out[0], out[4], out[5]}
}

@(test)
test_yuv_reference_values :: proc(t: ^testing.T) {
	Case :: struct {
		rgb, yuv: [3]u8,
	}
	cases := []Case {
		{{0, 0, 0}, {16, 128, 128}},
		{{255, 255, 255}, {235, 128, 128}},
		{{255, 0, 0}, {63, 102, 240}},
		{{0, 255, 0}, {173, 42, 26}},
		{{0, 0, 255}, {32, 240, 118}},
	}
	for c in cases {
		got := yuv_of(c.rgb)
		for k in 0 ..< 3 {
			testing.expectf(t, abs(int(got[k]) - int(c.yuv[k])) <= 1, "%v → %v, want %v", c.rgb, got, c.yuv)
		}
	}
	// Exact where the table is exact.
	testing.expect_value(t, yuv_of({0, 0, 0}), [3]u8{16, 128, 128})
	testing.expect_value(t, yuv_of({255, 255, 255}), [3]u8{235, 128, 128})
}

TEST_COLOURS :: [][3]u8 {
	{0, 0, 0}, {255, 255, 255}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {128, 128, 128},
	{0x0B, 0x0F, 0x17}, {230, 180, 140}, {255, 255, 0}, {0, 255, 255}, {255, 0, 255}, {40, 90, 200},
}

@(test)
test_yuv_round_trip_through_ffmpeg :: proc(t: ^testing.T) {
	tools, found := test_tools(t)
	if !found {
		return
	}
	dir := test_dir(t)
	B :: 32 // block size: chroma is shared only inside a block
	n := len(TEST_COLOURS)
	img := image_make(B * n, B)
	defer image_delete(&img)
	for c, i in TEST_COLOURS {
		fill_rect(&img, {i * B, 0, B, B}, {c[0], c[1], c[2], 255}, image_rect(img))
	}
	frame := make([]u8, yuv_frame_size(img.w, img.h))
	defer delete(frame)
	rgb_to_yuv420p(img, frame, 0, img.h)

	out := test_path(dir, "rt.mkv")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tools.ffmpeg, "-nostdin", "-v", "error", "-y")
	append(&cmd, ..encoder_input_args(img.w, img.h, {1, 1}, context.temp_allocator))
	append(&cmd, "-c:v", "libx264", "-qp", "0", "-preset", "ultrafast")
	append(&cmd, ..COLOR_TAGS)
	append(&cmd, out)
	e, err := encoder_open(cmd[:], test_path(dir, "enc.log"))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, encoder_write(&e, frame), nil)
	testing.expect_value(t, encoder_close(&e), nil)

	p, perr := probe(tools, out)
	testing.expect_value(t, perr, nil)
	d, derr := decoder_open(tools, p, 0, test_path(dir, "dec.log"))
	testing.expect_value(t, derr, nil)
	back := image_make(img.w, img.h)
	defer image_delete(&back)
	testing.expect(t, decoder_read(&d, back.pix))
	_ = decoder_close(&d)
	for c, i in TEST_COLOURS {
		got := image_pixel(back, i * B + B / 2, B / 2)
		for k in 0 ..< 3 {
			testing.expectf(t, abs(int(got[k]) - int(c[k])) <= 2, "%v came back as %v", c, got)
		}
	}
}
