// tessera: several videos (and stills) on one screen, with text, encoded as
// small as it can be without a visible loss. ffmpeg is only the codec; the
// layout, resampling, compositing, colour conversion, text and quality metric
// are ours.
package tessera

import "core:fmt"
import "core:os"

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
	fmt.eprintf("tessera: unknown command %q\n\n", cmd)
	fmt.eprint(USAGE)
	return EXIT_USAGE
}

print_command_help :: proc(cmd: string) -> int {
	switch cmd {
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
