#!/bin/bash
set -euo pipefail

requested_connector="${1:-auto}"
project_dir="$(cd "$(dirname "$0")" && pwd)"
hex_file="$project_dir/edid-1920x1080.hex"
firmware_dir=/lib/firmware/edid
firmware_name=fnos-1920x1080.bin
firmware_file="$firmware_dir/$firmware_name"
grub_file=/etc/default/grub

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0 [auto|HDMI-A-N|--list]" >&2
  exit 2
fi

list_connectors() {
  local status_file connector_path connector_status modes
  shopt -s nullglob
  for status_file in /sys/class/drm/card*-*/status; do
    connector_path="${status_file%/status}"
    connector_status="$(<"$status_file")"
    modes="$(paste -sd, "$connector_path/modes" 2>/dev/null || true)"
    printf '%-24s status=%-12s modes=%s\n' \
      "${connector_path##*/}" "$connector_status" "${modes:--}"
  done
  shopt -u nullglob
}

if [[ "$requested_connector" == --list ]]; then
  list_connectors
  exit 0
fi

resolve_connector() {
  local requested="$1" status_file connector_path
  local -a connected_hdmi all_hdmi matches
  shopt -s nullglob
  if [[ "$requested" == auto ]]; then
    for status_file in /sys/class/drm/card*-HDMI-A-*/status; do
      [[ "$(<"$status_file")" == connected ]] && connected_hdmi+=("$status_file")
      all_hdmi+=("$status_file")
    done
    if ((${#connected_hdmi[@]} == 1)); then
      printf '%s\n' "${connected_hdmi[0]}"
    elif ((${#connected_hdmi[@]} > 1)); then
      echo "More than one HDMI connector is connected; pass the exact HDMI-A-N name." >&2
      return 1
    elif ((${#all_hdmi[@]} == 1)); then
      # True headless mode: the only HDMI connector is a safe automatic pick.
      printf '%s\n' "${all_hdmi[0]}"
    elif ((${#all_hdmi[@]} > 1)); then
      echo "Headless system has multiple HDMI connectors; pass the exact HDMI-A-N name." >&2
      return 1
    else
      echo "No HDMI connector was found in /sys/class/drm." >&2
      return 1
    fi
  else
    matches=(/sys/class/drm/card*-"$requested"/status)
    if ((${#matches[@]} != 1)); then
      echo "Connector '$requested' did not resolve to exactly one DRM output." >&2
      return 1
    fi
    printf '%s\n' "${matches[0]}"
  fi
  shopt -u nullglob
}

if ! status_file="$(resolve_connector "$requested_connector")"; then
  echo >&2
  list_connectors >&2
  exit 3
fi
connector_path="${status_file%/status}"
card_connector="${connector_path##*/}"
connector="${card_connector#*-}"
card_name="${card_connector%-$connector}"

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

current_cmdline="$(sed -n -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/p' "$grub_file")"
[[ -n "$current_cmdline" || $(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=""' "$grub_file") -eq 1 ]] || {
  echo "Cannot parse GRUB_CMDLINE_LINUX_DEFAULT in $grub_file" >&2
  exit 6
}
new_cmdline=
for token in $current_cmdline; do
  case "$token" in
    "drm.edid_firmware=$connector:"*|"video=$connector:"*) continue ;;
  esac
  new_cmdline+="${new_cmdline:+ }$token"
done
new_cmdline+="${new_cmdline:+ }drm.edid_firmware=$connector:edid/$firmware_name"
new_cmdline+="${new_cmdline:+ }video=$connector:1920x1080@60e"

tmp_grub="$(mktemp)"
trap 'rm -f "$tmp_edid" "$tmp_grub"' EXIT
awk -v value="$new_cmdline" '
  /^GRUB_CMDLINE_LINUX_DEFAULT=/ {print "GRUB_CMDLINE_LINUX_DEFAULT=\"" value "\""; found=1; next}
  {print}
  END {if (!found) exit 1}
' "$grub_file" >"$tmp_grub"
cat "$tmp_grub" >"$grub_file"

update-initramfs -u
update-grub

echo "Installed a validated 1920x1080@60 EDID for $connector ($card_name)."
echo "GRUB backup: $backup"
echo "Reboot when convenient, then verify:"
echo "  cat /proc/cmdline"
echo "  cat /sys/class/drm/$card_name-$connector/status"
echo "  cat /sys/class/drm/$card_name-$connector/modes"
echo "The first/preferred mode should be 1920x1080."
