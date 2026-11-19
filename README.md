# Essaim OS Drivers

This repository builds the GPU drivers that Essaim Hubs offer to Linux workers:

- **NVIDIA**: open-source kernel modules (`open`) are precompiled here once per driver version and per Essaim image kernel. A worker can switch driver versions in about a minute without a compiler, kernel headers, or internet access.
- **AMD**: ROCm OpenCL runtime. The `amdgpu` kernel driver stays the one built into the image kernel; only the user-space OpenCL layer used by miners switches versions.

Only the open-source NVIDIA kernel modules (MIT/GPL dual-licensed) are published here. NVIDIA, ROCm, and Debian libraries remain hosted on their official upstream repositories. `manifest.json` lists their download URLs and SHA-256 checksums, and each Hub downloads them directly.

## How It Works

```
GitHub Actions ──▶ releases nvidia-VERSION (.deb kernel modules + JSON descriptor)
               ──▶ release manifest (manifest.json, read by Essaim Hubs)
Essaim Hub ──▶ manifest.json, then NVIDIA / AMD / Debian packages & modules ──▶ Hub cache ──▶ workers
```

Every driver version is tested prior to publication inside a clean Debian 13 container simulating a worker image:
- base image packages (`rig-packages.txt`);
- NVIDIA stack installed via DKMS;
- compiler and headers purged, matching the production worker image;
- offline installation using the exact same method as `essaim-agent`;
- for ROCm, clean uninstall verification afterwards.

Any version whose verification test fails is not published.

**Installation method (agent and tests)**
- **`dpkg` directly.** The worker image strips compiler packages without keeping DKMS dependencies intact, so `apt` would refuse any installation, whereas `dpkg` only validates the explicitly supplied packages.
- **Vendor driver packages** (NVIDIA, AMD, precompiled modules, and Essaim compat package): always installed.
- **Debian dependencies**: installed only when missing or older on the rig, never downgraded.
- **First NVIDIA driver switch**: the image's preinstalled DKMS module is purged after neutralizing its removal script (which would fail without `/usr/src`).
- **Post-install cleanup**: packages from the previous driver version no longer used by the new version are purged.

**`essaim-rocm-compat`**: `rocm-opencl` unnecessarily depends on `libelf-dev` and `libtinfo-dev`, which would pull `libc6-dev` (pinned to each worker's exact `libc6` version). This tiny virtual compatibility package satisfies those dependencies cleanly.

## Adding a Driver Version or Kernel

- **NVIDIA version**: add a line to `nvidia.txt`. Available versions come from the [NVIDIA CUDA Debian 13 repository](https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/).
- **ROCm version**: add a line to `rocm.txt`. Available versions come from the [AMD ROCm APT repository](https://repo.radeon.com/rocm/apt/).
- **New Essaim worker image**: add its kernel string to `kernels.txt`. All listed NVIDIA versions are then compiled for that kernel.
- **Retiring a version**: remove its line from `nvidia.txt` or `rocm.txt`. It drops out of `manifest.json`, while the old release stays intact.

Pushing to `main` builds any missing releases automatically. Triggering the workflow manually (`Run workflow`) can rebuild everything (`rebuild=true`).

These files mirror the `drivers/` folder of the Essaim OS repository via `python deploy/nx_drivers.py push`.

## Licenses

- **Build scripts, workflow, and documentation in this repository**: MIT License (`LICENSE`).
- **Published NVIDIA kernel modules**: NVIDIA `open` kernel module source under MIT/GPL dual license, compiled against Linux kernel headers (GPLv2). Each release includes its exact corresponding source package (`nvidia-kernel-open-dkms`), complemented by the build scripts in this repository.
- **`essaim-rocm-compat`**: empty virtual package built here under the MIT License.
- **NVIDIA, ROCm, and Debian libraries**: never redistributed here; each Hub fetches them directly from upstream repositories under their respective licenses.

## Scripts

| Script | Purpose |
|---|---|
| `nvidia-modules.sh VERSION OUT_DIR` | compiles kernel modules for each listed kernel, producing one `.deb` per kernel |
| `nvidia-test.sh VERSION OUT_DIR` | resolves NVIDIA package list and tests offline installation |
| `rocm-test.sh VERSION OUT_DIR` | resolves ROCm package list (including Debian dependencies) and tests offline install/removal |
| `publish.py` | generates version JSON descriptor and uploads GitHub Release assets |
| `manifest.py` | builds and publishes `manifest.json` |
| `plan.py` | computes pending matrix versions to build |

Shell scripts run as root inside disposable Debian 13 containers (`debian:trixie`), never on a host workstation.
