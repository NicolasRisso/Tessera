package tessera

import "core:math"

// Axis_Weights maps each output sample of one axis to a run of source samples:
// output i reads source indices first[i] ..< first[i]+count[i] with the
// weights weight[i*stride:][:count[i]], which sum to 1.
Axis_Weights :: struct {
	first:    []i32,
	count:    []i32,
	weight:   []f32,
	stride:   int,
	identity: bool, // scale 1: output i is source src_off+i
}

// catmull_rom is the cubic convolution kernel with a = -0.5.
catmull_rom :: proc "contextless" (d: f64) -> f64 {
	A :: -0.5
	x := abs(d)
	if x < 1 {
		return ((A + 2) * x - (A + 3)) * x * x + 1
	}
	if x < 2 {
		return ((A * x - 5 * A) * x + 8 * A) * x - 4 * A
	}
	return 0
}

// axis_weights precomputes the filter of one axis: source samples
// [src_off, src_off+src_len) onto dst_len output samples. Shrinking uses exact
// area coverage, enlarging Catmull-Rom, equal lengths a straight copy.
axis_weights :: proc(src_off, src_len, dst_len: int, allocator := context.allocator) -> Axis_Weights {
	assert(src_len > 0 && dst_len > 0)
	aw: Axis_Weights
	aw.first = make([]i32, dst_len, allocator)
	aw.count = make([]i32, dst_len, allocator)
	if src_len == dst_len {
		aw.identity = true
		aw.stride = 1
		aw.weight = make([]f32, dst_len, allocator)
		for i in 0 ..< dst_len {
			aw.first[i] = i32(src_off + i)
			aw.count[i] = 1
			aw.weight[i] = 1
		}
		return aw
	}
	inv := f64(src_len) / f64(dst_len) // source samples per output sample
	if dst_len < src_len {
		// Area: output i covers [i*inv, (i+1)*inv) of the source.
		aw.stride = int(math.ceil(inv)) + 1
		aw.weight = make([]f32, dst_len * aw.stride, allocator)
		for i in 0 ..< dst_len {
			s0 := f64(i) * inv
			s1 := min(f64(i + 1) * inv, f64(src_len))
			j0 := int(math.floor(s0))
			j1 := min(int(math.ceil(s1)), src_len) // exclusive
			w := aw.weight[i * aw.stride:][:aw.stride]
			sum: f64
			n := 0
			for j in j0 ..< j1 {
				cover := min(s1, f64(j + 1)) - max(s0, f64(j))
				if cover <= 1e-9 {
					if n == 0 {
						j0 += 1
					}
					continue
				}
				w[n] = f32(cover)
				sum += cover
				n += 1
			}
			for k in 0 ..< n {
				w[k] = f32(f64(w[k]) / sum)
			}
			aw.first[i] = i32(src_off + j0)
			aw.count[i] = i32(n)
		}
		return aw
	}
	// Catmull-Rom: four taps around the sample's centre, clamped at the edges
	// (clamped taps fold onto the edge sample).
	aw.stride = 4
	aw.weight = make([]f32, dst_len * 4, allocator)
	for i in 0 ..< dst_len {
		c := (f64(i) + 0.5) * inv - 0.5
		base := int(math.floor(c))
		lo := clamp(base - 1, 0, src_len - 1)
		hi := clamp(base + 2, 0, src_len - 1)
		acc: [4]f64
		sum: f64
		for t in base - 1 ..= base + 2 {
			k := catmull_rom(c - f64(t))
			j := clamp(t, 0, src_len - 1)
			acc[j - lo] += k
			sum += k
		}
		w := aw.weight[i * 4:][:4]
		for k in 0 ..= hi - lo {
			w[k] = f32(acc[k] / sum)
		}
		aw.first[i] = i32(src_off + lo)
		aw.count[i] = i32(hi - lo + 1)
	}
	return aw
}

axis_weights_delete :: proc(aw: ^Axis_Weights) {
	delete(aw.first)
	delete(aw.count)
	delete(aw.weight)
	aw^ = {}
}

// Resampler turns the crop rectangle of a src_w×src_h source into a
// dst_w×dst_h image. Weights are computed once; resample_rows runs per frame.
Resampler :: struct {
	src_w, src_h: int,
	crop:         Rect,
	dst_w, dst_h: int,
	h, v:         Axis_Weights,
}

resampler_make :: proc(src_w, src_h: int, crop: Rect, dst_w, dst_h: int, allocator := context.allocator) -> Resampler {
	return Resampler{
		src_w = src_w,
		src_h = src_h,
		crop = crop,
		dst_w = dst_w,
		dst_h = dst_h,
		h = axis_weights(crop.x, crop.w, dst_w, allocator),
		v = axis_weights(crop.y, crop.h, dst_h, allocator),
	}
}

resampler_delete :: proc(r: ^Resampler) {
	axis_weights_delete(&r.h)
	axis_weights_delete(&r.v)
}

// resampler_buffer_len is the length of the scratch row resample_rows needs.
resampler_buffer_len :: proc(r: ^Resampler) -> int {
	return r.crop.w * 3
}

// resample_rows writes output rows [y0, y1) of the resampled image into dst
// with its top left at (dx, dy). Only rows and columns inside clip are
// written. buf is a scratch row of resampler_buffer_len floats, one per
// thread. The vertical pass runs first, into buf, so that every output row is
// independent of the others; the result is the same as horizontal-first.
resample_rows :: proc(r: ^Resampler, src: Image, dst: ^Image, dx, dy: int, y0, y1: int, clip: Rect, buf: []f32) {
	assert(src.w == r.src_w && src.h == r.src_h)
	area := rect_intersect(rect_intersect(Rect{dx, dy + y0, r.dst_w, y1 - y0}, clip), image_rect(dst^))
	if rect_empty(area) {
		return
	}
	ox0 := area.x - dx // output columns [ox0, ox1)
	ox1 := ox0 + area.w
	cw3 := r.crop.w * 3
	for oy in area.y - dy ..< area.y - dy + area.h {
		out := dst.pix[((dy + oy) * dst.w + area.x) * 3:][:area.w * 3]
		vfirst := int(r.v.first[oy])
		vcount := int(r.v.count[oy])
		if r.v.identity && r.h.identity {
			copy(out, src.pix[(vfirst * src.w + r.crop.x + ox0) * 3:][:area.w * 3])
			continue
		}
		// Vertical pass: the weighted sum of the source rows, crop columns only.
		row := buf[:cw3]
		{
			vw := r.v.weight[oy * r.v.stride:]
			s := src.pix[(vfirst * src.w + r.crop.x) * 3:][:cw3]
			w := vw[0]
			for j in 0 ..< cw3 {
				row[j] = w * f32(s[j])
			}
			for k in 1 ..< vcount {
				s = src.pix[((vfirst + k) * src.w + r.crop.x) * 3:][:cw3]
				w = vw[k]
				for j in 0 ..< cw3 {
					row[j] += w * f32(s[j])
				}
			}
		}
		// Horizontal pass.
		for ox in ox0 ..< ox1 {
			first := (int(r.h.first[ox]) - r.crop.x) * 3
			n := int(r.h.count[ox])
			hw := r.h.weight[ox * r.h.stride:][:n]
			a0, a1, a2: f32
			for k in 0 ..< n {
				w := hw[k]
				p := first + k * 3
				a0 += w * row[p]
				a1 += w * row[p + 1]
				a2 += w * row[p + 2]
			}
			o := (ox - ox0) * 3
			out[o] = to_u8(a0)
			out[o + 1] = to_u8(a1)
			out[o + 2] = to_u8(a2)
		}
	}
}

@(private)
to_u8 :: #force_inline proc "contextless" (v: f32) -> u8 {
	return u8(clamp(v + 0.5, 0, 255))
}

// resample is resample_rows over the whole output, with its own scratch row.
resample :: proc(r: ^Resampler, src: Image, dst: ^Image, dx, dy: int) {
	buf := make([]f32, resampler_buffer_len(r), context.temp_allocator)
	resample_rows(r, src, dst, dx, dy, 0, r.dst_h, image_rect(dst^), buf)
}
