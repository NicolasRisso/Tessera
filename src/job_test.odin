package tessera

import "core:strings"
import "core:testing"

VALID_JOB :: `{
	// comments and trailing commas are allowed
	"output": "out/showcase.mp4",
	"size": "1920x1080",
	"fps": 60,
	"encode": {"codec": "h264", "quality": "high", "max_size_mb": 16},
	"scenes": [
		{
			"duration": 3,
			"texts": [{"text": "Fusefall", "size": 96, "anchor": "CC", "x": "50%", "y": "45%",
			           "shadow_dy": 3, "shadow_blur": 4, "shadow_color": "#000000A0", "fade": 0.5}],
		},
		{
			"cells": [
				{"src": "a.mp4", "label": "A", "start": 2.5},
				{"src": "/abs/b.mp4", "label": "B", "fit": "cover", "end": "loop"},
				"c.png",
			],
			"layout": {"cols": 2, "rows": 2, "title": "Two by two", "label_pos": "below"},
			"captions": [{"text": "note", "from": 1, "to": 4}],
			"duration": "shortest",
			"background": "#101010",
		},
	],
}`

@(test)
test_job_valid_parses :: proc(t: ^testing.T) {
	job, err := parse_job(VALID_JOB, "job.json", "/jobs")
	testing.expectf(t, err == nil, "%v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, job.output, "/jobs/out/showcase.mp4")
	testing.expect_value(t, job.fps, Rational{60, 1})
	testing.expect_value(t, job.encode.quality, Quality(Preset_Quality.High))
	testing.expect_value(t, job.encode.max_size_mb, 16)
	testing.expect_value(t, len(job.scenes), 2)
	s0 := job.scenes[0]
	testing.expect_value(t, s0.duration, Scene_Duration(3.0))
	testing.expect_value(t, len(s0.texts), 1)
	testing.expect_value(t, s0.texts[0].anchor, Anchor.CC)
	testing.expect_value(t, s0.texts[0].x, Coord{0.5, true})
	testing.expect_value(t, s0.texts[0].shadow_color, Color{0, 0, 0, 0xA0})
	s1 := job.scenes[1]
	testing.expect_value(t, len(s1.cells), 3)
	testing.expect_value(t, s1.cells[0].src, "/jobs/a.mp4")
	testing.expect_value(t, s1.cells[0].start, 2.5)
	testing.expect_value(t, s1.cells[1].src, "/abs/b.mp4")
	testing.expect_value(t, s1.cells[1].fit, Fit.Cover)
	testing.expect_value(t, s1.cells[1].end, End.Loop)
	testing.expect_value(t, s1.cells[2].src, "/jobs/c.png")
	testing.expect_value(t, s1.layout.title, "Two by two")
	testing.expect_value(t, s1.layout.label_pos, Label_Pos.Below)
	testing.expect_value(t, s0.layout.label_pos, Label_Pos.Above) // the default
	testing.expect_value(t, s1.duration, Scene_Duration(Duration_Rule.Shortest))
	testing.expect_value(t, s1.background, Color{16, 16, 16, 255})
	testing.expect_value(t, s1.captions[0].to, 4)
}

@(test)
test_job_errors_name_the_field :: proc(t: ^testing.T) {
	Case :: struct {
		from, to: string, // replace in VALID_JOB
		field:    string, // must appear in the error
	}
	cases := []Case {
		{`"output": "out/showcase.mp4",`, ``, "output"},
		{`"size": "1920x1080"`, `"size": "1921x1080"`, "size"},
		{`"fps": 60`, `"fps": "fast"`, "fps"},
		{`"codec": "h264"`, `"codec": "mpeg2"`, "encode.codec"},
		{`"quality": "high"`, `"quality": "great"`, "encode.quality"},
		{`"max_size_mb": 16`, `"max_size_mb": "16"`, "encode.max_size_mb"},
		{`"duration": 3,`, `"duration": -1,`, "scenes[0].duration"},
		{`"duration": 3,`, ``, "scenes[0].duration"},
		{`"size": 96`, `"size": 0`, "scenes[0].texts[0].size"},
		{`"anchor": "CC"`, `"anchor": "middle"`, "scenes[0].texts[0].anchor"},
		{`"x": "50%"`, `"x": "half"`, "scenes[0].texts[0].x"},
		{`"shadow_color": "#000000A0"`, `"shadow_color": "black"`, "scenes[0].texts[0].shadow_color"},
		{`"fade": 0.5`, `"fade": 0.5, "colour": "#fff"`, "scenes[0].texts[0]"},
		{`"start": 2.5`, `"start": -2`, "scenes[1].cells[0].start"},
		{`"fit": "cover"`, `"fit": "stretch"`, "scenes[1].cells[1].fit"},
		{`"end": "loop"`, `"end": "bounce"`, "scenes[1].cells[1].end"},
		{`{"src": "a.mp4", `, `{"source": "a.mp4", `, "scenes[1].cells[0]"},
		{`"cols": 2, "rows": 2`, `"cols": 1, "rows": 2`, "scenes[1].layout"},
		{`"label_pos": "below"`, `"label_pos": "over"`, "scenes[1].layout.label_pos"},
		{`"from": 1, "to": 4`, `"from": 4, "to": 1`, "scenes[1].captions[0].to"},
		{`"background": "#101010"`, `"background": 16`, "scenes[1].background"},
		{`"scenes": [`, `"scenes": 3, "unused": [`, "scenes"},
	}
	for c in cases {
		text, _ := strings.replace(VALID_JOB, c.from, c.to, 1, context.temp_allocator)
		testing.expectf(t, text != VALID_JOB, "case %q does not change the job", c.field)
		_, err := parse_job(text, "job.json", "/jobs")
		if err == nil {
			testing.expectf(t, false, "%s: no error", c.field)
			continue
		}
		msg := err.?
		testing.expectf(t, strings.contains(msg, c.field) && strings.has_prefix(msg, "job.json"), "%s: the error does not name it: %s", c.field, msg)
	}
	_, err := parse_job(`{"output": "x.mp4", "scenes": [}`, "bad.json", "")
	testing.expectf(t, err != nil && strings.contains(err.?, "bad.json:1:"), "a JSON error has a position: %v", err)
	free_all(context.temp_allocator)
}
