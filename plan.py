#!/usr/bin/env python3
"""Determine driver versions to (re)build for GitHub Actions matrix: prints 'nvidia=[...]' and 'rocm=[...]'.

An NVIDIA version is rebuilt if its release is missing or lacks modules for any kernel in kernels.txt;
a ROCm version is rebuilt if its release is missing. REBUILD=true rebuilds all listed versions.
"""
import json
import os
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent


def listed(name):
    return [line.strip() for line in (HERE / name).read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")]


def release_assets(tag):
    res = subprocess.run(["gh", "release", "view", tag, "--json", "assets"], capture_output=True, text=True)
    if res.returncode != 0:
        return None
    return {a["name"] for a in json.loads(res.stdout).get("assets", [])}


def module_file(version, kernel):
    return f"nvidia-modules-{version}-{kernel.replace('+', '_')}.deb"


def main():
    rebuild = os.environ.get("REBUILD", "false").lower() == "true"
    kernels = listed("kernels.txt")
    nvidia, rocm = [], []
    for v in listed("nvidia.txt"):
        assets = None if rebuild else release_assets(f"nvidia-{v}")
        has_source = assets is not None and any(a.startswith("nvidia-kernel-open-dkms_") for a in assets)
        if assets is None or f"nvidia-{v}.json" not in assets or not has_source \
                or any(module_file(v, k) not in assets for k in kernels):
            nvidia.append(v)
    for v in listed("rocm.txt"):
        assets = None if rebuild else release_assets(f"rocm-{v}")
        if assets is None or f"rocm-{v}.json" not in assets:
            rocm.append(v)
    print(f"nvidia={json.dumps(nvidia)}")
    print(f"rocm={json.dumps(rocm)}")


if __name__ == "__main__":
    main()
