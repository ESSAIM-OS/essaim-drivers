#!/usr/bin/env python3
"""Assemble manifest.json, the single index file read by Essaim Hubs.

  python3 manifest.py --drivers DIR --out manifest.json DESC.json...   from local descriptors
  python3 manifest.py --github                                         fetch release descriptors and
                                                                       publish to the 'manifest' release

Keeps only versions still listed in nvidia.txt and rocm.txt: removing a line hides that version.
"""
import argparse
import datetime
import json
import os
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def listed(drivers, name):
    path = Path(drivers) / name
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")]


def version_key(v):
    return tuple(int(x) for x in v.split(".") if x.isdigit())


def build(drivers, descs):
    wanted = {"nvidia": set(listed(drivers, "nvidia.txt")), "rocm": set(listed(drivers, "rocm.txt"))}
    out = {"schema": 1, "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "kernels": listed(drivers, "kernels.txt"), "nvidia": [], "rocm": []}
    for d in descs:
        vendor, version = d.get("vendor"), d.get("version")
        if vendor in wanted and version in wanted[vendor]:
            out[vendor].append(d)
    for vendor in ("nvidia", "rocm"):
        out[vendor].sort(key=lambda d: version_key(d["version"]))
    return out


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def from_github(drivers):
    tags = json.loads(gh("release", "list", "--limit", "500", "--json", "tagName"))
    descs = []
    with tempfile.TemporaryDirectory() as tmp:
        for t in tags:
            tag = t["tagName"]
            if not (tag.startswith("nvidia-") or tag.startswith("rocm-")):
                continue
            gh("release", "download", tag, "--pattern", f"{tag}.json", "--dir", tmp, "--clobber")
            path = Path(tmp) / f"{tag}.json"
            if path.exists():
                descs.append(json.loads(path.read_text(encoding="utf-8")))
        manifest = build(drivers, descs)
        target = Path(tmp) / "manifest.json"
        target.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        if subprocess.run(["gh", "release", "view", "manifest"], capture_output=True).returncode != 0:
            gh("release", "create", "manifest", "--title", "Driver Manifest", "--latest=false",
               "--notes", "manifest.json: available driver versions read by Essaim Hubs.")
        gh("release", "upload", "manifest", "--clobber", str(target))
    print(f"manifest: {len(manifest['nvidia'])} NVIDIA, {len(manifest['rocm'])} ROCm, "
          f"{len(manifest['kernels'])} kernels ({os.environ.get('GITHUB_REPOSITORY', '')})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--drivers", default=str(HERE))
    ap.add_argument("--out")
    ap.add_argument("--github", action="store_true")
    ap.add_argument("descs", nargs="*")
    args = ap.parse_args()
    if args.github:
        from_github(args.drivers)
        return
    descs = [json.loads(Path(p).read_text(encoding="utf-8")) for p in args.descs]
    manifest = build(args.drivers, descs)
    Path(args.out).write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
