package tessera

// GPOS pair kerning: the 'kern' feature's pair-adjustment lookups (type 2,
// formats 1 and 2, also behind type 9 extensions). Only the first glyph's
// horizontal advance adjustment is read, which is what kerning is; marks,
// cursive attachment and contextual positioning are not. Like the rest of
// the font reader every read is bounds-checked, and a GPOS table it cannot
// follow simply gives no kerning.

@(private = "file")
be16 :: proc(b: []u8, off: int) -> (v: int, ok: bool) {
	if off < 0 || off + 2 > len(b) {
		return 0, false
	}
	return int(u16(b[off]) << 8 | u16(b[off + 1])), true
}

@(private = "file")
be16s :: proc(b: []u8, off: int) -> (v: int, ok: bool) {
	u := be16(b, off) or_return
	return int(i16(u16(u))), true
}

@(private = "file")
be32 :: proc(b: []u8, off: int) -> (v: int, ok: bool) {
	hi := be16(b, off) or_return
	lo := be16(b, off + 2) or_return
	return hi << 16 | lo, true
}

@(private = "file")
tail :: proc(b: []u8, off: int) -> (s: []u8, ok: bool) {
	if off < 0 || off > len(b) {
		return nil, false
	}
	return b[off:], true
}

// gpos_kern_subtables finds the pair-adjustment subtables of every 'kern'
// feature, in lookup order. It returns nil for a font without them.
gpos_kern_subtables :: proc(gpos: []u8, allocator := context.allocator) -> [][]u8 {
	subs := make([dynamic][]u8, allocator)
	collect(gpos, &subs)
	return subs[:]

	collect :: proc(gpos: []u8, subs: ^[dynamic][]u8) -> (ok: bool) {
		major := be16(gpos, 0) or_return
		if major != 1 {
			return false
		}
		features := tail(gpos, be16(gpos, 6) or_return) or_return
		lookups := tail(gpos, be16(gpos, 8) or_return) or_return
		nlookups := be16(lookups, 0) or_return
		// Which lookups the 'kern' features use (any script, any language).
		used := make([]bool, nlookups, context.temp_allocator)
		nfeat := be16(features, 0) or_return
		for i in 0 ..< nfeat {
			rec := 2 + 6 * i
			if rec + 4 > len(features) || string(features[rec:rec + 4]) != "kern" {
				continue
			}
			feat := tail(features, be16(features, rec + 4) or_return) or_return
			n := be16(feat, 2) or_return
			for k in 0 ..< n {
				idx := be16(feat, 4 + 2 * k) or_return
				if idx < nlookups {
					used[idx] = true
				}
			}
		}
		for li in 0 ..< nlookups {
			if !used[li] {
				continue
			}
			lookup := tail(lookups, be16(lookups, 2 + 2 * li) or_return) or_return
			kind := be16(lookup, 0) or_return
			nsub := be16(lookup, 4) or_return
			for s in 0 ..< nsub {
				st := tail(lookup, be16(lookup, 6 + 2 * s) or_return) or_return
				if kind == 9 {
					// Extension: the real subtable is at a 32-bit offset.
					if (be16(st, 2) or_return) != 2 {
						continue
					}
					st = tail(st, be32(st, 4) or_return) or_return
				} else if kind != 2 {
					continue
				}
				append(subs, st)
			}
		}
		return true
	}
}

// value_size is the byte size of a ValueRecord with this format.
@(private = "file")
value_size :: proc(format: int) -> int {
	n := 0
	for bit in 0 ..< 8 {
		if format & (1 << uint(bit)) != 0 {
			n += 2
		}
	}
	return n
}

// x_advance reads XAdvance from a ValueRecord at off, 0 when absent.
@(private = "file")
x_advance :: proc(b: []u8, off, format: int) -> int {
	if format & 0x4 == 0 {
		return 0
	}
	skip := 2 * (format & 1) + 2 * ((format >> 1) & 1) // XPlacement, YPlacement
	return be16s(b, off + skip) or_else 0
}

// coverage_index is g's index in a Coverage table, or -1.
@(private = "file")
coverage_index :: proc(cov: []u8, g: int) -> int {
	format := be16(cov, 0) or_else 0
	n := be16(cov, 2) or_else 0
	switch format {
	case 1:
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			v := be16(cov, 4 + 2 * mid) or_else -1
			if v < 0 {
				return -1
			}
			if v < g {
				lo = mid + 1
			} else if v > g {
				hi = mid
			} else {
				return mid
			}
		}
	case 2:
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			rec := 4 + 6 * mid
			start := be16(cov, rec) or_else -1
			end := be16(cov, rec + 2) or_else -1
			if start < 0 {
				return -1
			}
			if g < start {
				hi = mid
			} else if g > end {
				lo = mid + 1
			} else {
				return (be16(cov, rec + 4) or_else 0) + g - start
			}
		}
	}
	return -1
}

// class_of is g's class in a ClassDef table (0 when unlisted).
@(private = "file")
class_of :: proc(cd: []u8, g: int) -> int {
	switch be16(cd, 0) or_else 0 {
	case 1:
		first := be16(cd, 2) or_else 0
		n := be16(cd, 4) or_else 0
		if g >= first && g < first + n {
			return be16(cd, 6 + 2 * (g - first)) or_else 0
		}
	case 2:
		n := be16(cd, 2) or_else 0
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			rec := 4 + 6 * mid
			start := be16(cd, rec) or_else 0
			end := be16(cd, rec + 2) or_else 0
			if g < start {
				hi = mid
			} else if g > end {
				lo = mid + 1
			} else {
				return be16(cd, rec + 4) or_else 0
			}
		}
	}
	return 0
}

// pair_adjust looks (left, right) up in one PairPos subtable. matched is
// true when the subtable decides the pair (even at 0), which ends the search
// within its lookup.
@(private = "file")
pair_adjust :: proc(st: []u8, left, right: int) -> (adv: int, matched: bool) {
	format := be16(st, 0) or_else 0
	cov := tail(st, be16(st, 2) or_else -1) or_else nil
	if cov == nil {
		return 0, false
	}
	ci := coverage_index(cov, left)
	if ci < 0 {
		return 0, false
	}
	vf1 := be16(st, 4) or_else 0
	vf2 := be16(st, 6) or_else 0
	s1, s2 := value_size(vf1), value_size(vf2)
	switch format {
	case 1:
		nsets := be16(st, 8) or_else 0
		if ci >= nsets {
			return 0, false
		}
		set := tail(st, be16(st, 10 + 2 * ci) or_else -1) or_else nil
		if set == nil {
			return 0, false
		}
		n := be16(set, 0) or_else 0
		rec := 2 + s1 + s2
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			off := 2 + mid * rec
			second := be16(set, off) or_else -1
			if second < 0 {
				return 0, false
			}
			if second < right {
				lo = mid + 1
			} else if second > right {
				hi = mid
			} else {
				return x_advance(set, off + 2, vf1), true
			}
		}
		return 0, false
	case 2:
		cd1 := tail(st, be16(st, 8) or_else -1) or_else nil
		cd2 := tail(st, be16(st, 10) or_else -1) or_else nil
		n1 := be16(st, 12) or_else 0
		n2 := be16(st, 14) or_else 0
		if cd1 == nil || cd2 == nil {
			return 0, false
		}
		c1 := class_of(cd1, left)
		c2 := class_of(cd2, right)
		if c1 >= n1 || c2 >= n2 {
			return 0, true
		}
		off := 16 + (c1 * n2 + c2) * (s1 + s2)
		return x_advance(st, off, vf1), true
	}
	return 0, false
}

// gpos_kerning is the pair's adjustment from the first kern subtable that
// decides it. Fonts whose kern feature has several pair lookups that add up
// are rare (Inter and DejaVu have one); tessera does not add them.
gpos_kerning :: proc(subs: [][]u8, left, right: int) -> int {
	for st in subs {
		if adv, matched := pair_adjust(st, left, right); matched {
			return adv
		}
	}
	return 0
}
