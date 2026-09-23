package tessera

import "core:testing"

@(test)
test_grid_dims_16_9 :: proc(t: ^testing.T) {
	want := [17][2]int {
		{}, {1, 1}, {2, 1}, {2, 2}, {2, 2}, {3, 2}, {3, 2}, {3, 3}, {3, 3}, {3, 3},
		{4, 3}, {4, 3}, {4, 3}, {4, 4}, {4, 4}, {4, 4}, {4, 4},
	}
	for n in 1 ..= 16 {
		c, r := grid_dims(n, 1920, 1080, 16.0 / 9.0)
		testing.expectf(t, [2]int{c, r} == want[n], "n=%d: got %dx%d, want %dx%d", n, c, r, want[n][0], want[n][1])
	}
}

@(test)
test_cell_rects_inside_disjoint_gaps :: proc(t: ^testing.T) {
	canvas := Rect{0, 0, 1920, 1080}
	for n in 1 ..= 16 {
		cols, rows := grid_dims(n, canvas.w, canvas.h, 16.0 / 9.0)
		rects := cell_rects(canvas, cols, rows, 8, 16, n)
		defer delete(rects)
		for a, i in rects {
			testing.expectf(t, a.x >= 16 && a.y >= 16 && a.x + a.w <= 1904 && a.y + a.h <= 1064, "n=%d cell %d %v outside", n, i, a)
			for b, j in rects[i + 1:] {
				testing.expectf(t, rect_empty(rect_intersect(a, b)), "n=%d cells %d and %d overlap", n, i, i + 1 + j)
			}
			// The horizontal neighbour in the same row is exactly one gap away.
			if i + 1 < n && (i + 1) % cols != 0 {
				b := rects[i + 1]
				testing.expectf(t, b.x - (a.x + a.w) == 8 && b.y == a.y, "n=%d gap after cell %d is %d", n, i, b.x - (a.x + a.w))
			}
			if i + cols < n {
				b := rects[i + cols]
				testing.expectf(t, b.y - (a.y + a.h) == 8, "n=%d vertical gap under cell %d is %d", n, i, b.y - (a.y + a.h))
			}
		}
	}
	// A short last row is centred.
	rects := cell_rects(canvas, 2, 2, 8, 16, 3)
	defer delete(rects)
	mid := rects[2].x + rects[2].w / 2
	testing.expectf(t, abs(mid - 960) <= 1, "last row centred at %d", mid)
}

@(test)
test_fit_rect_keeps_aspect :: proc(t: ^testing.T) {
	cells := []Rect{{0, 0, 940, 520}, {10, 20, 300, 600}, {0, 0, 1000, 100}, {5, 5, 77, 77}}
	sources := [][2]int{{1280, 720}, {640, 480}, {800, 600}, {1080, 1920}, {3, 1}}
	for cell in cells {
		for s in sources {
			dst, crop := fit_rect(s[0], s[1], cell, .Contain)
			testing.expect(t, crop == Rect{0, 0, s[0], s[1]})
			testing.expectf(t, dst.x >= cell.x && dst.y >= cell.y && dst.x + dst.w <= cell.x + cell.w && dst.y + dst.h <= cell.y + cell.h, "contain %v in %v escapes: %v", s, cell, dst)
			testing.expectf(t, dst.w == cell.w || dst.h == cell.h, "contain %v in %v fills neither side: %v", s, cell, dst)
			// dst.h against the height the source's aspect implies, within 1 px.
			ideal_h := f64(dst.w) * f64(s[1]) / f64(s[0])
			testing.expectf(t, abs(f64(dst.h) - ideal_h) <= 1 || abs(f64(dst.w) - f64(dst.h) * f64(s[0]) / f64(s[1])) <= 1, "contain %v in %v: %v", s, cell, dst)

			dst, crop = fit_rect(s[0], s[1], cell, .Cover)
			testing.expect(t, dst == cell)
			testing.expectf(t, crop.x >= 0 && crop.y >= 0 && crop.x + crop.w <= s[0] && crop.y + crop.h <= s[1], "cover crop %v of %v", crop, s)
			ideal_w := f64(crop.h) * f64(cell.w) / f64(cell.h)
			testing.expectf(t, abs(f64(crop.w) - ideal_w) <= 1 || abs(f64(crop.h) - f64(crop.w) * f64(cell.h) / f64(cell.w)) <= 1, "cover %v in %v: crop %v", s, cell, crop)
		}
	}
}

@(test)
test_native_canvas :: proc(t: ^testing.T) {
	w, h := native_canvas(2, 2, 1280, 720, 8, 16, 0)
	testing.expect_value(t, w, 2600)
	testing.expect_value(t, h, 1480)
	w, h = native_canvas(4, 4, 1280, 720, 8, 16, 0)
	testing.expectf(t, w <= 3840 && h <= 2160 && w % 2 == 0 && h % 2 == 0, "capped to %dx%d", w, h)
}
