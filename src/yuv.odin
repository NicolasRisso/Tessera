package tessera

// RGB8 → YUV420P, BT.709, limited range, on 0–1 values:
//   Y  = 16 + 219·(0.2126 R + 0.7152 G + 0.0722 B)
//   Cb = 128 + 224·(B − Y′)/1.8556
//   Cr = 128 + 224·(R − Y′)/1.5748
// chroma averaged over each 2×2 block, rounded and clamped. The output is
// tagged bt709 / tv range (COLOR_TAGS). Fixed point: 16 fractional bits for
// luma, 18 for chroma (a 2×2 sum is four pixels).

@(private = "file")
KR :: 0.2126
@(private = "file")
KG :: 0.7152
@(private = "file")
KB :: 0.0722

@(private = "file")
fix :: proc "contextless" (v: f64, bits: uint) -> i32 {
	s := v * f64(i64(1) << bits)
	return i32(s + 0.5 if s >= 0 else s - 0.5)
}

@(private = "file")
Y_SCALE :: 219.0 / 255.0
@(private = "file")
CB_SCALE :: 224.0 / 255.0 / 1.8556
@(private = "file")
CR_SCALE :: 224.0 / 255.0 / 1.5748

YUV_Coeffs :: struct {
	yr, yg, yb:    i32,
	cbr, cbg, cbb: i32,
	crr, crg, crb: i32,
}

@(private = "file")
coeffs_709 :: proc "contextless" () -> YUV_Coeffs {
	return YUV_Coeffs{
		yr = fix(KR * Y_SCALE, 16),
		yg = fix(KG * Y_SCALE, 16),
		yb = fix(KB * Y_SCALE, 16),
		cbr = fix(-KR * CB_SCALE, 16),
		cbg = fix(-KG * CB_SCALE, 16),
		cbb = fix((1 - KB) * CB_SCALE, 16),
		crr = fix((1 - KR) * CR_SCALE, 16),
		crg = fix(-KG * CR_SCALE, 16),
		crb = fix(-KB * CR_SCALE, 16),
	}
}

// yuv_frame_size is the byte size of a w×h YUV420P frame.
yuv_frame_size :: proc(w, h: int) -> int {
	return w * h + 2 * (w / 2) * (h / 2)
}

// rgb_to_yuv420p converts rows [y0, y1) of img (both even) into out, a whole
// YUV420P frame of img's size laid out Y, then U, then V.
rgb_to_yuv420p :: proc(img: Image, out: []u8, y0, y1: int) {
	assert(img.w % 2 == 0 && img.h % 2 == 0, "yuv420p needs even dimensions")
	assert(y0 % 2 == 0 && y1 % 2 == 0)
	c := coeffs_709()
	w, h := img.w, img.h
	cw := w / 2
	yplane := out[:w * h]
	uplane := out[w * h:][:cw * (h / 2)]
	vplane := out[w * h + cw * (h / 2):][:cw * (h / 2)]
	for y := y0; y < y1; y += 2 {
		r0 := img.pix[y * w * 3:][:w * 3]
		r1 := img.pix[(y + 1) * w * 3:][:w * 3]
		o0 := yplane[y * w:][:w]
		o1 := yplane[(y + 1) * w:][:w]
		ou := uplane[(y / 2) * cw:][:cw]
		ov := vplane[(y / 2) * cw:][:cw]
		for x in 0 ..< cw {
			i := x * 6
			sr, sg, sb: i32
			#unroll for k in 0 ..< 2 {
				{
					r, g, b := i32(r0[i + k * 3]), i32(r0[i + k * 3 + 1]), i32(r0[i + k * 3 + 2])
					o0[x * 2 + k] = u8((c.yr * r + c.yg * g + c.yb * b + (16 << 16) + (1 << 15)) >> 16)
					sr += r
					sg += g
					sb += b
				}
				{
					r, g, b := i32(r1[i + k * 3]), i32(r1[i + k * 3 + 1]), i32(r1[i + k * 3 + 2])
					o1[x * 2 + k] = u8((c.yr * r + c.yg * g + c.yb * b + (16 << 16) + (1 << 15)) >> 16)
					sr += r
					sg += g
					sb += b
				}
			}
			// Sums of four pixels: 18 fractional bits. Both results lie in
			// 16..240 before rounding, so no clamp is needed; keep one anyway
			// for rounding at the extremes.
			cb := (c.cbr * sr + c.cbg * sg + c.cbb * sb + (128 << 18) + (1 << 17)) >> 18
			cr := (c.crr * sr + c.crg * sg + c.crb * sb + (128 << 18) + (1 << 17)) >> 18
			ou[x] = u8(clamp(cb, 16, 240))
			ov[x] = u8(clamp(cr, 16, 240))
		}
	}
}
