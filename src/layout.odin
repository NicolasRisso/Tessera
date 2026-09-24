package tessera

import "core:math"

Fit :: enum {
	Contain, // letterbox the whole source inside the cell
	Cover,   // fill the cell, cropping the source's centre
}

DEFAULT_CANVAS_W :: 1920
DEFAULT_CANVAS_H :: 1080
DEFAULT_GAP      :: 8
DEFAULT_MARGIN   :: 16
MAX_CANVAS_W     :: 3840
MAX_CANVAS_H     :: 2160
DEFAULT_BG       :: Color{0x0B, 0x0F, 0x17, 255}

// grid_dims picks the grid that shows n cells of the given aspect (w/h) the
// largest on a canvas_w×canvas_h canvas. On a tie it prefers more columns on a
// wide canvas and more rows on a tall one.
grid_dims :: proc(n: int, canvas_w, canvas_h: int, cell_aspect: f32) -> (cols, rows: int) {
	if n <= 1 {
		return 1, 1
	}
	wide := canvas_w >= canvas_h
	best := -1.0
	for c in 1 ..= n {
		r := (n + c - 1) / c
		if (r - 1) * c >= n {
			continue // an empty row: the same as a smaller grid
		}
		cw := f64(canvas_w) / f64(c)
		ch := f64(canvas_h) / f64(r)
		w := min(cw, ch * f64(cell_aspect)) // the width a cell's picture gets
		area := w * w / f64(cell_aspect)
		// Within 1e-5 is a tie: cell_aspect is an f32.
		better := area > best * (1 + 1e-5)
		tie := !better && area >= best * (1 - 1e-5)
		if better || (tie && wide) { // c grows, so a tie on a wide canvas takes more columns
			best, cols, rows = area, c, r
		}
	}
	return
}

// cell_rects lays n equal cells out in a cols×rows grid inside canvas, with
// margin around the grid and gap between cells. Cells are filled row by row;
// a short last row is centred. Pixels that do not divide evenly go to the
// margins, so gaps are exact.
cell_rects :: proc(canvas: Rect, cols, rows, gap, margin: int, n: int, allocator := context.allocator) -> []Rect {
	rects := make([]Rect, n, allocator)
	inner_w := canvas.w - 2 * margin
	inner_h := canvas.h - 2 * margin
	cw := max((inner_w - gap * (cols - 1)) / cols, 1)
	ch := max((inner_h - gap * (rows - 1)) / rows, 1)
	grid_w := cols * cw + (cols - 1) * gap
	grid_h := rows * ch + (rows - 1) * gap
	x0 := canvas.x + (canvas.w - grid_w) / 2
	y0 := canvas.y + (canvas.h - grid_h) / 2
	for i in 0 ..< n {
		row, col := i / cols, i % cols
		in_row := min(cols, n - row * cols)
		shift := (cols - in_row) * (cw + gap) / 2
		rects[i] = Rect{x0 + shift + col * (cw + gap), y0 + row * (ch + gap), cw, ch}
	}
	return rects
}

// fit_rect places a src_w×src_h source in cell. dst is where it lands on the
// canvas, crop the part of the source that is shown.
fit_rect :: proc(src_w, src_h: int, cell: Rect, fit: Fit) -> (dst: Rect, crop: Rect) {
	sw, sh := f64(src_w), f64(src_h)
	switch fit {
	case .Contain:
		s := min(f64(cell.w) / sw, f64(cell.h) / sh)
		w := clamp(int(math.round(sw * s)), 1, cell.w)
		h := clamp(int(math.round(sh * s)), 1, cell.h)
		dst = Rect{cell.x + (cell.w - w) / 2, cell.y + (cell.h - h) / 2, w, h}
		crop = Rect{0, 0, src_w, src_h}
	case .Cover:
		s := max(f64(cell.w) / sw, f64(cell.h) / sh)
		w := clamp(int(math.round(f64(cell.w) / s)), 1, src_w)
		h := clamp(int(math.round(f64(cell.h) / s)), 1, src_h)
		dst = cell
		crop = Rect{(src_w - w) / 2, (src_h - h) / 2, w, h}
	}
	return
}

// Placement is where a cell's picture lands (dst), the part of its source
// shown (crop), and the strip its label takes (empty when none).
Placement :: struct {
	dst, crop, strip: Rect,
}

// place_pictures fits each picture in its cell. With a label strip of
// label_h above or below, the picture fits in the cell less the strip, and
// the strip spans the picture's width on that side. The pictures of a row
// align on the strip's side, so a row's strips share a y and each hugs its
// picture; the block is centred in the cell. With label_h 0 or Inside,
// every picture is fitted in its whole cell (v1).
place_pictures :: proc(cells: []Rect, sizes: [][2]int, fits: []Fit, cols, label_h: int, pos: Label_Pos, allocator := context.allocator) -> []Placement {
	ps := make([]Placement, len(cells), allocator)
	if label_h <= 0 || pos == .Inside {
		for c, i in cells {
			ps[i].dst, ps[i].crop = fit_rect(sizes[i][0], sizes[i][1], c, fits[i])
		}
		return ps
	}
	for c, i in cells {
		lh := min(label_h, c.h - 1)
		area := Rect{c.x, c.y + lh if pos == .Above else c.y, c.w, c.h - lh}
		ps[i].dst, ps[i].crop = fit_rect(sizes[i][0], sizes[i][1], area, fits[i])
	}
	for row0 := 0; row0 < len(cells); row0 += cols {
		row := ps[row0:min(row0 + cols, len(cells))]
		pic_h := 0
		for p in row {
			pic_h = max(pic_h, p.dst.h)
		}
		for &p, j in row {
			c := cells[row0 + j]
			lh := min(label_h, c.h - 1)
			top := c.y + (c.h - pic_h - lh) / 2
			if pos == .Above {
				p.strip = Rect{p.dst.x, top, p.dst.w, lh}
				p.dst.y = top + lh
			} else {
				p.dst.y = top + pic_h - p.dst.h
				p.strip = Rect{p.dst.x, top + pic_h, p.dst.w, lh}
			}
		}
	}
	return ps
}

// native_canvas sizes the canvas so that a cols×rows grid of cell_w×cell_h
// cells shows them 1:1, plus extra_h rows of pixels above the grid (a title
// band). Capped at 3840×2160 keeping the aspect; dimensions are even.
native_canvas :: proc(cols, rows, cell_w, cell_h, gap, margin, extra_h: int) -> (w, h: int) {
	w = cols * cell_w + (cols - 1) * gap + 2 * margin
	h = rows * cell_h + (rows - 1) * gap + 2 * margin + extra_h
	if w > MAX_CANVAS_W || h > MAX_CANVAS_H {
		s := min(f64(MAX_CANVAS_W) / f64(w), f64(MAX_CANVAS_H) / f64(h))
		w = int(f64(w) * s)
		h = int(f64(h) * s)
	}
	return even(w), even(h)
}

even :: proc(v: int) -> int {
	return max(v &~ 1, 2)
}
