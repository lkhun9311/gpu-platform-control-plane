# DCGM diagnostic images, read without a GPU (2026-11-04)

Free rehearsal item 1 of `docs/superpowers/specs/2026-11-04-dcgm-diag-runbook-design.md`, written by `hack/dcgm-diag-inspect-image.sh` on a laptop with no GPU, every container run with `--network none`.
One directory per image, each named by tag: `3.3.9` is the DCGM the platform's exporter uses, `4.4.2` the 4.x image the registration pins (the newest of the 4.x tags probed on 2026-11-04, not established to be the newest published).
Each command run in the image has its stdout, stderr and exit status as separate files, `<name>.out`, `<name>.err` and `<name>.exit`, because which stream a message lands on is itself a finding; the index fetch and the platform check have `.exit` files, and `strings.exit` records each strings extraction's status and line count.

| file | what it holds |
|---|---|
| `index.json`, `index.headers`, `index.sha256`, `index.exit` | the image index exactly as `nvcr.io` served it for the tag, the response headers with `docker-content-digest`, and the sha256 of the raw bytes, which the script requires to equal the pinned digest before running anything |
| `index-platforms.txt`, `.exit` | each platform manifest the index lists; the platform run must be one of them |
| `image.txt`, `pull.*` | the image pulled **by the pinned digest**: the digest Docker recorded, the platform, `size_bytes`, creation time, entrypoint and command |
| `nvidia-smi-in-image.*` | whether the image has its own `nvidia-smi`: `command -v nvidia-smi` in it exits 127 (its stdout records `exit=127`), so it does not |
| `version.*` | `dcgmi --version` |
| `diag-help.*` | `dcgmi diag --help` |
| `packages.*` | the DCGM packages `dpkg` lists |
| `executables.*` | sha256 of `dcgmi`, `nv-hostengine` and `nvvs`, with their paths |
| `plugins.*` | sha256 of every versioned diagnostic plugin library, by CUDA directory |
| `tools.*` | the image's user, and whether it carries `tar`, `timeout`, `pgrep`, `ps` and `sha256sum` |
| `diag-default.*`, `diag-badhost.*`, `diag-badhost-gpu0.*` | `dcgmi diag -r 1 -j` with no engine: by default, with `--host` naming a socket that does not exist, and with that and `-i gpu:0` |
| `discovery-default.*`, `discovery-badhost.*` | `dcgmi discovery -l` the same two ways |
| `strings.txt`, `strings.exit` | strings of `nvvs` and `dcgmi`: plugin directories, unsupported-CUDA messages, embedded-engine and connection messages, and key strings |
| `negative-tests/` | `hack/test/check-dcgm-diag-inspect.sh`'s transcripts: the inspection refusing a wrong pinned digest, an existing directory and a probe Docker could not run; and `docker top` and `docker inspect` on a running, stopped and removed container |

What it shows:
- The 4.4.2 index digest `becae9b2…5717` is the sha256 of the raw index, and its `linux/amd64` entry is `30dd30b9…52c1b`.
- 3.3.9 has plugins for CUDA 10, 11 and 12; 4.4.2 for CUDA 12 and 13.
- `dcgmi diag` that cannot reach the named host engine writes the connection error to **stdout**, before a JSON object, and still exits with a result; `dcgmi discovery` refuses (exit 235).
- On 4.4.2, with `-i gpu:0` the diagnostic's error names `entities gpu:0`; without it, `entities *,cpu:*`. 3.3.9 rejects `gpu:0` as an invalid GPU list.
- The top-level key of the diagnostic's JSON is `"DCGM Diagnostic"` in 4.4.2 and `"DCGM GPU Diagnostic"` in 3.3.9.
- 4.4.2's `dcgmi` carries key strings for `entity_id`, `serial`, `serial_num` and `device_id`, and none for `uuid`.

What it cannot show: anything a card would report.
The JSON's real structure, the test names and status words of each level on an A10G, how long they take, and what the output names the card by are read only from a paid session's output.
