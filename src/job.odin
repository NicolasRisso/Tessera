package tessera

import "core:fmt"
import "core:strconv"
import "core:strings"

// A Job is everything one run produces: scenes played one after another into
// one output file. `grid` builds a one-scene job from the command line; `run`
// loads one from JSON.

End :: enum {
	Hold,  // keep the last frame
	Black, // show the background
	Loop,  // start the source again
}

Cell :: struct {
	src:   string, // video or still image path
	label: string, // drawn in the cell; "" for none
	start: f64,    // seconds into the source where the cell begins
	fit:   Fit,
	end:   End,    // what the cell shows after its source runs out
}

Anchor :: enum {
	TL, TC, TR,
	CL, CC, CR,
	BL, BC, BR,
}

// Coord is a position in pixels, or a fraction of the canvas ("50%").
Coord :: struct {
	value:    f32,
	fraction: bool,
}

Text :: struct {
	text:          string, // UTF-8, '\n' breaks lines
	x, y:          Coord,
	anchor:        Anchor,
	size:          f32, // pixel height of the em
	color:         Color,
	outline_px:    f32,
	outline_color: Color,
	shadow_dx:     f32,
	shadow_dy:     f32,
	shadow_blur:   f32,
	shadow_color:  Color,
	box_color:     Color, // box_color.a == 0: no box
	box_pad:       f32,
	box_radius:    f32,
	from, to:      f64, // seconds within the scene; to <= 0 means the scene's end
	fade:          f64, // seconds of fade in and out
}

Layout :: struct {
	cols, rows: int, // 0: chosen by grid_dims
	gap:        int,
	margin:     int,
	label_size: f32, // 0: from the cell height
	title:      string, // a band above the grid; "" for none
}

Duration_Rule :: enum {
	Longest,
	Shortest,
}

// Scene_Duration is a rule or a number of seconds.
Scene_Duration :: union {
	f64,
	Duration_Rule,
}

// Caption is a timed line in the house style (bottom centre, on a box),
// sized from the canvas once it is known.
Caption :: struct {
	text:     string,
	from, to: f64, // to <= 0: the scene's end
}

Scene :: struct {
	cells:      []Cell,
	layout:     Layout,
	duration:   Scene_Duration,
	texts:      []Text,
	captions:   []Caption,
	background: Color,
}

Codec :: enum {
	H264,
	HEVC,
	AV1,
}

Preset_Quality :: enum {
	Visually_Lossless,
	High,
	Small,
}

CRF :: distinct int

// Quality is a preset (searched for) or an explicit CRF.
Quality :: union {
	Preset_Quality,
	CRF,
}

Metric :: enum {
	SSIM,
	VMAF,
}

Encode_Settings :: struct {
	codec:       Codec,
	quality:     Quality,
	max_size_mb: f64, // 0: no cap
	preset:      string, // encoder preset; "" for the codec's default
	keep_master: bool,
	force:       bool, // encode even when the size cap cannot be met
	metric:      Metric,
}

Job :: struct {
	output:    string,
	width:     int, // 0 with native: sized from the sources
	height:    int,
	native:    bool,
	fps:       Rational, // {0, 0}: the highest input rate, capped at 60
	scenes:    []Scene,
	encode:    Encode_Settings,
	font_path: string, // "" for the embedded font
	ffmpeg:    string,
	threads:   int, // 0: the core count minus one
	dry_run:   bool,
}

default_text :: proc() -> Text {
	return Text{
		anchor = .TL,
		size = 48,
		color = {255, 255, 255, 255},
		outline_color = {0, 0, 0, 255},
		shadow_color = {0, 0, 0, 160},
		box_color = {0, 0, 0, 0},
	}
}

default_layout :: proc() -> Layout {
	return Layout{gap = DEFAULT_GAP, margin = DEFAULT_MARGIN}
}

default_scene :: proc() -> Scene {
	return Scene{layout = default_layout(), duration = Duration_Rule.Longest, background = DEFAULT_BG}
}

default_encode :: proc() -> Encode_Settings {
	return Encode_Settings{codec = .H264, quality = Preset_Quality.Visually_Lossless}
}

// parse_color reads #RGB, #RRGGBB or #RRGGBBAA (the # is optional).
parse_color :: proc(s: string) -> (c: Color, ok: bool) {
	h := strings.trim_prefix(s, "#")
	hex :: proc(s: string) -> (u8, bool) {
		v, ok := strconv.parse_uint(s, 16)
		return u8(v), ok && v <= 255
	}
	switch len(h) {
	case 3:
		for i in 0 ..< 3 {
			v := hex(h[i:i + 1]) or_return
			c[i] = v * 17
		}
		c.a = 255
		return c, true
	case 6, 8:
		for i in 0 ..< len(h) / 2 {
			c[i] = hex(h[i * 2:][:2]) or_return
		}
		if len(h) == 6 {
			c.a = 255
		}
		return c, true
	}
	return {}, false
}

// parse_coord reads "120" (pixels) or "50%" (a fraction of the canvas).
parse_coord :: proc(s: string) -> (c: Coord, ok: bool) {
	if strings.has_suffix(s, "%") {
		v := strconv.parse_f32(s[:len(s) - 1]) or_return
		return Coord{v / 100, true}, true
	}
	v := strconv.parse_f32(s) or_return
	return Coord{v, false}, true
}

// parse_quality reads visually-lossless | high | small | crf=N.
parse_quality :: proc(s: string) -> (q: Quality, ok: bool) {
	switch s {
	case "visually-lossless", "visually_lossless", "lossless":
		return Preset_Quality.Visually_Lossless, true
	case "high":
		return Preset_Quality.High, true
	case "small":
		return Preset_Quality.Small, true
	}
	if strings.has_prefix(s, "crf=") {
		n, nok := strconv.parse_int(s[4:])
		if nok && n >= 0 && n <= 63 {
			return CRF(n), true
		}
	}
	return nil, false
}

// parse_fps reads 60, 29.97 or 30000/1001.
parse_fps :: proc(s: string) -> (r: Rational, ok: bool) {
	if strings.contains_rune(s, '/') {
		r = parse_rational(s)
	} else {
		v := strconv.parse_f64(s) or_return
		if v == f64(int(v)) {
			r = {int(v), 1}
		} else {
			r = {int(v * 1000 + 0.5), 1000}
		}
	}
	return r, r.num > 0 && r.den > 0 && rational_f64(r) <= 240
}

quality_string :: proc(q: Quality, allocator := context.temp_allocator) -> string {
	switch v in q {
	case Preset_Quality:
		switch v {
		case .Visually_Lossless:
			return "visually-lossless"
		case .High:
			return "high"
		case .Small:
			return "small"
		}
	case CRF:
		return fmt.aprintf("crf=%d", int(v), allocator = allocator)
	}
	return "?"
}
