package tessera

import "core:os"
import "core:testing"

@(private = "file")
load_default :: proc(t: ^testing.T) -> (f: Font, ok: bool) {
	err: Err
	f, err = font_load(DEFAULT_FONT_DATA, DEFAULT_FONT_NAME)
	testing.expectf(t, err == nil, "embedded font: %v", err)
	return f, err == nil
}

@(private = "file")
outline_of :: proc(f: ^Font, cp: rune) -> (curves: [dynamic]Curve, g: int, err: Err) {
	g = glyph_index(f, cp)
	err = glyph_outline(f, g, &curves)
	return
}

@(test)
test_ttf_embedded_font_parses :: proc(t: ^testing.T) {
	f, ok := load_default(t)
	if !ok {
		return
	}
	testing.expect(t, f.units_per_em > 0)
	testing.expect(t, f.num_glyphs > 100)
	testing.expect(t, f.ascender > 0 && f.descender < 0)
	testing.expect(t, glyph_is_composite(&f, glyph_index(&f, 'é')), "é is a composite in Inter")
	for cp in ([]rune{'A', 'g', 'é', '&', '—'}) {
		curves, g, err := outline_of(&f, cp)
		defer delete(curves)
		testing.expectf(t, g != 0, "%c has no glyph", cp)
		testing.expectf(t, err == nil, "%c: %v", cp, err)
		testing.expectf(t, len(curves) >= 3, "%c has %d curves", cp, len(curves))
		testing.expectf(t, glyph_advance(&f, g) > 0, "%c has no advance", cp)
	}
	free_all(context.temp_allocator)
}

@(test)
test_ttf_outline_is_closed_and_in_bounds :: proc(t: ^testing.T) {
	f, ok := load_default(t)
	if !ok {
		return
	}
	for cp in ([]rune{'A', 'O', 'g', 'é', '8'}) {
		curves, _, _ := outline_of(&f, cp)
		defer delete(curves)
		// Every curve starts where some curve ends: contours are closed.
		for c in curves {
			joined := false
			for d in curves {
				if d.p1 == c.p0 {
					joined = true
					break
				}
			}
			testing.expectf(t, joined, "%c: a curve starts at %v, where nothing ends", cp, c.p0)
			for p in ([][2]f32{c.p0, c.c, c.p1}) {
				testing.expectf(t, p.x > -f32(f.units_per_em) && p.x < 2 * f32(f.units_per_em) && p.y > f32(f.descender) * 2 && p.y < f32(f.ascender) * 2, "%c: point %v out of bounds", cp, p)
			}
		}
	}
	free_all(context.temp_allocator)
}

@(test)
test_ttf_unknown_code_point_is_glyph_0 :: proc(t: ^testing.T) {
	f, ok := load_default(t)
	if !ok {
		return
	}
	testing.expect_value(t, glyph_index(&f, 0x10FFFD), 0)
	testing.expect_value(t, glyph_index(&f, 0xE0FF), 0)
	testing.expect(t, glyph_index(&f, 'a') != glyph_index(&f, 'b'))
}

@(test)
test_ttf_truncated_font_is_an_error :: proc(t: ^testing.T) {
	data := DEFAULT_FONT_DATA
	// Every cut either fails to load or loads glyphs without crashing.
	for n := 0; n < len(data); n += 997 {
		f, err := font_load(data[:n])
		if err != nil {
			continue
		}
		curves: [dynamic]Curve
		for cp in ([]rune{'A', 'g', 'é'}) {
			_ = glyph_outline(&f, glyph_index(&f, cp), &curves)
		}
		delete(curves)
	}
	_, err := font_load(data[:len(data) / 2])
	testing.expect(t, err != nil, "half a font must not load")
	_, err = font_load(data[:3])
	testing.expect(t, err != nil)
	_, err = font_load(transmute([]u8)string("OTTO and the rest of a CFF font"))
	testing.expectf(t, err != nil && contains(err.?, "CFF"), "CFF error: %v", err)
	free_all(context.temp_allocator)
}

@(test)
test_ttf_corrupt_glyphs_do_not_crash :: proc(t: ^testing.T) {
	data := make([]u8, len(DEFAULT_FONT_DATA))
	defer delete(data)
	copy(data, DEFAULT_FONT_DATA)
	f, err := font_load(data)
	if err != nil {
		testing.expectf(t, false, "%v", err.?)
		return
	}
	// Scribble over the glyf table and read every glyph.
	seed: u32 = 12345
	for i := 0; i < len(f.glyf); i += 7 {
		seed = seed * 1664525 + 1013904223
		f.glyf[i] = u8(seed >> 24)
	}
	curves: [dynamic]Curve
	defer delete(curves)
	for g in 0 ..< f.num_glyphs {
		clear(&curves)
		_ = glyph_outline(&f, g, &curves)
		free_all(context.temp_allocator)
	}
}

@(test)
test_ttf_kern_table :: proc(t: ^testing.T) {
	// The embedded Inter keeps its kerning in GPOS, so the kern reader is
	// tested on DejaVu when the system has it.
	path := "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return
	}
	defer delete(data)
	f, err := font_load(data, path)
	testing.expect_value(t, err, nil)
	testing.expect(t, f.kern_pairs != nil, "DejaVu has a kern table")
	av := kerning(&f, glyph_index(&f, 'A'), glyph_index(&f, 'V'))
	testing.expectf(t, av < 0, "A-V kerning is %d", av)
	testing.expect_value(t, kerning(&f, glyph_index(&f, 'o'), glyph_index(&f, 'o')), 0)
	// é is a composite in DejaVu.
	testing.expect(t, glyph_is_composite(&f, glyph_index(&f, 'é')))
	curves: [dynamic]Curve
	defer delete(curves)
	testing.expect_value(t, glyph_outline(&f, glyph_index(&f, 'é'), &curves), nil)
	testing.expect(t, len(curves) > 5)
	free_all(context.temp_allocator)
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:][:len(sub)] == sub {
			return true
		}
	}
	return false
}
