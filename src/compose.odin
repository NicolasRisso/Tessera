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

LABEL_INSET     :: 12   // px from the picture's top left to an Inside label's box
LABEL_STRIP_PAD :: 0.25 // of the label size, added to its line height to make its strip

// auto_label_size is the label size for pictures pic_h pixels high.
auto_label_size :: proc(pic_h: int) -> f32 {
	return math.round(clamp(f32(pic_h) * 0.05, 14, 40))
}

// label_strip_height is the height of the strip an Above or Below label
// takes: one line of the font at size, and a small pad.
label_strip_height :: proc(te: ^Text_Engine, size: f32) -> int {
	f := &te.font
	line := f32(f.ascender - f.descender + f.line_gap) * size / f32(f.units_per_em)
	return int(math.ceil(line + size * LABEL_STRIP_PAD))
}

// label_text places a cell's label: Above or Below, left-aligned with the
// picture and centred in its strip, on the background (dark text on a light
// one); Inside, on the picture's top left on a translucent box.
label_text :: proc(label: string, size: f32, pos: Label_Pos, dst, strip: Rect, background: Color) -> Text {
	t := default_text()
	t.text = label
	t.size = size
	if pos != .Inside {
		t.anchor = .CL
		t.x = Coord{f32(strip.x), false}
		t.y = Coord{f32(strip.y) + f32(strip.h) / 2, false}
		t.shadow_color = {}
		luma := 0.2126 * f32(background.r) + 0.7152 * f32(background.g) + 0.0722 * f32(background.b)
		if luma > 140 {
			t.color = {0x10, 0x10, 0x10, 255}
		}
		return t
	}
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

// ---- On threads ----
//
// A frame is two batches: first every stale cell cache, cut into row
// chunks; then the canvas, cut into bands of rows, each band composed and
// converted to YUV by one task. Nothing is shared between tasks of a batch
// except what they only read.

RESAMPLE_CHUNK_ROWS :: 32

@(private = "file")
Chunk :: struct {
	cs:     ^Cell_State,
	y0, y1: int,
}

@(private = "file")
Frame_Work :: struct {
	canvas: ^Image,
	st:     ^Scene_State,
	t:      f64,
	yuv:    []u8,
	chunks: []Chunk,
	band_h: int, // even
	bands:  int,
}

@(private = "file")
resample_task :: proc(data: rawptr, i: int) {
	fw := (^Frame_Work)(data)
	c := fw.chunks[i]
	buf := make([]f32, resampler_buffer_len(&c.cs.rs), context.temp_allocator)
	resample_cell_rows(c.cs, c.y0, c.y1, buf)
}

@(private = "file")
band_task :: proc(data: rawptr, i: int) {
	fw := (^Frame_Work)(data)
	y0 := i * fw.band_h
	y1 := min(y0 + fw.band_h, fw.canvas.h)
	band := Rect{0, y0, fw.canvas.w, y1 - y0}
	compose_band(fw.canvas, fw.st, fw.t, band)
	rgb_to_yuv420p(fw.canvas^, fw.yuv, y0, y1)
}

// compose_frame_yuv draws frame t and converts it to yuv420p, on the
// workers' threads.
compose_frame_yuv :: proc(canvas: ^Image, st: ^Scene_State, t: f64, yuv: []u8, w: ^Workers) {
	fw := Frame_Work{canvas = canvas, st = st, t = t, yuv = yuv}
	chunks := make([dynamic]Chunk, context.temp_allocator)
	for &cs in st.cells {
		if !cell_needs_resample(&cs) {
			continue
		}
		for y := 0; y < cs.dst.h; y += RESAMPLE_CHUNK_ROWS {
			append(&chunks, Chunk{&cs, y, min(y + RESAMPLE_CHUNK_ROWS, cs.dst.h)})
		}
		cs.cached = cs.version
	}
	fw.chunks = chunks[:]
	workers_run(w, len(fw.chunks), resample_task, &fw)
	// About four bands per thread, so a slow band does not hold the frame.
	fw.bands = clamp(w.threads * 4, 1, canvas.h / 2)
	fw.band_h = (canvas.h / fw.bands + 1) &~ 1
	fw.bands = (canvas.h + fw.band_h - 1) / fw.band_h
	workers_run(w, fw.bands, band_task, &fw)
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
