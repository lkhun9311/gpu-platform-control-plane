# The smallest image that can run a gloo DDP step.
#
# Not pytorch/pytorch:*-cuda*-runtime, which the repository's own sample names: that image carries a CUDA
# runtime this experiment never calls and costs about 7 GB to pull onto a kind node. The question here is the
# control plane around distributed training, not the device, so the CPU wheel is the honest dependency.
#
# torch is pinned by version and installed from the CPU index, so no CUDA payload is fetched at all.
FROM python:3.12-slim

# --index-url, not --extra-index-url: the latter would let the default index win and pull the CUDA build.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.5.1

WORKDIR /work

# The script IS baked in, which the first draft of this file said it would not be.
#
# The plan was a ConfigMap mount, so that editing the script would not mean rebuilding and re-loading 1.26 GB
# onto the kind node. MLTrainingJob cannot express that: its only volume field is `stateVolume`, which takes
# a PersistentVolumeClaim name and nothing else -- no ConfigMap, no emptyDir, no hostPath.
#
# Provenance does not depend on the tag either way, because the script hashes itself at startup and the run
# records that hash. Local iteration still mounts over /work, so a rebuild is only needed before a run that
# goes to the cluster.
COPY train.py /work/train.py
