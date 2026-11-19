#!/usr/bin/env python3
"""Generate a driver version JSON descriptor and publish it to a GitHub Release.

  python3 publish.py describe VENDOR VERSION DIR BASE_URL   writes DIR/VENDOR-VERSION.json
  python3 publish.py upload VENDOR VERSION DIR              publishes release VENDOR-VERSION (GitHub Actions, gh)

DIR holds package/module lists produced by the shell scripts (nvidia-V.packages.tsv, nvidia-V.modules.tsv
and module .deb files, or rocm-V.packages.tsv). Only kernel modules / compat packages are uploaded here;
upstream NVIDIA, AMD, and Debian packages remain hosted on official repositories.
"""
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def read_tsv(path):
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(line.split("\t"))
    return rows


def package_name(file):
    return file.split("_", 1)[0]


def package_version(packages, name):
    for p in packages:
        if p.get("package") == name:
            return p.get("version", "")
    return ""


COMPAT = "essaim-rocm-compat_1_all.deb"


def own_file(folder, file, base_url):
    """Locally built package uploaded to the release (NVIDIA modules or ROCm compat)."""
    path = Path(folder) / file
    return {"url": f"{base_url.rstrip('/')}/{file}", "file": file, "size": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "package": file.split("_", 1)[0], "version": file.split("_")[1] if file.count("_") >= 2 else ""}


def describe(vendor, version, folder, base_url):
    folder = Path(folder)
    packages = [{"url": u, "file": f, "size": int(s), "sha256": h, "package": p, "version": v}
                for u, f, s, h, p, v in read_tsv(folder / f"{vendor}-{version}.packages.tsv")]
    if not packages:
        raise SystemExit("empty package list")
    desc = {
        "vendor": vendor,
        "version": version,
        "branch": version.split(".")[0] if vendor == "nvidia" else ".".join(version.split(".")[:2]),
        "packages": packages,
        "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if vendor == "nvidia":
        desc["package_version"] = package_version(packages, "libcuda1")
        modules = {}
        for kernel, file, size, sha in read_tsv(folder / f"nvidia-{version}.modules.tsv"):
            modules[kernel] = {"url": f"{base_url.rstrip('/')}/{file}", "file": file, "size": int(size), "sha256": sha,
                               "package": "essaim-nvidia-modules", "version": desc.get("package_version", "")}
        if not modules:
            raise SystemExit("no compiled modules")
        desc["modules"] = modules
    else:
        desc["package_version"] = package_version(packages, "rocm-core")
        desc["extras"] = [own_file(folder, COMPAT, base_url)]
        # AMD packages to purge when reverting to 'no AMD OpenCL'; shared Debian deps stay installed.
        desc["remove"] = sorted({p["package"] for p in packages if "repo.radeon.com" in p["url"]})
    if not desc["package_version"]:
        raise SystemExit("main package version missing from list")
    out = folder / f"{vendor}-{version}.json"
    out.write_text(json.dumps(desc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    return out


def gh(*args, check=True):
    return subprocess.run(["gh", *args], check=check, capture_output=True, text=True)


def upload(vendor, version, folder):
    repo = os.environ["GITHUB_REPOSITORY"]
    tag = f"{vendor}-{version}"
    base = f"https://github.com/{repo}/releases/download/{tag}"
    desc = describe(vendor, version, folder, base)
    files = [str(desc)]
    if vendor == "nvidia":
        files += [str(Path(folder) / f) for _, f, _, _ in read_tsv(Path(folder) / f"nvidia-{version}.modules.tsv")]
        # Exact GPLv2 kernel module sources alongside binary .debs: matching nvidia-kernel-open-dkms package.
        source = (Path(folder) / f"nvidia-{version}.source").read_text(encoding="utf-8").strip()
        files.append(str(Path(folder) / source))
    else:
        files.append(str(Path(folder) / COMPAT))
    if gh("release", "view", tag, check=False).returncode != 0:
        title = f"NVIDIA {version}" if vendor == "nvidia" else f"ROCm {version}"
        notes = "Built by GitHub Actions. Read by Essaim Hubs via manifest.json."
        if vendor == "nvidia":
            notes += ("\n\nNVIDIA 'open' kernel modules (dual MIT/GPL), compiled against Linux kernel headers (GPLv2). "
                      "Corresponding source code: nvidia-kernel-open-dkms package attached to this release, "
                      "together with the build scripts in this repository.")
        gh("release", "create", tag, "--title", title, "--latest=false", "--notes", notes)
    gh("release", "upload", tag, "--clobber", *files)
    print(f"{tag}: {len(files)} file(s) published")


def main():
    if len(sys.argv) >= 6 and sys.argv[1] == "describe":
        print(describe(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]))
    elif len(sys.argv) >= 5 and sys.argv[1] == "upload":
        upload(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
