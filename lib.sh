# Shared helpers for driver build scripts. Executed as root inside a disposable Debian 13 environment
# (debian:trixie container on GitHub, fresh chroot locally): nothing here should run on a real host.
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
APT="apt-get -y -q -o Dpkg::Use-Pty=0 --no-install-recommends"

# NVIDIA packages installed on a worker besides the kernel module (matches rig/image/customize.sh).
NV_SET="nvidia-kernel-support firmware-nvidia-gsp nvidia-driver-cuda nvidia-opencl-icd nvidia-persistenced"
# AMD OpenCL: minimal runtime for miners, plus rocminfo for post-install verification.
ROCM_SET="rocm-opencl rocminfo"
# Compiler/header packages purged after module build (matches rig/image/customize.sh).
PURGE_RE='^(gcc|gcc-14.*|g\+\+.*|cpp|cpp-14.*|libstdc\+\+-14-dev|libgcc-14-dev|linux-headers-.*|linux-kbuild-.*|make|binutils.*|libc6-dev|linux-libc-dev|libc-dev-bin|rpcsvc-proto|libcrypt-dev|libasan8|liblsan0|libubsan1|libtsan2|libhwasan0)$'

die() { echo "ERROR: $*" >&2; exit 1; }

# Bare container: install CA certificates over HTTP first, then enable full HTTPS Debian repos.
# security carries recent kernel headers; non-free provides NVIDIA GSP firmware.
bootstrap() {
    $APT update >/dev/null
    $APT install ca-certificates curl xz-utils kmod >/dev/null
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
    # Keep uncompressed package indexes so pin_version can read them; remove Docker's gzip override.
    rm -f /etc/apt/apt.conf.d/docker-gzip-indexes
    echo 'Acquire::GzipIndexes "false";' > /etc/apt/apt.conf.d/zz-essaim-indexes
    rm -rf /var/lib/apt/lists/*
    cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

nvidia_sources() {
    mkdir -p /etc/apt/keyrings
    cp "$HERE/nvidia-cuda.asc" /etc/apt/keyrings/nvidia-cuda.asc
    cat > /etc/apt/sources.list.d/nvidia-cuda.sources <<EOF
Types: deb
URIs: https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/
Suites: /
Architectures: amd64
Signed-By: /etc/apt/keyrings/nvidia-cuda.asc
EOF
}

# ROCm is only published for Ubuntu: use AMD's Ubuntu 24.04 (noble) packages tested here on Debian 13.
amd_sources() {
    mkdir -p /etc/apt/keyrings
    cp "$HERE/rocm.asc" /etc/apt/keyrings/rocm.asc
    cat > /etc/apt/sources.list.d/rocm.sources <<EOF
Types: deb
URIs: https://repo.radeon.com/rocm/apt/$1
Suites: noble
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.asc
EOF
    # Debian also ships older ROCm packages (6.1) with higher epoch/versions; pin AMD's repo higher.
    mkdir -p /etc/apt/preferences.d
    printf 'Package: *\nPin: origin repo.radeon.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/essaim-rocm
}

# Pin an exact Debian package version across all matching NVIDIA packages in the index so apt 3
# allows installing versions older than the latest repository release.
pin_version() {
    names=$(cat /var/lib/apt/lists/*nvidia*_Packages \
        | awk -v v="$1" '/^Package: / { p = $2 } /^Version: / { if ($2 == v) print p }' | sort -u | tr '\n' ' ')
    [ -n "$names" ] || die "no NVIDIA package found at version $1 in index"
    mkdir -p /etc/apt/preferences.d
    printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n' "$names" "$1" > /etc/apt/preferences.d/essaim-pin
}

unpin() {
    rm -f /etc/apt/preferences.d/essaim-pin
}

# Resolve exact Debian package version for an upstream version (620.70.06 -> 620.70.06-1).
deb_version() {
    v=$(apt-cache madison "$1" | awk -v want="$2" '{ if (index($3, want "-") == 1) print $3 }' | sort -V | tail -1)
    [ -n "$v" ] || die "$1 $2 missing from repositories"
    echo "$v"
}

# Simulated worker environment: base packages from rig-packages.txt without kernel, bootloader, or compiler.
rig_base() {
    pk=$(grep -v -E '^(#|$|linux-image-|linux-headers-|grub-|efibootmgr$|dkms$|gcc$|make$|initramfs-tools$)' "$HERE/rig-packages.txt")
    # shellcheck disable=SC2086
    $APT install $pk >/dev/null
}

# Install the NVIDIA stack as the image does (including dkms), then purge compiler/headers like the image.
rig_nvidia() {
    pv=$(deb_version nvidia-driver-cuda "$1")
    args="nvidia-kernel-open-dkms=$pv"
    for p in $NV_SET; do args="$args $p=$pv"; done
    pin_version "$pv"
    # shellcheck disable=SC2086
    $APT install $args >/dev/null
    unpin
    dpkg-query -W -f='${Package}\n' | grep -E "$PURGE_RE" | xargs dpkg --purge --force-depends >/dev/null 2>&1
    rm -rf /usr/src/*
}

# Resolve packages apt would install: "url<TAB>apt_name<TAB>size<TAB>ALGO:checksum".
print_uris() {
    # shellcheck disable=SC2086
    $APT install --print-uris -qq "$@" \
        | sed -n "s/^'\([^']*\)' \([^ ]*\) \([0-9]*\) \([A-Za-z0-9]*:[0-9a-f]*\)\$/\1	\2	\3	\4/p"
}

# Download print_uris entries into $2, verify SHA-256 against the signed APT index, and emit:
# "url<TAB>file<TAB>size<TAB>sha256<TAB>package<TAB>version".
fetch_list() {
    mkdir -p "$2"
    # shellcheck disable=SC2034
    while IFS="	" read -r url apt_name size hash; do
        # apt percent-encodes '+', '~', and ':' in URLs; decode them for local filenames.
        name=$(printf '%s' "${url##*/}" | sed 's/%2[bB]/+/g; s/%7[eE]/~/g; s/%3[aA]/:/g')
        pkg=${apt_name%%_*}
        rest=${apt_name#*_}
        ver=$(echo "${rest%_*}" | sed 's/%3a/:/g')
        want=$(apt-cache show "$pkg=$ver" 2>/dev/null | awk '/^SHA256:/ { print $2; exit }')
        [ -n "$want" ] || die "SHA-256 for $pkg $ver missing from index"
        curl -fsSL --retry 3 -o "$2/$name" "$url" || die "download failed: $url"
        got=$(sha256sum "$2/$name" | cut -d' ' -f1)
        [ "$got" = "$want" ] || die "checksum mismatch: $name"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$name" "$size" "$got" "$pkg" "$ver"
    done < "$1"
}

# Vendor packages are always installed; Debian dependencies are only installed if missing or older.
VENDOR_HOSTS="developer.download.nvidia.com repo.radeon.com"

is_vendor_url() {
    for h in $VENDOR_HOSTS; do
        case "$1" in *"://$h/"*) return 0 ;; esac
    done
    return 1
}

# Filter .deb paths to install from fetch_list ($1) + our own built packages in $2.
select_debs() {
    while IFS="	" read -r url name size sha pkg ver; do
        if is_vendor_url "$url"; then
            echo "$2/$name"
            continue
        fi
        have=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$pkg" 2>/dev/null | awk '$1 ~ /^ii/ { print $2 }')
        if [ -z "$have" ] || dpkg --compare-versions "$have" lt "$ver"; then
            echo "$2/$name"
        fi
    done < "$1"
    for f in "$2"/*.deb; do
        [ -e "$f" ] || continue
        cut -f2 "$1" | grep -q -x -F "$(basename "$f")" || echo "$f"
    done
}

# Mirror agent behavior on a worker: dpkg only, without apt sources.
# Usage: offline_install DIR LIST [packages_to_purge...]
offline_install() {
    dir="$1"
    list="$2"
    shift 2
    rm -rf /var/lib/apt/lists/*
    debs=$(select_debs "$list" "$dir")
    echo "   $(echo "$debs" | grep -c .) package(s) to install out of $(ls "$dir"/*.deb 2>/dev/null | wc -l)"
    if [ -n "$debs" ]; then
        # shellcheck disable=SC2086
        dpkg --force-confdef --force-confold -i $debs || die "dpkg -i failed"
    fi
    if [ $# -gt 0 ]; then
        dpkg --purge "$@" || die "dpkg --purge failed"
    fi
    audit=$(dpkg --audit)
    [ -z "$audit" ] || die "incomplete installation: $audit"
}

# First NVIDIA switch on a worker (matches RETIRE_DKMS in crates/essaim-agent/src/drivers.rs):
# neutralize dkms prerm/postrm scripts that fail when /usr/src is absent before purging.
retire_dkms() {
    for s in prerm postrm; do
        f=/var/lib/dpkg/info/nvidia-kernel-open-dkms.$s
        if [ -e "$f" ]; then printf '#!/bin/sh\nexit 0\n' > "$f"; fi
    done
    dpkg --purge nvidia-kernel-open-dkms || die "unable to purge dkms module"
    rm -f /lib/modules/*/updates/dkms/nvidia*.ko*
    rm -rf /var/lib/dkms/nvidia
}

# Extract unique package names from a fetch_list belonging to a specific upstream host.
vendor_names() {
    grep "://$2/" "$1" | cut -f2 | sed 's/_.*//' | sort -u
}

image_nvidia_version() {   # Preinstalled NVIDIA version in the base worker image (last line of nvidia.txt)
    grep -v -E '^(#|$)' "$HERE/nvidia.txt" | tail -1
}
