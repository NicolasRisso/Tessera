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
