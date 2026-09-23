package tessera

// Image is 8-bit sRGB, three bytes per pixel, row-major, stride w*3.
Image :: struct {
	w, h: int,
	pix:  []u8,
}

Rect :: struct {
	x, y, w, h: int,
}

// Color is sRGB plus alpha (255 = opaque).
Color :: [4]u8

// Mask is an 8-bit coverage map (0 = none, 255 = full), row-major.
Mask :: struct {
	w, h: int,
	a:    []u8,
}

image_make :: proc(w, h: int, allocator := context.allocator) -> Image {
	return Image{w = w, h = h, pix = make([]u8, w * h * 3, allocator)}
}

image_delete :: proc(img: ^Image) {
	delete(img.pix)
	img^ = {}
}

mask_make :: proc(w, h: int, allocator := context.allocator) -> Mask {
	return Mask{w = w, h = h, a = make([]u8, max(w * h, 0), allocator)}
}

mask_delete :: proc(m: ^Mask) {
	delete(m.a)
	m^ = {}
}

image_rect :: proc(img: Image) -> Rect {
	return Rect{0, 0, img.w, img.h}
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 {
		return {}
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

rect_empty :: proc(r: Rect) -> bool {
	return r.w <= 0 || r.h <= 0
}

// blend8 mixes src over dst with an 8-bit alpha, rounding to nearest.
@(private)
blend8 :: #force_inline proc "contextless" (dst, src: u8, a: u32) -> u8 {
	return u8((u32(dst) * (255 - a) + u32(src) * a + 127) / 255)
}

// fill_rect paints r (clipped to clip and the image) in c, alpha-blended when
// c.a < 255.
fill_rect :: proc(img: ^Image, r: Rect, c: Color, clip: Rect) {
	area := rect_intersect(rect_intersect(r, clip), image_rect(img^))
	if rect_empty(area) || c.a == 0 {
		return
	}
	a := u32(c.a)
	for y in area.y ..< area.y + area.h {
		row := img.pix[(y * img.w + area.x) * 3:][:area.w * 3]
		if a == 255 {
			for x := 0; x < len(row); x += 3 {
				row[x], row[x + 1], row[x + 2] = c.r, c.g, c.b
			}
		} else {
			for x := 0; x < len(row); x += 3 {
				row[x] = blend8(row[x], c.r, a)
				row[x + 1] = blend8(row[x + 1], c.g, a)
				row[x + 2] = blend8(row[x + 2], c.b, a)
			}
		}
	}
}

// blend_mask paints colour c through the coverage mask m placed with its top
// left at (x, y), scaled by c.a and opacity (0..1), clipped to clip.
blend_mask :: proc(img: ^Image, m: Mask, x, y: int, c: Color, opacity: f32, clip: Rect) {
	area := rect_intersect(rect_intersect(Rect{x, y, m.w, m.h}, clip), image_rect(img^))
	if rect_empty(area) {
		return
	}
	k := u32(clamp(f32(c.a) * opacity + 0.5, 0, 255)) // 0..255
	if k == 0 {
		return
	}
	for py in area.y ..< area.y + area.h {
		mrow := m.a[(py - y) * m.w + (area.x - x):][:area.w]
		row := img.pix[(py * img.w + area.x) * 3:][:area.w * 3]
		for cov, i in mrow {
			if cov == 0 {
				continue
			}
			a := (u32(cov) * k + 127) / 255
			j := i * 3
			row[j] = blend8(row[j], c.r, a)
			row[j + 1] = blend8(row[j + 1], c.g, a)
			row[j + 2] = blend8(row[j + 2], c.b, a)
		}
	}
}

// blit copies src with its top left at (x, y), clipped to clip.
blit :: proc(dst: ^Image, src: Image, x, y: int, clip: Rect) {
	area := rect_intersect(rect_intersect(Rect{x, y, src.w, src.h}, clip), image_rect(dst^))
	if rect_empty(area) {
		return
	}
	for py in area.y ..< area.y + area.h {
		s := src.pix[((py - y) * src.w + (area.x - x)) * 3:][:area.w * 3]
		copy(dst.pix[(py * dst.w + area.x) * 3:][:area.w * 3], s)
	}
}

image_pixel :: proc(img: Image, x, y: int) -> [3]u8 {
	i := (y * img.w + x) * 3
	return {img.pix[i], img.pix[i + 1], img.pix[i + 2]}
}
