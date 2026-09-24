package tessera

import "core:fmt"
import "core:strconv"
import "core:strings"

GRID_USAGE :: `usage: tessera grid <input>... -o <out.mp4> [options]

Puts every input (video or still image) in one grid, one cell each, in the
order given, and encodes the result. No audio.

layout
  --cols N, --rows N        the grid (default: whatever makes cells largest)
  --size WxH | native       the canvas (default 1920x1080; native shows the
                            largest input 1:1, up to 3840x2160)
  --fit contain|cover       letterbox inside the cell (default) or fill it
  --gap PX                  between cells (default 8)
  --margin PX               around the grid (default 16)
  --bg #RRGGBB              background (default #0B0F17)
text
  --label TEXT              one per input, in order, drawn in its cell's top
                            left (repeat the option; "" leaves a cell bare)
  --title TEXT              a line above the grid
  --caption "TEXT@FROM-TO"  a timed line at the bottom (seconds; "@3-" runs
                            to the end; no @ is the whole video); repeatable
  --font PATH               a TrueType (.ttf) font (default: Inter SemiBold)
time
  --fps N                   output rate (default: the highest input's, max 60)
  --duration longest|shortest|SECONDS   (default longest)
  --end hold|black|loop     what a cell shows once its video ends (default hold)
encoding
  -o, --output PATH         the output file (.mp4, .mkv, .mov)
  --codec h264|hevc|av1     (default h264)
  --quality visually-lossless|high|small|crf=N   (default visually-lossless)
                            a preset searches for the largest CRF whose SSIM
                            stays over its target (mean/every frame):
                            visually-lossless 0.990/0.980, high 0.980/0.965,
                            small 0.965/0.940; crf=N encodes at N, no search
  --metric ssim|vmaf        what the search measures (default ssim, ours);
                            vmaf needs an ffmpeg with libvmaf, targets 95/90/85
  --max-size MB             raise the CRF until the file fits; refuses when
                            that would fall below the small target
  --force                   encode at the size cap even below that floor
  --preset NAME             the encoder's preset (default per codec)
  --encoder-opt NAME=VALUE  passed to ffmpeg as -NAME VALUE after the codec's
                            defaults (tune=animation, aq-mode=3, g=600, ...)
  --keep-master             keep the lossless master beside the output
  --threads N               compositing and SSIM threads (default cores - 1)
  --ffmpeg PATH             the ffmpeg binary (else TESSERA_FFMPEG, else PATH)
  --dry-run                 print the plan and the ffmpeg commands, encode nothing
`

// Args walks a command line; options take their value as the next argument
// or after '='.
Args :: struct {
	list: []string,
	i:    int,
}

// next_option splits "--name=value" and reports whether the argument is an option.
@(private = "file")
split_option :: proc(a: string) -> (name: string, value: string, has_value: bool) {
	if eq := strings.index_byte(a, '='); eq > 0 && strings.has_prefix(a, "--") {
		return a[:eq], a[eq + 1:], true
	}
	return a, "", false
}

@(private = "file")
option_value :: proc(args: ^Args, name, inline: string, has_inline: bool) -> (v: string, err: Err) {
	if has_inline {
		return inline, nil
	}
	if args.i + 1 >= len(args.list) {
		return "", fmt.aprintf("%s needs a value", name)
	}
	args.i += 1
	return args.list[args.i], nil
}

@(private = "file")
int_value :: proc(name, v: string, lo, hi: int) -> (n: int, err: Err) {
	x, ok := strconv.parse_int(v)
	if !ok || x < lo || x > hi {
		return 0, fmt.aprintf("%s: %q is not a whole number from %d to %d", name, v, lo, hi)
	}
	return x, nil
}

@(private = "file")
float_value :: proc(name, v: string, lo, hi: f64) -> (n: f64, err: Err) {
	x, ok := strconv.parse_f64(v)
	if !ok || x < lo || x > hi {
		return 0, fmt.aprintf("%s: %q is not a number from %v to %v", name, v, lo, hi)
	}
	return x, nil
}

// parse_size reads WxH (both even) or native.
parse_size :: proc(v: string) -> (w, h: int, native: bool, err: Err) {
	if v == "native" {
		return 0, 0, true, nil
	}
	i := strings.index_any(v, "xX")
	if i < 0 {
		return 0, 0, false, fmt.aprintf("--size: %q is not WxH or native", v)
	}
	w, err = int_value("--size width", v[:i], 16, 8192)
	if err != nil {
		return
	}
	h, err = int_value("--size height", v[i + 1:], 16, 8192)
	if err != nil {
		return
	}
	if w % 2 != 0 || h % 2 != 0 {
		return 0, 0, false, fmt.aprintf("--size: %dx%d must be even in both directions (yuv420p)", w, h)
	}
	return
}

parse_end :: proc(v: string) -> (e: End, ok: bool) {
	switch v {
	case "hold":
		return .Hold, true
	case "black":
		return .Black, true
	case "loop":
		return .Loop, true
	}
	return .Hold, false
}

parse_fit :: proc(v: string) -> (f: Fit, ok: bool) {
	switch v {
	case "contain":
		return .Contain, true
	case "cover":
		return .Cover, true
	}
	return .Contain, false
}

parse_codec :: proc(v: string) -> (c: Codec, ok: bool) {
	switch v {
	case "h264", "x264", "avc":
		return .H264, true
	case "hevc", "h265", "x265":
		return .HEVC, true
	case "av1":
		return .AV1, true
	}
	return .H264, false
}

parse_duration :: proc(v: string) -> (d: Scene_Duration, err: Err) {
	switch v {
	case "longest":
		return Duration_Rule.Longest, nil
	case "shortest":
		return Duration_Rule.Shortest, nil
	}
	s := float_value("--duration", v, 0.001, 86400) or_return
	return s, nil
}

// parse_grid turns `tessera grid` arguments into a one-scene job.
parse_grid :: proc(list: []string) -> (job: Job, err: Err) {
	args := Args{list = list}
	scene := default_scene()
	job.encode = default_encode()
	job.width, job.height = DEFAULT_CANVAS_W, DEFAULT_CANVAS_H
	inputs := make([dynamic]string)
	labels := make([dynamic]string)
	captions := make([dynamic]Caption)
	fit := Fit.Contain
	end := End.Hold
	for ; args.i < len(args.list); args.i += 1 {
		a := args.list[args.i]
		if len(a) < 2 || a[0] != '-' {
			append(&inputs, a)
			continue
		}
		name, inline, has := split_option(a)
		switch name {
		case "-o", "--output":
			job.output = option_value(&args, name, inline, has) or_return
		case "--cols":
			scene.layout.cols = int_value(name, option_value(&args, name, inline, has) or_return, 1, 16) or_return
		case "--rows":
			scene.layout.rows = int_value(name, option_value(&args, name, inline, has) or_return, 1, 16) or_return
		case "--size":
			job.width, job.height, job.native = parse_size(option_value(&args, name, inline, has) or_return) or_return
		case "--fit":
			v := option_value(&args, name, inline, has) or_return
			ok: bool
			if fit, ok = parse_fit(v); !ok {
				return job, fmt.aprintf("--fit: %q is not contain or cover", v)
			}
		case "--gap":
			scene.layout.gap = int_value(name, option_value(&args, name, inline, has) or_return, 0, 512) or_return
		case "--margin":
			scene.layout.margin = int_value(name, option_value(&args, name, inline, has) or_return, 0, 512) or_return
		case "--bg":
			v := option_value(&args, name, inline, has) or_return
			ok: bool
			if scene.background, ok = parse_color(v); !ok {
				return job, fmt.aprintf("--bg: %q is not a colour (#RRGGBB)", v)
			}
			scene.background.a = 255
		case "--fps":
			v := option_value(&args, name, inline, has) or_return
			ok: bool
			if job.fps, ok = parse_fps(v); !ok {
				return job, fmt.aprintf("--fps: %q is not a frame rate (like 60, 29.97 or 30000/1001)", v)
			}
		case "--duration":
			scene.duration = parse_duration(option_value(&args, name, inline, has) or_return) or_return
		case "--end":
			v := option_value(&args, name, inline, has) or_return
			ok: bool
			if end, ok = parse_end(v); !ok {
				return job, fmt.aprintf("--end: %q is not hold, black or loop", v)
			}
		case "--codec":
			v := option_value(&args, name, inline, has) or_return
			ok: bool
			if job.encode.codec, ok = parse_codec(v); !ok {
				return job, fmt.aprintf("--codec: %q is not h264, hevc or av1", v)
			}
		case "--quality":
			v := option_value(&args, name, inline, has) or_return
			ok: bool
			if job.encode.quality, ok = parse_quality(v); !ok {
				return job, fmt.aprintf("--quality: %q is not visually-lossless, high, small or crf=N", v)
			}
		case "--max-size":
			job.encode.max_size_mb = float_value(name, option_value(&args, name, inline, has) or_return, 0.001, 1e6) or_return
		case "--force":
			job.encode.force = true
		case "--keep-master":
			job.encode.keep_master = true
		case "--threads":
			job.threads = int_value(name, option_value(&args, name, inline, has) or_return, 1, 256) or_return
		case "--metric":
			v := option_value(&args, name, inline, has) or_return
			switch v {
			case "ssim":
				job.encode.metric = .SSIM
			case "vmaf":
				job.encode.metric = .VMAF
			case:
				return job, fmt.aprintf("--metric: %q is not ssim or vmaf", v)
			}
		case "--encoder-opt":
			v := option_value(&args, name, inline, has) or_return
			if !add_encoder_option(&job.encode, v) {
				return job, fmt.aprintf("--encoder-opt: %q is not NAME=VALUE (like tune=animation, aq-mode=3, g=600)", v)
			}
		case "--preset":
			job.encode.preset = option_value(&args, name, inline, has) or_return
		case "--label":
			append(&labels, option_value(&args, name, inline, has) or_return)
		case "--title":
			scene.layout.title = option_value(&args, name, inline, has) or_return
		case "--caption":
			append(&captions, parse_caption(option_value(&args, name, inline, has) or_return) or_return)
		case "--font":
			job.font_path = option_value(&args, name, inline, has) or_return
		case "--ffmpeg":
			job.ffmpeg = option_value(&args, name, inline, has) or_return
		case "--dry-run":
			job.dry_run = true
		case:
			return job, fmt.aprintf("grid: unknown option %q (see tessera grid --help)", a)
		}
	}
	if len(inputs) == 0 {
		return job, "grid: no inputs"
	}
	if len(inputs) > 16 {
		return job, fmt.aprintf("grid: %d inputs; a grid holds at most 16", len(inputs))
	}
	if job.output == "" {
		return job, "grid: no output; give -o PATH"
	}
	for in_path in inputs {
		if in_path == job.output {
			return job, fmt.aprintf("grid: the output %q is also an input", job.output)
		}
	}
	if scene.layout.cols > 0 && scene.layout.rows > 0 && scene.layout.cols * scene.layout.rows < len(inputs) {
		return job, fmt.aprintf("grid: a %dx%d grid cannot hold %d inputs", scene.layout.cols, scene.layout.rows, len(inputs))
	}
	if len(labels) > len(inputs) {
		return job, fmt.aprintf("grid: %d labels for %d inputs", len(labels), len(inputs))
	}
	cells := make([]Cell, len(inputs))
	for in_path, i in inputs {
		cells[i] = Cell{src = in_path, fit = fit, end = end}
		if i < len(labels) {
			cells[i].label = labels[i]
		}
	}
	scene.cells = cells
	scene.captions = captions[:]
	scenes := make([]Scene, 1)
	scenes[0] = scene
	job.scenes = scenes
	return job, nil
}

// parse_caption reads "TEXT@FROM-TO": seconds, TO empty for the end, no @
// for the whole scene. The last @ splits, so the text may hold one.
parse_caption :: proc(v: string) -> (c: Caption, err: Err) {
	at := strings.last_index_byte(v, '@')
	if at < 0 {
		return Caption{text = v}, nil
	}
	c.text = v[:at]
	span := v[at + 1:]
	dash := strings.index_byte(span, '-')
	if dash < 0 {
		return c, fmt.aprintf("--caption %q: the time is FROM-TO in seconds, like @2-5.5 or @3-", v)
	}
	if dash > 0 {
		ok: bool
		if c.from, ok = strconv.parse_f64(span[:dash]); !ok || c.from < 0 {
			return c, fmt.aprintf("--caption %q: %q is not a time in seconds", v, span[:dash])
		}
	}
	if dash + 1 < len(span) {
		ok: bool
		if c.to, ok = strconv.parse_f64(span[dash + 1:]); !ok || c.to <= c.from {
			return c, fmt.aprintf("--caption %q: the end must be a time after the start", v)
		}
	}
	return c, nil
}
