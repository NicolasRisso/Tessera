package tessera

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:thread"

// Workers runs batches of tasks on a core:thread pool. The pool has no "wait
// for these" call, so workers_run queues a batch, works on it from the
// calling thread too, and then waits for the stragglers.
Workers :: struct {
	pool:    thread.Pool,
	threads: int, // including the calling thread
	owner:   int, // the calling thread's id
}

// default_threads is the core count minus one, at least 1.
default_threads :: proc() -> int {
	return max(os.get_processor_core_count() - 1, 1)
}

workers_init :: proc(w: ^Workers, threads: int) {
	w.threads = max(threads, 1)
	w.owner = os.get_current_thread_id()
	if w.threads > 1 {
		thread.pool_init(&w.pool, runtime.heap_allocator(), w.threads - 1)
		thread.pool_start(&w.pool)
	}
}

workers_destroy :: proc(w: ^Workers) {
	if w.threads > 1 {
		thread.pool_join(&w.pool)
		thread.pool_destroy(&w.pool)
	}
	w^ = {}
}

Work_Proc :: #type proc(data: rawptr, index: int)

@(private = "file")
Work_Item :: struct {
	fn:    Work_Proc,
	data:  rawptr,
	index: int,
	owner: int,
}

@(private = "file")
run_item :: proc(task: thread.Task) {
	item := (^Work_Item)(task.data)
	item.fn(item.data, item.index)
	// A pool thread's scratch is its own to clear; the calling thread's may
	// hold the caller's data (and this batch's items).
	if os.get_current_thread_id() != item.owner {
		free_all(context.temp_allocator)
	}
}

// workers_run calls fn(data, i) for i in 0 ..< n across the threads and
// returns when every call has returned.
workers_run :: proc(w: ^Workers, n: int, fn: Work_Proc, data: rawptr) {
	if w.threads <= 1 || n <= 1 {
		for i in 0 ..< n {
			fn(data, i)
		}
		return
	}
	items := make([]Work_Item, n)
	defer delete(items)
	for i in 0 ..< n {
		items[i] = Work_Item{fn, data, i, w.owner}
		thread.pool_add_task(&w.pool, runtime.heap_allocator(), run_item, &items[i], i)
	}
	// Help from this thread, then wait for the ones still running.
	for task in thread.pool_pop_waiting(&w.pool) {
		thread.pool_do_work(&w.pool, task)
	}
	for thread.pool_num_outstanding(&w.pool) > 0 {
		intrinsics.cpu_relax()
	}
	for _ in thread.pool_pop_done(&w.pool) {
	}
}
