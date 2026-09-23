// tessera: several videos (and stills) on one screen, with text, encoded as
// small as it can be without a visible loss. ffmpeg is only the codec; the
// layout, resampling, compositing, colour conversion, text and quality metric
// are ours.
package tessera

import "core:fmt"
import "core:os"
import "core:strconv"

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
	case "ssim":
		return cmd_ssim(rest)
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
	case "ssim":
		fmt.print(SSIM_USAGE)
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

SSIM_USAGE :: `usage: tessera ssim <a> <b> [--frames N] [--threads N] [--ffmpeg PATH]

SSIM between two videos of the same size, on the luma plane, frame by frame
from the start (11x11 Gaussian window). Prints the mean and the worst frame.
`

cmd_ssim :: proc(args: []string) -> int {
	paths := make([dynamic]string, context.temp_allocator)
	frames, threads := 0, 0
	ffmpeg := ""
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--frames", "--threads", "--ffmpeg":
			if i + 1 >= len(args) {
				errorf("%s needs a value", a)
				return EXIT_USAGE
			}
			i += 1
			if a == "--ffmpeg" {
				ffmpeg = args[i]
				continue
			}
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 {
				errorf("%s: %q is not a positive whole number", a, args[i])
				return EXIT_USAGE
			}
			if a == "--frames" {
				frames = n
			} else {
				threads = n
			}
		case:
			if len(a) > 1 && a[0] == '-' {
				errorf("ssim: unknown option %q", a)
				return EXIT_USAGE
			}
			append(&paths, a)
		}
	}
	if len(paths) != 2 {
		fmt.eprint(SSIM_USAGE)
		return EXIT_USAGE
	}
	tools, terr := find_tools(ffmpeg)
	if terr != nil {
		errorf("%s", terr.?)
		return EXIT_RUNTIME
	}
	pa, aerr := probe(tools, paths[0])
	if aerr != nil {
		errorf("%s", aerr.?)
		return EXIT_RUNTIME
	}
	pb, berr := probe(tools, paths[1])
	if berr != nil {
		errorf("%s", berr.?)
		return EXIT_RUNTIME
	}
	tmp, derr := os.make_directory_temp("", "tessera-*", context.allocator)
	if derr != nil {
		errorf("cannot create a temporary directory: %v", derr)
		return EXIT_RUNTIME
	}
	defer os.remove_all(tmp)
	w: Workers
	workers_init(&w, threads if threads > 0 else default_threads())
	defer workers_destroy(&w)
	res, err := ssim_compare(tools, pa, 0, pb, 0, frames, &w, tmp)
	if err != nil {
		errorf("%s", err.?)
		return EXIT_RUNTIME
	}
	worst := 0
	for s, i in res.frames {
		if s < res.frames[worst] {
			worst = i
		}
	}
	fmt.printf("ssim mean %.5f, min %.5f (frame %d), %d frames, luma\n", res.mean, res.min, worst, len(res.frames))
	return EXIT_OK
}
