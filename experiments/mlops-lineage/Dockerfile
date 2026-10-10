# One image for training and serving, so the code that wrote a model and the code that reads it share a torch build.
FROM python:3.12-slim

RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.5.1
# The client-only distribution, pinned to the tracking server's version; the full package would pull a web stack this image never runs.
RUN pip install --no-cache-dir mlflow-skinny==2.17.2

WORKDIR /work

COPY train.py serve.py /work/

# InferenceDeployment supplies only args (`--model ... --model-path ...`), so the server must be the entrypoint.
# MLTrainingJob sets `command`, which replaces this, so training uses the same image unchanged.
ENTRYPOINT ["python3", "/work/serve.py"]
