// tessera: several videos (and stills) on one screen, with text, encoded as
// small as it can be without a visible loss. ffmpeg is only the codec; the
// layout, resampling, compositing, colour conversion, text and quality metric
// are ours.
package tessera

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

VERSION :: "0.1.0"

// Exit codes.
EXIT_OK      :: 0
EXIT_RUNTIME :: 1 // the job was valid but something failed while doing it
EXIT_USAGE   :: 2 // the command line or the job file is wrong

USAGE :: `tessera — several videos on one screen, encoded small without a visible loss

usage:
  tessera grid <input>... -o <out.mp4> [options]   N videos or stills → one video
  tessera run <job.json> [--dry-run]               a JSON job of scenes, one after another
  tessera probe <input>...                          what tessera sees in each input
  tessera ssim <a> <b> [--frames N]                 SSIM between two videos (luma)
  tessera version                                   print the version
  tessera help | <command> --help                   this text, or one command's

The output has no audio track (v1). ffmpeg and ffprobe are found through
--ffmpeg, then TESSERA_FFMPEG, then PATH.
`

main :: proc() {
	os.exit(run_main(os.args[1:]))
}

// run_main dispatches a command and returns the process exit code.
run_main :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprint(USAGE)
		return EXIT_USAGE
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "version", "--version", "-V":
		fmt.printf("tessera %s (%s)\n", VERSION, ODIN_OS_STRING)
		return EXIT_OK
	case "help", "--help", "-h":
		if len(rest) > 0 {
			return print_command_help(rest[0])
		}
		fmt.print(USAGE)
		return EXIT_OK
	}
	if len(rest) > 0 && (rest[0] == "--help" || rest[0] == "-h") {
		return print_command_help(cmd)
	}
	switch cmd {
	case "probe":
		return cmd_probe(rest)
	case "grid":
		job, err := parse_grid(rest)
		if err != nil {
			errorf("%s", err.?)
			return EXIT_USAGE
		}
		return execute_job(&job)
	case "run":
		return cmd_run(rest)
	}
	fmt.eprintf("tessera: unknown command %q\n\n", cmd)
	fmt.eprint(USAGE)
	return EXIT_USAGE
}

PROBE_USAGE :: `usage: tessera probe <input>... [--ffmpeg PATH]

Prints what tessera sees in each input: size, frame rate, frame count,
duration, codec and pixel format, and whether it is a still or has a
variable frame rate.
`

print_command_help :: proc(cmd: string) -> int {
	switch cmd {
	case "probe":
		fmt.print(PROBE_USAGE)
		return EXIT_OK
	case "grid":
		fmt.print(GRID_USAGE)
		return EXIT_OK
	case "run":
		fmt.print(RUN_USAGE)
		return EXIT_OK
	case "version", "help":
		fmt.print(USAGE)
		return EXIT_OK
	}
	fmt.eprintf("tessera: no help for unknown command %q\n", cmd)
	return EXIT_USAGE
}

// errorf prints a one-line error to stderr, prefixed with the program name.
errorf :: proc(format: string, args: ..any) {
	fmt.eprint("tessera: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

// Err is a failure message for the user, or nil. Messages are whole
// sentences that name the file, field or tool at fault.
Err :: Maybe(string)

cmd_probe :: proc(args: []string) -> int {
	inputs := make([dynamic]string, context.temp_allocator)
	ffmpeg_flag := ""
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--ffmpeg":
			if i + 1 >= len(args) {
				errorf("--ffmpeg needs a path")
				return EXIT_USAGE
			}
			i += 1
			ffmpeg_flag = args[i]
		case len(a) > 1 && a[0] == '-':
			errorf("probe: unknown option %q", a)
			return EXIT_USAGE
		case:
			append(&inputs, a)
		}
	}
	if len(inputs) == 0 {
		fmt.eprint(PROBE_USAGE)
		return EXIT_USAGE
	}
	tools, terr := find_tools(ffmpeg_flag)
	if terr != nil {
		errorf("%s", terr.?)
		return EXIT_RUNTIME
	}
	code := EXIT_OK
	for path in inputs {
		p, err := probe(tools, path)
		if err != nil {
			errorf("%s", err.?)
			code = EXIT_RUNTIME
			continue
		}
		if p.still {
			fmt.printf("%s: still %dx%d, %s %s\n", path, p.width, p.height, p.codec, p.pix_fmt)
			continue
		}
		fmt.printf("%s: %dx%d, %d/%d fps, %d frames, %.3f s, %s %s%s\n", path, p.width, p.height,
			p.fps.num, p.fps.den, p.frames, p.duration, p.codec, p.pix_fmt,
			" (variable frame rate: decoded at the average)" if p.vfr else "")
	}
	return code
}

// execute_job probes, plans, and (unless it is a dry run) renders and encodes.
execute_job :: proc(job: ^Job) -> int {
	tools, terr := find_tools(job.ffmpeg)
	if terr != nil {
		errorf("%s", terr.?)
		return EXIT_RUNTIME
	}
	if err := require_encoder(&tools, codec_encoder(job.encode.codec)); err != nil {
		errorf("%s", err.?)
		return EXIT_RUNTIME
	}
	te: Text_Engine
	if ferr := load_font(&te, job.font_path); ferr != nil {
		errorf("%s", ferr.?)
		return EXIT_RUNTIME
	}
	defer text_engine_destroy(&te)
	r, rerr := resolve(job, tools)
	if rerr != nil {
		errorf("%s", rerr.?)
		return EXIT_RUNTIME
	}
	r.text = &te
	crf := PLACEHOLDER_CRF
	if q, ok := job.encode.quality.(CRF); ok {
		crf = int(q)
	}
	if job.dry_run {
		return print_plan(&r, crf)
	}
	tmp, derr := os.make_directory_temp("", "tessera-*", context.allocator)
	if derr != nil {
		errorf("cannot create a temporary directory: %v", derr)
		return EXIT_RUNTIME
	}
	started := time.tick_now()
	log, _ := filepath.join({tmp, "encode.log"})
	enc, eerr := encoder_open(encode_command(&r, crf, job.output), log)
	if eerr != nil {
		errorf("%s", eerr.?)
		return EXIT_RUNTIME
	}
	err := render(&r, &enc, tmp)
	if err != nil {
		_ = finish_child(&enc.child, kill = true)
		_ = os.remove(job.output)
		errorf("%s", err.?)
		errorf("logs kept in %s", tmp)
		return EXIT_RUNTIME
	}
	if cerr := encoder_close(&enc); cerr != nil {
		errorf("%s", cerr.?)
		errorf("logs kept in %s", tmp)
		return EXIT_RUNTIME
	}
	_ = os.remove_all(tmp)
	size := file_mb(job.output)
	fmt.printf("%s: %dx%d, %d frames at %d/%d fps, crf %d, %.1f MB, %.1f s\n", job.output, r.w, r.h,
		enc.frames, r.fps.num, r.fps.den, crf, size, time.duration_seconds(time.tick_since(started)))
	return EXIT_OK
}

// file_mb is a file's size in megabytes (10^6 bytes), 0 if it is missing.
file_mb :: proc(path: string) -> f64 {
	f, err := os.open(path)
	if err != nil {
		return 0
	}
	defer os.close(f)
	n, _ := os.file_size(f)
	return f64(n) / 1e6
}

// print_plan is --dry-run: the canvas, the rects, the rate, the durations
// and the ffmpeg commands.
print_plan :: proc(r: ^Resolved, crf: int) -> int {
	fmt.printf("canvas %dx%d, %d/%d fps, %s, quality %s\n", r.w, r.h, r.fps.num, r.fps.den,
		codec_name(r.job.encode.codec), quality_string(r.job.encode.quality))
	total := 0.0
	for &scene, i in r.job.scenes {
		st, err := plan_scene(r, &scene, i)
		if err != nil {
			errorf("%s", err.?)
			return EXIT_RUNTIME
		}
		total += f64(st.frames) * f64(r.fps.den) / f64(r.fps.num)
		fmt.printf("scene %d: %.3f s, %d frames\n", i + 1, st.duration, st.frames)
		if !rect_empty(st.title_rect) {
			fmt.printf("  title band %v\n", st.title_rect)
		}
		for cs, ci in st.cells {
			fmt.printf("  cell %d %v: %s %dx%d → %v (crop %v)\n", ci + 1, cs.rect, cs.cell.src,
				cs.probe.width, cs.probe.height, cs.dst, cs.crop)
			fmt.printf("    decode: %s\n", command_line(decoder_command(r.tools, cs.probe, cs.cell.start, context.temp_allocator)))
		}
		close_scene(&st)
	}
	fmt.printf("total %.3f s\n", total)
	fmt.printf("encode: %s\n", command_line(encode_command(r, crf, r.job.output, context.temp_allocator)))
	return EXIT_OK
}

// command_line quotes a command for display.
command_line :: proc(cmd: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a, i in cmd {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if a == "" || strings.contains_any(a, " \t\"'$&|;<>()*?") {
			strings.write_quoted_string(&b, a)
		} else {
			strings.write_string(&b, a)
		}
	}
	return strings.to_string(b)
}

// load_font reads the --font file, or takes the embedded font.
load_font :: proc(te: ^Text_Engine, path: string) -> Err {
	data := DEFAULT_FONT_DATA
	name := DEFAULT_FONT_NAME
	if path != "" {
		bytes, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			return fmt.aprintf("--font %s: %v", path, err)
		}
		data, name = bytes, path
	}
	font := font_load(data, name) or_return
	text_engine_init(te, font)
	return nil
}

RUN_USAGE :: `usage: tessera run <job.json> [-o OUT] [--ffmpeg PATH] [--dry-run]

Plays the job's scenes one after another into one video. The job format is
in the README; paths inside it are relative to the job file. -o replaces
the job's output.
`

cmd_run :: proc(args: []string) -> int {
	path, output, ffmpeg := "", "", ""
	dry := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--dry-run":
			dry = true
		case "-o", "--output", "--ffmpeg":
			if i + 1 >= len(args) {
				errorf("%s needs a value", a)
				return EXIT_USAGE
			}
			i += 1
			if a == "--ffmpeg" {
				ffmpeg = args[i]
			} else {
				output = args[i]
			}
		case:
			if len(a) > 1 && a[0] == '-' {
				errorf("run: unknown option %q (see tessera run --help)", a)
				return EXIT_USAGE
			}
			if path != "" {
				errorf("run: one job file at a time")
				return EXIT_USAGE
			}
			path = a
		}
	}
	if path == "" {
		fmt.eprint(RUN_USAGE)
		return EXIT_USAGE
	}
	job, err := load_job(path)
	if err != nil {
		errorf("%s", err.?)
		return EXIT_USAGE
	}
	if output != "" {
		job.output = output
	}
	if ffmpeg != "" {
		job.ffmpeg = ffmpeg
	}
	job.dry_run = job.dry_run || dry
	return execute_job(&job)
}
