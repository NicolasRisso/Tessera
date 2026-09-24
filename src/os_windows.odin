#+build windows
package tessera

import "core:os"
import win32 "core:sys/windows"

// keep_to_self stops a child from inheriting our end of a pipe. core:os
// makes both ends of a Windows pipe inheritable and starts children with
// every inheritable handle, so without this each later ffmpeg would hold
// our end of an earlier one's pipe.
keep_to_self :: proc(f: ^os.File) {
	win32.SetHandleInformation(win32.HANDLE(os.fd(f)), win32.HANDLE_FLAG_INHERIT, 0)
}
