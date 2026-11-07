# The local rehearsal's stand-in for an EC2 instance: Ubuntu 24.04 with systemd as PID 1, and what both AMIs bring
# that the user-data relies on (python3, CA certificates, an AWS CLI). Slurm and everything else the session installs
# is installed by the user-data, from the archive, as on EC2.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd systemd-sysv dbus python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# The AWS CLI is a stub that keeps the run's S3 prefix in /fakes3.
COPY aws /usr/local/bin/aws
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
