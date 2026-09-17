#!/bin/bash
set -uo pipefail

container="${1:-ubuntu26-gnome-hdmi}"

echo '=== Docker resource config ==='
sudo docker inspect "$container" --format \
  'Status={{.State.Status}} OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} RestartCount={{.RestartCount}} Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}} PidsLimit={{.HostConfig.PidsLimit}}' || exit 1

echo
echo '=== Current usage ==='
sudo docker stats --no-stream "$container" || true

echo
echo '=== Host memory / swap ==='
free -h || true
swapon --show || true

echo
echo '=== Recent host OOM / cgroup kills ==='
sudo dmesg -T 2>/dev/null | grep -Ei 'oom|out of memory|killed process|memory cgroup' | tail -100 || true

echo
echo '=== Container cgroup memory events ==='
pid="$(sudo docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || true)"
if [[ -n "$pid" && "$pid" != "0" && -r "/proc/$pid/cgroup" ]]; then
  cgroup_path="$(awk -F: '$1=="0" {print $3}' "/proc/$pid/cgroup")"
  if [[ -n "$cgroup_path" && -r "/sys/fs/cgroup${cgroup_path}/memory.events" ]]; then
    cat "/sys/fs/cgroup${cgroup_path}/memory.events"
  else
    echo 'memory.events not readable'
  fi
else
  echo 'container is not running'
fi
