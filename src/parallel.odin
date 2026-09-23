package tessera

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:sync"
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

// ---- Reading ahead ----
//
// A decoder can only run as far ahead of us as its pipe holds (64 KB on
// Linux, a sliver of a frame), so without help every read waits for
// ffmpeg to decode. A Prefetch reads frames on its own thread into a ring
// of buffers; the consumer holds one buffer at a time.

PREFETCH_FRAMES :: 3

Prefetch :: struct {
	dec:    Decoder,
	bufs:   [PREFETCH_FRAMES][]u8,
	filled: sync.Sema, // frames ready (or the end)
	free:   sync.Sema, // buffers the reader may fill
	head:   int, // next buffer the consumer takes
	tail:   int, // frames the reader has filled (atomic)
	eof:    bool, // the reader is done (atomic)
	stop:   bool, // asked to stop (atomic)
	held:   bool, // the consumer holds buffer head-1
	th:     ^thread.Thread,
}

@(private = "file")
prefetch_reader :: proc(p: ^Prefetch) {
	for {
		sync.sema_wait(&p.free)
		if intrinsics.atomic_load(&p.stop) {
			break
		}
		tail := intrinsics.atomic_load(&p.tail)
		if !decoder_read(&p.dec, p.bufs[tail % PREFETCH_FRAMES]) {
			break
		}
		intrinsics.atomic_store(&p.tail, tail + 1)
		sync.sema_post(&p.filled)
	}
	intrinsics.atomic_store(&p.eof, true)
	sync.sema_post(&p.filled)
}

// prefetch_start takes over an open decoder and starts reading ahead. p
// must not move until prefetch_stop.
prefetch_start :: proc(p: ^Prefetch, dec: Decoder) {
	p^ = {}
	p.dec = dec
	for &b in p.bufs {
		b = make([]u8, dec.frame_bytes)
	}
	sync.sema_post(&p.free, PREFETCH_FRAMES)
	p.th = thread.create_and_start_with_poly_data(p, prefetch_reader)
}

// prefetch_next returns the next frame, valid until the call after next
// (the previous one stays valid until then, so a held last frame survives
// the end). ok is false at the end of the stream.
prefetch_next :: proc(p: ^Prefetch) -> (frame: []u8, ok: bool) {
	sync.sema_wait(&p.filled)
	if p.head >= intrinsics.atomic_load(&p.tail) {
		// The end: leave the post for anyone asking again.
		sync.sema_post(&p.filled)
		return nil, false
	}
	if p.held {
		sync.sema_post(&p.free) // the frame before this one
	}
	frame = p.bufs[p.head % PREFETCH_FRAMES]
	p.head += 1
	p.held = true
	return frame, true
}

// prefetch_stop ends the reader (killing the decoder if it is not done) and
// frees the buffers.
prefetch_stop :: proc(p: ^Prefetch) -> Err {
	if p.th == nil {
		return nil
	}
	intrinsics.atomic_store(&p.stop, true)
	sync.sema_post(&p.free)
	// A reader blocked in read() wakes when the decoder dies.
	if !intrinsics.atomic_load(&p.eof) {
		_ = os.process_kill(p.dec.process)
	}
	thread.join(p.th)
	thread.destroy(p.th)
	p.th = nil
	err := decoder_close(&p.dec)
	for b in p.bufs {
		delete(b)
	}
	return err
}

// ---- Writing behind ----
//
// The same for the encoder: frames are handed to a writer thread, so the
// next frame is composed while the last one goes down the pipe.

WRITE_BEHIND :: 2

Write_Behind :: struct {
	enc:    ^Encoder,
	bufs:   [WRITE_BEHIND][]u8,
	filled: sync.Sema, // frames to write (or the end, after stop)
	free:   sync.Sema, // buffers the composer may fill
	head:   int, // next buffer the composer fills
	queued: int, // frames handed over (atomic)
	stop:   bool, // no more frames (atomic)
	err:    Err, // the writer's first failure; read after join
	failed: bool, // atomic mirror of err != nil
	th:     ^thread.Thread,
}

@(private = "file")
writer_loop :: proc(wb: ^Write_Behind) {
	written := 0
	for {
		sync.sema_wait(&wb.filled)
		if written >= intrinsics.atomic_load(&wb.queued) {
			break // woken by stop with nothing left
		}
		if !intrinsics.atomic_load(&wb.failed) {
			if err := encoder_write(wb.enc, wb.bufs[written % WRITE_BEHIND]); err != nil {
				wb.err = err
				intrinsics.atomic_store(&wb.failed, true)
			}
		}
		written += 1
		sync.sema_post(&wb.free)
	}
}

write_behind_start :: proc(wb: ^Write_Behind, enc: ^Encoder, frame_bytes: int) {
	wb^ = {}
	wb.enc = enc
	for &b in wb.bufs {
		b = make([]u8, frame_bytes)
	}
	sync.sema_post(&wb.free, WRITE_BEHIND)
	wb.th = thread.create_and_start_with_poly_data(wb, writer_loop)
}

// write_behind_buffer waits for a buffer to compose the next frame into.
write_behind_buffer :: proc(wb: ^Write_Behind) -> []u8 {
	sync.sema_wait(&wb.free)
	return wb.bufs[wb.head % WRITE_BEHIND]
}

// write_behind_submit hands the buffer from write_behind_buffer to the
// writer. It reports an earlier write's failure.
write_behind_submit :: proc(wb: ^Write_Behind) -> bool {
	wb.head += 1
	intrinsics.atomic_add(&wb.queued, 1)
	sync.sema_post(&wb.filled)
	return !intrinsics.atomic_load(&wb.failed)
}

// write_behind_finish writes what is queued, stops the writer and frees the
// buffers. It returns the first write error.
write_behind_finish :: proc(wb: ^Write_Behind) -> Err {
	if wb.th == nil {
		return nil
	}
	intrinsics.atomic_store(&wb.stop, true)
	sync.sema_post(&wb.filled)
	thread.join(wb.th)
	thread.destroy(wb.th)
	wb.th = nil
	for b in wb.bufs {
		delete(b)
	}
	return wb.err
}
