#!/bin/bash
# Build a TOC0-signed U-Boot for the Jide Remix Mini (RM1G, Allwinner H64/A64)
# that boots from the internal eMMC.
#
# Tested on Ubuntu 24.04 x86_64 (cross-compiling). Output:
#   out/u-boot-sunxi-with-spl.bin
set -euo pipefail

UBOOT_REPO=https://github.com/u-boot/u-boot.git
UBOOT_REF=10adf52ed29d31c72fa06c1d9ee311d47c537215   # 2026-10-07 (v2026.10 cycle)
TFA_REPO=https://github.com/ARM-software/arm-trusted-firmware.git
TFA_REF=510355478850fb9bb4b064554d3dc2416b8b4b96     # 2026-10-05

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="$HERE/out"
export CROSS_COMPILE=aarch64-linux-gnu-

if command -v apt-get >/dev/null && [ "${SKIP_DEPS:-0}" != 1 ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq git make gcc gcc-aarch64-linux-gnu bison flex bc \
    libssl-dev libgnutls28-dev device-tree-compiler python3-dev python3-setuptools \
    python3-pyelftools swig openssl
fi

mkdir -p "$WORK" "$OUT"

fetch() {  # fetch <repo> <ref> <dir>
  if [ ! -d "$3/.git" ]; then
    git init -q "$3"
    git -C "$3" remote add origin "$1"
  fi
  git -C "$3" fetch -q --depth=1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

echo ">> Trusted Firmware-A (BL31)"
fetch "$TFA_REPO" "$TFA_REF" "$WORK/tfa"
make -C "$WORK/tfa" -s -j"$(nproc)" PLAT=sun50i_a64 bl31
BL31="$WORK/tfa/build/sun50i_a64/release/bl31.bin"

echo ">> U-Boot"
fetch "$UBOOT_REPO" "$UBOOT_REF" "$WORK/u-boot"
cp "$HERE/configs/remix-mini-pc_defconfig" "$WORK/u-boot/configs/"
cd "$WORK/u-boot"
# The BROM only checks that the SPL is TOC0-wrapped and signed; no key hash is
# burned in the fuses, so any RSA key works. A fresh one is made per build.
[ -f root_key.pem ] || openssl genrsa -out root_key.pem 2048 2>/dev/null
make -s remix-mini-pc_defconfig
make -s -j"$(nproc)" BL31="$BL31"

head -c 4 u-boot-sunxi-with-spl.bin | grep -q TOC0 || { echo "No TOC0 header!"; exit 1; }
cp u-boot-sunxi-with-spl.bin "$OUT/"
(cd "$OUT" && sha256sum u-boot-sunxi-with-spl.bin)
echo ">> Done: $OUT/u-boot-sunxi-with-spl.bin"
