#!/bin/sh
# Compile open-source NVIDIA kernel modules for each kernel in kernels.txt into one .deb per kernel
# so workers can switch driver versions offline without headers or a compiler.
# Usage (root, disposable Debian 13): sh nvidia-modules.sh VERSION OUT_DIR
# Outputs: OUT_DIR/nvidia-modules-VERSION-KERNEL.deb ('+' replaced by '_') and OUT_DIR/nvidia-VERSION.modules.tsv
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
VER="$1"
OUT="$2"
mkdir -p "$OUT"
KERNELS=$(grep -v -E '^(#|$)' "$HERE/kernels.txt")

bootstrap
nvidia_sources
$APT update >/dev/null

# Fetch kernel headers from snapshot.debian.org when an older kernel is no longer on main mirrors.
snapshot_headers() {
    pkg="linux-headers-$1"
    info=$(curl -fsS "https://snapshot.debian.org/mr/binary/$pkg/") || die "$pkg unknown on snapshot.debian.org"
    bver=$(echo "$info" | grep -o '"binary_version": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    files=$(curl -fsS "https://snapshot.debian.org/mr/binary/$pkg/$bver/binfiles?fileinfo=1")
    archive=$(echo "$files" | grep -o '"archive_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    seen=$(echo "$files" | grep -o '"first_seen": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    [ -n "$archive" ] && [ -n "$seen" ] || die "$pkg: snapshot archive timestamp not found"
    case "$archive" in
        debian-security) suites="trixie-security" ;;
        *) suites="trixie trixie-updates trixie-proposed-updates" ;;
    esac
    cat > /etc/apt/sources.list.d/snapshot.sources <<EOF
Types: deb
URIs: https://snapshot.debian.org/archive/$archive/$seen/
Suites: $suites
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no
EOF
    $APT update >/dev/null
    $APT install "$pkg" >/dev/null
}

for k in $KERNELS; do
    echo "== headers $k"
    $APT install "linux-headers-$k" >/dev/null 2>&1 || snapshot_headers "$k"
done

PV=$(deb_version nvidia-kernel-open-dkms "$VER")
echo "== nvidia-kernel-open-dkms $PV"
pin_version "$PV"
$APT install "nvidia-kernel-open-dkms=$PV" >/dev/null
unpin
# Exact GPLv2 kernel module sources published alongside the binary .deb modules.
(cd "$OUT" && apt-get download -q "nvidia-kernel-open-dkms=$PV" >/dev/null) || die "sources for $PV not found"
SRC=$(cd "$OUT" && ls nvidia-kernel-open-dkms_*.deb | head -1)
[ -n "$SRC" ] || die "source package missing"
echo "$SRC" > "$OUT/nvidia-$VER.source"
CONF=$(ls /usr/src/*"-$VER"/dkms.conf 2>/dev/null | head -1)
[ -n "$CONF" ] || die "dkms.conf for $VER not found"
NAME=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONF" | head -1)
[ -n "$NAME" ] || die "dkms module name missing in $CONF"

: > "$OUT/nvidia-$VER.modules.tsv"
for k in $KERNELS; do
    echo "== modules $VER for $k"
    dkms build -m "$NAME" -v "$VER" -k "$k" --force >/dev/null || die "dkms build failed for $k"
    BUILT="/var/lib/dkms/$NAME/$VER/$k/x86_64/module"
    [ -e "$BUILT/nvidia.ko" ] || [ -e "$BUILT/nvidia.ko.xz" ] || die "nvidia.ko missing after build ($k)"

    ROOT=$(mktemp -d)
    DEST="$ROOT/lib/modules/$k/updates/essaim"
    mkdir -p "$DEST" "$ROOT/DEBIAN"
    for f in "$BUILT"/*.ko "$BUILT"/*.ko.xz "$BUILT"/*.ko.zst; do
        [ -e "$f" ] || continue
        case "$f" in
            *.ko) xz -C crc32 -T1 -c "$f" > "$DEST/$(basename "$f").xz" ;;
            *) cp "$f" "$DEST/" ;;
        esac
    done
    for f in "$DEST"/*; do
        magic=$(modinfo -F vermagic "$f" | awk '{print $1}')
        [ "$magic" = "$k" ] || die "$(basename "$f"): vermagic $magic instead of $k"
    done

    cat > "$ROOT/DEBIAN/control" <<EOF
Package: essaim-nvidia-modules
Version: $PV
Architecture: amd64
Maintainer: Essaim OS <noreply@essaimos.com>
Section: kernel
Priority: optional
Depends: firmware-nvidia-gsp (= $PV), nvidia-kernel-support (= $PV)
Provides: nvidia-kernel-$VER
Conflicts: nvidia-kernel-open-dkms, nvidia-kernel-dkms
Replaces: nvidia-kernel-open-dkms, nvidia-kernel-dkms
Description: Precompiled NVIDIA open modules $VER for kernel $k
 Built by Essaim OS from nvidia-kernel-open-dkms $PV for compiler-free driver switches.
EOF
    cat > "$ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ] && [ -e /lib/modules/$k/modules.builtin ]; then depmod -a $k; fi
EOF
    cat > "$ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if [ -e /lib/modules/$k/modules.builtin ]; then depmod -a $k || true; fi
EOF
    chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"
    FILE="nvidia-modules-$VER-$(echo "$k" | tr '+' '_').deb"
    dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$OUT/$FILE" >/dev/null
    rm -rf "$ROOT"
    SIZE=$(stat -c %s "$OUT/$FILE")
    SHA=$(sha256sum "$OUT/$FILE" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\n' "$k" "$FILE" "$SIZE" "$SHA" >> "$OUT/nvidia-$VER.modules.tsv"
    echo "   $FILE ($((SIZE / 1024 / 1024)) MB)"
done
echo "== modules ready: $OUT"
