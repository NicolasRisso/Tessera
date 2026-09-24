#+build !windows
package tessera

import "core:os"
import "core:sys/posix"

// A dead encoder must surface as a write error with its log, not kill us
// with SIGPIPE.
@(init)
ignore_sigpipe :: proc "contextless" () {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

// keep_to_self stops a child from inheriting our end of a pipe. On POSIX
// core:os pipes are close-on-exec already.
keep_to_self :: proc(f: ^os.File) {
}
