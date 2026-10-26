# NVIDIA's nccl-tests, built against the NCCL the platform's training image loads, for experiment C
# (docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md).
#
# Every input is pinned so the image's digest names one build:
#   * the base by its linux/amd64 digest, nvidia/cuda:12.4.1-devel-ubuntu22.04 as Docker Hub served it on 2026-10-26;
#     it ships libnccl2 and libnccl-dev 2.21.5-1+cuda12.4 (read with dpkg-query on 2026-10-26), the NCCL that
#     run 3's torch 2.5.1 ranks reported, and the build refuses any other;
#   * nccl-tests by commit, the one tag v2.13.11 named on 2026-10-26;
#   * Ubuntu 22.04's Open MPI by package version, because mpirun is what starts one process per GPU in one Pod.
#
# It is built and pushed by the owner, and the pushed digest is what the session runs (NCCLTESTS_IMAGE); nothing
# in this repository pushes it.
#   docker build -t <registry>/nccl-tests:2.13.11-nccl2.21.5 experiments/multi-gpu-throughput/nccl-tests
FROM nvidia/cuda@sha256:5645fec64549cc35930eee9d85aafd2b0006c0c3f22632be5a1d85e2604e9749

ARG NCCL_TESTS_COMMIT=8dfeab9eb9bdfdf13503e71e1f33e7f8a208b540
ARG NCCL_PACKAGE=2.21.5-1+cuda12.4
ARG OPENMPI_PACKAGE=4.1.2-2ubuntu1

# The NCCL the base ships is checked rather than reinstalled: a base that moved under the digest cannot, but a
# change to this file that swapped the base would otherwise build against whatever NCCL came with it.
RUN test "$(dpkg-query -W -f='${Version}' libnccl2)" = "$NCCL_PACKAGE" \
 && test "$(dpkg-query -W -f='${Version}' libnccl-dev)" = "$NCCL_PACKAGE" \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git ca-certificates openmpi-bin="$OPENMPI_PACKAGE" libopenmpi-dev="$OPENMPI_PACKAGE" \
 && rm -rf /var/lib/apt/lists/*

# sm_86 only, the A10G's compute capability; a build for every architecture would only make the image larger.
RUN git clone https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests \
 && git -C /opt/nccl-tests checkout --detach "$NCCL_TESTS_COMMIT" \
 && make -C /opt/nccl-tests -j"$(nproc)" MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
      CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86" \
 && test -x /opt/nccl-tests/build/all_reduce_perf \
 && lib="$(ldd /opt/nccl-tests/build/all_reduce_perf | awk '$1 == "libnccl.so.2" {print $3}')" \
 && test "$(basename "$(readlink -f "$lib")")" = libnccl.so.2.21.5

# The base sets NCCL_VERSION as a package label. NCCL itself does not read it, and the scorer allows it by name.
ENV PATH=/opt/nccl-tests/build:$PATH
