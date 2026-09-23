package tessera

import "core:testing"

@(private = "file")
constant_image :: proc(w, h: int, c: [3]u8) -> Image {
	img := image_make(w, h)
	for i := 0; i < len(img.pix); i += 3 {
		img.pix[i], img.pix[i + 1], img.pix[i + 2] = c[0], c[1], c[2]
	}
	return img
}

@(private = "file")
scale_to :: proc(src: Image, crop: Rect, w, h: int) -> Image {
	r := resampler_make(src.w, src.h, crop, w, h)
	defer resampler_delete(&r)
	out := image_make(w, h)
	resample(&r, src, &out, 0, 0)
	free_all(context.temp_allocator)
	return out
}

@(test)
test_resample_constant_stays_constant :: proc(t: ^testing.T) {
	src := constant_image(97, 61, {200, 17, 90})
	defer image_delete(&src)
	sizes := [][2]int{{31, 20}, {48, 30}, {97, 61}, {150, 90}, {400, 250}, {50, 200}}
	for s in sizes {
		out := scale_to(src, image_rect(src), s[0], s[1])
		defer image_delete(&out)
		for i := 0; i < len(out.pix); i += 3 {
			p := [3]u8{out.pix[i], out.pix[i + 1], out.pix[i + 2]}
			if p != {200, 17, 90} {
				testing.expectf(t, false, "%v: pixel %d is %v", s, i / 3, p)
				break
			}
		}
	}
}

@(test)
test_resample_weights_sum_to_one :: proc(t: ^testing.T) {
	cases := [][3]int{{0, 1280, 944}, {0, 720, 531}, {3, 100, 7}, {0, 640, 1920}, {10, 33, 34}, {0, 5, 5}, {0, 2, 1}}
	for c in cases {
		aw := axis_weights(c[0], c[1], c[2])
		defer axis_weights_delete(&aw)
		for i in 0 ..< c[2] {
			sum: f32
			n := int(aw.count[i])
			for w in aw.weight[i * aw.stride:][:n] {
				sum += w
			}
			testing.expectf(t, abs(sum - 1) <= 1e-5, "%v: row %d sums to %v", c, i, sum)
			first := int(aw.first[i])
			testing.expectf(t, first >= c[0] && first + n <= c[0] + c[1], "%v: row %d reads outside the source", c, i)
		}
	}
}

@(test)
test_resample_checkerboard_area_halves :: proc(t: ^testing.T) {
	src := image_make(64, 48)
	defer image_delete(&src)
	for y in 0 ..< src.h {
		for x in 0 ..< src.w {
			v: u8 = 255 if (x + y) % 2 == 0 else 0
			i := (y * src.w + x) * 3
			src.pix[i], src.pix[i + 1], src.pix[i + 2] = v, v, v
		}
	}
	out := scale_to(src, image_rect(src), 32, 24)
	defer image_delete(&out)
	for v, i in out.pix {
		if v != 127 && v != 128 {
			testing.expectf(t, false, "byte %d is %d, want 127 or 128", i, v)
			break
		}
	}
}

@(test)
test_resample_identity :: proc(t: ^testing.T) {
	src := image_make(40, 30)
	defer image_delete(&src)
	for &v, i in src.pix {
		v = u8((i * 37) % 251)
	}
	out := scale_to(src, image_rect(src), 40, 30)
	defer image_delete(&out)
	testing.expect(t, string(out.pix) == string(src.pix), "scale 1 is not a copy")

	// A crop at scale 1 is a copy of the crop.
	crop := Rect{5, 7, 20, 10}
	part := scale_to(src, crop, 20, 10)
	defer image_delete(&part)
	for y in 0 ..< 10 {
		for x in 0 ..< 20 {
			testing.expect(t, image_pixel(part, x, y) == image_pixel(src, x + 5, y + 7))
		}
	}
}

@(test)
test_resample_writes_only_its_rect :: proc(t: ^testing.T) {
	src := constant_image(16, 16, {255, 255, 255})
	defer image_delete(&src)
	dst := image_make(40, 40)
	defer image_delete(&dst)
	r := resampler_make(16, 16, image_rect(src), 10, 12)
	defer resampler_delete(&r)
	resample(&r, src, &dst, 5, 6)
	free_all(context.temp_allocator)
	for y in 0 ..< 40 {
		for x in 0 ..< 40 {
			inside := x >= 5 && x < 15 && y >= 6 && y < 18
			want: u8 = 255 if inside else 0
			if image_pixel(dst, x, y)[0] != want {
				testing.expectf(t, false, "(%d,%d) = %d", x, y, image_pixel(dst, x, y)[0])
				return
			}
		}
	}
}

@(test)
test_blend_mask_half :: proc(t: ^testing.T) {
	img := constant_image(4, 4, {0, 0, 0})
	defer image_delete(&img)
	m := mask_make(2, 2)
	defer mask_delete(&m)
	for &a in m.a {
		a = 255
	}
	blend_mask(&img, m, 1, 1, {255, 255, 255, 255}, 0.5, image_rect(img))
	testing.expect_value(t, image_pixel(img, 0, 0)[0], 0)
	v := image_pixel(img, 1, 1)[0]
	testing.expectf(t, v == 127 || v == 128, "half-blend is %d", v)
}
