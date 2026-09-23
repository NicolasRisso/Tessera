package tessera

import "core:math"
import "core:testing"

@(private = "file")
polygon_mask :: proc(w, h: int, pts: [][2]f32) -> Mask {
	r := raster_make(w, h)
	defer raster_delete(&r)
	for p, i in pts {
		raster_line(&r, p, pts[(i + 1) % len(pts)])
	}
	m := mask_make(w, h)
	raster_to_mask(&r, &m)
	return m
}

@(private = "file")
at :: proc(m: Mask, x, y: int) -> u8 {
	return m.a[y * m.w + x]
}

@(test)
test_raster_pixel_aligned_rectangle :: proc(t: ^testing.T) {
	// Both windings give the same coverage.
	for reverse in ([]bool{false, true}) {
		pts := [][2]f32{{2, 2}, {6, 2}, {6, 5}, {2, 5}}
		if reverse {
			pts = [][2]f32{{2, 2}, {2, 5}, {6, 5}, {6, 2}}
		}
		m := polygon_mask(10, 8, pts)
		defer mask_delete(&m)
		for y in 0 ..< 8 {
			for x in 0 ..< 10 {
				inside := x >= 2 && x < 6 && y >= 2 && y < 5
				want: u8 = 255 if inside else 0
				testing.expectf(t, at(m, x, y) == want, "reverse=%v (%d,%d) = %d, want %d", reverse, x, y, at(m, x, y), want)
			}
		}
	}
}

@(test)
test_raster_half_pixel_offset :: proc(t: ^testing.T) {
	m := polygon_mask(10, 8, {{2.5, 2}, {6.5, 2}, {6.5, 5}, {2.5, 5}})
	defer mask_delete(&m)
	for y in 2 ..< 5 {
		for x in 0 ..< 10 {
			v := int(at(m, x, y))
			switch x {
			case 2, 6:
				testing.expectf(t, v == 127 || v == 128, "edge (%d,%d) = %d, want half", x, y, v)
			case 3, 4, 5:
				testing.expectf(t, v == 255, "inside (%d,%d) = %d", x, y, v)
			case:
				testing.expectf(t, v == 0, "outside (%d,%d) = %d", x, y, v)
			}
		}
	}
}

@(test)
test_raster_triangle_area :: proc(t: ^testing.T) {
	pts := [][2]f32{{1.3, 1.7}, {37.2, 5.1}, {11.6, 29.4}}
	m := polygon_mask(40, 32, pts)
	defer mask_delete(&m)
	sum: f64
	for v in m.a {
		sum += f64(v) / 255
	}
	a, b, c := pts[0], pts[1], pts[2]
	area := abs(f64((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y))) / 2
	testing.expectf(t, abs(sum - area) / area < 0.005, "coverage %.3f vs area %.3f", sum, area)
}

@(test)
test_raster_quad_circle_area :: proc(t: ^testing.T) {
	// A circle of radius 10 from 8 quadratic arcs (themselves within 0.3 %
	// of the circle).
	r := raster_make(32, 32)
	defer raster_delete(&r)
	N :: 8
	R :: 10.0
	cx, cy: f32 = 16, 16
	k := R / math.cos(f32(3.14159265 / N))
	for i in 0 ..< N {
		a0 := f32(i) * 2 * 3.14159265 / N
		a1 := f32(i + 1) * 2 * 3.14159265 / N
		am := (a0 + a1) / 2
		p0 := [2]f32{cx + R * math.cos(a0), cy + R * math.sin(a0)}
		p1 := [2]f32{cx + R * math.cos(a1), cy + R * math.sin(a1)}
		c := [2]f32{cx + k * math.cos(am), cy + k * math.sin(am)}
		raster_quad(&r, p0, c, p1)
	}
	m := mask_make(32, 32)
	defer mask_delete(&m)
	raster_to_mask(&r, &m)
	sum: f64
	for v in m.a {
		sum += f64(v) / 255
	}
	// Chords lie inside the curve by at most the tolerance.
	hi := 3.14159265 * R * R * 1.005
	lo := 3.14159265 * (R - FLATTEN_TOLERANCE) * (R - FLATTEN_TOLERANCE)
	testing.expectf(t, sum >= lo && sum <= hi, "circle coverage %.2f, want %.2f..%.2f", sum, lo, hi)
}

@(test)
test_raster_glyph_has_ink :: proc(t: ^testing.T) {
	f, err := font_load(DEFAULT_FONT_DATA)
	testing.expect_value(t, err, nil)
	curves: [dynamic]Curve
	defer delete(curves)
	_ = glyph_outline(&f, glyph_index(&f, 'O'), &curves)
	scale := f32(48) / f32(f.units_per_em)
	m := rasterize_curves(curves[:], scale, 2, 40, 48, 48)
	defer mask_delete(&m)
	// An O is ink around a hole: its centre is empty, its sides full.
	testing.expectf(t, at(m, 16, 22) < 20, "centre of O = %d", at(m, 16, 22))
	full := 0
	for v in m.a {
		if v == 255 {
			full += 1
		}
	}
	testing.expectf(t, full > 50, "an O at 48 px has %d full pixels", full)
	free_all(context.temp_allocator)
}
