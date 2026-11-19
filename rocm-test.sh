#!/bin/sh
# Resolve AMD OpenCL (ROCm) packages and Debian dependencies, and verify offline install and removal
# on a simulated worker. Usage (root, disposable Debian 13): sh rocm-test.sh VERSION OUT_DIR
# Outputs OUT_DIR/rocm-VERSION.packages.tsv and OUT_DIR/essaim-rocm-compat_1_all.deb
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
VER="$1"
OUT="$2"
mkdir -p "$OUT"
COMPAT="$OUT/essaim-rocm-compat_1_all.deb"

# rocm-opencl declares dependencies on libelf-dev and libtinfo-dev even though it only needs runtime libs;
# without this virtual package they would pull libc6-dev, which is tightly coupled to the worker's libc6.
ROOT=$(mktemp -d)
mkdir -p "$ROOT/DEBIAN"
cat > "$ROOT/DEBIAN/control" <<EOF
Package: essaim-rocm-compat
Version: 1
Architecture: all
Maintainer: Essaim OS <noreply@essaimos.com>
Section: libs
Priority: optional
Depends: libelf1t64, libtinfo6
Provides: libelf-dev, libtinfo-dev
Description: Runtime dependencies for AMD OpenCL without development headers
 rocm-opencl depends on libelf-dev and libtinfo-dev for shared libraries only.
 This package satisfies them without pulling the C toolchain onto workers.
EOF
dpkg-deb --root-owner-group --build "$ROOT" "$COMPAT" >/dev/null
rm -rf "$ROOT"

bootstrap
nvidia_sources
amd_sources "$VER"
$APT update >/dev/null
echo "== simulated worker"
rig_base

# Pass the compat package in the same apt resolution so its runtime deps (libelf1t64) are recorded.
cp "$COMPAT" /tmp/
# shellcheck disable=SC2086
print_uris "/tmp/$(basename "$COMPAT")" $ROCM_SET | grep -v "^file:" > /tmp/uris.tsv
COUNT=$(wc -l < /tmp/uris.tsv)
[ "$COUNT" -gt 3 ] || die "ROCm package list unexpectedly short ($COUNT)"
grep -q "/rocm/apt/$VER/" /tmp/uris.tsv || die "no AMD $VER package found in list"
grep -q "/rocm/apt/$VER/.*/rocminfo_" /tmp/uris.tsv || die "rocminfo did not come from AMD repo"
! grep -q -E "/(libc6-dev|libelf-dev|libtinfo-dev)_" /tmp/uris.tsv || die "development packages unexpectedly pulled"
echo "== $COUNT packages for ROCm $VER"

PACK=/tmp/pack
fetch_list /tmp/uris.tsv "$PACK" > "$OUT/rocm-$VER.packages.tsv"
cp "$COMPAT" "$PACK/"

# Worker image always carries the preinstalled NVIDIA stack (plus compiler cleanup): ensure it stays intact.
echo "== base image NVIDIA stack + compiler cleanup"
rig_nvidia "$(image_nvidia_version)"

echo "== offline install of ROCm $VER"
offline_install "$PACK" "$OUT/rocm-$VER.packages.tsv"
dpkg-query -W -f='${Status}' nvidia-kernel-open-dkms | grep -q 'ok installed' || die "base NVIDIA module was altered"

got=$(dpkg-query -W -f='${Version}' rocm-core)
case "$got" in "$VER".*) ;; *) die "rocm-core at $got instead of $VER" ;; esac
ICD=$(ls /etc/OpenCL/vendors/ | grep -i amd | head -1)
[ -n "$ICD" ] || die "AMD OpenCL ICD file missing"
LIB=$(cat "/etc/OpenCL/vendors/$ICD")
case "$LIB" in
    /*) [ -e "$LIB" ] || die "AMD OpenCL library missing: $LIB" ;;
    *) ldconfig -p | grep -q "$LIB" || [ -e "/opt/rocm/lib/$LIB" ] || die "AMD OpenCL library not found: $LIB" ;;
esac
[ -x /opt/rocm/bin/rocminfo ] || die "AMD rocminfo binary missing"
! dpkg-query -W -f='${Status}' libhsa-runtime64-1 2>/dev/null | grep -q 'ok installed' || die "Debian ROCm runtime mixed with AMD"
echo "== ROCm $VER: offline install succeeded ($ICD -> $LIB)"

# Removal test (matches hub cleanup): remove AMD vendor packages while keeping Debian shared deps.
# shellcheck disable=SC2046
offline_install /nonexistent /dev/null $(vendor_names "$OUT/rocm-$VER.packages.tsv" repo.radeon.com)
if dpkg-query -W -f='${Status}' rocm-core 2>/dev/null | grep -q 'ok installed'; then
    die "rocm-core still installed after removal"
fi
! ls /etc/OpenCL/vendors/ 2>/dev/null | grep -qi amd || die "AMD OpenCL ICD file remained after removal"
echo "== ROCm $VER: removal succeeded"
