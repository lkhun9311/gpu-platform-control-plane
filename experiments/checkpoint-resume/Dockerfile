# The same base and torch wheel as experiments/cpu-ddp, so the two experiments differ only in train.py.
FROM python:3.12-slim

RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.5.1

WORKDIR /work

COPY train.py /work/train.py
