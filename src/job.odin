package tessera

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
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

// ---- Loading a job file (JSON, comments and trailing commas allowed) ----

JOB_FIELDS :: []string{"output", "size", "fps", "font", "ffmpeg", "threads", "encode", "scenes"}
ENCODE_FIELDS :: []string{"codec", "quality", "max_size_mb", "preset", "keep_master", "force", "metric"}
SCENE_FIELDS :: []string{"cells", "layout", "duration", "texts", "captions", "background"}
LAYOUT_FIELDS :: []string{"cols", "rows", "gap", "margin", "label_size", "title"}
CELL_FIELDS :: []string{"src", "label", "start", "fit", "end"}
CAPTION_FIELDS :: []string{"text", "from", "to"}
TEXT_FIELDS :: []string {
	"text", "x", "y", "anchor", "size", "color", "outline_px", "outline_color",
	"shadow_dx", "shadow_dy", "shadow_blur", "shadow_color",
	"box_color", "box_pad", "box_radius", "from", "to", "fade",
}

// load_job reads a job file. Relative paths inside it are relative to the
// file's directory.
load_job :: proc(path: string) -> (job: Job, err: Err) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return job, fmt.aprintf("%s: %v", path, rerr)
	}
	return parse_job(string(data), path, filepath.dir(path))
}

// parse_job turns the text of a job file into a validated Job. Every error
// names the file and the field.
parse_job :: proc(text, name, base_dir: string) -> (job: Job, err: Err) {
	p := json.make_parser_from_string(text, .JSON5, false, context.allocator)
	root, jerr := json.parse_value(&p)
	if jerr != nil || p.curr_token.kind != .EOF {
		pos := p.curr_token.pos
		what := fmt.tprint(jerr) if jerr != nil else "unexpected text after the job"
		return job, fmt.aprintf("%s:%d:%d: not valid JSON (%s)", name, pos.line, pos.column, what)
	}
	jw := Job_Walker{name = name, base = base_dir}
	return jw_job(&jw, root)
}

@(private = "file")
Job_Walker :: struct {
	name: string, // the file, for messages
	base: string, // relative paths start here
}

@(private = "file")
fail :: proc(jw: ^Job_Walker, at: string, format: string, args: ..any) -> Err {
	return fmt.aprintf("%s: %s: %s", jw.name, at, fmt.tprintf(format, ..args))
}

@(private = "file")
as_object :: proc(jw: ^Job_Walker, v: json.Value, at: string, allowed: []string) -> (o: json.Object, err: Err) {
	ok: bool
	if o, ok = v.(json.Object); !ok {
		return nil, fail(jw, at, "expected an object {...}")
	}
	for key in o {
		known := false
		for a in allowed {
			if a == key {
				known = true
				break
			}
		}
		if !known {
			return nil, fail(jw, at, "unknown field %q (known: %s)", key, strings.join(allowed, ", ", context.temp_allocator))
		}
	}
	return o, nil
}

@(private = "file")
as_array :: proc(jw: ^Job_Walker, o: json.Object, key, at: string) -> (a: json.Array, err: Err) {
	v, found := o[key]
	if !found {
		return nil, nil
	}
	ok: bool
	if a, ok = v.(json.Array); !ok {
		return nil, fail(jw, fmt.tprintf("%s.%s", at, key), "expected an array [...]")
	}
	return a, nil
}

@(private = "file")
get_number :: proc(jw: ^Job_Walker, o: json.Object, key, at: string, lo, hi: f64, def: f64) -> (v: f64, err: Err) {
	raw, found := o[key]
	if !found {
		return def, nil
	}
	#partial switch n in raw {
	case json.Float:
		v = n
	case json.Integer:
		v = f64(n)
	case:
		return 0, fail(jw, fmt.tprintf("%s.%s", at, key), "expected a number")
	}
	if v < lo || v > hi {
		return 0, fail(jw, fmt.tprintf("%s.%s", at, key), "%v is outside %v..%v", v, lo, hi)
	}
	return v, nil
}

@(private = "file")
get_string :: proc(jw: ^Job_Walker, o: json.Object, key, at: string, def := "") -> (s: string, err: Err) {
	raw, found := o[key]
	if !found {
		return def, nil
	}
	ok: bool
	if s, ok = raw.(json.String); !ok {
		return "", fail(jw, fmt.tprintf("%s.%s", at, key), "expected a string")
	}
	return s, nil
}

@(private = "file")
get_bool :: proc(jw: ^Job_Walker, o: json.Object, key, at: string) -> (b: bool, err: Err) {
	raw, found := o[key]
	if !found {
		return false, nil
	}
	ok: bool
	if b, ok = raw.(json.Boolean); !ok {
		return false, fail(jw, fmt.tprintf("%s.%s", at, key), "expected true or false")
	}
	return b, nil
}

@(private = "file")
get_color :: proc(jw: ^Job_Walker, o: json.Object, key, at: string, def: Color) -> (c: Color, err: Err) {
	s := get_string(jw, o, key, at) or_return
	if s == "" {
		return def, nil
	}
	ok: bool
	if c, ok = parse_color(s); !ok {
		return def, fail(jw, fmt.tprintf("%s.%s", at, key), "%q is not a colour (#RRGGBB or #RRGGBBAA)", s)
	}
	return c, nil
}

@(private = "file")
get_coord :: proc(jw: ^Job_Walker, o: json.Object, key, at: string, def: Coord) -> (c: Coord, err: Err) {
	raw, found := o[key]
	if !found {
		return def, nil
	}
	#partial switch v in raw {
	case json.Float:
		return Coord{f32(v), false}, nil
	case json.Integer:
		return Coord{f32(v), false}, nil
	case json.String:
		if r, ok := parse_coord(v); ok {
			return r, nil
		}
	}
	return def, fail(jw, fmt.tprintf("%s.%s", at, key), "expected pixels (120) or a percentage (\"50%%\")")
}

@(private = "file")
resolve_path :: proc(jw: ^Job_Walker, p: string) -> string {
	if p == "" || filepath.is_abs(p) {
		return p
	}
	j, _ := filepath.join({jw.base, p})
	return j
}

@(private = "file")
jw_job :: proc(jw: ^Job_Walker, root: json.Value) -> (job: Job, err: Err) {
	o := as_object(jw, root, "job", JOB_FIELDS) or_return
	job.width, job.height = DEFAULT_CANVAS_W, DEFAULT_CANVAS_H
	job.encode = default_encode()

	out := get_string(jw, o, "output", "job") or_return
	if out == "" {
		return job, fail(jw, "output", "missing: the file to write")
	}
	job.output = resolve_path(jw, out)
	if size := get_string(jw, o, "size", "job") or_return; size != "" {
		w, h, native, serr := parse_size(size)
		if serr != nil {
			return job, fail(jw, "size", "%s", serr.?)
		}
		job.width, job.height, job.native = w, h, native
	}
	if raw, found := o["fps"]; found {
		#partial switch v in raw {
		case json.Float:
			job.fps, _ = parse_fps(fmt.tprintf("%v", v))
		case json.String:
			job.fps, _ = parse_fps(v)
		}
		if job.fps.num <= 0 {
			return job, fail(jw, "fps", "expected a frame rate like 60, 29.97 or \"30000/1001\"")
		}
	}
	job.font_path = resolve_path(jw, get_string(jw, o, "font", "job") or_return)
	job.ffmpeg = get_string(jw, o, "ffmpeg", "job") or_return
	job.threads = int(get_number(jw, o, "threads", "job", 0, 256, 0) or_return)

	if raw, found := o["encode"]; found {
		e := as_object(jw, raw, "encode", ENCODE_FIELDS) or_return
		if c := get_string(jw, e, "codec", "encode") or_return; c != "" {
			ok: bool
			if job.encode.codec, ok = parse_codec(c); !ok {
				return job, fail(jw, "encode.codec", "%q is not h264, hevc or av1", c)
			}
		}
		if q := get_string(jw, e, "quality", "encode") or_return; q != "" {
			ok: bool
			if job.encode.quality, ok = parse_quality(q); !ok {
				return job, fail(jw, "encode.quality", "%q is not visually-lossless, high, small or crf=N", q)
			}
		}
		if m := get_string(jw, e, "metric", "encode") or_return; m != "" {
			switch m {
			case "ssim":
				job.encode.metric = .SSIM
			case "vmaf":
				job.encode.metric = .VMAF
			case:
				return job, fail(jw, "encode.metric", "%q is not ssim or vmaf", m)
			}
		}
		job.encode.max_size_mb = get_number(jw, e, "max_size_mb", "encode", 0, 1e6, 0) or_return
		job.encode.preset = get_string(jw, e, "preset", "encode") or_return
		job.encode.keep_master = get_bool(jw, e, "keep_master", "encode") or_return
		job.encode.force = get_bool(jw, e, "force", "encode") or_return
	}

	scenes := as_array(jw, o, "scenes", "job") or_return
	if len(scenes) == 0 {
		return job, fail(jw, "scenes", "missing or empty: a job needs at least one scene")
	}
	job.scenes = make([]Scene, len(scenes))
	for v, i in scenes {
		job.scenes[i] = jw_scene(jw, v, fmt.aprintf("scenes[%d]", i)) or_return
	}
	return job, nil
}

@(private = "file")
jw_scene :: proc(jw: ^Job_Walker, v: json.Value, at: string) -> (s: Scene, err: Err) {
	o := as_object(jw, v, at, SCENE_FIELDS) or_return
	s = default_scene()
	s.background = get_color(jw, o, "background", at, DEFAULT_BG) or_return
	s.background.a = 255
	if raw, found := o["duration"]; found {
		#partial switch d in raw {
		case json.Float:
			if d <= 0 {
				return s, fail(jw, fmt.tprintf("%s.duration", at), "must be more than 0 seconds")
			}
			s.duration = f64(d)
		case json.String:
			switch d {
			case "longest":
				s.duration = Duration_Rule.Longest
			case "shortest":
				s.duration = Duration_Rule.Shortest
			case:
				return s, fail(jw, fmt.tprintf("%s.duration", at), "%q is not \"longest\", \"shortest\" or a number of seconds", d)
			}
		case:
			return s, fail(jw, fmt.tprintf("%s.duration", at), "expected \"longest\", \"shortest\" or a number of seconds")
		}
	}
	if raw, found := o["layout"]; found {
		lw := fmt.tprintf("%s.layout", at)
		l := as_object(jw, raw, lw, LAYOUT_FIELDS) or_return
		s.layout.cols = int(get_number(jw, l, "cols", lw, 0, 16, 0) or_return)
		s.layout.rows = int(get_number(jw, l, "rows", lw, 0, 16, 0) or_return)
		s.layout.gap = int(get_number(jw, l, "gap", lw, 0, 512, DEFAULT_GAP) or_return)
		s.layout.margin = int(get_number(jw, l, "margin", lw, 0, 512, DEFAULT_MARGIN) or_return)
		s.layout.label_size = f32(get_number(jw, l, "label_size", lw, 0, 400, 0) or_return)
		s.layout.title = get_string(jw, l, "title", lw) or_return
	}
	cells := as_array(jw, o, "cells", at) or_return
	if len(cells) > 16 {
		return s, fail(jw, fmt.tprintf("%s.cells", at), "%d cells; a scene holds at most 16", len(cells))
	}
	s.cells = make([]Cell, len(cells))
	for cv, i in cells {
		s.cells[i] = jw_cell(jw, cv, fmt.tprintf("%s.cells[%d]", at, i)) or_return
	}
	if s.layout.cols > 0 && s.layout.rows > 0 && s.layout.cols * s.layout.rows < len(cells) {
		return s, fail(jw, fmt.tprintf("%s.layout", at), "a %dx%d grid cannot hold %d cells", s.layout.cols, s.layout.rows, len(cells))
	}
	if _, timed := s.duration.(f64); !timed && len(cells) == 0 {
		return s, fail(jw, fmt.tprintf("%s.duration", at), "a scene without cells needs a duration in seconds")
	}
	texts := as_array(jw, o, "texts", at) or_return
	s.texts = make([]Text, len(texts))
	for tv, i in texts {
		s.texts[i] = jw_text(jw, tv, fmt.tprintf("%s.texts[%d]", at, i)) or_return
	}
	caps := as_array(jw, o, "captions", at) or_return
	s.captions = make([]Caption, len(caps))
	for cv, i in caps {
		cw := fmt.tprintf("%s.captions[%d]", at, i)
		c := as_object(jw, cv, cw, CAPTION_FIELDS) or_return
		s.captions[i].text = get_string(jw, c, "text", cw) or_return
		s.captions[i].from = get_number(jw, c, "from", cw, 0, 86400, 0) or_return
		s.captions[i].to = get_number(jw, c, "to", cw, 0, 86400, 0) or_return
		if s.captions[i].to > 0 && s.captions[i].to <= s.captions[i].from {
			return s, fail(jw, fmt.tprintf("%s.to", cw), "must be after from (or 0 for the scene's end)")
		}
	}
	return s, nil
}

@(private = "file")
jw_cell :: proc(jw: ^Job_Walker, v: json.Value, at: string) -> (c: Cell, err: Err) {
	o: json.Object
	if s, is_string := v.(json.String); is_string {
		return Cell{src = resolve_path(jw, s)}, nil // "a.mp4" is short for {"src": "a.mp4"}
	}
	o = as_object(jw, v, at, CELL_FIELDS) or_return
	src := get_string(jw, o, "src", at) or_return
	if src == "" {
		return c, fail(jw, fmt.tprintf("%s.src", at), "missing: the video or image to show")
	}
	c.src = resolve_path(jw, src)
	c.label = get_string(jw, o, "label", at) or_return
	c.start = get_number(jw, o, "start", at, 0, 86400, 0) or_return
	if f := get_string(jw, o, "fit", at) or_return; f != "" {
		ok: bool
		if c.fit, ok = parse_fit(f); !ok {
			return c, fail(jw, fmt.tprintf("%s.fit", at), "%q is not \"contain\" or \"cover\"", f)
		}
	}
	if e := get_string(jw, o, "end", at) or_return; e != "" {
		ok: bool
		if c.end, ok = parse_end(e); !ok {
			return c, fail(jw, fmt.tprintf("%s.end", at), "%q is not \"hold\", \"black\" or \"loop\"", e)
		}
	}
	return c, nil
}

@(private = "file")
jw_text :: proc(jw: ^Job_Walker, v: json.Value, at: string) -> (t: Text, err: Err) {
	o := as_object(jw, v, at, TEXT_FIELDS) or_return
	t = default_text()
	t.text = get_string(jw, o, "text", at) or_return
	if t.text == "" {
		return t, fail(jw, fmt.tprintf("%s.text", at), "missing: the words to draw")
	}
	t.x = get_coord(jw, o, "x", at, Coord{0.5, true}) or_return
	t.y = get_coord(jw, o, "y", at, Coord{0.5, true}) or_return
	t.anchor = .CC
	if a := get_string(jw, o, "anchor", at) or_return; a != "" {
		ok: bool
		if t.anchor, ok = parse_anchor(a); !ok {
			return t, fail(jw, fmt.tprintf("%s.anchor", at), "%q is not one of TL TC TR CL CC CR BL BC BR", a)
		}
	}
	t.size = f32(get_number(jw, o, "size", at, 1, 1000, 48) or_return)
	t.color = get_color(jw, o, "color", at, t.color) or_return
	t.outline_px = f32(get_number(jw, o, "outline_px", at, 0, 50, 0) or_return)
	t.outline_color = get_color(jw, o, "outline_color", at, t.outline_color) or_return
	t.shadow_dx = f32(get_number(jw, o, "shadow_dx", at, -100, 100, 0) or_return)
	t.shadow_dy = f32(get_number(jw, o, "shadow_dy", at, -100, 100, 0) or_return)
	t.shadow_blur = f32(get_number(jw, o, "shadow_blur", at, 0, 50, 0) or_return)
	t.shadow_color = get_color(jw, o, "shadow_color", at, t.shadow_color) or_return
	t.box_color = get_color(jw, o, "box_color", at, t.box_color) or_return
	t.box_pad = f32(get_number(jw, o, "box_pad", at, 0, 500, 0) or_return)
	t.box_radius = f32(get_number(jw, o, "box_radius", at, 0, 500, 0) or_return)
	t.from = get_number(jw, o, "from", at, 0, 86400, 0) or_return
	t.to = get_number(jw, o, "to", at, 0, 86400, 0) or_return
	if t.to > 0 && t.to <= t.from {
		return t, fail(jw, fmt.tprintf("%s.to", at), "must be after from (or 0 for the scene's end)")
	}
	t.fade = get_number(jw, o, "fade", at, 0, 3600, 0) or_return
	return t, nil
}

parse_anchor :: proc(s: string) -> (a: Anchor, ok: bool) {
	names := [9]string{"tl", "tc", "tr", "cl", "cc", "cr", "bl", "bc", "br"}
	l := strings.to_lower(s, context.temp_allocator)
	for n, i in names {
		if l == n {
			return Anchor(i), true
		}
	}
	return .TL, false
}
