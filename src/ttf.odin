package tessera

import "core:fmt"

// A TrueType reader: head, maxp, hhea, hmtx, cmap (formats 4 and 12), loca,
// glyf (simple and composite glyphs) and kern (format 0). Every read is
// bounds-checked: a malformed font is an error, never a crash.

Font :: struct {
	data:          []u8,
	units_per_em:  int,
	long_loca:     bool,
	num_glyphs:    int,
	ascender:      int,
	descender:     int, // negative below the baseline
	line_gap:      int,
	num_hmetrics:  int,
	hmtx:          []u8,
	loca:          []u8,
	glyf:          []u8,
	cmap:          []u8, // the chosen subtable
	cmap_format:   int,
	kern_pairs:    []u8, // format 0 pairs, 6 bytes each, sorted; nil without kern
}

// Curve is a quadratic Bézier from p0 through control c to p1, in font units
// (y up). A straight line has c at the midpoint of p0 and p1 and line set.
Curve :: struct {
	p0, c, p1: [2]f32,
	line:      bool,
}

@(private = "file")
u8_at :: proc(b: []u8, off: int) -> (v: u8, ok: bool) {
	if off < 0 || off + 1 > len(b) {
		return 0, false
	}
	return b[off], true
}

@(private = "file")
u16_at :: proc(b: []u8, off: int) -> (v: u16, ok: bool) {
	if off < 0 || off + 2 > len(b) {
		return 0, false
	}
	return u16(b[off]) << 8 | u16(b[off + 1]), true
}

@(private = "file")
i16_at :: proc(b: []u8, off: int) -> (v: i16, ok: bool) {
	u := u16_at(b, off) or_return
	return i16(u), true
}

@(private = "file")
u32_at :: proc(b: []u8, off: int) -> (v: u32, ok: bool) {
	if off < 0 || off + 4 > len(b) {
		return 0, false
	}
	return u32(b[off]) << 24 | u32(b[off + 1]) << 16 | u32(b[off + 2]) << 8 | u32(b[off + 3]), true
}

@(private = "file")
sub :: proc(b: []u8, off, n: int) -> (s: []u8, ok: bool) {
	if off < 0 || n < 0 || off + n > len(b) {
		return nil, false
	}
	return b[off:][:n], true
}

// find_table returns the named table's bytes, or ok = false.
@(private = "file")
find_table :: proc(data: []u8, dir: int, tag: string) -> (t: []u8, found: bool, ok: bool) {
	n := int(u16_at(data, dir + 4) or_return)
	for i in 0 ..< n {
		rec := dir + 12 + 16 * i
		name := sub(data, rec, 4) or_return
		if string(name) != tag {
			continue
		}
		off := int(u32_at(data, rec + 8) or_return)
		length := int(u32_at(data, rec + 12) or_return)
		t = sub(data, off, length) or_return
		return t, true, true
	}
	return nil, false, true
}

// font_load parses the tables tessera needs. data must outlive the Font.
font_load :: proc(data: []u8, name := "font") -> (f: Font, err: Err) {
	f.data = data
	tag := sub(data, 0, 4) or_else nil
	if tag == nil {
		return f, fmt.aprintf("%s: not a font (too short)", name)
	}
	dir := 0
	switch string(tag) {
	case "OTTO":
		return f, fmt.aprintf("%s: CFF fonts are not supported; use a TrueType (.ttf) font", name)
	case "ttcf":
		// A collection: use its first font.
		off, ok := u32_at(data, 12)
		if !ok {
			return f, fmt.aprintf("%s: truncated font collection", name)
		}
		dir = int(off)
	case "\x00\x01\x00\x00", "true":
	case:
		return f, fmt.aprintf("%s: not a TrueType font", name)
	}
	if ok := parse_tables(&f, dir); !ok {
		return f, fmt.aprintf("%s: malformed or truncated TrueType font", name)
	}
	if f.glyf == nil {
		return f, fmt.aprintf("%s: no glyf table; use a TrueType (.ttf) font with outlines", name)
	}
	if f.cmap == nil {
		return f, fmt.aprintf("%s: no Unicode character map", name)
	}
	return f, nil
}

@(private = "file")
parse_tables :: proc(f: ^Font, dir: int) -> (ok: bool) {
	data := f.data
	found: bool
	head: []u8
	if head, found = find_table(data, dir, "head") or_return; !found {
		return false
	}
	f.units_per_em = int(u16_at(head, 18) or_return)
	if f.units_per_em < 16 || f.units_per_em > 16384 {
		return false
	}
	f.long_loca = (i16_at(head, 50) or_return) != 0

	maxp: []u8
	if maxp, found = find_table(data, dir, "maxp") or_return; !found {
		return false
	}
	f.num_glyphs = int(u16_at(maxp, 4) or_return)

	hhea: []u8
	if hhea, found = find_table(data, dir, "hhea") or_return; !found {
		return false
	}
	f.ascender = int(i16_at(hhea, 4) or_return)
	f.descender = int(i16_at(hhea, 6) or_return)
	f.line_gap = int(i16_at(hhea, 8) or_return)
	f.num_hmetrics = int(u16_at(hhea, 34) or_return)
	if f.num_hmetrics == 0 {
		return false
	}

	if f.hmtx, found = find_table(data, dir, "hmtx") or_return; !found || len(f.hmtx) < 4 * f.num_hmetrics {
		return false
	}
	f.loca, _ = find_table(data, dir, "loca") or_return
	f.glyf, _ = find_table(data, dir, "glyf") or_return
	if f.glyf != nil && len(f.loca) < (f.num_glyphs + 1) * (4 if f.long_loca else 2) {
		return false
	}

	cmap: []u8
	if cmap, found = find_table(data, dir, "cmap") or_return; found {
		pick_cmap(f, cmap) or_return
	}

	kern: []u8
	if kern, found = find_table(data, dir, "kern") or_return; found {
		pick_kern(f, kern) // a kern table we cannot read is ignored, not fatal
	}
	return true
}

// pick_cmap prefers a full-Unicode subtable (3/10, format 12), then the BMP
// one (3/1, format 4), then any platform 0 subtable of a readable format.
@(private = "file")
pick_cmap :: proc(f: ^Font, cmap: []u8) -> (ok: bool) {
	n := int(u16_at(cmap, 2) or_return)
	best_rank := 0
	for i in 0 ..< n {
		rec := 4 + 8 * i
		platform := u16_at(cmap, rec) or_return
		encoding := u16_at(cmap, rec + 2) or_return
		off := int(u32_at(cmap, rec + 4) or_return)
		format := int(u16_at(cmap, off) or_return)
		if format != 4 && format != 12 {
			continue
		}
		rank := 0
		switch {
		case platform == 3 && encoding == 10:
			rank = 4
		case platform == 3 && encoding == 1:
			rank = 3
		case platform == 0:
			rank = 2 if format == 12 else 1
		}
		if rank > best_rank {
			best_rank = rank
			f.cmap = cmap[off:]
			f.cmap_format = format
		}
	}
	return true
}

@(private = "file")
pick_kern :: proc(f: ^Font, kern: []u8) {
	version, ok := u16_at(kern, 0)
	if !ok || version != 0 {
		return // Apple's version 1 kern tables are not read
	}
	n, _ := u16_at(kern, 2)
	off := 4
	for _ in 0 ..< int(n) {
		length, ok1 := u16_at(kern, off + 2)
		coverage, ok2 := u16_at(kern, off + 4)
		if !ok1 || !ok2 {
			return
		}
		format := coverage >> 8
		horizontal := coverage & 1 != 0
		cross := coverage & 4 != 0
		if format == 0 && horizontal && !cross {
			npairs, ok3 := u16_at(kern, off + 6)
			pairs, ok4 := sub(kern, off + 14, int(npairs) * 6)
			if ok3 && ok4 {
				f.kern_pairs = pairs
				return
			}
		}
		off += int(length)
	}
}

// glyph_index maps a code point to a glyph; 0 (.notdef) when it is missing.
glyph_index :: proc(f: ^Font, cp: rune) -> int {
	c := u32(cp)
	b := f.cmap
	switch f.cmap_format {
	case 4:
		if c > 0xFFFF {
			return 0
		}
		segx2 := int(u16_at(b, 6) or_else 0)
		ends := 14
		starts := ends + segx2 + 2
		deltas := starts + segx2
		ranges := deltas + segx2
		// Binary search for the first segment whose end >= c.
		lo, hi := 0, segx2 / 2
		for lo < hi {
			mid := (lo + hi) / 2
			e := u16_at(b, ends + mid * 2) or_else 0
			if u32(e) < c {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo >= segx2 / 2 {
			return 0
		}
		start := u32(u16_at(b, starts + lo * 2) or_else 0xFFFF)
		if c < start {
			return 0
		}
		delta := u16_at(b, deltas + lo * 2) or_else 0
		range := int(u16_at(b, ranges + lo * 2) or_else 0)
		g: u16
		if range == 0 {
			g = u16(c) + delta
		} else {
			at := ranges + lo * 2 + range + int(c - start) * 2
			g = u16_at(b, at) or_else 0
			if g != 0 {
				g += delta
			}
		}
		return int(g) if int(g) < f.num_glyphs else 0
	case 12:
		n := int(u32_at(b, 12) or_else 0)
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			rec := 16 + mid * 12
			first := u32_at(b, rec) or_else 0
			last := u32_at(b, rec + 4) or_else 0
			if c < first {
				hi = mid
			} else if c > last {
				lo = mid + 1
			} else {
				g := int((u32_at(b, rec + 8) or_else 0) + (c - first))
				return g if g < f.num_glyphs else 0
			}
		}
	}
	return 0
}

// glyph_advance is the glyph's advance width in font units.
glyph_advance :: proc(f: ^Font, g: int) -> int {
	i := min(g, f.num_hmetrics - 1)
	return int(u16_at(f.hmtx, i * 4) or_else 0)
}

// kerning is the adjustment between two glyphs from the kern table, in font
// units (usually negative); 0 without one.
kerning :: proc(f: ^Font, left, right: int) -> int {
	if f.kern_pairs == nil {
		return 0
	}
	key := u32(left) << 16 | u32(right)
	n := len(f.kern_pairs) / 6
	// Pairs are 6-byte records sorted by (left << 16 | right).
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		k := u32_at(f.kern_pairs, mid * 6) or_else 0
		if k < key {
			lo = mid + 1
		} else if k > key {
			hi = mid
		} else {
			return int(i16_at(f.kern_pairs, mid * 6 + 4) or_else 0)
		}
	}
	return 0
}

// glyph_data returns a glyph's bytes in glyf; empty for a blank glyph.
@(private = "file")
glyph_data :: proc(f: ^Font, g: int) -> (b: []u8, ok: bool) {
	if g < 0 || g >= f.num_glyphs {
		return nil, false
	}
	start, end: int
	if f.long_loca {
		start = int(u32_at(f.loca, g * 4) or_return)
		end = int(u32_at(f.loca, g * 4 + 4) or_return)
	} else {
		start = int(u16_at(f.loca, g * 2) or_return) * 2
		end = int(u16_at(f.loca, g * 2 + 2) or_return) * 2
	}
	if end < start {
		return nil, false
	}
	return sub(f.glyf, start, end - start)
}

// glyph_is_composite reports whether a glyph is built from other glyphs.
glyph_is_composite :: proc(f: ^Font, g: int) -> bool {
	b, ok := glyph_data(f, g)
	if !ok || len(b) < 2 {
		return false
	}
	n, _ := i16_at(b, 0)
	return n < 0
}

// glyph_outline appends the glyph's curves (font units, y up) to out.
glyph_outline :: proc(f: ^Font, g: int, out: ^[dynamic]Curve) -> Err {
	if !append_glyph(f, g, {1, 0, 0, 1, 0, 0}, out, 0) {
		return fmt.aprintf("glyph %d is malformed", g)
	}
	return nil
}

// Affine is x' = a·x + c·y + e, y' = b·x + d·y + f.
@(private = "file")
Affine :: [6]f32

@(private = "file")
apply :: proc(m: Affine, p: [2]f32) -> [2]f32 {
	return {m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]}
}

@(private = "file")
append_glyph :: proc(f: ^Font, g: int, m: Affine, out: ^[dynamic]Curve, depth: int) -> (ok: bool) {
	if depth > 8 {
		return false
	}
	b := glyph_data(f, g) or_return
	if len(b) == 0 {
		return true // a blank glyph such as space
	}
	ncontours := int(i16_at(b, 0) or_return)
	if ncontours >= 0 {
		return append_simple(b, ncontours, m, out)
	}
	// Composite: components until MORE_COMPONENTS is clear.
	ARG_1_AND_2_ARE_WORDS :: 0x0001
	ARGS_ARE_XY_VALUES :: 0x0002
	WE_HAVE_A_SCALE :: 0x0008
	MORE_COMPONENTS :: 0x0020
	WE_HAVE_AN_X_AND_Y_SCALE :: 0x0040
	WE_HAVE_A_TWO_BY_TWO :: 0x0080
	off := 10
	for {
		flags := u16_at(b, off) or_return
		child := int(u16_at(b, off + 2) or_return)
		off += 4
		dx, dy: f32
		if flags & ARG_1_AND_2_ARE_WORDS != 0 {
			dx = f32(i16_at(b, off) or_return)
			dy = f32(i16_at(b, off + 2) or_return)
			off += 4
		} else {
			dx = f32(i8(u8_at(b, off) or_return))
			dy = f32(i8(u8_at(b, off + 1) or_return))
			off += 2
		}
		if flags & ARGS_ARE_XY_VALUES == 0 {
			dx, dy = 0, 0 // point-matched placement: not supported, placed at the origin
		}
		f2 :: proc(b: []u8, off: int) -> (v: f32, ok: bool) {
			return f32(i16_at(b, off) or_return) / 16384, true
		}
		a, bb, c, d: f32 = 1, 0, 0, 1
		switch {
		case flags & WE_HAVE_A_SCALE != 0:
			a = f2(b, off) or_return
			d = a
			off += 2
		case flags & WE_HAVE_AN_X_AND_Y_SCALE != 0:
			a = f2(b, off) or_return
			d = f2(b, off + 2) or_return
			off += 4
		case flags & WE_HAVE_A_TWO_BY_TWO != 0:
			a = f2(b, off) or_return
			bb = f2(b, off + 2) or_return
			c = f2(b, off + 4) or_return
			d = f2(b, off + 6) or_return
			off += 8
		}
		// The component's transform, then the parent's.
		local := Affine{a, bb, c, d, dx, dy}
		combined := Affine {
			m[0] * local[0] + m[2] * local[1],
			m[1] * local[0] + m[3] * local[1],
			m[0] * local[2] + m[2] * local[3],
			m[1] * local[2] + m[3] * local[3],
			m[0] * local[4] + m[2] * local[5] + m[4],
			m[1] * local[4] + m[3] * local[5] + m[5],
		}
		append_glyph(f, child, combined, out, depth + 1) or_return
		if flags & MORE_COMPONENTS == 0 {
			return true
		}
	}
}

@(private = "file")
append_simple :: proc(b: []u8, ncontours: int, m: Affine, out: ^[dynamic]Curve) -> (ok: bool) {
	if ncontours == 0 {
		return true
	}
	ends := make([]int, ncontours, context.temp_allocator)
	npoints := 0
	for i in 0 ..< ncontours {
		ends[i] = int(u16_at(b, 10 + i * 2) or_return)
		if i > 0 && ends[i] < ends[i - 1] {
			return false
		}
		npoints = ends[i] + 1
	}
	if npoints > 65535 {
		return false
	}
	off := 10 + ncontours * 2
	ninstr := int(u16_at(b, off) or_return)
	off += 2 + ninstr

	ON_CURVE :: 0x01
	X_SHORT :: 0x02
	Y_SHORT :: 0x04
	REPEAT :: 0x08
	X_SAME_OR_POS :: 0x10
	Y_SAME_OR_POS :: 0x20

	flags := make([]u8, npoints, context.temp_allocator)
	for i := 0; i < npoints; {
		fl := u8_at(b, off) or_return
		off += 1
		flags[i] = fl
		i += 1
		if fl & REPEAT != 0 {
			n := int(u8_at(b, off) or_return)
			off += 1
			for _ in 0 ..< n {
				if i >= npoints {
					return false
				}
				flags[i] = fl
				i += 1
			}
		}
	}
	pts := make([][2]f32, npoints, context.temp_allocator)
	v := 0
	for i in 0 ..< npoints {
		fl := flags[i]
		if fl & X_SHORT != 0 {
			d := int(u8_at(b, off) or_return)
			off += 1
			v += d if fl & X_SAME_OR_POS != 0 else -d
		} else if fl & X_SAME_OR_POS == 0 {
			v += int(i16_at(b, off) or_return)
			off += 2
		}
		pts[i].x = f32(v)
	}
	v = 0
	for i in 0 ..< npoints {
		fl := flags[i]
		if fl & Y_SHORT != 0 {
			d := int(u8_at(b, off) or_return)
			off += 1
			v += d if fl & Y_SAME_OR_POS != 0 else -d
		} else if fl & Y_SAME_OR_POS == 0 {
			v += int(i16_at(b, off) or_return)
			off += 2
		}
		pts[i].y = f32(v)
	}
	for &p in pts {
		p = apply(m, p)
	}

	start := 0
	for end in ends {
		contour_to_curves(pts[start:end + 1], flags[start:end + 1], out)
		start = end + 1
	}
	return true
}

// contour_to_curves turns one closed contour of on- and off-curve points into
// curves, inserting the implied on-curve midpoint between two off-curve points.
@(private = "file")
contour_to_curves :: proc(pts: [][2]f32, flags: []u8, out: ^[dynamic]Curve) {
	n := len(pts)
	if n < 2 {
		return
	}
	on :: proc(fl: u8) -> bool {
		return fl & 1 != 0
	}
	// Find a start point that is on the curve, or make one.
	first := -1
	for fl, i in flags {
		if on(fl) {
			first = i
			break
		}
	}
	if first < 0 {
		// All off-curve: start at the implied point between 0 and 1.
		walk_curves(pts, flags, 1, n, (pts[0] + pts[1]) * 0.5, out)
		return
	}
	walk_curves(pts, flags, first + 1, n, pts[first], out)
}

@(private = "file")
walk_curves :: proc(pts: [][2]f32, flags: []u8, from, n: int, start: [2]f32, out: ^[dynamic]Curve) {
	cur := start
	ctrl: [2]f32
	have_ctrl := false
	for k in 0 ..< n {
		i := (from + k) % n
		p := pts[i]
		if flags[i] & 1 != 0 {
			if have_ctrl {
				append(out, Curve{cur, ctrl, p, false})
				have_ctrl = false
			} else if p != cur {
				append(out, Curve{cur, (cur + p) * 0.5, p, true})
			}
			cur = p
		} else {
			if have_ctrl {
				mid := (ctrl + p) * 0.5
				append(out, Curve{cur, ctrl, mid, false})
				cur = mid
			}
			ctrl = p
			have_ctrl = true
		}
	}
	// Close back to the start.
	if have_ctrl {
		append(out, Curve{cur, ctrl, start, false})
	} else if cur != start {
		append(out, Curve{cur, (cur + start) * 0.5, start, true})
	}
}
