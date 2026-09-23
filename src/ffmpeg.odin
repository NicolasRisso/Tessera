package tessera

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// ffmpeg and ffprobe are child processes talking raw frames over pipes: the
// codec, and nothing else. Their stderr always goes to a log file, never to
// an undrained pipe.

EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""

Rational :: struct {
	num, den: int,
}

rational_f64 :: proc(r: Rational) -> f64 {
	return f64(r.num) / f64(r.den) if r.den != 0 else 0
}

Tools :: struct {
	ffmpeg:   string,
	ffprobe:  string,
	encoders: string, // `ffmpeg -encoders` output, loaded on first use
}

// find_tools locates ffmpeg: the --ffmpeg flag, then TESSERA_FFMPEG, then
// PATH. ffprobe is looked for beside it, then on PATH.
find_tools :: proc(flag: string) -> (tools: Tools, err: Err) {
	ffmpeg := flag
	from := "--ffmpeg"
	if ffmpeg == "" {
		if env, ok := os.lookup_env("TESSERA_FFMPEG", context.allocator); ok && env != "" {
			ffmpeg, from = env, "TESSERA_FFMPEG"
		}
	}
	if ffmpeg == "" {
		ffmpeg = look_path("ffmpeg" + EXE_SUFFIX)
		if ffmpeg == "" {
			return {}, "ffmpeg not found: install it, put it on PATH, or pass --ffmpeg PATH (or set TESSERA_FFMPEG)"
		}
		from = "PATH"
	} else if !os.is_file(ffmpeg) {
		return {}, fmt.aprintf("ffmpeg not found at %q (from %s)", ffmpeg, from)
	}
	probe_name := "ffprobe" + EXE_SUFFIX
	ffprobe, _ := filepath.join({filepath.dir(ffmpeg), probe_name})
	if !os.is_file(ffprobe) {
		ffprobe = look_path(probe_name)
		if ffprobe == "" {
			return {}, fmt.aprintf("ffprobe not found beside %q or on PATH", ffmpeg)
		}
	}
	return Tools{ffmpeg = ffmpeg, ffprobe = ffprobe}, nil
}

// look_path returns the first PATH entry holding a file called name, or "".
look_path :: proc(name: string) -> string {
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	dirs, _ := filepath.split_list(path, context.temp_allocator)
	for d in dirs {
		if d == "" {
			continue
		}
		p, _ := filepath.join({d, name})
		if os.is_file(p) {
			return p
		}
		delete(p)
	}
	return ""
}

// require_encoder fails with a sentence naming the encoder when this ffmpeg
// build lacks it.
require_encoder :: proc(tools: ^Tools, encoder: string) -> Err {
	if tools.encoders == "" {
		out, err := capture({tools.ffmpeg, "-hide_banner", "-encoders"})
		if err != nil {
			return err
		}
		tools.encoders = out
	}
	it := tools.encoders
	for line in strings.split_lines_iterator(&it) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) >= 2 && fields[1] == encoder {
			return nil
		}
	}
	return fmt.aprintf("this ffmpeg (%s) has no %s encoder; install a build with it or pick another --codec", tools.ffmpeg, encoder)
}

// capture runs a command to completion and returns its stdout; a non-zero
// exit is an error carrying the end of its stderr.
capture :: proc(command: []string) -> (stdout: string, err: Err) {
	state, out, errb, e := os.process_exec(os.Process_Desc{command = command}, context.allocator)
	defer delete(errb)
	if e != nil {
		delete(out)
		return "", fmt.aprintf("cannot run %s: %v", command[0], e)
	}
	if !state.success || state.exit_code != 0 {
		delete(out)
		return "", fmt.aprintf("%s failed (exit %d): %s", filepath.base(command[0]), state.exit_code, last_line(string(errb)))
	}
	return string(out), nil
}

// log_summary picks the line of an ffmpeg log that says what went wrong: the
// first one mentioning an error, else the last.
log_summary :: proc(text: string) -> string {
	it := text
	for line in strings.split_lines_iterator(&it) {
		if strings.contains(line, "rror") || strings.contains(line, "Invalid") {
			return strings.trim_space(line)
		}
	}
	return last_line(text)
}

// last_line is the last non-empty line of a log, for error messages.
last_line :: proc(text: string) -> string {
	s := strings.trim_right_space(text)
	if i := strings.last_index_byte(s, '\n'); i >= 0 {
		return s[i + 1:]
	}
	return s
}

// Probe is what tessera needs to know about one input.
Probe :: struct {
	path:         string,
	width:        int,
	height:       int,
	fps:          Rational, // r_frame_rate
	avg_fps:      Rational,
	frames:       int, // counted or estimated; 1 for a still
	duration:     f64, // seconds; 0 for a still
	pix_fmt:      string,
	codec:        string,
	format:       string,
	still:        bool,
	vfr:          bool, // r_frame_rate != avg_frame_rate: decoded with -fps_mode cfr
	counted:      bool, // frames is the container's count, not an estimate
}

probe :: proc(tools: Tools, path: string) -> (p: Probe, err: Err) {
	if !os.is_file(path) {
		return {}, fmt.aprintf("%s: no such file", path)
	}
	out := capture(
		{
			tools.ffprobe, "-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,pix_fmt,codec_name:format=duration,format_name",
			"-of", "json", path,
		},
	) or_return
	defer delete(out)
	p = parse_probe(path, out) or_return
	if p.counted || p.still {
		return p, nil
	}
	// No frame count in the container (Matroska, NUT, ...): count packets,
	// which demuxes without decoding. The duration alone is off by a frame
	// in some containers.
	counted := capture(
		{
			tools.ffprobe, "-v", "error", "-select_streams", "v:0", "-count_packets",
			"-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path,
		},
	) or_return
	defer delete(counted)
	if n, ok := strconv.parse_int(strings.trim_space(counted)); ok && n > 0 {
		p.frames = n
		p.counted = true
		p.duration = f64(n) / rational_f64(p.avg_fps if p.vfr else p.fps)
	}
	return p, nil
}

parse_probe :: proc(path, text: string) -> (p: Probe, err: Err) {
	root, jerr := json.parse_string(text, .JSON, false)
	defer json.destroy_value(root)
	if jerr != nil {
		return {}, fmt.aprintf("%s: ffprobe output is not JSON (%v)", path, jerr)
	}
	obj, _ := root.(json.Object)
	streams, _ := obj["streams"].(json.Array)
	if len(streams) == 0 {
		return {}, fmt.aprintf("%s: no video stream", path)
	}
	s, _ := streams[0].(json.Object)
	f, _ := obj["format"].(json.Object)
	str :: proc(o: json.Object, key: string) -> string {
		v, _ := o[key].(json.String)
		return v
	}
	num :: proc(o: json.Object, key: string) -> (f64, bool) {
		#partial switch v in o[key] {
		case json.Integer:
			return f64(v), true
		case json.Float:
			return v, true
		case json.String:
			return strconv.parse_f64(v)
		}
		return 0, false
	}
	p.path = strings.clone(path)
	w, _ := num(s, "width")
	h, _ := num(s, "height")
	p.width, p.height = int(w), int(h)
	if p.width <= 0 || p.height <= 0 {
		return {}, fmt.aprintf("%s: the video stream has no size", path)
	}
	p.fps = parse_rational(str(s, "r_frame_rate"))
	p.avg_fps = parse_rational(str(s, "avg_frame_rate"))
	p.pix_fmt = strings.clone(str(s, "pix_fmt"))
	p.codec = strings.clone(str(s, "codec_name"))
	p.format = strings.clone(str(f, "format_name"))
	dur, has_dur := num(f, "duration")
	nb, has_nb := num(s, "nb_frames")
	image := p.format == "image2" || strings.has_suffix(p.format, "_pipe")
	one_frame := !has_nb || nb <= 1
	if image && one_frame && (!has_dur || dur <= 0.05) {
		p.still = true
		p.frames = 1
		p.fps = {1, 1}
		p.avg_fps = {1, 1}
		return p, nil
	}
	if p.fps.num <= 0 || p.fps.den <= 0 {
		p.fps = p.avg_fps
	}
	if p.fps.num <= 0 || p.fps.den <= 0 {
		return {}, fmt.aprintf("%s: no frame rate", path)
	}
	if p.avg_fps.num > 0 && p.avg_fps.den > 0 && p.avg_fps.num * p.fps.den != p.fps.num * p.avg_fps.den {
		p.vfr = true
	}
	rate := rational_f64(p.avg_fps if p.vfr else p.fps)
	p.duration = dur if has_dur else 0
	if has_nb && nb > 0 && !p.vfr {
		p.frames = int(nb)
		p.counted = true
		if !has_dur {
			p.duration = f64(p.frames) / rate
		}
	} else if p.duration > 0 {
		p.frames = int(p.duration * rate + 0.5)
	} else {
		return {}, fmt.aprintf("%s: neither a frame count nor a duration", path)
	}
	return p, nil
}

parse_rational :: proc(s: string) -> Rational {
	i := strings.index_byte(s, '/')
	if i < 0 {
		v, ok := strconv.parse_f64(s)
		if !ok || v <= 0 {
			return {}
		}
		return {int(v * 1000 + 0.5), 1000}
	}
	n, ok1 := strconv.parse_int(s[:i])
	d, ok2 := strconv.parse_int(s[i + 1:])
	if !ok1 || !ok2 {
		return {}
	}
	return {n, d}
}

// Child is a running ffmpeg with one end of a pipe.
Child :: struct {
	process:  os.Process,
	pipe:     ^os.File, // our end: stdout of a decoder, stdin of an encoder
	log_path: string,
	running:  bool,
}

// start_child runs command with its stderr in log_path and one pipe to us:
// its stdout when reading, its stdin otherwise.
start_child :: proc(command: []string, log_path: string, reading: bool) -> (c: Child, err: Err) {
	logf, lerr := os.open(log_path, {.Write, .Create, .Trunc})
	if lerr != nil {
		return {}, fmt.aprintf("cannot create %s: %v", log_path, lerr)
	}
	defer os.close(logf)
	r, w, perr := os.pipe()
	if perr != nil {
		return {}, fmt.aprintf("cannot create a pipe: %v", perr)
	}
	desc := os.Process_Desc{command = command, stderr = logf}
	ours, theirs := r, w
	if reading {
		desc.stdout = w
	} else {
		desc.stdin = r
		ours, theirs = w, r
	}
	p, serr := os.process_start(desc)
	os.close(theirs) // the child holds its own copy; ours must go or EOF never comes
	if serr != nil {
		os.close(ours)
		return {}, fmt.aprintf("cannot start %s: %v", command[0], serr)
	}
	return Child{process = p, pipe = ours, log_path = strings.clone(log_path), running = true}, nil
}

// finish_child closes our end, waits, and reports a failure with the last
// line of the child's log. kill stops a child we no longer need.
finish_child :: proc(c: ^Child, kill := false) -> (err: Err) {
	if !c.running {
		return nil
	}
	c.running = false
	if c.pipe != nil {
		os.close(c.pipe)
		c.pipe = nil
	}
	if kill {
		_ = os.process_kill(c.process)
	}
	state, werr := os.process_wait(c.process)
	if werr != nil {
		return fmt.aprintf("waiting for ffmpeg: %v", werr)
	}
	if !kill && (!state.success || state.exit_code != 0) {
		log, _ := os.read_entire_file(c.log_path, context.temp_allocator)
		return fmt.aprintf("ffmpeg failed (exit %d): %s [log: %s]", state.exit_code, log_summary(string(log)), c.log_path)
	}
	return nil
}

// Decoder yields a source's frames as RGB24 at the source's own size.
Decoder :: struct {
	using child: Child,
	src:         Probe,
	start:       f64,
	frame_bytes: int,
	index:       int, // frames read so far
	eof:         bool,
}

// decoder_command decodes src from start to raw frames of pix_fmt (rgb24 for
// compositing, yuv420p to read the luma of our own encodes untouched).
decoder_command :: proc(tools: Tools, src: Probe, start: f64, allocator := context.allocator, pix_fmt := "rgb24", frames := 0) -> []string {
	cmd := make([dynamic]string, allocator)
	append(&cmd, tools.ffmpeg, "-nostdin", "-v", "error")
	if start > 0 && !src.still {
		append(&cmd, "-ss", fmt.aprintf("%.6f", start, allocator = allocator))
	}
	append(&cmd, "-i", src.path, "-an", "-sn", "-dn")
	if src.still {
		append(&cmd, "-frames:v", "1")
	} else if frames > 0 {
		append(&cmd, "-frames:v", fmt.aprintf("%d", frames, allocator = allocator))
	}
	if !src.still && src.vfr {
		append(&cmd, "-fps_mode", "cfr", "-r", fmt.aprintf("%d/%d", src.avg_fps.num, src.avg_fps.den, allocator = allocator))
	}
	// ffmpeg's default yuv→rgb path truncates: half a level darker on
	// average. Accurate rounding and full chroma interpolation cost ~15 %
	// of the decoder's time and remove the bias. An output option: before
	// -i it is silently ignored.
	append(&cmd, "-sws_flags", "accurate_rnd+full_chroma_int")
	append(&cmd, "-f", "rawvideo", "-pix_fmt", pix_fmt, "-")
	return cmd[:]
}

decoder_open :: proc(tools: Tools, src: Probe, start: f64, log_path: string, pix_fmt := "rgb24", frames := 0) -> (d: Decoder, err: Err) {
	d.src = src
	d.start = start
	switch pix_fmt {
	case "rgb24":
		d.frame_bytes = src.width * src.height * 3
	case "yuv420p":
		d.frame_bytes = yuv_frame_size(src.width, src.height)
	case "gray":
		d.frame_bytes = src.width * src.height
	case:
		return d, fmt.aprintf("decoder: unsupported pixel format %s", pix_fmt)
	}
	cmd := decoder_command(tools, src, start, context.temp_allocator, pix_fmt, frames)
	d.child = start_child(cmd, log_path, true) or_return
	return d, nil
}

// decoder_read reads the next frame into buf (frame_bytes long). It returns
// false at the end of the stream; a short last frame counts as the end.
decoder_read :: proc(d: ^Decoder, buf: []u8) -> bool {
	if d.eof {
		return false
	}
	n, _ := os.read_full(d.pipe, buf[:d.frame_bytes])
	if n < d.frame_bytes {
		d.eof = true
		return false
	}
	d.index += 1
	return true
}

// decoder_close stops the child, killing it if it is not done.
decoder_close :: proc(d: ^Decoder) -> Err {
	return finish_child(&d.child, kill = !d.eof)
}

// Encoder takes raw YUV420P frames on stdin.
Encoder :: struct {
	using child: Child,
	frames:      int,
}

// encoder_input_args are the arguments describing our raw frames.
encoder_input_args :: proc(w, h: int, fps: Rational, allocator := context.allocator) -> []string {
	a := make([dynamic]string, allocator)
	append(&a, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", fmt.aprintf("%dx%d", w, h, allocator = allocator))
	append(&a, "-r", fmt.aprintf("%d/%d", fps.num, fps.den, allocator = allocator), "-i", "-")
	return a[:]
}

// COLOR_TAGS marks the output BT.709 limited range, which is what yuv.odin writes.
COLOR_TAGS :: []string{"-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"}

encoder_open :: proc(command: []string, log_path: string) -> (e: Encoder, err: Err) {
	e.child = start_child(command, log_path, false) or_return
	return e, nil
}

encoder_write :: proc(e: ^Encoder, frame: []u8) -> Err {
	n, werr := os.write(e.pipe, frame)
	if werr != nil || n != len(frame) {
		// The encoder died; its log says why.
		ferr := finish_child(&e.child)
		if ferr != nil {
			return ferr
		}
		return fmt.aprintf("writing to ffmpeg: %v", werr)
	}
	e.frames += 1
	return nil
}

// encoder_close signals the end of the stream and waits for the file.
encoder_close :: proc(e: ^Encoder) -> Err {
	return finish_child(&e.child)
}
