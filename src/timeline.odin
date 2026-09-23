package tessera

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:time"

// The frame loop. Output frame n of a scene is at t = n / fps; a cell shows
// source frame k = floor(t · src_fps + 1e-6), reading and discarding until k
// is current. Past the source's end the cell holds, goes to background, or
// loops.

Cell_State :: struct {
	cell:      Cell,
	probe:     Probe,
	rect:      Rect, // the cell
	dst:       Rect, // where the picture lands (fit_rect)
	crop:      Rect, // the part of the source shown
	rs:        Resampler,
	cache:     Image, // the resampled current frame, dst-sized
	frame:     []u8, // the current source frame, rgb24
	spare:     []u8, // the next read goes here, then the two swap
	dec:       Decoder,
	decoding:  bool,
	shown:     int, // index of frame within the current pass; -1: none yet
	version:   int, // bumps with every new frame in `frame`
	cached:    int, // version resampled into cache; -1: none
	loop_base: int, // source frames played by earlier passes
	length:    int, // frames in one pass; 0 until the decoder has ended
	visible:   bool,
}

Scene_State :: struct {
	scene:      ^Scene,
	index:      int,
	cells:      []Cell_State,
	frames:     int, // output frames in the scene
	duration:   f64,
	grid_rect:  Rect,
	title_rect: Rect, // empty without a title
	label_size: f32,
	sprites:    [dynamic]Sprite, // labels, the title, the texts, the captions
}

// Resolved is a job with every source probed and the canvas and rate fixed.
Resolved :: struct {
	job:    ^Job,
	tools:  Tools,
	probes: map[string]Probe,
	fps:    Rational,
	w, h:   int,
	text:   ^Text_Engine,
}

// decode_rate is the rate the decoder delivers frames at.
decode_rate :: proc(p: Probe) -> f64 {
	return rational_f64(p.avg_fps if p.vfr else p.fps)
}

TITLE_BAND_FRACTION :: 0.075 // of the canvas height, when a scene has a title

title_band_height :: proc(canvas_h: int) -> int {
	return int(f32(canvas_h) * TITLE_BAND_FRACTION + 0.5)
}

// resolve probes every source once and settles the output rate and canvas.
resolve :: proc(job: ^Job, tools: Tools) -> (r: Resolved, err: Err) {
	r.job = job
	r.tools = tools
	best_fps: Rational
	for &scene in job.scenes {
		for c in scene.cells {
			if c.src in r.probes {
				continue
			}
			p := probe(tools, c.src) or_return
			r.probes[c.src] = p
			if !p.still && rational_f64(p.fps) > rational_f64(best_fps) {
				best_fps = p.avg_fps if p.vfr else p.fps
			}
		}
	}
	r.fps = job.fps
	if r.fps.num == 0 {
		r.fps = best_fps
		if r.fps.num == 0 {
			r.fps = {30, 1}
		}
		if rational_f64(r.fps) > 60 {
			r.fps = {60, 1}
		}
	}
	r.w, r.h = job.width, job.height
	if job.native {
		r.w, r.h = DEFAULT_CANVAS_W, DEFAULT_CANVAS_H
		for &scene in job.scenes {
			if len(scene.cells) == 0 {
				continue
			}
			sw, sh := 0, 0
			for c in scene.cells {
				p := r.probes[c.src]
				if p.width * p.height > sw * sh {
					sw, sh = p.width, p.height
				}
			}
			cols, rows := scene_grid(&scene, r.w, r.h, r.probes)
			// The title band scales with the canvas, so size without it first.
			_, h := native_canvas(cols, rows, sw, sh, scene.layout.gap, scene.layout.margin, 0)
			extra := title_band_height(h) if scene.layout.title != "" else 0
			r.w, r.h = native_canvas(cols, rows, sw, sh, scene.layout.gap, scene.layout.margin, extra)
			break
		}
	}
	if r.w <= 0 || r.h <= 0 {
		r.w, r.h = DEFAULT_CANVAS_W, DEFAULT_CANVAS_H
	}
	return r, nil
}

// scene_grid is the scene's cols×rows, from its layout or grid_dims.
scene_grid :: proc(scene: ^Scene, canvas_w, canvas_h: int, probes: map[string]Probe) -> (cols, rows: int) {
	n := len(scene.cells)
	if n == 0 {
		return 0, 0
	}
	cols, rows = scene.layout.cols, scene.layout.rows
	if cols > 0 && rows > 0 {
		return
	}
	if cols > 0 {
		return cols, (n + cols - 1) / cols
	}
	if rows > 0 {
		return (n + rows - 1) / rows, rows
	}
	// The aspect of the largest source stands for all of them.
	aspect: f32 = 16.0 / 9.0
	best := 0
	for c in scene.cells {
		p := probes[c.src]
		if p.width * p.height > best {
			best = p.width * p.height
			aspect = f32(p.width) / f32(p.height)
		}
	}
	title_h := title_band_height(canvas_h) if scene.layout.title != "" else 0
	return grid_dims(n, canvas_w, canvas_h - title_h, aspect)
}

// cell_seconds is how long a cell's source plays from its start.
cell_seconds :: proc(c: Cell, p: Probe) -> f64 {
	if p.still {
		return 0
	}
	return max(f64(p.frames) / decode_rate(p) - c.start, 0)
}

// scene_duration applies the scene's rule to its cells.
scene_duration :: proc(scene: ^Scene, index: int, probes: map[string]Probe) -> (seconds: f64, err: Err) {
	switch d in scene.duration {
	case f64:
		if d <= 0 {
			return 0, fmt.aprintf("scene %d: duration must be positive", index + 1)
		}
		return d, nil
	case Duration_Rule:
		have := false
		for c in scene.cells {
			p := probes[c.src]
			if p.still {
				continue
			}
			s := cell_seconds(c, p)
			if !have {
				seconds, have = s, true
			} else if d == .Longest {
				seconds = max(seconds, s)
			} else {
				seconds = min(seconds, s)
			}
		}
		if !have {
			return 0, fmt.aprintf("scene %d has no video to time it by; give its duration in seconds", index + 1)
		}
		if seconds <= 0 {
			return 0, fmt.aprintf("scene %d: every video starts past its end", index + 1)
		}
		return seconds, nil
	}
	return 0, fmt.aprintf("scene %d: no duration", index + 1)
}

// plan_scene lays a scene out on the canvas. It opens nothing.
plan_scene :: proc(r: ^Resolved, scene: ^Scene, index: int) -> (st: Scene_State, err: Err) {
	st.scene = scene
	st.index = index
	st.duration = scene_duration(scene, index, r.probes) or_return
	st.frames = max(int(math.round(st.duration * rational_f64(r.fps))), 1)
	canvas := Rect{0, 0, r.w, r.h}
	st.grid_rect = canvas
	if scene.layout.title != "" {
		th := title_band_height(r.h)
		st.title_rect = Rect{0, scene.layout.margin, r.w, th}
		st.grid_rect = Rect{0, th, r.w, r.h - th}
	}
	n := len(scene.cells)
	if n == 0 {
		return st, nil
	}
	cols, rows := scene_grid(scene, r.w, r.h, r.probes)
	if cols * rows < n {
		return st, fmt.aprintf("scene %d: a %dx%d grid cannot hold %d cells", index + 1, cols, rows, n)
	}
	rects := cell_rects(st.grid_rect, cols, rows, scene.layout.gap, scene.layout.margin, n, context.temp_allocator)
	st.cells = make([]Cell_State, n)
	for c, i in scene.cells {
		cs := &st.cells[i]
		cs.cell = c
		cs.probe = r.probes[c.src]
		cs.rect = rects[i]
		cs.dst, cs.crop = fit_rect(cs.probe.width, cs.probe.height, cs.rect, c.fit)
	}
	st.label_size = scene.layout.label_size
	if st.label_size <= 0 && n > 0 {
		st.label_size = clamp(f32(rects[0].h) * 0.05, 14, 40)
	}
	return st, nil
}

// scene_sprites renders the scene's labels, title and texts.
scene_sprites :: proc(r: ^Resolved, st: ^Scene_State) {
	for cs in st.cells {
		if cs.cell.label == "" {
			continue
		}
		t := label_text(cs.cell.label, st.label_size, cs.dst)
		append(&st.sprites, make_sprite(r.text, t, r.w, r.h))
	}
	if st.scene.layout.title != "" {
		append(&st.sprites, make_sprite(r.text, title_text(st.scene.layout.title, st.title_rect), r.w, r.h))
	}
	for t in st.scene.texts {
		append(&st.sprites, make_sprite(r.text, t, r.w, r.h))
	}
	for c in st.scene.captions {
		append(&st.sprites, make_sprite(r.text, caption_text(c.text, c.from, c.to, r.h), r.w, r.h))
	}
}

// open_scene starts the decoders and allocates the buffers.
open_scene :: proc(r: ^Resolved, st: ^Scene_State, tmp: string) -> Err {
	scene_sprites(r, st)
	for &cs, i in st.cells {
		p := cs.probe
		cs.frame = make([]u8, p.width * p.height * 3)
		cs.spare = make([]u8, p.width * p.height * 3)
		cs.rs = resampler_make(p.width, p.height, cs.crop, cs.dst.w, cs.dst.h)
		cs.cache = image_make(cs.dst.w, cs.dst.h)
		cs.shown = -1
		cs.cached = -1
		cs.visible = false
		start_decoder(r, &cs, tmp, st.index, i) or_return
		if p.still {
			if !decoder_read(&cs.dec, cs.frame) {
				_ = decoder_close(&cs.dec)
				return fmt.aprintf("%s: could not decode the image", cs.cell.src)
			}
			decoder_close(&cs.dec) or_return
			cs.decoding = false
			cs.shown = 0
			cs.version = 1
			cs.length = 1
			cs.visible = true
		}
	}
	return nil
}

@(private = "file")
start_decoder :: proc(r: ^Resolved, cs: ^Cell_State, tmp: string, scene, cell: int) -> Err {
	name := fmt.tprintf("decode-s%d-c%d.log", scene + 1, cell + 1)
	log, _ := filepath.join({tmp, name}, context.temp_allocator)
	cs.dec = decoder_open(r.tools, cs.probe, cs.cell.start, log) or_return
	cs.decoding = true
	return nil
}

close_scene :: proc(st: ^Scene_State) {
	for &cs in st.cells {
		if cs.decoding {
			_ = decoder_close(&cs.dec)
			cs.decoding = false
		}
		delete(cs.frame)
		delete(cs.spare)
		resampler_delete(&cs.rs)
		image_delete(&cs.cache)
	}
	delete(st.cells)
	st.cells = nil
	for &s in st.sprites {
		sprite_delete(&s)
	}
	delete(st.sprites)
	st.sprites = nil
}

// cell_advance brings the cell to the source frame shown at scene time t.
cell_advance :: proc(r: ^Resolved, cs: ^Cell_State, t: f64, tmp: string, scene, cell: int) -> Err {
	if cs.probe.still {
		return nil
	}
	k := int(math.floor(t * decode_rate(cs.probe) + 1e-6))
	for {
		local := k - cs.loop_base
		if cs.length > 0 && local >= cs.length {
			// Past the end of this pass.
			switch cs.cell.end {
			case .Hold:
				cs.visible = cs.shown >= 0
			case .Black:
				cs.visible = false
			case .Loop:
				if cs.length <= 0 {
					cs.visible = false
					return nil
				}
				cs.loop_base += cs.length
				start_decoder(r, cs, tmp, scene, cell) or_return
				cs.shown = -1
				continue
			}
			return nil
		}
		for cs.shown < local {
			if !cs.decoding || !decoder_read(&cs.dec, cs.spare) {
				if cs.decoding {
					cs.decoding = false
					decoder_close(&cs.dec) or_return
				}
				cs.length = cs.shown + 1
				break
			}
			cs.frame, cs.spare = cs.spare, cs.frame
			cs.shown += 1
			cs.version += 1
		}
		if cs.shown >= local {
			cs.visible = true
			return nil
		}
		if cs.length == 0 {
			// The source gave no frame at all from its start.
			cs.visible = false
			return nil
		}
	}
}

// render composes every scene and writes the frames to the encoder.
render :: proc(r: ^Resolved, enc: ^Encoder, tmp: string) -> Err {
	canvas := image_make(r.w, r.h)
	defer image_delete(&canvas)
	yuv := make([]u8, yuv_frame_size(r.w, r.h))
	defer delete(yuv)
	total := 0
	for &scene, i in r.job.scenes {
		st := plan_scene(r, &scene, i) or_return
		total += st.frames
		close_scene(&st)
	}
	done := 0
	started := time.tick_now()
	tty := os.is_tty(os.stderr)
	for &scene, si in r.job.scenes {
		st := plan_scene(r, &scene, si) or_return
		defer close_scene(&st)
		open_scene(r, &st, tmp) or_return
		for n in 0 ..< st.frames {
			t := f64(n) * f64(r.fps.den) / f64(r.fps.num)
			for &cs, ci in st.cells {
				cell_advance(r, &cs, t, tmp, si, ci) or_return
			}
			compose_frame(&canvas, &st, t)
			rgb_to_yuv420p(canvas, yuv, 0, r.h)
			encoder_write(enc, yuv) or_return
			done += 1
			if tty && (done % 30 == 0 || done == total) {
				secs := time.duration_seconds(time.tick_since(started))
				fmt.eprintf("\rcompose: frame %d/%d, %.1f frames/s   ", done, total, f64(done) / max(secs, 1e-3))
			}
			free_all(context.temp_allocator)
		}
	}
	if tty {
		fmt.eprintln()
	}
	return nil
}
