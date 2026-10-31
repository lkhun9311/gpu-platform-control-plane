# One image for every Slurm role: slurmctld, slurmdbd and the slurmd compute nodes.
# The base is pinned by digest and every Slurm and MUNGE package by its exact Debian version, so a rebuild either reproduces this lab or fails loudly when the archive no longer carries that version.
# Debian 13 rather than Ubuntu 24.04, because 24.04's Slurm 23.11 cannot run slurmd without a working cgroup plugin and has no CgroupPlugin=disabled.
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

ARG SLURM_VERSION=24.11.5-4+deb13u1
ARG MUNGE_VERSION=0.5.16-1.1~deb13u1

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      slurmctld=${SLURM_VERSION} \
      slurmd=${SLURM_VERSION} \
      slurmdbd=${SLURM_VERSION} \
      slurm-client=${SLURM_VERSION} \
      slurm-wlm-basic-plugins=${SLURM_VERSION} \
      munge=${MUNGE_VERSION} \
      procps iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Every container is built from this one layer, so they all share this key and can authenticate to each other.
# It is a lab key baked into a local image that is never pushed; it must not be reused anywhere real.
RUN dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null \
 && chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key

# Two tenants submit as ordinary users with fixed UIDs, so every container resolves them the same way.
RUN useradd -m -u 2001 alice && useradd -m -u 2002 bob

RUN mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /run/slurm \
 && chown -R slurm:slurm /var/spool/slurmctld /var/log/slurm /run/slurm

# Modes are set in a RUN rather than with COPY --chmod, which the legacy builder on this host refuses.
COPY etc/slurm.conf etc/gres.conf etc/cgroup.conf etc/slurmdbd.conf /etc/slurm/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chown slurm:slurm /etc/slurm/slurmdbd.conf && chmod 600 /etc/slurm/slurmdbd.conf \
 && chmod 755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
