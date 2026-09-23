package tessera

import "core:math"

// One output frame: the background, each cell's picture, then the labels,
// the title and the scene's texts. Everything draws through a band rectangle so
// the frame can be split into rows.

// cell_needs_resample reports whether the cell's cache is stale.
cell_needs_resample :: proc(cs: ^Cell_State) -> bool {
	return cs.visible && cs.cached != cs.version
}

// resample_cell_rows refreshes rows [y0, y1) of a cell's cache from its
// current source frame.
resample_cell_rows :: proc(cs: ^Cell_State, y0, y1: int, buf: []f32) {
	src := Image{w = cs.probe.width, h = cs.probe.height, pix = cs.frame}
	resample_rows(&cs.rs, src, &cs.cache, 0, 0, y0, y1, image_rect(cs.cache), buf)
}

// compose_band draws the part of the frame inside band. The cells' caches
// must be current.
compose_band :: proc(canvas: ^Image, st: ^Scene_State, t: f64, band: Rect) {
	fill_rect(canvas, band, st.scene.background, band)
	for &cs in st.cells {
		if cs.visible {
			blit(canvas, cs.cache, cs.dst.x, cs.dst.y, band)
		}
	}
	for &s in st.sprites {
		draw_sprite(canvas, &s, sprite_opacity(&s, t, st.duration), band)
	}
}

// Label, title and caption styles.

LABEL_INSET :: 12 // px from the picture's top left to the label's box

label_text :: proc(label: string, size: f32, dst: Rect) -> Text {
	t := default_text()
	t.text = label
	t.size = size
	t.box_color = {0, 0, 0, 150}
	t.box_pad = math.round(size * 0.4)
	t.box_radius = size * 0.3
	t.shadow_color = {}
	t.x = Coord{f32(dst.x + LABEL_INSET) + t.box_pad, false}
	t.y = Coord{f32(dst.y + LABEL_INSET) + t.box_pad, false}
	return t
}

title_text :: proc(title: string, band: Rect) -> Text {
	t := default_text()
	t.text = title
	t.size = math.round(f32(band.h) * 0.5)
	t.anchor = .CC
	t.x = Coord{f32(band.x) + f32(band.w) / 2, false}
	t.y = Coord{f32(band.y) + f32(band.h) / 2, false}
	t.shadow_dy = 2
	t.shadow_blur = 2
	t.shadow_color = {0, 0, 0, 170}
	return t
}

// caption_text is a timed line at the bottom centre, on a box.
caption_text :: proc(text: string, from, to: f64, canvas_h: int) -> Text {
	t := default_text()
	t.text = text
	t.size = math.round(f32(canvas_h) * 0.035)
	t.anchor = .BC
	t.x = Coord{0.5, true}
	t.y = Coord{0.94, true}
	t.box_color = {0, 0, 0, 170}
	t.box_pad = math.round(t.size * 0.45)
	t.box_radius = t.size * 0.3
	t.shadow_color = {}
	t.from, t.to = from, to
	t.fade = 0.3
	return t
}

// compose_frame draws a whole frame on the calling thread.
compose_frame :: proc(canvas: ^Image, st: ^Scene_State, t: f64) {
	for &cs in st.cells {
		if cell_needs_resample(&cs) {
			buf := make([]f32, resampler_buffer_len(&cs.rs), context.temp_allocator)
			resample_cell_rows(&cs, 0, cs.dst.h, buf)
			cs.cached = cs.version
		}
	}
	compose_band(canvas, st, t, image_rect(canvas^))
}
