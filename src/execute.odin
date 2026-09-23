package tessera

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// execute_job probes, plans, and (unless it is a dry run) renders and
// encodes: straight to the output at an explicit CRF, or through a lossless
// master and the quality search for a preset.
execute_job :: proc(job: ^Job) -> int {
	tools, terr := find_tools(job.ffmpeg)
	if terr != nil {
		errorf("%s", terr.?)
		return EXIT_RUNTIME
	}
	for enc in ([]string{codec_encoder(job.encode.codec), "libx264"}) {
		if err := require_encoder(&tools, enc); err != nil {
			errorf("%s", err.?)
			return EXIT_RUNTIME
		}
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
	if job.dry_run {
		return print_plan(&r)
	}

	w: Workers
	workers_init(&w, job.threads if job.threads > 0 else default_threads())
	defer workers_destroy(&w)
	tmp, derr := os.make_directory_temp("", "tessera-*", context.allocator)
	if derr != nil {
		errorf("cannot create a temporary directory: %v", derr)
		return EXIT_RUNTIME
	}
	started := time.tick_now()
	err: Err
	if crf, explicit := job.encode.quality.(CRF); explicit {
		err = encode_direct(&r, int(crf), tmp)
	} else {
		err = encode_searched(&r, job.encode.quality.(Preset_Quality), tmp, &w)
	}
	if err != nil {
		errorf("%s", err.?)
		if strings.contains(err.?, "[log: ") {
			errorf("logs kept in %s", tmp)
		} else {
			_ = os.remove_all(tmp)
		}
		return EXIT_RUNTIME
	}
	_ = os.remove_all(tmp)
	fmt.printf("done in %.1f s\n", time.duration_seconds(time.tick_since(started)))
	return EXIT_OK
}

// compose_into renders the job into an encoder running cmd.
compose_into :: proc(r: ^Resolved, cmd: []string, tmp: string) -> (stats: Render_Stats, err: Err) {
	enc := encoder_open(cmd, tmp_file(tmp, "encode.log")) or_return
	stats, err = render(r, &enc, tmp)
	if err != nil {
		_ = finish_child(&enc.child, kill = true)
		return
	}
	encoder_close(&enc) or_return
	fmt.printf("compose: %d frames in %.1f s, %.1f frames/s\n", stats.frames, stats.seconds, f64(stats.frames) / max(stats.seconds, 1e-3))
	return stats, nil
}

// encode_direct: an explicit CRF, no master, no search.
encode_direct :: proc(r: ^Resolved, crf: int, tmp: string) -> Err {
	job := r.job
	_, err := compose_into(r, encode_command(r, crf, job.output, context.temp_allocator), tmp)
	if err != nil {
		_ = os.remove(job.output)
		return err
	}
	mb := file_mb(job.output)
	fmt.printf("%s: %dx%d, %d/%d fps, %s crf %d → %s\n", job.output, r.w, r.h, r.fps.num, r.fps.den,
		codec_name(job.encode.codec), crf, size_string(mb))
	if job.encode.max_size_mb > 0 && mb > job.encode.max_size_mb {
		fmt.printf("note: %s is over the %s cap; an explicit crf is not searched, use a quality preset to have it fitted\n", size_string(mb), size_string(job.encode.max_size_mb))
	}
	return nil
}

// encode_searched: compose a lossless master, search the CRF, encode the
// master at it, and check the result against the master.
encode_searched :: proc(r: ^Resolved, q: Preset_Quality, tmp: string, w: ^Workers) -> Err {
	job := r.job
	master := tmp_file(tmp, "master.mkv")
	master = strings.clone(master)
	compose_into(r, master_command(r, master, context.temp_allocator), tmp) or_return
	mp := probe(r.tools, master) or_return
	fmt.printf("master: %d frames, %s lossless\n", mp.frames, size_string(file_mb(master)))

	s := Search{r = r, master = master, probe = mp, tmp = tmp, workers = w}
	s.windows = plan_windows(mp.frames, r.fps)
	t := target_for(q)
	fmt.printf("search: %s (ssim mean ≥ %.3f, every frame ≥ %.3f) on %d window(s) of %d frames\n",
		quality_string(job.encode.quality), t.mean, t.min, len(s.windows), s.windows[0].frames)
	choice := choose_crf(&s, q, job.encode) or_return
	if choice.note != "" {
		fmt.printf("note: %s\n", choice.note)
	}
	c := choice.candidate
	fmt.printf("crf %d (ssim mean %.4f, min %.4f) → %s\n", c.crf, c.mean, c.min, size_string(c.est_mb))

	crf := choice.crf
	final_start := time.tick_now()
	for attempt := 0; ; attempt += 1 {
		final := run_child(transcode_command(r, master, 0, 0, crf, job.output, context.temp_allocator), tmp_file(tmp, "final.log")) or_return
		finish_child(&final) or_return
		mb := file_mb(job.output)
		cap := job.encode.max_size_mb
		if cap <= 0 || mb <= cap || attempt == 3 || crf >= CRF_MAX {
			break
		}
		// The estimate undershot: one CRF up, if the floor allows it.
		next := evaluate(&s, crf + 1) or_return
		if !meets(next, target_for(.Small)) && !job.encode.force {
			return fmt.aprintf("%s came out at %s, over the %s cap, and crf %d would drop below the small floor; raise --max-size or pass --force", job.output, size_string(mb), size_string(cap), crf + 1)
		}
		fmt.printf("note: %s is over the %s cap; encoding again at crf %d\n", size_string(mb), size_string(cap), crf + 1)
		crf += 1
	}
	encode_secs := time.duration_seconds(time.tick_since(final_start))

	// The whole result against the whole master.
	op := probe(r.tools, job.output) or_return
	res := ssim_compare(r.tools, mp, 0, op, 0, 0, w, tmp) or_return
	defer ssim_result_delete(&res)
	fmt.printf("%s: %dx%d, %d/%d fps, %s crf %d → %s; whole video ssim mean %.4f, min %.4f (%d frames); encode %.1f s\n",
		job.output, r.w, r.h, r.fps.num, r.fps.den, codec_name(job.encode.codec), crf, size_string(file_mb(job.output)),
		res.mean, res.min, len(res.frames), encode_secs)

	if job.encode.keep_master {
		kept := fmt.aprintf("%s.master.mkv", strings.trim_suffix(job.output, filepath_ext(job.output)))
		if os.rename(master, kept) != nil {
			// Across file systems: copy instead.
			if os.copy_file(kept, master) != nil {
				fmt.printf("note: could not keep the master at %s\n", kept)
			}
		}
		fmt.printf("master kept: %s\n", kept)
	}
	return nil
}

@(private = "file")
filepath_ext :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '.')
	j := strings.last_index_any(p, "/\\")
	if i <= j + 1 {
		return ""
	}
	return p[i:]
}

// file_mb is a file's size in megabytes (10^6 bytes), 0 if it is missing.
file_mb :: proc(path: string) -> f64 {
	return f64(file_bytes(path)) / 1e6
}

// print_plan is --dry-run: the canvas, the rects, the rate, the durations
// and the ffmpeg commands.
print_plan :: proc(r: ^Resolved) -> int {
	fmt.printf("canvas %dx%d, %d/%d fps, %s, quality %s\n", r.w, r.h, r.fps.num, r.fps.den,
		codec_name(r.job.encode.codec), quality_string(r.job.encode.quality))
	total := 0.0
	frames := 0
	for &scene, i in r.job.scenes {
		st, err := plan_scene(r, &scene, i)
		if err != nil {
			errorf("%s", err.?)
			return EXIT_RUNTIME
		}
		total += f64(st.frames) * f64(r.fps.den) / f64(r.fps.num)
		frames += st.frames
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
	fmt.printf("total %.3f s, %d frames\n", total, frames)
	if crf, explicit := r.job.encode.quality.(CRF); explicit {
		fmt.printf("encode: %s\n", command_line(encode_command(r, int(crf), r.job.output, context.temp_allocator)))
		return EXIT_OK
	}
	master := "<tmp>/master.mkv"
	fmt.printf("master: %s\n", command_line(master_command(r, master, context.temp_allocator)))
	windows := plan_windows(frames, r.fps, context.temp_allocator)
	for w in windows {
		fmt.printf("  window at %.3f s, %d frames\n", w.start, w.frames)
	}
	fmt.printf("each candidate: %s\n", command_line(transcode_command(r, master, windows[0].start, windows[0].frames, 23, "<tmp>/window.mkv", context.temp_allocator)))
	fmt.printf("final: %s\n", command_line(transcode_command(r, master, 0, 0, 23, r.job.output, context.temp_allocator)))
	fmt.println("(crf 23 above stands for the searched value)")
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
