package tessera

import "core:testing"

@(test)
test_windows_short_video_is_one_window :: proc(t: ^testing.T) {
	w := plan_windows(600, {60, 1})
	defer delete(w)
	testing.expect_value(t, len(w), 1)
	testing.expect_value(t, w[0], Window{0, 600})
}

@(test)
test_windows_spread_evenly :: proc(t: ^testing.T) {
	w := plan_windows(2400, {60, 1})
	defer delete(w)
	testing.expect_value(t, len(w), 6)
	for win, i in w {
		testing.expect_value(t, win.frames, 120)
		first := int(win.start * 60 + 0.5)
		testing.expectf(t, first >= 0 && first + 120 <= 2400, "window %d escapes: %v", i, win)
		testing.expectf(t, abs(win.start * 60 - f64(first)) < 1e-9, "window %d starts between frames", i)
		if i > 0 {
			testing.expectf(t, win.start > w[i - 1].start + 2, "windows %d and %d overlap", i - 1, i)
		}
	}
	// Centred on the sixths of the video.
	testing.expectf(t, abs(w[0].start + 1 - 40.0 / 12) < 0.02, "first window at %v", w[0].start)
}

@(test)
test_targets_are_ordered :: proc(t: ^testing.T) {
	vl, hi, sm := target_for(.Visually_Lossless), target_for(.High), target_for(.Small)
	testing.expect(t, vl.mean > hi.mean && hi.mean > sm.mean)
	testing.expect(t, vl.min > hi.min && hi.min > sm.min)
	testing.expect(t, meets(Candidate{mean = 0.991, min = 0.981}, vl))
	testing.expect(t, !meets(Candidate{mean = 0.995, min = 0.979}, vl))
}

@(test)
test_estimate_counts_the_files_keyframes :: proc(t: ^testing.T) {
	// Six 120-frame windows, each a 100 kB keyframe and 119 frames of 10 kB.
	ps := Packet_Stats{key_bytes = 6 * 100_000, keys = 6, other_bytes = 6 * 119 * 10_000, others = 6 * 119}
	// A 2400-frame file with a keyframe every 600 frames has 4 of them.
	got := estimate_bytes(ps, 6, 2400, 600)
	want := 4.0 * 100_000 + 2396.0 * 10_000
	testing.expectf(t, abs(got - want) < 1, "estimate %v, want %v", got, want)
	// One keyframe only (libaom through ffmpeg).
	got = estimate_bytes(ps, 6, 2400, 0)
	testing.expectf(t, abs(got - (100_000 + 2399.0 * 10_000)) < 1, "no interval: %v", got)
	// Scene cuts inside the windows count at their rate: two extra
	// keyframes in 720 window frames are 2400 × 2/720 ≈ 6.7 in the file.
	cut := Packet_Stats{key_bytes = 8 * 100_000, keys = 8, other_bytes = 712 * 10_000, others = 712}
	got = estimate_bytes(cut, 6, 2400, 600)
	keys := 4 + 2400.0 * 2 / 720
	testing.expectf(t, abs(got - (keys * 100_000 + (2400 - keys) * 10_000)) < 1, "with cuts: %v", got)
}

@(test)
test_file_keyint :: proc(t: ^testing.T) {
	e := default_encode()
	testing.expect_value(t, file_keyint(e, {60, 1}), 600)
	testing.expect_value(t, file_keyint(e, {30000, 1001}), 300)
	e.codec = .HEVC
	testing.expect_value(t, file_keyint(e, {60, 1}), 250)
	e.codec = .AV1
	testing.expect_value(t, file_keyint(e, {60, 1}), 0)
	testing.expect(t, add_encoder_option(&e, "g=120"))
	testing.expect_value(t, file_keyint(e, {60, 1}), 120)
	delete(e.options)
}
