#!/bin/sh
# Resolve NVIDIA packages for a driver version (upstream URLs, sizes, SHA-256) and verify that a
# simulated worker upgrades/switches to it offline with the modules built by nvidia-modules.sh.
# Usage (root, disposable Debian 13): sh nvidia-test.sh VERSION OUT_DIR    (NV_FROM: starting version)
# Reads OUT_DIR/nvidia-VERSION.modules.tsv, writes OUT_DIR/nvidia-VERSION.packages.tsv
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
VER="$1"
OUT="$2"
MODS="$OUT/nvidia-$VER.modules.tsv"
[ -s "$MODS" ] || die "$MODS missing: run nvidia-modules.sh first"
FROM="${NV_FROM:-$(image_nvidia_version)}"
if [ "$FROM" = "$VER" ]; then
    FROM=$(grep -v -E '^(#|$)' "$HERE/nvidia.txt" | grep -v -x "$VER" | tail -1)
fi

bootstrap
nvidia_sources
$APT update >/dev/null
echo "== simulated worker"
rig_base

PV=$(deb_version nvidia-driver-cuda "$VER")
args=""
for p in $NV_SET; do args="$args $p=$PV"; done
pin_version "$PV"
# shellcheck disable=SC2086
print_uris $args > /tmp/uris.tsv
unpin
COUNT=$(wc -l < /tmp/uris.tsv)
[ "$COUNT" -gt 5 ] || die "NVIDIA package list unexpectedly short ($COUNT)"
echo "== $COUNT packages for NVIDIA $PV"

PACK=/tmp/pack
fetch_list /tmp/uris.tsv "$PACK" > "$OUT/nvidia-$VER.packages.tsv"
KFIRST=$(head -1 "$MODS" | cut -f1)
cp "$OUT/$(head -1 "$MODS" | cut -f2)" "$PACK/"

if [ -n "$FROM" ]; then
    echo "== image base driver: NVIDIA $FROM (with dkms), then image-style cleanup"
    rig_nvidia "$FROM"
fi

echo "== offline switch to $PV"
# Match hub cleanup: purge NVIDIA packages from the previous version omitted in the new one.
OBSOLETE=""
if [ -n "$FROM" ]; then
    FROMPV=$(dpkg-query -W -f='${Version}' libcuda1)
    vendor_names "$OUT/nvidia-$VER.packages.tsv" developer.download.nvidia.com > /tmp/new-names
    OBSOLETE=$(dpkg-query -W -f='${Package} ${Version}\n' | awk -v v="$FROMPV" '$2 == v { print $1 }' \
        | grep -v -x -F -f /tmp/new-names | grep -v -x nvidia-kernel-open-dkms || true)
fi
if dpkg-query -W -f='${Status}' nvidia-kernel-open-dkms 2>/dev/null | grep -q 'ok installed'; then
    retire_dkms
fi
# shellcheck disable=SC2086
offline_install "$PACK" "$OUT/nvidia-$VER.packages.tsv" $OBSOLETE

got=$(dpkg-query -W -f='${Version}' libcuda1)
[ "$got" = "$PV" ] || die "libcuda1 at $got instead of $PV"
got=$(dpkg-query -W -f='${Version}' essaim-nvidia-modules)
[ "$got" = "$PV" ] || die "essaim-nvidia-modules at $got instead of $PV"
if dpkg-query -W -f='${Status}' nvidia-kernel-open-dkms 2>/dev/null | grep -q 'ok installed'; then
    die "nvidia-kernel-open-dkms still installed"
fi
LEFT=$(dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' | awk -v v="${FROMPV:-none}" '$2 == v && $3 ~ /^ii/')
[ -z "$LEFT" ] || die "leftover packages from previous version: $LEFT"
ls "/lib/modules/$KFIRST/updates/essaim/nvidia.ko.xz" >/dev/null || die "module missing for $KFIRST"
echo "== NVIDIA $PV: offline install succeeded from ${FROM:-clean} (purged: ${OBSOLETE:-none})"
