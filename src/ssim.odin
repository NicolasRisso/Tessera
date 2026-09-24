package tessera

import "core:fmt"
import "core:math"
import "core:path/filepath"

// SSIM on the luma plane: the standard Gaussian window (11×11, σ = 1.5),
// K1 = 0.01, K2 = 0.03, L = 255, averaged over every window that fits in the
// frame. Separable: each row is filtered horizontally into a ring of 11
// rows, and each output row sums the ring vertically.

SSIM_N :: 11
SSIM_C1 :: (0.01 * 255) * (0.01 * 255)
SSIM_C2 :: (0.03 * 255) * (0.03 * 255)

ssim_kernel :: proc() -> (g: [SSIM_N]f32) {
	sum: f64
	for i in 0 ..< SSIM_N {
		d := f64(i - SSIM_N / 2)
		v := math.exp(-d * d / (2 * 1.5 * 1.5))
		g[i] = f32(v)
		sum += v
	}
	for &v in g {
		v = f32(f64(v) / sum)
	}
	return
}

// ssim_plane is the mean SSIM of two w×h 8-bit planes.
ssim_plane :: proc(a, b: []u8, w, h: int) -> f64 {
	if w < SSIM_N || h < SSIM_N {
		return ssim_global(a[:w * h], b[:w * h])
	}
	g := ssim_kernel()
	ow, oh := w - SSIM_N + 1, h - SSIM_N + 1
	// Rows as floats, their products, and the ring of filtered rows
	// (μa, μb, E[a²], E[b²], E[ab] before the vertical pass).
	row := make([]f32, 5 * w)
	defer delete(row)
	fa, fb, faa, fbb, fab := row[:w], row[w:][:w], row[2 * w:][:w], row[3 * w:][:w], row[4 * w:][:w]
	ring := make([]f32, 5 * SSIM_N * ow)
	defer delete(ring)
	stats := make([]f32, 5 * ow)
	defer delete(stats)
	slot :: #force_inline proc(ring: []f32, q, r, ow: int) -> []f32 {
		return ring[(q * SSIM_N + r) * ow:][:ow]
	}
	total: f64
	for y in 0 ..< h {
		ra := a[y * w:][:w]
		rb := b[y * w:][:w]
		for x in 0 ..< w {
			va, vb := f32(ra[x]), f32(rb[x])
			fa[x], fb[x] = va, vb
			faa[x], fbb[x], fab[x] = va * va, vb * vb, va * vb
		}
		r := y % SSIM_N
		srcs := [5][]f32{fa, fb, faa, fbb, fab}
		for q in 0 ..< 5 {
			out := slot(ring, q, r, ow)
			src := srcs[q]
			for x in 0 ..< ow {
				s: f32
				#unroll for k in 0 ..< SSIM_N {
					s += g[k] * src[x + k]
				}
				out[x] = s
			}
		}
		if y < SSIM_N - 1 {
			continue
		}
		// Output row y−10 from ring rows y−10 ..= y: each statistic summed
		// down the ring a whole row at a time (contiguous, so it vectorises),
		// then the SSIM formula across the row.
		yo := y - (SSIM_N - 1)
		for q in 0 ..< 5 {
			out := stats[q * ow:][:ow]
			first := slot(ring, q, yo % SSIM_N, ow)
			g0 := g[0]
			for x in 0 ..< ow {
				out[x] = g0 * first[x]
			}
			for k in 1 ..< SSIM_N {
				src := slot(ring, q, (yo + k) % SSIM_N, ow)
				gk := g[k]
				for x in 0 ..< ow {
					out[x] += gk * src[x]
				}
			}
		}
		mua_row, mub_row := stats[:ow], stats[ow:][:ow]
		eaa, ebb, eab := stats[2 * ow:][:ow], stats[3 * ow:][:ow], stats[4 * ow:][:ow]
		line: f64
		for x in 0 ..< ow {
			mua, mub := mua_row[x], mub_row[x]
			va := eaa[x] - mua * mua
			vb := ebb[x] - mub * mub
			cov := eab[x] - mua * mub
			num := (2 * mua * mub + SSIM_C1) * (2 * cov + SSIM_C2)
			den := (mua * mua + mub * mub + SSIM_C1) * (va + vb + SSIM_C2)
			line += f64(num / den)
		}
		total += line
	}
	return total / f64(ow * oh)
}

// ssim_global is SSIM over one window the size of the plane, for planes
// smaller than the Gaussian window.
ssim_global :: proc(a, b: []u8) -> f64 {
	n := f64(len(a))
	if n == 0 {
		return 1
	}
	sa, sb, saa, sbb, sab: f64
	for i in 0 ..< len(a) {
		va, vb := f64(a[i]), f64(b[i])
		sa += va
		sb += vb
		saa += va * va
		sbb += vb * vb
		sab += va * vb
	}
	mua, mub := sa / n, sb / n
	va := saa / n - mua * mua
	vb := sbb / n - mub * mub
	cov := sab / n - mua * mub
	return ((2 * mua * mub + SSIM_C1) * (2 * cov + SSIM_C2)) / ((mua * mua + mub * mub + SSIM_C1) * (va + vb + SSIM_C2))
}

SSIM_Result :: struct {
	frames: [dynamic]f64,
	mean:   f64,
	min:    f64,
}

ssim_result_delete :: proc(r: ^SSIM_Result) {
	delete(r.frames)
}

// ssim_summarise fills mean and min from the per-frame scores (any metric).
ssim_summarise :: proc(r: ^SSIM_Result) {
	r.mean, r.min = 0, 0
	for s, i in r.frames {
		r.mean += s
		r.min = s if i == 0 else min(r.min, s)
	}
	if len(r.frames) > 0 {
		r.mean /= f64(len(r.frames))
	}
}

@(private = "file")
SSIM_Batch :: struct {
	a, b:   [][]u8,
	w, h:   int,
	scores: []f64,
}

@(private = "file")
ssim_task :: proc(data: rawptr, i: int) {
	batch := (^SSIM_Batch)(data)
	batch.scores[i] = ssim_plane(batch.a[i], batch.b[i], batch.w, batch.h)
}

// ssim_compare decodes a (from a_start) and b (from b_start) and scores
// their luma frame by frame, up to max_frames (0: until either ends).
ssim_compare :: proc(tools: Tools, a: Probe, a_start: f64, b: Probe, b_start: f64, max_frames: int, workers: ^Workers, tmp: string) -> (res: SSIM_Result, err: Err) {
	if a.width != b.width || a.height != b.height {
		return res, fmt.aprintf("ssim: %s is %dx%d but %s is %dx%d", a.path, a.width, a.height, b.path, b.width, b.height)
	}
	la, _ := filepath.join({tmp, "ssim-a.log"}, context.temp_allocator)
	lb, _ := filepath.join({tmp, "ssim-b.log"}, context.temp_allocator)
	da := decoder_open(tools, a, a_start, la, "yuv420p", max_frames) or_return
	defer decoder_close(&da)
	db := decoder_open(tools, b, b_start, lb, "yuv420p", max_frames) or_return
	defer decoder_close(&db)

	n := max(workers.threads * 2, 1)
	bufs := make([][]u8, 2 * n)
	defer {
		for buf in bufs {
			delete(buf)
		}
		delete(bufs)
	}
	for &buf in bufs {
		buf = make([]u8, da.frame_bytes)
	}
	scores := make([]f64, n)
	defer delete(scores)
	for max_frames <= 0 || len(res.frames) < max_frames {
		k := 0
		for k < n && (max_frames <= 0 || len(res.frames) + k < max_frames) {
			if !decoder_read(&da, bufs[k]) || !decoder_read(&db, bufs[n + k]) {
				break
			}
			k += 1
		}
		if k == 0 {
			break
		}
		batch := SSIM_Batch{bufs[:k], bufs[n:][:k], a.width, a.height, scores[:k]}
		workers_run(workers, k, ssim_task, &batch)
		append(&res.frames, ..scores[:k])
		if k < n {
			break
		}
	}
	if len(res.frames) == 0 {
		return res, fmt.aprintf("ssim: no frames to compare in %s and %s", a.path, b.path)
	}
	ssim_summarise(&res)
	return res, nil
}
