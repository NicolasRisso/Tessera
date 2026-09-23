package tessera

import "core:math"

// Outline → anti-aliased coverage, the font-rs method: every line adds its
// signed area to an accumulation buffer, and a running sum along each row
// turns that into coverage min(1, |sum|). Quadratic curves are flattened to
// lines first. Coordinates are pixels, y down.

Raster :: struct {
	w, h:   int,
	stride: int, // w + 2: a line's area can land up to two cells right of x
	acc:    []f32,
}

raster_make :: proc(w, h: int, allocator := context.allocator) -> Raster {
	return Raster{w = w, h = h, stride = w + 2, acc = make([]f32, (w + 2) * h, allocator)}
}

raster_delete :: proc(r: ^Raster) {
	delete(r.acc)
	r^ = {}
}

raster_clear :: proc(r: ^Raster) {
	for &v in r.acc {
		v = 0
	}
}

// raster_line accumulates the signed area of the line p0→p1.
raster_line :: proc(r: ^Raster, p0, p1: [2]f32) {
	if abs(p0.y - p1.y) <= 1e-6 {
		return
	}
	dir: f32 = 1
	a, b := p0, p1
	if a.y > b.y {
		dir = -1
		a, b = b, a
	}
	// Outside the canvas in x the area still counts, at the edge.
	a.x = clamp(a.x, 0, f32(r.w))
	b.x = clamp(b.x, 0, f32(r.w))
	dxdy := (b.x - a.x) / (b.y - a.y)
	x := a.x
	if a.y < 0 {
		x -= a.y * dxdy
	}
	y0 := max(int(a.y), 0)
	y1 := min(int(math.ceil(b.y)), r.h)
	for y in y0 ..< y1 {
		row := r.acc[y * r.stride:][:r.stride]
		dy := min(f32(y + 1), b.y) - max(f32(y), a.y)
		xnext := x + dxdy * dy
		d := dy * dir
		x0, x1 := x, xnext
		if x0 > x1 {
			x0, x1 = x1, x0
		}
		x0floor := math.floor(x0)
		x0i := int(x0floor)
		x1ceil := math.ceil(x1)
		x1i := int(x1ceil)
		if x1i <= x0i + 1 {
			// The line stays within one pixel column on this row.
			xmf := 0.5 * (x + xnext) - x0floor
			row[x0i] += d - d * xmf
			row[x0i + 1] += d * xmf
		} else {
			s := 1 / (x1 - x0)
			x0f := x0 - x0floor
			a0 := 0.5 * s * (1 - x0f) * (1 - x0f)
			x1f := x1 - x1ceil + 1
			am := 0.5 * s * x1f * x1f
			row[x0i] += d * a0
			if x1i == x0i + 2 {
				row[x0i + 1] += d * (1 - a0 - am)
			} else {
				a1 := s * (1.5 - x0f)
				row[x0i + 1] += d * (a1 - a0)
				for xi in x0i + 2 ..< x1i - 1 {
					row[xi] += d * s
				}
				a2 := a1 + f32(x1i - x0i - 3) * s
				row[x1i - 1] += d * (1 - a2 - am)
			}
			row[x1i] += d * am
		}
		x = xnext
	}
}

// FLATTEN_TOLERANCE is the largest distance, in pixels, between a curve and
// the lines that stand for it.
FLATTEN_TOLERANCE :: 0.2

// raster_quad flattens the quadratic p0→c→p1 into lines. B'' = 2(p0 − 2c +
// p1), so a chord over 1/n of the curve strays at most |p0 − 2c + p1| / (4n²)
// from it: n follows from the control point's distance to the chord.
raster_quad :: proc(r: ^Raster, p0, c, p1: [2]f32) {
	dev := p0 - 2 * c + p1
	devlen := math.sqrt(dev.x * dev.x + dev.y * dev.y)
	n := int(math.ceil(math.sqrt(devlen / (4 * FLATTEN_TOLERANCE))))
	if n <= 1 {
		raster_line(r, p0, p1)
		return
	}
	n = min(n, 64)
	prev := p0
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		p := u * u * p0 + 2 * u * t * c + t * t * p1
		raster_line(r, prev, p)
		prev = p
	}
}

// raster_to_mask sums each row into coverage and writes it to m (w×h).
raster_to_mask :: proc(r: ^Raster, m: ^Mask) {
	assert(m.w == r.w && m.h == r.h)
	for y in 0 ..< r.h {
		row := r.acc[y * r.stride:][:r.stride]
		out := m.a[y * r.w:][:r.w]
		sum: f32
		for x in 0 ..< r.w {
			sum += row[x]
			out[x] = u8(min(abs(sum), 1) * 255 + 0.5)
		}
	}
}

// rasterize_curves draws font-unit curves as a w×h mask: a point p lands at
// (p.x·scale + dx, dy − p.y·scale), flipping y up to y down.
rasterize_curves :: proc(curves: []Curve, scale, dx, dy: f32, w, h: int, allocator := context.allocator) -> Mask {
	m := mask_make(w, h, allocator)
	if w <= 0 || h <= 0 {
		return m
	}
	r := raster_make(w, h, context.temp_allocator)
	tr :: #force_inline proc(p: [2]f32, scale, dx, dy: f32) -> [2]f32 {
		return {p.x * scale + dx, dy - p.y * scale}
	}
	for c in curves {
		p0 := tr(c.p0, scale, dx, dy)
		p1 := tr(c.p1, scale, dx, dy)
		if c.line {
			raster_line(&r, p0, p1)
		} else {
			raster_quad(&r, p0, tr(c.c, scale, dx, dy), p1)
		}
	}
	raster_to_mask(&r, &m)
	return m
}
