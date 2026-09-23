#+build !windows
package tessera

import "core:sys/posix"

// A dead encoder must surface as a write error with its log, not kill us
// with SIGPIPE.
@(init)
ignore_sigpipe :: proc "contextless" () {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}
