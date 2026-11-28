#!/usr/bin/env bash
set -euo pipefail
exec > >(tee /var/log/crown2-startup.log) 2>&1
trap 'touch /var/lib/crown2-startup.failed' ERR
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential cmake git python3 binutils linux-tools-common linux-tools-generic
mkdir -p /work/crown2
chmod 1777 /work/crown2
date -u
gcc --version
cmake --version
touch /var/lib/crown2-startup.ready
