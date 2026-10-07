#!/bin/bash
# Run ON the Remix Mini while it is booted from microSD (Armbian).
# Copies the running system to the internal eMMC and writes a TOC0 U-Boot to
# the eMMC, so the device boots without a microSD card.
#
#   sudo bash install-emmc.sh [u-boot.bin]             -> diagnostics only, writes nothing
#   sudo bash install-emmc.sh [u-boot.bin] --install   -> backup + copy + bootloader
#
# Default u-boot.bin: ../prebuilt/remixmini-uboot-emmc-toc0.bin next to this script.
# Safety net: the BROM always tries the microSD first, so if the eMMC does not
# boot, put the card back in and the device boots as before.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../prebuilt/remixmini-uboot-emmc-toc0.bin"
MODE=check
for a in "$@"; do
  case "$a" in
    --install) MODE=install ;;
    *) BIN="$a" ;;
  esac
done
BACKUP_DIR=/root/emmc-original

[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }

# --- 1. Find disks -----------------------------------------------------------
ROOTPART=$(findmnt -no SOURCE /)
ROOTDISK=/dev/$(lsblk -no PKNAME "$ROOTPART")
EMMC=""
for d in /dev/mmcblk[0-9]; do [ -e "${d}boot0" ] && EMMC=$d; done
echo "Running system: $ROOTPART (disk $ROOTDISK)"
echo "eMMC:           ${EMMC:-NOT FOUND}"
[ -n "$EMMC" ] || { echo "Linux does not see the eMMC. Is the remix-mini-pc DTB active?"; exit 1; }
[ "$EMMC" != "$ROOTDISK" ] || { echo "Already running from the eMMC."; exit 1; }
lsblk -o NAME,SIZE,FSTYPE,LABEL "$EMMC"

# --- 2. Diagnostics -----------------------------------------------------------
echo; echo "Read test (first 64 MB)..."
dd if="$EMMC" of=/dev/null bs=1M count=64 status=none && echo "  read OK"
for p in boot0 boot1; do
  if head -c 64 "${EMMC}$p" | grep -aq TOC0; then f="has TOC0"; else f="no TOC0"; fi
  echo "  ${EMMC}$p: $f"
done
if head -c 8256 "$EMMC" | tail -c 64 | grep -aq TOC0; then
  echo "  user area @8K: has TOC0 (stock Remix OS bootloader)"
fi
if command -v mmc >/dev/null; then
  mmc extcsd read "$EMMC" | grep -i -A2 "PARTITION_CONFIG" || true
else
  echo "  (install mmc-utils to see PARTITION_CONFIG)"
fi
USED_KB=$(df --output=used -k / | tail -1)
EMMC_KB=$(( $(blockdev --getsize64 "$EMMC") / 1024 ))
echo "  rootfs used: $((USED_KB/1024)) MB, eMMC: $((EMMC_KB/1024)) MB"

[ "$MODE" = install ] || { echo; echo "Diagnostics done. Nothing was written."; exit 0; }

# --- 3. Pre-flight -----------------------------------------------------------
[ -f "$BIN" ] || { echo "Missing bootloader: $BIN"; exit 1; }
head -c 4 "$BIN" | grep -q TOC0 || { echo "$BIN has no TOC0 header."; exit 1; }
[ -f "$HERE/../prebuilt/SHA256SUMS" ] && [ "$BIN" -ef "$HERE/../prebuilt/remixmini-uboot-emmc-toc0.bin" ] && \
  (cd "$HERE/../prebuilt" && sha256sum -c --quiet SHA256SUMS)
[ "$USED_KB" -lt $((EMMC_KB * 85 / 100)) ] || { echo "Root filesystem does not fit in the eMMC."; exit 1; }
for c in rsync sfdisk mkfs.ext4 blkid wipefs; do
  command -v $c >/dev/null || apt-get install -y rsync fdisk e2fsprogs util-linux
done

echo; echo "This ERASES the eMMC ($EMMC, stock Remix OS) after backing it up to $BACKUP_DIR (on the SD)."
read -rp "Type ERASE to continue: " ok
[ "$ok" = "ERASE" ] || { echo "Cancelled."; exit 1; }

# --- 4. Hold Armbian's u-boot package ----------------------------------------
# An update of linux-u-boot-* would rewrite a non-TOC0 Pine64 bootloader to the
# boot disk, and the Remix Mini would no longer boot.
for p in $(dpkg-query -W -f='${Package}\n' 'linux-u-boot-*' 2>/dev/null); do apt-mark hold "$p"; done

# --- 5. Full eMMC backup -----------------------------------------------------
mkdir -p "$BACKUP_DIR"
if [ ! -f "$BACKUP_DIR/emmc.img" ]; then
  echo "Backing up the eMMC (about 10-12 minutes)..."
  dd if="$EMMC" of="$BACKUP_DIR/emmc.img" bs=4M status=progress conv=fsync
fi
[ -f "$BACKUP_DIR/boot0.img" ] || dd if="${EMMC}boot0" of="$BACKUP_DIR/boot0.img" status=none
[ -f "$BACKUP_DIR/boot1.img" ] || dd if="${EMMC}boot1" of="$BACKUP_DIR/boot1.img" status=none

# --- 6. Partition and format -------------------------------------------------
wipefs -a "$EMMC"
dd if=/dev/zero of="$EMMC" bs=1M count=4 conv=fsync status=none
echo 'start=8192, type=83' | sfdisk "$EMMC"     # partition starts at 4 MiB
partprobe "$EMMC" 2>/dev/null || sleep 2
PART="${EMMC}p1"
mkfs.ext4 -F -L armbi_emmc "$PART"
UUID=$(blkid -s UUID -o value "$PART")

# --- 7. Copy the system ------------------------------------------------------
mkdir -p /mnt/emmc
mount "$PART" /mnt/emmc
rsync -aAXH --info=progress2 \
  --exclude={"/dev/*","/proc/*","/sys/*","/run/*","/tmp/*","/mnt/*","/media/*","/lost+found","/root/emmc-original*"} \
  / /mnt/emmc/
OLDUUID=$(blkid -s UUID -o value "$ROOTPART")
sed -i "s/$OLDUUID/$UUID/" /mnt/emmc/boot/armbianEnv.txt /mnt/emmc/etc/fstab
grep rootdev /mnt/emmc/boot/armbianEnv.txt
grep "$UUID" /mnt/emmc/etc/fstab
sync; umount /mnt/emmc

# --- 8. Write the TOC0 U-Boot at 8 KiB ----------------------------------------
dd if="$BIN" of="$EMMC" bs=1024 seek=8 conv=fsync,notrunc status=none
sync
dd if="$EMMC" bs=1 skip=8192 count=4 status=none | grep -q TOC0 && echo "U-Boot written (TOC0 @ 8 KiB)."

echo
echo "Done. Run 'poweroff', remove the microSD and power on."
echo "If it does not boot: insert the microSD again; the SD system is untouched."
