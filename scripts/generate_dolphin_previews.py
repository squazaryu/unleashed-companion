#!/usr/bin/env python3

import argparse
import json
import re
import shutil
from pathlib import Path


def animation_names(firmware: Path) -> list[str]:
    manifest = firmware / "assets/dolphin/external/manifest.txt"
    names = re.findall(r"^Name: (.+)$", manifest.read_text(encoding="utf-8"), re.MULTILINE)
    return ["L1_Tv_128x47", *names]


def source_frame(firmware: Path, name: str) -> Path:
    group = "internal" if name == "L1_Tv_128x47" else "external"
    return firmware / "assets/dolphin" / group / name / "frame_0.png"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("firmware", type=Path)
    parser.add_argument("companion", type=Path)
    args = parser.parse_args()

    destination = args.companion / "Resources/Assets.xcassets"
    names = animation_names(args.firmware)

    for stale in destination.glob("Dolphin_*.imageset"):
        shutil.rmtree(stale)

    contents = {
        "images": [
            {"filename": "frame_0.png", "idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": False},
    }

    for name in names:
        source = source_frame(args.firmware, name)
        if not source.is_file():
            raise FileNotFoundError(source)
        imageset = destination / f"Dolphin_{name}.imageset"
        imageset.mkdir()
        shutil.copyfile(source, imageset / "frame_0.png")
        (imageset / "Contents.json").write_text(
            json.dumps(contents, indent=2) + "\n",
            encoding="utf-8",
        )

    print(f"Generated {len(names)} Dolphin previews")


if __name__ == "__main__":
    main()
