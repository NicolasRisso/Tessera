package tessera

// One output frame: the background, each cell's picture, then (later) its
// label and the scene's texts. Everything draws through a band rectangle so
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
