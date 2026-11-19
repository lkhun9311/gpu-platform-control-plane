# build.sh runs this over upstream's deployments/container/Dockerfile and builds from the result.
# It inserts one RUN before the build stage's apt step, and every upstream line stays byte for byte.
# The inserted RUN moves every archive.ubuntu.com entry of the base image's sources.list to EC2's Seoul mirror of the same archive.
# Only the host changes, so the suites, components and options of each entry stay as the image has them.
# It fails the build if any apt source still names archive.ubuntu.com, or if the mirror's jammy main entry is absent.
# That way the slow host cannot come back unnoticed, whatever form a later image writes its entries in.
# It also makes apt retry a failed fetch five times and drop a connection that stalls for 30 s.
# security.ubuntu.com, and the Debian stage's deb.debian.org, are left as they are.
/^RUN apt-get update && apt-get install -y \\$/i\
RUN sed -i 's|//archive[.]ubuntu[.]com/|//ap-northeast-2.ec2.archive.ubuntu.com/|' /etc/apt/sources.list && ! grep -rq '//archive[.]ubuntu[.]com/' /etc/apt/sources.list /etc/apt/sources.list.d && grep -q '^deb http://ap-northeast-2.ec2.archive.ubuntu.com/ubuntu/ jammy main' /etc/apt/sources.list && echo 'Acquire::Retries "5"; Acquire::http::Timeout "30";' >/etc/apt/apt.conf.d/80-session-retries
