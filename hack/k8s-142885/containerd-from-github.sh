#!/bin/bash
# Installs containerd and runc from their GitHub releases, at the versions the first instance had from apt.
# Used on the second instance, whose Ubuntu mirror did not answer at boot, then restarts node-setup.sh.
set -e
cd /tmp
curl -sfL -o c.tgz https://github.com/containerd/containerd/releases/download/v2.2.1/containerd-2.2.1-linux-amd64.tar.gz
tar -C /usr/local -xzf c.tgz
curl -sfL -o /usr/local/sbin/runc https://github.com/opencontainers/runc/releases/download/v1.3.4/runc.amd64 && chmod +x /usr/local/sbin/runc
curl -sfL -o /etc/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/v2.2.1/containerd.service
mkdir -p /etc/containerd; /usr/local/bin/containerd config default > /etc/containerd/config.toml
systemctl daemon-reload; systemctl enable --now containerd
systemctl is-active containerd; /usr/local/bin/containerd --version; runc --version | head -1
rm -rf /var/log/k8s
nohup bash /root/node-setup.sh 5a0b7d10d74c49bccfd6ed328cd78bd89020eccc /root/bins.tgz > /root/setup.log 2>&1 < /dev/null &
echo restarted
