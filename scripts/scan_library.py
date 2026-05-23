#!/usr/bin/env python3
"""Probe a single video file with ffprobe and emit a compact JSON object
on stdout describing its container, video, audio and subtitle streams,
plus any subtitle sidecar files that share its stem in the same directory.

Designed to be invoked once per file (one-shot per process) so it can be
parallelized by a driver such as `xargs -P` or GNU parallel. Example
usage at the repo root:

    find <library-root> -maxdepth N -type f \\
        \\( -iname "*.mkv" -o -iname "*.mp4" \\) -print0 \\
        | xargs -0 -n1 -P8 python3 scripts/scan_library.py \\
        > catalog.jsonl

Records are line-delimited JSON, suitable for feeding into
`scripts/bucket_catalog.py` or any jq pipeline.
"""
import json
import os
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: scan_library.py <file>")
    path = sys.argv[1]
    r = subprocess.run(
        [
            "ffprobe",
            "-v", "error",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            path,
        ],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(json.dumps({"path": path, "error": r.stderr.strip()[:200]}, ensure_ascii=False))
        return
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        print(json.dumps({"path": path, "error": f"json: {e}"}, ensure_ascii=False))
        return

    fmt = d.get("format", {}) or {}
    rec = {
        "path": path,
        "container": fmt.get("format_name"),
        "duration": _float(fmt.get("duration")),
        "size": _int(fmt.get("size")),
        "video": [],
        "audio": [],
        "subs": [],
    }
    for s in d.get("streams", []):
        t = s.get("codec_type")
        tags = s.get("tags") or {}
        idx = s.get("index")
        if t == "video":
            rec["video"].append({
                "index": idx,
                "codec": s.get("codec_name"),
                "profile": s.get("profile"),
                "width": s.get("width"),
                "height": s.get("height"),
                "pix_fmt": s.get("pix_fmt"),
                "fps": s.get("avg_frame_rate"),
                "has_b_frames": s.get("has_b_frames"),
            })
        elif t == "audio":
            rec["audio"].append({
                "index": idx,
                "codec": s.get("codec_name"),
                "channels": s.get("channels"),
                "layout": s.get("channel_layout"),
                "sample_rate": _int(s.get("sample_rate")),
                "lang": tags.get("language"),
                "title": tags.get("title"),
                "default": (s.get("disposition") or {}).get("default", 0) == 1,
            })
        elif t == "subtitle":
            rec["subs"].append({
                "index": idx,
                "codec": s.get("codec_name"),
                "lang": tags.get("language"),
                "title": tags.get("title"),
                "default": (s.get("disposition") or {}).get("default", 0) == 1,
            })

    # Sidecar subtitles: any file in the same directory whose name starts
    # with the same stem and ends in a recognized subtitle extension.
    stem, _ = os.path.splitext(path)
    base = os.path.basename(stem)
    parent = os.path.dirname(path) or "."
    sidecars = []
    try:
        for entry in os.listdir(parent):
            if entry.startswith(base + ".") or entry.startswith(base + "_"):
                lower = entry.lower()
                if lower.endswith((".srt", ".vtt", ".ass", ".ssa", ".sub")):
                    sidecars.append(entry)
    except OSError:
        pass
    rec["sidecars"] = sidecars

    print(json.dumps(rec, ensure_ascii=False))


def _int(v):
    try:
        return int(v) if v is not None else None
    except (ValueError, TypeError):
        return None


def _float(v):
    try:
        return float(v) if v is not None else None
    except (ValueError, TypeError):
        return None


if __name__ == "__main__":
    main()
