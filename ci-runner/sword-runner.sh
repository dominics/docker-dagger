#!/usr/bin/env bash
# Installs the sword-td GitHub Actions runner for dominics/td in WSL Ubuntu.
set -euo pipefail
token=$1
version=2.338.2
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential pkg-config curl ca-certificates git jq gh unzip \
  libasound2-dev libudev-dev \
  libx11-dev libxcursor-dev libxrandr-dev libxi-dev libxkbcommon-dev libwayland-dev \
  mesa-vulkan-drivers libvulkan1 valgrind brotli rsync openssh-client nodejs >/dev/null
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
install -d -o runner -g runner /opt/actions-runner
cd /opt/actions-runner
if [ ! -x ./config.sh ]; then
  curl -fsSL -o /tmp/runner.tgz "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-x64-$version.tar.gz"
  sudo -u runner tar xzf /tmp/runner.tgz -C /opt/actions-runner
  rm /tmp/runner.tgz
fi
if [ ! -f .runner ]; then
  sudo -u runner ./config.sh --url https://github.com/dominics/td --token "$token" \
    --name sword-td --labels td --work /home/runner/work --unattended --replace
fi
# 7.8 GB of the WSL VM's memory against a Bevy link: fewer parallel rustc.
grep -q '^CARGO_BUILD_JOBS=' .env 2>/dev/null || echo 'CARGO_BUILD_JOBS=8' >> .env
chown runner:runner .env
./svc.sh install runner >/dev/null
unit=$(systemctl list-unit-files 'actions.runner.*' --no-legend | awk '{print $1}')
install -d "/etc/systemd/system/$unit.d"
printf '[Service]\nNice=10\nCPUWeight=50\n' > "/etc/systemd/system/$unit.d/priority.conf"
systemctl daemon-reload
systemctl enable --now "$unit"
systemctl restart "$unit"
sleep 5
systemctl is-active "$unit"
