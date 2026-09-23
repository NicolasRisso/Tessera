package tessera

import "core:os"
import "core:testing"

@(private = "file")
engine_for :: proc(t: ^testing.T, data: []u8) -> (te: Text_Engine, ok: bool) {
	f, err := font_load(data)
	if err != nil {
		testing.expectf(t, false, "%v", err.?)
		return
	}
	text_engine_init(&te, f)
	return te, true
}

@(private = "file")
check_advances :: proc(t: ^testing.T, te: ^Text_Engine, s: string, size: f32) {
	l := layout_text(te, s, size)
	defer layout_delete(&l)
	f := &te.font
	scale := size / f32(f.units_per_em)
	want: f32
	prev := -1
	for r in s {
		g := glyph_index(f, r)
		if prev >= 0 {
			want += f32(kerning(f, prev, g)) * scale
		}
		want += f32(glyph_advance(f, g)) * scale
		prev = g
	}
	testing.expectf(t, abs(l.width - want) < 1e-3, "%q: width %v, want %v", s, l.width, want)
	testing.expect_value(t, l.lines, 1)
}

@(test)
test_text_advance_is_sum_of_glyphs :: proc(t: ^testing.T) {
	te, ok := engine_for(t, DEFAULT_FONT_DATA)
	if !ok {
		return
	}
	defer text_engine_destroy(&te)
	check_advances(t, &te, "Top & bottom", 26)
	check_advances(t, &te, "Fusefall — four HUD layouts", 54)
	check_advances(t, &te, "é\xff!", 30) // the invalid byte is U+FFFD

	// With kerning: DejaVu has a kern table, and AV kerns.
	data, err := os.read_entire_file("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", context.allocator)
	if err != nil {
		return
	}
	defer delete(data)
	dv, dok := engine_for(t, data)
	if !dok {
		return
	}
	defer text_engine_destroy(&dv)
	check_advances(t, &dv, "AVAWAY Ta", 40)
	plain := f32(glyph_advance(&dv.font, glyph_index(&dv.font, 'A')) + glyph_advance(&dv.font, glyph_index(&dv.font, 'V')))
	l := layout_text(&dv, "AV", f32(dv.font.units_per_em))
	defer layout_delete(&l)
	testing.expectf(t, l.width < plain, "AV (%v) is kerned tighter than A + V (%v)", l.width, plain)
}

@(test)
test_text_newline_adds_a_line_height :: proc(t: ^testing.T) {
	te, ok := engine_for(t, DEFAULT_FONT_DATA)
	if !ok {
		return
	}
	defer text_engine_destroy(&te)
	l := layout_text(&te, "one\ntwo lines\nthree", 32)
	defer layout_delete(&l)
	testing.expect_value(t, l.lines, 3)
	f := &te.font
	testing.expectf(t, abs(l.line_height - f32(f.ascender - f.descender + f.line_gap) * 32 / f32(f.units_per_em)) < 1e-4, "line height %v", l.line_height)
	testing.expect_value(t, l.glyphs[3].line, 1)
	testing.expect_value(t, l.glyphs[3].x, 0)

	// Rendered, the second line's ink sits one line height below the first.
	a := make_sprite(&te, Text{text = "H", size = 32, color = {255, 255, 255, 255}}, 200, 200)
	defer sprite_delete(&a)
	b := make_sprite(&te, Text{text = "H\nH", size = 32, color = {255, 255, 255, 255}}, 200, 200)
	defer sprite_delete(&b)
	top_row :: proc(m: Mask, from: int) -> int {
		for y in from ..< m.h {
			for x in 0 ..< m.w {
				if m.a[y * m.w + x] > 128 {
					return y
				}
			}
		}
		return -1
	}
	fa := a.layers[len(a.layers) - 1].mask
	fb := b.layers[len(b.layers) - 1].mask
	first := top_row(fb, 0)
	testing.expect_value(t, first, top_row(fa, 0))
	// Skip past the first H's ink, then find the second.
	gap := first
	for gap < fb.h && top_row(fb, gap) == gap {
		gap += 1
	}
	second := top_row(fb, gap)
	testing.expectf(t, abs(f32(second - first) - l.line_height) <= 1, "lines %d px apart, line height %v", second - first, l.line_height)
	free_all(context.temp_allocator)
}

@(test)
test_text_sprite_layers_and_fade :: proc(t: ^testing.T) {
	te, ok := engine_for(t, DEFAULT_FONT_DATA)
	if !ok {
		return
	}
	defer text_engine_destroy(&te)
	txt := default_text()
	txt.text = "Label"
	txt.size = 30
	txt.outline_px = 2
	txt.shadow_dx, txt.shadow_dy, txt.shadow_blur = 2, 2, 2
	txt.box_color = {0, 0, 0, 160}
	txt.box_pad = 8
	txt.from, txt.to, txt.fade = 1, 3, 0.5
	s := make_sprite(&te, txt, 640, 360)
	defer sprite_delete(&s)
	testing.expect_value(t, len(s.layers), 4) // box, shadow, outline, fill
	testing.expect_value(t, s.layers[0].color, txt.box_color)
	testing.expect_value(t, s.layers[3].color, txt.color)
	// The outline covers at least the fill.
	fill, outline := s.layers[3].mask, s.layers[2].mask
	for v, i in fill.a {
		if v > outline.a[i] {
			testing.expectf(t, false, "outline thinner than the fill at %d", i)
			break
		}
	}
	testing.expect_value(t, sprite_opacity(&s, 0.5, 10), 0)
	testing.expect_value(t, sprite_opacity(&s, 2, 10), 1)
	testing.expectf(t, abs(sprite_opacity(&s, 1.25, 10) - 0.5) < 1e-4, "half faded in")
	testing.expect_value(t, sprite_opacity(&s, 3, 10), 0)
	free_all(context.temp_allocator)
}
