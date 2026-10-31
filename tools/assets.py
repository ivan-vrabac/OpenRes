#!/usr/bin/env python3
"""Checks the app's pictures. Stdlib only. Run from the repository root.

  python tools/assets.py validate [--strict]

Every file under app/assets and the Android resources must be a readable image (or a known
media type). Maintainers can keep a list of SHA-256 hashes of pictures that must never be
committed in tools/blocked_hashes.txt (gitignored); any match fails the check. --strict also
fails on files of unknown type.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
BLOCKED = ROOT / "tools" / "blocked_hashes.txt"
ASSET_DIRS = ["assets", "android/app/src/main/res"]
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
OTHER_EXT = {".ttf", ".otf", ".mp3", ".ogg", ".wav", ".json", ".xml", ".csv", ".txt", ".md"}


def image_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return 1, 1
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return struct.unpack("<HH", data[6:10])
    return 0, 0


def walk_assets():
    for d in ASSET_DIRS:
        base = APP / d
        if base.exists():
            for p in sorted(base.rglob("*")):
                if p.is_file():
                    yield p.relative_to(APP).as_posix(), p


def cmd_validate(args) -> int:
    blocked = set()
    if BLOCKED.exists():
        blocked = {ln.strip() for ln in BLOCKED.read_text().splitlines() if ln.strip()}
    errors, warnings, n = [], [], 0
    for rel, p in walk_assets():
        n += 1
        ext = p.suffix.lower()
        if ext in IMAGE_EXT and image_size(p) == (0, 0):
            errors.append(f"unreadable image: app/{rel}")
        elif ext not in IMAGE_EXT | OTHER_EXT:
            warnings.append(f"unknown file type: app/{rel}")
        if blocked and hashlib.sha256(p.read_bytes()).hexdigest() in blocked:
            errors.append(f"blocked picture: app/{rel}")
    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print(f"{n} asset files" + (f", {len(blocked)} blocked hashes" if blocked else ""))
    if errors or (args.strict and warnings):
        print("validation FAILED")
        return 1
    print("validation OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate").add_argument("--strict", action="store_true")
    return cmd_validate(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
