#!/usr/bin/env python3
# Example: the job behind the Fusefall renderer showcase (2026-09-24) — a title card, three 2×2
# pages of stills (OpenGL / Vulkan before / Vulkan after / Mobile after), two 2×2 clip scenes
# recorded headless on a GTX 1060, a bench table laid out in columns, and a closing card.
#
#   python3 renderer-showcase.py > job.json && tessera run job.json
#
# It expects the MiniTD scratch layout it was written for: stills in ../out/{before,after-v2}/
# named <shot>-<renderer>.png and clips in ../out/showcase/<tour>-<label>.avi. Change O and the
# name lists for your own material; everything else is plain tessera job JSON (README, "The job
# format").
import json, sys

O = "../out"
LABELS = ["OpenGL — the reference", "Vulkan — before", "Vulkan — after", "Mobile — after"]
MUTED = "#9FB3C8"

def stills(shot):
    return [f"{O}/before/{shot}-compat.png", f"{O}/before/{shot}-vulkan.png",
            f"{O}/after-v2/{shot}-vulkan.png", f"{O}/after-v2/{shot}-mobile.png"]

def grid(srcs, title, caption, duration=None, start=0.0):
    scene = {
        "layout": {"cols": 2, "rows": 2, "gap": 10, "margin": 14, "title": title, "label_pos": "above"},
        "cells": [{"src": s, "label": l, "start": start} for s, l in zip(srcs, LABELS)],
        "captions": [{"text": caption, "from": 0.4, "to": 4.5}] if caption else [],
    }
    if duration is not None:
        scene["duration"] = duration
    return scene

def clips(tour):
    return [f"{O}/showcase/{tour}-{r}.avi" for r in ("compat", "vulkan-before", "vulkan-after", "mobile-after")]

ROWS = [
    ("OpenGL — Compatibility", "6.5", "7.7", "10.7"),
    ("Vulkan — Forward+", "14.0", "15.6", "22.6"),
    ("Vulkan — Mobile", "12.8", "16.2", "22.8"),
    ("OpenGL, no copy to the display", "4.2", "4.7", "5.6"),
]

def bench_card():
    t = [{"text": "Engine bench — GTX 1060 · Ryzen 5 2600", "size": 56, "y": "13%"},
         {"text": "mean frame time in ms, median of 3 runs — after the parity work", "size": 30, "y": "21%", "color": MUTED}]
    cols = ["42%", "63%", "84%"]
    for x, h in zip(cols, ["4,000 bodies", "8,000", "16,000"]):
        t.append({"text": h, "size": 32, "x": x, "y": "32%", "anchor": "CR", "color": MUTED})
    for i, (name, *vals) in enumerate(ROWS):
        y = f"{42 + 10 * i}%"
        t.append({"text": name, "size": 38, "x": "8%", "y": y, "anchor": "CL",
                  "color": "#9FB3C8" if i == 3 else "#FFFFFF"})
        for x, v in zip(cols, vals):
            t.append({"text": v, "size": 38, "x": x, "y": y, "anchor": "CR",
                      "color": "#9FB3C8" if i == 3 else "#FFFFFF"})
    t.append({"text": "Headless: Vulkan presents into Xvfb, a cost this setup cannot separate from rendering.", "size": 28, "y": "84%", "color": MUTED})
    t.append({"text": "Parity cost: none on OpenGL, +0.8 ms Forward+ at 4k, +1.6 ms Mobile at 8k. Bodies only, no towers.", "size": 28, "y": "90%", "color": MUTED})
    return t

job = {
    "output": "fusefall-renderers.mp4",
    "size": "1920x1080",
    "fps": 60,
    "encode": {"codec": "h264", "quality": "visually-lossless", "max_size_mb": 15.5},
    "scenes": [
        {"duration": 4, "texts": [
            {"text": "Fusefall", "size": 120, "y": "38%", "fade": 0.4,
             "shadow_dy": 4, "shadow_blur": 6, "shadow_color": "#000000C0"},
            {"text": "Vulkan and Mobile now look like OpenGL", "size": 52, "y": "54%", "from": 0.4, "fade": 0.4},
            {"text": "GTX 1060 · Godot 4.6.2 · 24 Sep 2026", "size": 34, "y": "64%", "color": MUTED, "from": 0.8, "fade": 0.4},
        ]},
        grid(stills("board"), "Level 1 at rest",
             "The neon rims, the green entrance and the red target come back on Vulkan", duration=7),
        grid(stills("shots"), "Towers firing, range disc up",
             "The grey veil of the range disc is gone: translucent passes blend as OpenGL blends", duration=7),
        grid(stills("menu"), "The main menu", None, duration=5),
        grid(clips("vfx"), "The tower-effects tour — the same frames on every renderer",
             "Recorded headless on the GTX 1060, then composited with tessera"),
        grid(clips("props"), "Props and lava", None, duration=30, start=5.0),
        {"duration": 13, "texts": bench_card()},
        {"duration": 5, "texts": [
            {"text": "tessera", "size": 110, "y": "40%", "fade": 0.4},
            {"text": "four videos, one screen — its own layout, scaler, text and SSIM in Odin", "size": 38,
             "y": "55%", "color": MUTED, "from": 0.3, "fade": 0.4},
            {"text": "encoded at the largest CRF that keeps SSIM ≥ 0.990", "size": 34, "y": "63%",
             "color": MUTED, "from": 0.6, "fade": 0.4},
        ]},
    ],
}
json.dump(job, sys.stdout, ensure_ascii=False, indent=1)
