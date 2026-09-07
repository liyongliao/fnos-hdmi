#!/bin/bash
set -euo pipefail

connector="${1:-HDMI-A-1}"
project_dir="$(cd "$(dirname "$0")" && pwd)"
hex_file="$project_dir/edid-1920x1080.hex"
firmware_dir=/lib/firmware/edid
firmware_name=fnos-1920x1080.bin
firmware_file="$firmware_dir/$firmware_name"
grub_file=/etc/default/grub

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0 [$connector]" >&2
  exit 2
fi
if [[ ! -e "/sys/class/drm/card0-$connector/status" ]]; then
  echo "Unknown physical-GPU connector: $connector" >&2
  exit 3
fi
for command_name in xxd update-initramfs update-grub; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2
    exit 4
  }
done

tmp_edid="$(mktemp)"
trap 'rm -f "$tmp_edid"' EXIT
xxd -r -p "$hex_file" >"$tmp_edid"

size="$(stat -c %s "$tmp_edid")"
checksum="$(od -An -tu1 -v "$tmp_edid" | awk '{for (i=1;i<=NF;i++) s+=$i} END {print s%256}')"
if [[ "$size" != 128 || "$checksum" != 0 ]]; then
  echo "Bundled EDID validation failed: size=$size checksum=$checksum" >&2
  exit 5
fi

backup="$grub_file.fnos-edid-backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$grub_file" "$backup"
install -d -m 0755 "$firmware_dir"
install -m 0644 "$tmp_edid" "$firmware_file"

append_kernel_arg() {
  local argument="$1"
  if ! grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | grep -Fq "$argument"; then
    sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s|\"$| $argument\"|" "$grub_file"
  fi
}

append_kernel_arg "drm.edid_firmware=$connector:edid/$firmware_name"
append_kernel_arg "video=$connector:1920x1080@60e"

update-initramfs -u
update-grub

echo "Installed a validated 1920x1080@60 EDID for $connector."
echo "GRUB backup: $backup"
echo "Reboot when convenient, then verify:"
echo "  cat /sys/class/drm/card0-$connector/modes"
echo "The first/preferred mode should be 1920x1080."
