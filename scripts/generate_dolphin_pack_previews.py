#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import ssl
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from pathlib import Path

import heatshrink2
from PIL import Image


def download(url: str, digest: str, cache: Path) -> Path:
    target = cache / digest.lower()
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == digest.lower():
        return target
    request = urllib.request.Request(url, headers={"User-Agent": "TumoCompanion-preview-builder"})
    context = ssl.create_default_context(cafile="/etc/ssl/cert.pem")
    error = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=60, context=context) as response:
                data = response.read()
            break
        except Exception as caught:
            error = caught
            time.sleep(attempt + 1)
    else:
        raise error
    if hashlib.sha256(data).hexdigest() != digest.lower():
        raise ValueError(f"Digest mismatch: {url}")
    target.write_bytes(data)
    return target


def metadata(data: bytes) -> tuple[int, int, int, list[int]]:
    text = data.decode("utf-8")
    width = int(re.search(r"^Width: (\d+)$", text, re.MULTILINE).group(1))
    height = int(re.search(r"^Height: (\d+)$", text, re.MULTILINE).group(1))
    frame_rate = int(re.search(r"^Frame rate: (\d+)$", text, re.MULTILINE).group(1))
    order_match = re.search(r"^Frames order:\s*(.*)$", text, re.MULTILINE)
    order = [int(value) for value in order_match.group(1).split()] if order_match else []
    if not 1 <= width <= 128 or not 1 <= height <= 64:
        raise ValueError(f"Unsupported preview size: {width}x{height}")
    if not 1 <= frame_rate <= 60:
        raise ValueError(f"Unsupported frame rate: {frame_rate}")
    return width, height, frame_rate, order


def decode_frame(data: bytes, width: int, height: int) -> Image.Image:
    expected = ((width + 7) // 8) * height
    if data[:1] == b"\x00":
        bitmap = data[1:]
    elif data[:2] == b"\x01\x00" and len(data) >= 4:
        compressed_size = int.from_bytes(data[2:4], "little")
        compressed = data[4 : 4 + compressed_size]
        bitmap = heatshrink2.decompress(compressed, window_sz2=8, lookahead_sz2=4)
    else:
        raise ValueError("Unsupported Flipper bitmap header")
    if len(bitmap) != expected:
        raise ValueError(f"Unexpected bitmap size: {len(bitmap)} != {expected}")

    row_bytes = (width + 7) // 8
    image = Image.new("1", (width, height), 1)
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            if bitmap[y * row_bytes + x // 8] & (1 << (x % 8)):
                pixels[x, y] = 0
    return image


def zip_files(archive_path: Path, root: str) -> tuple[bytes, list[bytes]]:
    with zipfile.ZipFile(archive_path) as archive:
        prefix = root.rstrip("/") + "/"
        frame_names = sorted(
            (
                name
                for name in archive.namelist()
                if name.startswith(prefix)
                and re.fullmatch(r"frame_\d+\.bm", name[len(prefix) :])
            ),
            key=lambda name: int(re.search(r"frame_(\d+)\.bm$", name).group(1)),
        )
        if not frame_names:
            raise ValueError("No Flipper bitmap frames")
        return archive.read(prefix + "meta.txt"), [archive.read(name) for name in frame_names]


def payload_preview(pack: dict, cache: Path) -> tuple[bytes, list[bytes]]:
    payload = pack["payload"]
    kind = payload["kind"]
    if kind == "remoteZip":
        archive = download(payload["url"], payload["sha256"], cache)
        root = pack["id"]
        return zip_files(archive, root)
    if kind == "repositoryArchive":
        archive = download(payload["url"], payload["sha256"], cache)
        root = f'{payload["rootDirectory"]}/{payload["animationPath"]}'
        return zip_files(archive, root)
    if kind == "remoteFiles":
        files = {item["name"]: item["sha256"] for item in payload["files"]}
        base = payload["baseURL"]
        meta = download(base + "meta.txt", files["meta.txt"], cache).read_bytes()
        frame_names = sorted(
            (name for name in files if re.fullmatch(r"frame_\d+\.bm", name)),
            key=lambda name: int(re.search(r"frame_(\d+)\.bm$", name).group(1)),
        )
        frames = [download(base + name, files[name], cache).read_bytes() for name in frame_names]
        return meta, frames
    raise ValueError(f"Unsupported payload: {kind}")


def representative_frame(frames: list[Image.Image], width: int, height: int) -> Image.Image:
    candidates = []
    total = width * height
    for frame in frames:
        black = sum(1 for value in frame.getdata() if value == 0)
        if 0 < black < total:
            candidates.append((min(black, total - black), frame))
    if not candidates:
        raise ValueError("Animation has no informative preview frame")
    return max(candidates, key=lambda candidate: candidate[0])[1]


def ordered_frames(frames: list[Image.Image], order: list[int]) -> list[Image.Image]:
    ordered = [frames[index] for index in order if 0 <= index < len(frames)]
    return ordered or frames


def save_animation(frames: list[Image.Image], frame_rate: int, destination: Path) -> None:
    if not frames:
        raise ValueError("Animation has no frames")
    palette_frames = [
        frame.convert("L").convert("P", palette=Image.Palette.ADAPTIVE, colors=2)
        for frame in frames
    ]
    palette_frames[0].save(
        destination,
        format="GIF",
        save_all=True,
        append_images=palette_frames[1:],
        duration=max(20, round(1000 / frame_rate)),
        loop=0,
        optimize=True,
        disposal=2,
    )


def save_preview(image: Image.Image, destination: Path) -> None:
    if destination.is_file():
        with Image.open(destination) as existing:
            if existing.size == image.size and existing.convert("1").tobytes() == image.convert("1").tobytes():
                return
    image.save(destination, optimize=True)


def legacy_animation_ids(root: Path) -> list[str]:
    source = (root / "Sources/Features/DolphinGallery/DolphinProfile.swift").read_text(
        encoding="utf-8"
    )
    catalog = source.split("enum DolphinCatalog", 1)[1].split("struct DolphinCollection", 1)[0]
    return re.findall(r'"(L\d_[^"]+)"', catalog)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--cache", type=Path, default=Path("/tmp/tumocompanion-dolphin-cache"))
    parser.add_argument(
        "--legacy-root",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "unleashed-firmware/assets/dolphin",
    )
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()

    catalog_path = args.root / "Resources/DolphinPacks/catalog.json"
    packs = json.loads(catalog_path.read_text(encoding="utf-8"))["packs"]
    destination = args.root / "Resources/DolphinPreviews"
    animation_destination = args.root / "Resources/DolphinAnimations"
    destination.mkdir(parents=True, exist_ok=True)
    animation_destination.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)

    for momentum in (args.root / "Resources/DolphinPacks/Momentum").iterdir():
        if not momentum.is_dir():
            continue
        meta = (momentum / "meta.txt").read_bytes()
        raw_frames = [path.read_bytes() for path in sorted(momentum.glob("frame_*.bm"))]
        width, height, frame_rate, order = metadata(meta)
        frames = [decode_frame(frame, width, height) for frame in raw_frames]
        save_preview(
            representative_frame(frames, width, height),
            destination / f"{momentum.name}.png",
        )
        save_animation(
            ordered_frames(frames, order),
            frame_rate,
            animation_destination / f"{momentum.name}.gif",
        )

    def generate(pack: dict) -> tuple[str, str | None]:
        try:
            meta, frames = payload_preview(pack, args.cache)
            width, height, frame_rate, order = metadata(meta)
            decoded = [decode_frame(frame, width, height) for frame in frames]
            save_preview(
                representative_frame(decoded, width, height),
                destination / f'{pack["id"]}.png',
            )
            save_animation(
                ordered_frames(decoded, order),
                frame_rate,
                animation_destination / f'{pack["id"]}.gif',
            )
            return pack["id"], None
        except Exception as error:
            return pack["id"], str(error)

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
        results = list(executor.map(generate, packs))

    failures = [(pack_id, error) for pack_id, error in results if error is not None]
    if failures:
        for pack_id, error in failures:
            print(f"Unsupported {pack_id}: {error}")
        raise SystemExit(f"{len(failures)} catalog packs cannot be previewed or installed")

    expected = {pack_id for pack_id, _ in results} | {
        path.name
        for path in (args.root / "Resources/DolphinPacks/Momentum").iterdir()
        if path.is_dir()
    }
    if not args.legacy_root.is_dir():
        raise SystemExit(f"Legacy animation source is missing: {args.legacy_root}")
    legacy_directories = {
        path.parent.name: path.parent for path in args.legacy_root.rglob("meta.txt")
    }
    for animation_id in legacy_animation_ids(args.root):
        directory = legacy_directories.get(animation_id)
        if directory is None:
            raise SystemExit(f"Legacy animation source is missing: {animation_id}")
        meta = (directory / "meta.txt").read_bytes()
        width, height, frame_rate, order = metadata(meta)
        frame_paths = sorted(
            directory.glob("frame_*.png"),
            key=lambda path: int(re.search(r"frame_(\d+)\.png$", path.name).group(1)),
        )
        frames = [Image.open(path).convert("1") for path in frame_paths]
        if not frames:
            raise SystemExit(f"Legacy animation has no frames: {animation_id}")
        save_animation(
            ordered_frames(frames, order),
            frame_rate,
            animation_destination / f"{animation_id}.gif",
        )
        expected.add(animation_id)

    for stale in destination.glob("*.png"):
        if stale.stem not in expected:
            stale.unlink()
    for stale in animation_destination.glob("*.gif"):
        if stale.stem not in expected:
            stale.unlink()
    print(f"Generated {len(expected)} verified Dolphin previews and animations")


if __name__ == "__main__":
    main()
