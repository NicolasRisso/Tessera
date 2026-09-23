package tessera

import "core:math"

// Text: UTF-8 → glyphs → one coverage mask per string, then the effects as
// more masks (outline, shadow, box). A Sprite is a text ready to draw: its
// layers are made once per scene and blended every frame with the text's
// fade.

// Glyphs are cached per (glyph, size, quarter-pixel x offset), so spacing is
// kept to a quarter pixel without rasterising every placement.
SUBPIXEL_STEPS :: 4

Glyph_Key :: struct {
	glyph: int,
	size:  i32, // pixel size × 64
	sub:   i32, // 0 ..< SUBPIXEL_STEPS
}

Glyph_Bitmap :: struct {
	mask:      Mask,
	left, top: int, // the mask's top left is at (pen + left, baseline − top)
}

Text_Engine :: struct {
	font:      Font,
	cache:     map[Glyph_Key]Glyph_Bitmap,
	cap_top:   f32, // ink top of 'H', font units above the baseline
	ink_foot:  f32, // ink bottom of 'g', font units below the baseline (positive)
	curves:    [dynamic]Curve,
}

text_engine_init :: proc(te: ^Text_Engine, font: Font) {
	te.font = font
	te.cap_top = f32(font.ascender) * 0.75
	te.ink_foot = f32(-font.descender) * 0.8
	if top, _, ok := glyph_ink_y(te, 'H'); ok {
		te.cap_top = top
	}
	if _, bottom, ok := glyph_ink_y(te, 'g'); ok {
		te.ink_foot = -bottom
	}
}

text_engine_destroy :: proc(te: ^Text_Engine) {
	for _, &b in te.cache {
		mask_delete(&b.mask)
	}
	delete(te.cache)
	delete(te.curves)
}

@(private = "file")
glyph_ink_y :: proc(te: ^Text_Engine, cp: rune) -> (top, bottom: f32, ok: bool) {
	g := glyph_index(&te.font, cp)
	if g == 0 {
		return
	}
	clear(&te.curves)
	if glyph_outline(&te.font, g, &te.curves) != nil || len(te.curves) == 0 {
		return
	}
	top, bottom = -1e9, 1e9
	for c in te.curves {
		for p in ([][2]f32{c.p0, c.c, c.p1}) {
			top = max(top, p.y)
			bottom = min(bottom, p.y)
		}
	}
	return top, bottom, true
}

// glyph_bitmap rasterises (or finds) glyph g at size px, shifted right by
// sub/SUBPIXEL_STEPS of a pixel.
glyph_bitmap :: proc(te: ^Text_Engine, g: int, size: f32, sub: int) -> ^Glyph_Bitmap {
	key := Glyph_Key{g, i32(size * 64 + 0.5), i32(sub)}
	if b, ok := &te.cache[key]; ok {
		return b
	}
	clear(&te.curves)
	_ = glyph_outline(&te.font, g, &te.curves) // a broken glyph draws as nothing
	b: Glyph_Bitmap
	if len(te.curves) > 0 {
		scale := size / f32(te.font.units_per_em)
		fx := f32(sub) / SUBPIXEL_STEPS
		xmin, ymin: f32 = 1e9, 1e9
		xmax, ymax: f32 = -1e9, -1e9
		for c in te.curves {
			for p in ([][2]f32{c.p0, c.c, c.p1}) {
				xmin, xmax = min(xmin, p.x), max(xmax, p.x)
				ymin, ymax = min(ymin, p.y), max(ymax, p.y)
			}
		}
		b.left = int(math.floor(xmin * scale + fx))
		right := int(math.ceil(xmax * scale + fx))
		b.top = int(math.ceil(ymax * scale))
		bottom := int(math.floor(ymin * scale))
		b.mask = rasterize_curves(te.curves[:], scale, fx - f32(b.left), f32(b.top), right - b.left, b.top - bottom)
	}
	te.cache[key] = b
	return &te.cache[key]
}

Placed_Glyph :: struct {
	glyph: int,
	x:     f32, // pen position from the line's start, pixels
	line:  int,
}

Text_Layout :: struct {
	glyphs:      [dynamic]Placed_Glyph,
	line_widths: [dynamic]f32,
	width:       f32, // the widest line
	line_height: f32,
	lines:       int,
}

layout_delete :: proc(l: ^Text_Layout) {
	delete(l.glyphs)
	delete(l.line_widths)
}

// layout_text places each code point's glyph: advances plus kerning, '\n'
// starting a new line one line height down. Invalid UTF-8 decodes as U+FFFD;
// a missing glyph is glyph 0.
layout_text :: proc(te: ^Text_Engine, text: string, size: f32, allocator := context.allocator) -> Text_Layout {
	l: Text_Layout
	l.glyphs = make([dynamic]Placed_Glyph, allocator)
	l.line_widths = make([dynamic]f32, allocator)
	f := &te.font
	scale := size / f32(f.units_per_em)
	l.line_height = f32(f.ascender - f.descender + f.line_gap) * scale
	pen: f32
	prev := -1
	line := 0
	for r in text {
		if r == '\n' {
			append(&l.line_widths, pen)
			pen = 0
			prev = -1
			line += 1
			continue
		}
		if r == '\r' {
			continue
		}
		g := glyph_index(f, r)
		if prev >= 0 {
			pen += f32(kerning(f, prev, g)) * scale
		}
		append(&l.glyphs, Placed_Glyph{g, pen, line})
		pen += f32(glyph_advance(f, g)) * scale
		prev = g
	}
	append(&l.line_widths, pen)
	l.lines = line + 1
	for w in l.line_widths {
		l.width = max(l.width, w)
	}
	return l
}

// Sprite_Layer is one mask drawn in one colour, offset from the sprite.
Sprite_Layer :: struct {
	mask:   Mask,
	color:  Color,
	dx, dy: int,
}

Sprite :: struct {
	x, y:     int, // canvas position of the layers' common top left
	layers:   [dynamic]Sprite_Layer, // drawn in order: box, shadow, outline, fill
	from, to: f64, // to <= 0: until the scene ends
	fade:     f64,
}

sprite_delete :: proc(s: ^Sprite) {
	for &l in s.layers {
		mask_delete(&l.mask)
	}
	delete(s.layers)
}

// resolve_coord turns a Coord into pixels along an axis of length n.
resolve_coord :: proc(c: Coord, n: int) -> f32 {
	return c.value * f32(n) if c.fraction else c.value
}

// make_sprite renders t for a canvas_w×canvas_h canvas.
make_sprite :: proc(te: ^Text_Engine, t: Text, canvas_w, canvas_h: int) -> Sprite {
	sp := Sprite{from = t.from, to = t.to, fade = t.fade}
	if t.text == "" || t.size <= 0 {
		return sp
	}
	size := t.size
	scale := size / f32(te.font.units_per_em)
	l := layout_text(te, t.text, size, context.temp_allocator)

	// The frame: cap top of the first line to the ink foot of the last, the
	// widest line across. Lines align within it by the anchor's column.
	cap := te.cap_top * scale
	foot := te.ink_foot * scale
	frame_w := l.width
	frame_h := cap + f32(l.lines - 1) * l.line_height + foot
	col := int(t.anchor) % 3
	row := int(t.anchor) / 3
	line_x :: proc(l: Text_Layout, line, col: int) -> f32 {
		return (l.width - l.line_widths[line]) * f32(col) / 2
	}

	// Where each glyph lands, in frame pixels, and the ink's bounds.
	Placed :: struct {
		bm:   Glyph_Bitmap, // a copy: the cache's map may move as it grows
		x, y: int,
	}
	placed := make([dynamic]Placed, context.temp_allocator)
	ink := Rect{}
	for pg in l.glyphs {
		x := line_x(l, pg.line, col) + pg.x
		base := int(math.round(cap + f32(pg.line) * l.line_height))
		xi := int(math.floor(x))
		sub := int(math.round((x - f32(xi)) * SUBPIXEL_STEPS))
		if sub == SUBPIXEL_STEPS {
			xi, sub = xi + 1, 0
		}
		bm := glyph_bitmap(te, pg.glyph, size, sub)^
		if bm.mask.w == 0 || bm.mask.h == 0 {
			continue
		}
		p := Placed{bm, xi + bm.left, base - bm.top}
		append(&placed, p)
		r := Rect{p.x, p.y, bm.mask.w, bm.mask.h}
		ink = r if rect_empty(ink) else rect_union(ink, r)
	}
	frame := Rect{0, 0, int(math.ceil(frame_w)), int(math.ceil(frame_h))}
	extent := rect_union(frame, ink) if !rect_empty(ink) else frame

	outline := max(t.outline_px, 0)
	blur := max(t.shadow_blur, 0)
	has_shadow := t.shadow_color.a > 0 && (t.shadow_dx != 0 || t.shadow_dy != 0 || blur > 0)
	has_box := t.box_color.a > 0
	pad := int(math.ceil(outline)) + 1
	if has_shadow {
		pad += int(math.ceil(blur)) * 2 + int(math.ceil(max(abs(t.shadow_dx), abs(t.shadow_dy))))
	}
	if has_box {
		pad = max(pad, int(math.ceil(t.box_pad)) + 1)
	}
	area := Rect{extent.x - pad, extent.y - pad, extent.w + 2 * pad, extent.h + 2 * pad}

	fill := mask_make(area.w, area.h)
	for p in placed {
		add_mask(&fill, p.bm.mask, p.x - area.x, p.y - area.y)
	}

	// Anchor the frame at (x, y).
	ax := resolve_coord(t.x, canvas_w) - f32(frame.w) * f32(col) / 2
	ay := resolve_coord(t.y, canvas_h) - f32(frame.h) * f32(row) / 2
	sp.x = int(math.round(ax)) + area.x
	sp.y = int(math.round(ay)) + area.y

	if has_box {
		bp := int(math.round(t.box_pad))
		box := Rect{extent.x - bp - area.x, extent.y - bp - area.y, extent.w + 2 * bp, extent.h + 2 * bp}
		append(&sp.layers, Sprite_Layer{rounded_rect_mask(area.w, area.h, box, t.box_radius), t.box_color, 0, 0})
	}
	body := fill
	outline_mask: Mask
	if outline > 0 {
		outline_mask = dilate(fill, outline)
		body = outline_mask
	}
	if has_shadow {
		shadow := mask_make(area.w, area.h)
		copy(shadow.a, body.a)
		if blur > 0 {
			box_blur(&shadow, int(math.round(blur)))
			box_blur(&shadow, int(math.round(blur)))
		}
		append(&sp.layers, Sprite_Layer{shadow, t.shadow_color, int(math.round(t.shadow_dx)), int(math.round(t.shadow_dy))})
	}
	if outline > 0 {
		append(&sp.layers, Sprite_Layer{outline_mask, t.outline_color, 0, 0})
	}
	append(&sp.layers, Sprite_Layer{fill, t.color, 0, 0})
	return sp
}

rect_union :: proc(a, b: Rect) -> Rect {
	x0 := min(a.x, b.x)
	y0 := min(a.y, b.y)
	x1 := max(a.x + a.w, b.x + b.w)
	y1 := max(a.y + a.h, b.y + b.h)
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// add_mask adds src into dst at (x, y), saturating: glyphs that touch share
// their edge pixels' coverage.
add_mask :: proc(dst: ^Mask, src: Mask, x, y: int) {
	for sy in 0 ..< src.h {
		dy := y + sy
		if dy < 0 || dy >= dst.h {
			continue
		}
		for sx in 0 ..< src.w {
			dx := x + sx
			if dx < 0 || dx >= dst.w {
				continue
			}
			i := dy * dst.w + dx
			dst.a[i] = u8(min(int(dst.a[i]) + int(src.a[sy * src.w + sx]), 255))
		}
	}
}

// dilate grows a mask by a disc of radius r, anti-aliased at the rim.
dilate :: proc(m: Mask, r: f32) -> Mask {
	out := mask_make(m.w, m.h)
	ri := int(math.ceil(r))
	Tap :: struct {
		dx, dy: int,
		w:      f32,
	}
	taps := make([dynamic]Tap, context.temp_allocator)
	for dy in -ri ..= ri {
		for dx in -ri ..= ri {
			d := math.sqrt(f32(dx * dx + dy * dy))
			w := clamp(r + 0.5 - d, 0, 1)
			if w > 0 {
				append(&taps, Tap{dx, dy, w})
			}
		}
	}
	for y in 0 ..< m.h {
		for x in 0 ..< m.w {
			best: f32
			for t in taps {
				sx, sy := x + t.dx, y + t.dy
				if sx < 0 || sy < 0 || sx >= m.w || sy >= m.h {
					continue
				}
				v := f32(m.a[sy * m.w + sx]) * t.w
				best = max(best, v)
			}
			out.a[y * m.w + x] = u8(best + 0.5)
		}
	}
	return out
}

// box_blur blurs a mask in place with a (2r+1)-wide box, horizontally then
// vertically.
box_blur :: proc(m: ^Mask, r: int) {
	if r <= 0 {
		return
	}
	n := max(m.w, m.h)
	tmp := make([]u32, n, context.temp_allocator)
	win := u32(2 * r + 1)
	// Rows.
	for y in 0 ..< m.h {
		row := m.a[y * m.w:][:m.w]
		for x in 0 ..< m.w {
			tmp[x] = u32(row[x])
		}
		sum: u32
		for x in -r ..< m.w + r + 1 {
			if x >= 0 && x < m.w {
				sum += tmp[x]
			}
			out := x - r
			if out >= 0 && out < m.w {
				row[out] = u8((sum + win / 2) / win)
			}
			drop := x - 2 * r
			if drop >= 0 && drop < m.w {
				sum -= tmp[drop]
			}
		}
	}
	// Columns.
	for x in 0 ..< m.w {
		for y in 0 ..< m.h {
			tmp[y] = u32(m.a[y * m.w + x])
		}
		sum: u32
		for y in -r ..< m.h + r + 1 {
			if y >= 0 && y < m.h {
				sum += tmp[y]
			}
			out := y - r
			if out >= 0 && out < m.h {
				m.a[out * m.w + x] = u8((sum + win / 2) / win)
			}
			drop := y - 2 * r
			if drop >= 0 && drop < m.h {
				sum -= tmp[drop]
			}
		}
	}
}

// rounded_rect_mask covers r (radius rad) in a w×h mask, anti-aliased.
rounded_rect_mask :: proc(w, h: int, r: Rect, radius: f32) -> Mask {
	m := mask_make(w, h)
	rad := clamp(radius, 0, f32(min(r.w, r.h)) / 2)
	x0, y0 := f32(r.x), f32(r.y)
	x1, y1 := f32(r.x + r.w), f32(r.y + r.h)
	for py in max(r.y, 0) ..< min(r.y + r.h, h) {
		for px in max(r.x, 0) ..< min(r.x + r.w, w) {
			// Distance from the pixel centre to the rounded rectangle's edge.
			cx, cy := f32(px) + 0.5, f32(py) + 0.5
			qx := max(x0 + rad - cx, cx - (x1 - rad), 0)
			qy := max(y0 + rad - cy, cy - (y1 - rad), 0)
			cov: f32 = 1
			if qx > 0 && qy > 0 {
				d := math.sqrt(qx * qx + qy * qy) - rad
				cov = clamp(0.5 - d, 0, 1)
			}
			m.a[py * w + px] = u8(cov * 255 + 0.5)
		}
	}
	return m
}

// sprite_opacity is how visible a sprite is at scene time t of a scene
// lasting duration seconds.
sprite_opacity :: proc(s: ^Sprite, t, duration: f64) -> f32 {
	to := s.to if s.to > 0 else duration
	if t < s.from || t >= to {
		return 0
	}
	if s.fade <= 0 {
		return 1
	}
	return f32(clamp(min((t - s.from) / s.fade, (to - t) / s.fade), 0, 1))
}

// draw_sprite blends a sprite's layers onto the canvas inside band.
draw_sprite :: proc(canvas: ^Image, s: ^Sprite, opacity: f32, band: Rect) {
	if opacity <= 0 {
		return
	}
	for l in s.layers {
		blend_mask(canvas, l.mask, s.x + l.dx, s.y + l.dy, l.color, opacity, band)
	}
}
