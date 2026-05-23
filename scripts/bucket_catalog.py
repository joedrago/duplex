#!/usr/bin/env python3
"""Classify a JSON-lines catalog (produced by `scripts/scan_library.py`)
into testing buckets that line up with duplex's capability matrix, and
print a per-bucket summary with example entries.

Usage:

    python3 scripts/bucket_catalog.py <catalog.jsonl> [--limit N]

Buckets:
  A   mp4-direct-passthrough           .mp4, single video + audio, no subs,
                                       audio codec is passthrough-friendly
  A2  mp4-direct-with-srt              like A, with a sidecar .srt
  B   mkv-single-audio-good            .mkv, one audio whose codec is
                                       passthrough-friendly (mux-only path)
  Bx  mkv-single-audio-needs-xcode     .mkv, one audio that triggers the
                                       transcode chain
  C   mkv-multi-audio-all-good         .mkv, >=2 audios, all passthrough
  D   mkv-multi-audio-codec-mix        .mkv, >=2 audios with a mix of
                                       passthrough and transcode-required
  E   mkv-multi-audio-all-need-xcode   .mkv, >=2 audios, all require xcode
  Ec  mkv-multi-audio-channel-mix      .mkv, >=2 audios with differing
                                       channel counts (e.g. 2ch vs 6ch).
                                       Highlights swap-UX cases that look
                                       similar at the codec level but
                                       differ in layout.
  F   mkv-mixed-sub-formats            .mkv with both text and image
                                       subtitle streams in the container
  G   many-subs                        files with >=5 subtitle streams

The "good vs transcode" split is governed by GOOD_AUDIO below. Keep it in
sync with duplex's capability matrix if that ever changes.
"""
import argparse
import json
import os
import sys
from collections import defaultdict


# Audio codecs duplex treats as passthrough-friendly inside fragmented MP4.
GOOD_AUDIO = {"aac"}

# Subtitle codec classes (text = browser-renderable via WebVTT conversion,
# image = bitmap, requires burn-in or rendering pipeline we don't have).
TEXT_SUB_CODECS = {"subrip", "ass", "ssa", "mov_text", "webvtt"}
IMAGE_SUB_CODECS = {"hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"}


def needs_transcode(a):
    codec = (a.get("codec") or "").lower()
    return codec not in GOOD_AUDIO


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog", help="Path to a JSON-lines catalog from scan_library.py")
    ap.add_argument("--limit", type=int, default=8, help="Max examples to show per bucket")
    args = ap.parse_args()

    records = []
    with open(args.catalog) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "error" in r:
                continue
            ext = os.path.splitext(r["path"])[1].lower()
            if ext not in (".mkv", ".mp4"):
                continue
            records.append(r)

    print(f"# Catalog: {len(records)} mkv/mp4 files\n")

    buckets = defaultdict(list)
    for r in records:
        ext = os.path.splitext(r["path"])[1].lower()
        vids = r.get("video") or []
        auds = r.get("audio") or []
        subs = r.get("subs") or []
        sidecars = r.get("sidecars") or []
        xcoded = [needs_transcode(a) for a in auds]
        n_xcode = sum(1 for x in xcoded if x)
        n_good = len(auds) - n_xcode
        channels = {a.get("channels") for a in auds}

        if ext == ".mp4" and len(vids) == 1 and len(auds) == 1 and not xcoded[0]:
            if any(sc.lower().endswith(".srt") for sc in sidecars):
                buckets["A2_mp4_direct_with_srt"].append(r)
            elif not subs:
                buckets["A_mp4_direct_passthrough"].append(r)

        if ext == ".mkv" and len(vids) == 1 and len(auds) == 1:
            if not xcoded[0]:
                buckets["B_mkv_single_audio_good"].append(r)
            else:
                buckets["Bx_mkv_single_audio_needs_xcode"].append(r)

        if ext == ".mkv" and len(auds) >= 2:
            if n_xcode == 0:
                buckets["C_mkv_multi_audio_all_good"].append(r)
            elif n_good >= 1 and n_xcode >= 1:
                buckets["D_mkv_multi_audio_codec_mix"].append(r)
            else:
                buckets["E_mkv_multi_audio_all_need_xcode"].append(r)
            if len(channels) > 1:
                buckets["Ec_mkv_multi_audio_channel_mix"].append(r)

        sub_codecs = {(s.get("codec") or "").lower() for s in subs}
        if ext == ".mkv" and (sub_codecs & TEXT_SUB_CODECS) and (sub_codecs & IMAGE_SUB_CODECS):
            buckets["F_mkv_mixed_sub_formats"].append(r)
        if len(subs) >= 5:
            buckets["G_many_subs"].append(r)

    for name in sorted(buckets):
        rows = buckets[name]
        print(f"## {name}  ({len(rows)} files)")
        for r in rows[: args.limit]:
            audio_desc = ", ".join(
                f"{(a.get('codec') or '?')}/{a.get('channels') or '?'}ch"
                + (f"/{a.get('lang')}" if a.get('lang') else "")
                for a in r.get("audio") or []
            )
            v = (r.get("video") or [{}])[0]
            side_desc = f" +{len(r.get('sidecars') or [])}sidecar" if r.get("sidecars") else ""
            print(f"  - {os.path.basename(r['path'])}")
            print(
                f"      v={v.get('codec')} {v.get('width')}x{v.get('height')} prof={v.get('profile')}  "
                f"audio=[{audio_desc}]  subs={_sub_summary(r.get('subs') or [])}{side_desc}"
            )
        if len(rows) > args.limit:
            print(f"  ... ({len(rows) - args.limit} more)")
        print()


def _sub_summary(subs):
    if not subs:
        return "0"
    counts = defaultdict(int)
    for s in subs:
        c = (s.get("codec") or "?").lower()
        if c in TEXT_SUB_CODECS:
            counts["text"] += 1
        elif c in IMAGE_SUB_CODECS:
            counts["image"] += 1
        else:
            counts[c] += 1
    return f"{len(subs)}({','.join(f'{k}:{v}' for k, v in counts.items())})"


if __name__ == "__main__":
    main()
