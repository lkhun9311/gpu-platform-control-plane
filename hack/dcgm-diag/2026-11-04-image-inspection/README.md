# DCGM diagnostic images, read without a GPU (2026-11-04)

Free rehearsal item 1 of `docs/superpowers/specs/2026-11-04-dcgm-diag-runbook-design.md`, written by `hack/dcgm-diag-inspect-image.sh` on a laptop with no GPU, every container run with `--network none`.
One directory per image: `3.3.9` is the DCGM the exporter uses, `4.4.2` the newest full DCGM image published.

| file | what it holds |
|---|---|
| `image.txt` | the digest pulled, platform, creation time, entrypoint, command and user |
| `version.txt` | `dcgmi --version` |
| `diag-help.txt` | `dcgmi diag --help` |
| `packages.txt` | the DCGM packages `dpkg` lists |
| `plugins.txt` | the versioned diagnostic plugin libraries, by CUDA directory |
| `engine-probe.txt` | `dcgmi diag` and `dcgmi discovery` with no host engine running, by default and with `--host` naming a socket that does not exist |
| `strings.txt` | strings of `nvvs` and `dcgmi`: plugin directories, unsupported-CUDA messages, embedded-engine and connection messages, and key strings |

What it shows:
- 3.3.9 has plugins for CUDA 10, 11 and 12; 4.4.2 for CUDA 12 and 13.
- `dcgmi diag` that cannot reach the named host engine prints a connection error and still returns a result, while `dcgmi discovery` refuses (exit 235).
- 4.4.2's `dcgmi` carries key strings for `entity_id`, `serial`, `serial_num` and `device_id`, and none for `uuid`.

What it cannot show: anything a card would report.
The JSON's real nesting, which tests level 2 runs on an A10G, how long they take, and what the embedded engine would test are all read only from a paid session's output.
