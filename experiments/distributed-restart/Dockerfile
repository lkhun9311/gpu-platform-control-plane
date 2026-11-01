# The same base and torch wheel as experiments/cpu-ddp and experiments/checkpoint-resume, so the layer is shared and the
# experiments differ only in their train.py.
FROM python:3.12-slim

RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.5.1

WORKDIR /work

COPY train.py /work/train.py
