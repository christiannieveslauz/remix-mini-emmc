"""
Write a Remix Mini boot blob to a microSD from Windows, starting at 8 KiB.

Run in PowerShell AS ADMINISTRATOR, after flashing the Armbian Pine64 image:
    Get-Disk                                   # find the microSD disk number
    python write-boot-blob-windows.py 2 remixmini_boot_gap_8k_to_1m.bin

Equivalent to:
    dd if=<blob> of=/dev/sdX bs=1024 seek=8 conv=fsync,notrunc
It leaves the MBR (first 8 KiB) and the Armbian partition untouched.
Windows will say the card is unreadable/only offer "Eject" after flashing:
that is normal (ext4). Do NOT format it.
"""
import json
import subprocess
import sys

OFFSET = 8192
SECTOR = 512
MAX_SIZE_GB = 256  # refuse anything larger than a plausible microSD


def disk_info(n: int) -> dict:
    cmd = (
        f"Get-Disk -Number {n} | Select-Object Number,FriendlyName,BusType,"
        f"Size,IsBoot,IsSystem | ConvertTo-Json"
    )
    out = subprocess.run(["powershell", "-NoProfile", "-Command", cmd],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    n, binpath = int(sys.argv[1]), sys.argv[2]

    data = open(binpath, "rb").read()
    if len(data) % SECTOR:
        sys.exit(f"Blob is {len(data)} bytes, not a multiple of {SECTOR}. Aborting.")
    if OFFSET + len(data) > 1024 * 1024:
        sys.exit("Blob would extend past the first MiB and hit the partition. Aborting.")
    if b"TOC0" not in data[:64]:
        print("WARNING: no TOC0 signature at the start of the blob. Right file?")

    info = disk_info(n)
    size_gb = info["Size"] / 1e9
    print(f"Disk {n}: {info['FriendlyName']} | {info['BusType']} | {size_gb:.1f} GB | "
          f"system={info['IsSystem']} boot={info['IsBoot']}")
    if info["IsSystem"] or info["IsBoot"] or size_gb > MAX_SIZE_GB:
        sys.exit("This does not look like a microSD (system disk or too large). Aborting.")

    if input(f"Write {len(data)} bytes to disk {n} at byte {OFFSET}? "
             f"Type the disk number again to confirm: ").strip() != str(n):
        sys.exit("Cancelled.")

    path = rf"\\.\PhysicalDrive{n}"
    with open(path, "r+b", buffering=0) as f:
        f.seek(OFFSET)
        f.write(data)
        f.flush()
    with open(path, "rb", buffering=0) as f:
        f.seek(OFFSET)
        back = f.read(len(data))
    if back != data:
        sys.exit("ERROR: verification failed. Do not use this card; try again.")
    print("OK: written and verified. Eject the card and boot the Remix Mini.")


if __name__ == "__main__":
    main()
