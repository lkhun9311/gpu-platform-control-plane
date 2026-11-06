# What `dcgmi diag` reports on one rented A10G with no known fault: a registration

Written 2026-11-04, before any run.
Revised five times the same day after adversarial reviews by codex `gpt-6-astra` (25 findings, then 23, 24, 18 and 12); each was re-checked against the code, the archives or the image before it changed this page.
The fifth review's blocker count rose instead of falling, because the re-admission runbook and its platform exercise kept producing operational gaps.
So this revision **narrows the study to Part 1**, the diagnostic itself, and moves the runbook and everything that served it to "Deferred, not registered", each with its reason.
**Draft. Not registered.** It becomes the registration only by the owner's approval, from the commit that records that approval, and no run before it counts.
Nothing here has been bought or run on a card.
Every number is either read from a file named beside it, derived on this page with its arithmetic shown, or marked "to be measured" or "to be read".

## Why

`docs/03_GPU_NODE_LIFECYCLE.md` ends the node's life cycle with "Re-intake -> Recover" and says "a recovered node re-runs intake before returning to `Serve`".
Its status line lists a "re-intake script" as a target, not as built.
The platform can latch a DCGM-reported fault and taint the node (`internal/controller/nodehealth_gpufault.go`), and run 3 of the gpu-fault study showed the node returning to service on a fresh zero reading (`2026-10-27-gpu-fault-reaction-design.md`, "Result, 2026-11-01").
Any re-intake step would run an NVIDIA diagnostic on the card, and this repository has never seen what that diagnostic prints on a real card, how long it takes, or what it names the card by.
This page buys only that: the first real output, so that a later runbook can be written against what the tool does rather than what its help text says.
The owner's reordering of the next three weeks (`storage/career/job/kor/42dot/apply/2026/08-개발방향-재정렬.md`, section 4 row B2) put the item at "정상 GPU 1대의 실행 확인일 뿐, 불량 판별률 아님"; that document lives outside this repository, so its wording is quoted here rather than linked.

## The question

On one rented A10G that has **no known fault** (its health is not independently established):
1. What do `dcgmi diag -r 1`, `-r 2` and `-r 3`, on DCGM 4.4.2 against the explicit entity `gpu:0`, print, test by test, and how long does each take, in the order and on the card state this page registers?
2. What evidence of the card's identity and history can be captured around them: driver version, the driver's supported CUDA version, the host's CUDA toolkit and the CUDA versions the image's DCGM packages target, GPU UUID, serial and PCI bus ID, ECC mode and counters (volatile and aggregate, single-bit and double-bit), retired or remapped rows if the card reports them, and the Xid lines the kernel journal still holds for the current boot?

It is **not** a question about defect detection, and **nothing in the output is scored**.
One card with no known fault cannot show that a diagnostic detects an unhealthy one, how often it misses, or how often it flags a good card.
Such a card can still receive a failing or warning result; that would be transcribed as printed, and it would not be a measured false-positive rate either.
No sensitivity, specificity, miss rate or re-admission rate is computed, quoted or implied by anything on this page.

## What is verified, and what is not (2026-11-04)

Archived by `hack/dcgm-diag-inspect-image.sh`, with no GPU and every container run with `--network none`, in `hack/dcgm-diag/2026-11-04-image-inspection`, one directory per DCGM version; each command run in the image has its stdout, stderr and exit status as separate files (`<name>.out`, `<name>.err`, `<name>.exit`), the index fetch and platform check have `.exit` files, and `strings.exit` records each strings extraction's status and line count:
- **The image is pinned by its index digest, and the archive shows what that digest resolves to.**
  `index.json` is the index exactly as `nvcr.io` served it for `nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04`; its sha256 (`index.sha256`) is `becae9b24707d2bdfce87cb72626e24b2fbfbca812329ca52540ad0e0d955717`, the same as the response's `docker-content-digest` (`index.headers`) and Docker's `RepoDigests` after the pull (`image.txt`), and its `linux/amd64` entry is `sha256:30dd30b980ebf2f15a3fe7e629db9b8540f93bed794327dd34a0d4afd8a52c1b`.
- **The image carries the diagnostic.** `version.out` prints `dcgmi  version: 4.4.2`; `executables.out` lists `/usr/bin/dcgmi`, `/usr/bin/nv-hostengine` and `/usr/libexec/datacenter-gpu-manager-4/nvvs` with their sha256; `plugins.out` lists each versioned plugin library with its sha256: for 4.4.2, the plugin directories are `cuda12`, `cuda13` and `cudaless`.
  `tools.out` shows the image runs as root and carries `tar`, `timeout`, `pgrep`, `ps` and `sha256sum`.
- **The AMI's driver needs a CUDA 13 plugin set, which 3.3.9 lacks.**
  The AMI's driver 595.91.07 reports `CUDA Version: 13.2` (`hack/mps-capability/2026-10-24-run2/m5c-run/mpscap/diag/nvidia-smi.txt`; run 3 recorded the same driver version, `hack/gpu-fault/2026-11-01-run3/preflight-nvidia-smi.csv`).
  3.3.9, the version the exporter uses, has plugin directories only for CUDA 10, 11 and 12 (`3.3.9/plugins.out`), so it is not used.
  `nvvs` picks the directory by the driver's CUDA version, and the 4.4.2 binary also carries "Detected unsupported CUDA version {}; defaulting to {}" (`4.4.2/strings.txt`), which is why the session checks the driver's major version against the image's directories before any diagnostic.
- **A failed connection to the host engine does not stop `dcgmi diag`, and its message lands on stdout before the JSON.**
  With `--host` naming a socket that does not exist, `dcgmi diag -r 1 -j` writes "Error: unable to establish a connection to the specified host: unix:///tmp/none.sock" to **stdout**, followed by a JSON object, with nothing on stderr and exit 226 (`diag-badhost.out`, `.err`, `.exit`); with no `--host` and no engine it writes only the JSON, also exit 226 (`diag-default.*`).
  So the connection error is found by reading stdout, and it also makes stdout not a single JSON document.
  `dcgmi discovery -l` refuses instead: exit 235, "Unable to connect to host engine" (`discovery-badhost.*`, `discovery-default.*`).
  The binary links `dcgmStartEmbedded_v2` (`strings.txt`), consistent with `dcgmi diag` running on an embedded engine when none is reachable; what that engine would test on a card is not needed here and not bought.
- **An explicit entity is honoured by 4.4.2 even without a GPU** (3.3.9 rejects the `gpu:0` syntax outright, "Invalid gpu list 'gpu:0'", `3.3.9/diag-badhost-gpu0.err`, one more reason it is not used).
  With `-i gpu:0` the error names `entities gpu:0` and "Detected driver major version 0 is not between the required versions 346 and 2000" (`diag-badhost-gpu0.out`); without it, the error names `entities *,cpu:*` (`diag-badhost.out`), so an unselected diagnostic would include CPU entities.
- **The no-GPU failure shape**, from the producer: `{"DCGM Diagnostic" : {"runtime_error" : "...", "version" : "4.4.2"}}` (`diag-default.out`).
  It is the fixture for the error-envelope check below and nothing else; a fixture of external output must come from the producer, and this is the only output the producer has given without a card.
- **The JSON's structure, as NVIDIA's 4.4.2 source writes it** (read 2026-11-04 from `dcgmi/Diag.cpp` and `nvvs/include/NvvsJsonStrings.h` at the `v4.4.2` tag of github.com/NVIDIA/DCGM; source, not yet real output):
  `"DCGM Diagnostic"."test_categories"[]` each hold a `"category"` and `"tests"[]`; each test holds a `"name"`, `"results"[]` and a `"test_summary"`; each result holds `"entity_group"`, `"entity_group_id"`, `"entity_id"`, `"status"`, and optionally `"warnings"[]` (`"warning"`, `"error_id"`, `"error_category"`, `"error_severity"`) and `"info"[]`.
  The card's serial is **not** in a result: a separate `"entity_groups"[]` lists each group's `"entities"[]` with `"entity_id"`, `"serial_num"` (omitted when blank) and `"device_id"`, so a result is tied to a card only by joining its group and `entity_id` to that list.
  The source writes the status words `Pass`, `Skip`, `Warn` and `Fail`, and **writes no result record for a test that did not run** (Diag.cpp's HelperJsonAddResult returns early on DCGM_DIAG_RESULT_NOT_RUN, upstream names, not this repository's), so a missing test or entity is silent unless something checks for it.
  The 4.4.2 binary's key strings agree (`strings.txt`: `entity_id`, `entity_groups`, `serial_num`, `device_id`, `results`, `tests`, `test_summary`, `warnings`, `info`, `error_id`, `error_category`, `metadata`, `runtime_error`), and no `uuid` key appears in either.

Not verified, and found out only from the session's first real output:
- whether the real `-j` output has the structure the source writes, its test names for each level, and its status words;
- whether that output carries the card's serial for `gpu:0`;
- every duration, and whether `-r 3` completes on a g5.2xlarge inside its limit;
- the exact `dcgmi discovery -l` text, and so how its GPU 0 entry names the card;
- whether this card exposes ECC counters and retired or remapped rows, read from `nvidia-smi -q -d ECC,PAGE_RETIREMENT,ROW_REMAPPER` (the display names are confirmed by the session's first command, on the AMI's own `nvidia-smi`).

## The apparatus

One g5.2xlarge Spot instance, the pinned Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) `ami-097edab977037f65f` (run 3's, `hack/gpu-fault/2026-11-01-run3/session-provenance.txt`), and the diagnostic image above.
**No kind cluster, no operator, no exporter, no workload.**
The host runs only the evidence commands and the diagnostic's two containers.

### Host preparation: the container runtime and the GPU in a container

What this AMI already has is read from run 3's archive, not assumed.
On the host, run 3's bring-up script installs `nvidia-container-toolkit` only `if ! command -v nvidia-ctk` (`hack/gpu-fault/2026-11-01-run3/bringup.sh:2-9`), and its log goes straight from starting that script to `nvidia-ctk runtime configure`'s "Wrote updated config to /etc/docker/daemon.json" at 02:37:49 with no package installation between (`hack/gpu-fault/2026-11-01-run3/log.txt:63-67`): **the AMI ships `nvidia-ctk`, but Docker's NVIDIA runtime was configured by the run**, not found configured.
The later installation of `nvidia-container-toolkit` 1.20.1 in that log (`:194-213`) is inside the kind node (`bringup.sh:92-105`, a `docker exec m5cgpu-worker` that installs and configures the toolkit there), which this study does not build.
So host preparation registers these steps, each with its timeout, and nothing else from the inherited bring-up:
1. `command -v nvidia-ctk` must succeed and `nvidia-ctk --version` is recorded; if it fails, the instance is not this AMI as run 3 saw it, and the session aborts as `DCGM DIAG: REFUSED (host)` rather than installing anything.
2. `nvidia-ctk runtime configure --runtime=docker --set-as-default`, then `systemctl restart docker`, both exit statuses recorded, exactly as `bringup.sh:10` and `:15` do, without the kind-only `accept-nvidia-visible-devices-as-volume-mounts` change, which is for the kind node's device list.
3. **The GPU in a container**: `docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility --network none --entrypoint nvidia-smi <pinned image> --query-gpu=index,uuid --format=csv,noheader` must exit 0 and print exactly one line whose UUID equals the host's `nvidia-smi` for index 0; otherwise `DCGM DIAG: REFUSED (host)`.
   The image has no `nvidia-smi` of its own (`command -v nvidia-smi` in it exits 127 with empty stdout, `4.4.2/nvidia-smi-in-image.*`), so this also shows the runtime injecting the host driver's utilities, which the diagnostic's `utility` and `compute` needs depend on.

### The host engine and the diagnostic

The diagnostic runs against an explicit host engine, so the engine it used is known and recorded rather than chosen by `dcgmi`:
- the engine is one long-lived container, `dcgm-he`, from the pinned image, started with `--gpus all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility --network none -v $OUT/engine:/out` and the command `nv-hostengine -n -b 127.0.0.1 --log-level ERROR -f /out/engine-<k>.log` (the image's default command is `-n -b 0.0.0.0 --log-level NONE -f -`, `image.txt`, which keeps no log; `-b 127.0.0.1` because the container has only loopback; `<k>` counts engine starts, so a restarted engine never overwrites its predecessor's log);
  its host PID (`docker inspect -f '{{.State.Pid}}' dcgm-he`) is recorded at each start;
- each diagnostic is `timeout -k 30 <L> docker exec dcgm-he dcgmi diag --host localhost:5555 -i gpu:0 -r <N> -j --statspath /out/<run>/stats --debugLogFile /out/<run>/nvvs.log`, its stdout, stderr and exit status kept as separate files on the host;
  each run has its own stats and debug-log directory, because the help says statistics otherwise go to the current directory (`diag-help.out`), where the next run would overwrite them;
  the help calls the debug log "Encrypted", so it is archived and hashed but **not read** by this study;
- immediately before each diagnostic, `docker exec dcgm-he dcgmi discovery --host localhost:5555 -l` must exit 0, and its output must contain the UUID `nvidia-smi` reports for index 0; otherwise the run is INVALID (engine or identity) and is not started.

**Order and state.**
Order: `-r 3` once, then `-r 1` three times, then `-r 2` three times.
`-r 3` comes first so that the run whose limit is longest can never be starved by an earlier run's overrun; the phase is also sized to every run's worst case (Cost, below), so ordering is a second guard, not the only one.
Three is a convention (the least that gives a median that is not an endpoint, as in `2026-10-27-gpu-fault-reaction-design.md`, "Verdict rules"); `-r 3` once because its help text says about 15 minutes.
Every duration is an observation **in this sequence**, with level confounded with order and with the card's warming; card-state, ECC and kernel rows are read before and after every diagnostic and persistence mode is recorded; nothing is described as a level's isolated cost.

**Timing.**
Wall time is measured on the host around the `docker exec`.
A `docker exec dcgm-he true`, three times before the first diagnostic, gives the exec overhead, reported beside the wall times and never subtracted.

**Limits, cancellation and the residual check.**
Per-run limits `L`: `-r 1` 300 s, `-r 2` 600 s, `-r 3` 1,800 s (conventions: at least twice the help text's figure, and for `-r 1` a floor).
Each run occupies a **slot** of `L` plus 325 s, every part with its own timeout, so a slot's worst case is its length:
its before rows, the identity read and the discovery check 30 s; the client's kill-after 30 s (`timeout -k 30 L` may return only at `L` + 30); the engine kill wait 30 s; the after rows 30 s; the residual check 15 s; an engine restart and its discovery check 45 s; hashing the run's files 15 s; the upload, three attempts of 30 s with two 5 s pauses, 100 s; and the `MANIFEST` upload 30 s.
A run starts only if its whole slot fits before Part 1's phase end; otherwise it is **NOT-RUN**, which is not a failure.
When a run reaches `L`, killing the `docker exec` stops the client, not work the engine started for it, so the **engine container is killed**: `docker kill dcgm-he`, wait up to 30 s, then the host check below; if clean, a new `dcgm-he` is started for the next run, and that run is recorded as on a fresh engine.

After **every** run, timed out or not, the host checks three states, never two.
The engine's state is read first, with `docker inspect -f '{{.State.Status}}' dcgm-he`, which must print `running` (no time-out) or `exited` (after a kill); anything else, or a failed `inspect`, is **unreadable**.
- **clean**, engine `running`: `docker top dcgm-he -eo pid,ppid,comm` exits 0, its first line is the header `PID PPID COMMAND` (three columns, as `docker top` prints it, checked on 2026-11-04), and exactly one further line follows, three fields, the engine's recorded host PID with command `nv-hostengine`; `pgrep -a nvvs` on the host exits 1; and `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` exits 0 and every line it prints, if any, names the engine's recorded PID;
- **clean**, engine `exited`: `docker top` is not used (it exits 1 on a stopped container, "is not running"); `pgrep -a nvvs` and `pgrep -x nv-hostengine` on the host both exit 1, and the compute-apps query exits 0 with no line;
- **residual**: any of those reads succeeds and shows a process other than the engine (a second `docker top` row, an `nvvs`, another compute PID, or any engine process after a kill);
- **unreadable**: any read exits with a status other than the ones above, the header is not the one expected, or a line does not parse as a process row.

Residual or unreadable makes the card **contaminated**: every later diagnostic is NOT-RUN (contaminated), the evidence is uploaded, and the instance shuts itself down.
A clean check lets the next run start.

**Isolation monitoring.**
During each diagnostic the host runs `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` every 2 s and maps each PID to its cgroup (`/proc/<pid>/cgroup`).
A sample is **valid** only if the command exited 0 within 5 s and every line it printed parses as a PID and a name; a failed or malformed sample is counted, kept, and never treated as "no foreign process".
Processes in `dcgm-he`'s cgroup are the diagnostic's own work.
Any other compute process in a valid sample makes the run INVALID (interference).
A run with any 10 s window lacking a valid sample, or a sampled PID whose cgroup could not be read, is reported as **isolation unverified** beside its outcome.
The claim made is only "no foreign compute process observed in valid samples at the 2 s cadence"; this query lists compute processes, not graphics users or monitoring clients.
Before `dcgm-he` starts, the host shows `docker ps -q` empty, `pgrep -a nv-hostengine` with no match, and no active systemd unit whose name contains `dcgm`.

**Evidence rows.**
Evidence commands run **on the host, not in a container**; each one's exit status, start and end (`date +%s.%N`), stdout and stderr are separate files:

| row | command |
|---|---|
| boot | `cat /proc/sys/kernel/random/boot_id`; `uptime -s` |
| card, driver, identity | `nvidia-smi --query-gpu=index,name,uuid,serial,pci.bus_id,driver_version,memory.total,ecc.mode.current,persistence_mode --format=csv`; `nvidia-smi -q` |
| driver's supported CUDA | the "CUDA Version" line of `nvidia-smi` (driver capability, not a toolkit) |
| host toolkit | `command -v nvcc` and `nvcc --version`; absent is recorded as absent |
| image's CUDA targets | from the archived inspection: the CUDA-specific DCGM packages (`packages.out`) and plugin directories (`plugins.out`); this is what the image is built for, not an installed toolkit or its version |
| ECC, retirement, remapping | `nvidia-smi -q -d ECC,PAGE_RETIREMENT,ROW_REMAPPER` |
| card state | `nvidia-smi --query-gpu=temperature.gpu,clocks.sm,clocks.mem,power.draw,power.limit,clocks_throttle_reasons.active --format=csv` |
| kernel Xid | `journalctl -k -b --no-pager -o short-monotonic`, filtered afterwards for NVRM and `Xid`, its exit status recorded apart from the filter's |

The kernel row reports the lines the journal **still holds** for the current boot; whether earlier lines were rotated away is not established by a readable journal, and is not claimed.
A row whose command fails or is denied is **UNREADABLE**, never empty.

**The driver contract.**
The registration names the expected driver: 595.91.07.
On the instance, before anything else runs on the card, the first `nvidia-smi` read is compared with it, and the driver's CUDA major version must have a directory under the image's `plugins/` (13 today, `4.4.2/plugins.out`).
Either failing is an **in-session abort**: nothing runs on the card, the evidence so far is uploaded, the instance shuts itself down, and the session verdict is `DCGM DIAG: REFUSED (driver)`.

**Cancellation preflight.**
Before the first diagnostic, the cancellation path is run once for real: a `sleep 600` started by `docker exec dcgm-he` is run past a 10 s limit, `dcgm-he` is killed and restarted, and the residual check must read **clean**; otherwise the session aborts before any diagnostic as `DCGM DIAG: REFUSED (cancellation)`.
That is the first clean read on a host with a GPU; the laptop rehearsal can only stub it.

### Evidence preservation and recovery

After each run, its directory is uploaded with `aws s3 cp --recursive`, the exit status checked and up to three attempts made, and one line (run name, file count, sha256 of its `SHA256SUMS`) is appended to an uploaded `MANIFEST`.
The laptop fetches with `aws s3 sync` of the run's whole prefix, not a fixed list of names (the inherited runner's fixed list, `hack/gpu-fault-session.sh:357`, is not reused), and checks each run's files against its `SHA256SUMS` and the `MANIFEST`.
A run with no `MANIFEST` line, or whose files fail their hashes, is reported as **NOT-RECOVERED**, never as a result; an interruption therefore loses at most the run in progress and anything not yet in the `MANIFEST`.
The directory is hack/dcgm-diag/<date>-run1/; the image archive and source archive are recorded in `NOT-COMMITTED.sha256`, as for the gpu-fault runs.

## Registered outcomes and refusals

### Refusals before purchase

The existing runner already refuses on these, and the new runner reuses them: `SESSION_CONFIRM=yes` absent, a dirty tree, credentials for an account other than `007635145730`, a Spot price above the cap in every zone, a "G and VT" Spot quota under 8 vCPU, the termination sweeper not Active and `ENABLED rate(5 minutes)` and aimed at itself, and an earlier instance with this study's `purpose` tag still live.

**New work, not implemented anywhere today** (there is no diagnostic runner in this checkout):
- the AMI ID must equal `ami-097edab977037f65f` (the existing check, `hack/gpu-fault-session.sh:62-80`, checks only the ID's syntax and the AMI's name);
- the instance type must be g5.2xlarge;
- the registration must name the expected driver version;
- the image must be named by the registered index digest, and the committed inspection must show `nvvs` and a plugin directory for CUDA 13;
- the credentials must outlast the session's phases plus the termination wait plus 30 minutes, derived from this runner's constants (the existing runner hard-codes `CRED_MIN_MINUTES=155`, `hack/gpu-fault-session.sh:45`), and are **re-read immediately before launch**;
- the sweeper's last-thirty-minutes check must sum **every** CloudWatch datapoint in the window (the existing check reads only `Datapoints[0].Sum`, `hack/gpu-fault-session.sh:107-117`);
- two price constants: the **compute cap** passed as EC2's Spot `MaxPrice` is $1.10 an hour, and the **all-in rate at that cap** used for allowances is $1.1324 an hour ($1.10 + $0.0274 for 200 GB gp3 + $0.005 for a public IPv4, `2026-10-08-measuring-prospective-admission-design.md:733-737`).

Each refusal is shown to fire on its own bent copy, one at a time on a clean tree.

### Per diagnostic run

Checked in this order; the first that holds decides:
1. **NOT-RUN**: it was not started because its slot did not fit, the card was contaminated, or the session aborted. Not a failure.
2. **INVALID (identity or engine), not started**: the `nvidia-smi` read immediately before it does not show exactly one A10G with the session's UUID, or the `discovery` check before it failed or did not contain that UUID; the diagnostic is then not run, and the slot's remaining time is not reused.
3. **INVALID (engine or interference)**, after it ran: its stdout contains "unable to establish a connection", or a foreign compute process appeared in a valid isolation sample.
4. **TIMED-OUT**: it reached `L` and was cancelled; reported as "not complete inside L", never as a time, whatever its output holds; a clean cancellation and a contaminated one are kept apart.
5. **INVALID (output)**: stdout, stderr and exit status were not all recorded; stdout is not exactly one JSON document whose top level is an **object**; that object has no member `"DCGM Diagnostic"` holding an object; that member holds a `"runtime_error"` (the error envelope, the shape of `diag-default.out`, whatever else beside it); or it holds no `"test_categories"` array containing at least one test with a `"name"`. So `{}`, `null`, an array, a bare string, or a document with no test are INVALID (output), never RESULT.
6. **RESULT**: otherwise, **whatever the diagnostic itself reported**, including a non-zero exit with a failing test, which is a result.
6. **NOT-RECOVERED** replaces any of these when the run's files did not come back intact (above).

### Transcription rule, frozen now

The test list and the status vocabulary are **read from the first real output**, under this rule, frozen before launch; nothing is classified or scored before then, and nothing in this registration is scored after then either.
The rule follows the structure NVIDIA's 4.4.2 source writes (above); where the real output departs from it, the departure is reported, never repaired.
For each RESULT run:
1. **The whole document**: every member path is listed with its value in document order, including `null`, empty strings, empty arrays and empty objects, so nothing is chosen in advance and nothing is dropped.
2. **Every test, with every result**: for each element of `"DCGM Diagnostic"."test_categories"[]`, its `"category"`; for each element of its `"tests"[]`, the `"name"`, the `"test_summary"` copied separately and as printed when present (the source can omit it), and **each** element of `"results"[]` with its `"entity_group"`, `"entity_group_id"`, `"entity_id"`, `"status"`, every `"warnings"[]` entry and every `"info"[]` entry, copied as printed. A test whose `"results"` is absent or empty is listed as **no entity result record**: the source writes `"results"` only when it appends a result and writes none for a test that did not run on an entity, so this is a valid shape, not a departure, and it does not show that the test did nothing (its `"test_summary"`, if any, is kept beside it).
3. **The entity join**: each result's (`"entity_group_id"`, `"entity_id"`) is looked up in the top-level `"entity_groups"[]."entities"[]`, and its `"serial_num"` and `"device_id"` are copied beside the result; a result with no match, or more than one, is listed as **entity not joined**, and a result whose group is not the GPU group, or whose `entity_id` is not 0, is listed as **outside gpu:0**.
4. **The card**: the `"serial_num"` joined to `gpu:0`'s results is compared with the serial `nvidia-smi` printed for index 0 in the same boot; equal, different, or absent on either side, as found.
5. **Status words** are copied as printed and **not classed**: no pass, fail, warn or skip is assigned by this registration, even though the source writes `Pass`, `Skip`, `Warn` and `Fail`.
6. **The observed comparison set and what each run lacks from it.** The help text says "higher numbered tests include all beneath" (`diag-help.out`), so each level's comparison set is the union of test names seen in that level's RESULT runs together with every name seen at a lower level. Each RESULT run reports the names of that set it lacks, as **missing**, and each test with no entity result record; a missing test is never inferred to have passed. This set is built from what was observed, so a test absent from **every** output is absent from it too: it detects differences between outputs, and the **completeness of any level's test list is unknown** and reported as such. A name seen only at a higher level is reported as **only at level N**.
7. **Structure not as the source writes it**: `test_categories` absent or not an array, a test element without a string `"name"`, or `tests`, `results` or `entity_groups` present but not an array. That run is reported as **structure departed**, with step 1's whole-document listing as its only transcription. An absent `"results"`, an absent `"test_summary"`, or an absent `"entity_groups"` is the source's own valid shape and is not a departure; with no `"entity_groups"`, every result is **entity not joined**.

This is a transcription rule, not a scorer: it can be applied by hand to the archived bytes, and a later parser may only reproduce it.
A later registration may class the statuses, using the vocabulary this output shows; it is not this one.

### Per level

- **REPORTED**: every registered repetition is RESULT (3 for `-r 1` and `-r 2`, 1 for `-r 3`).
- **PARTIAL**: at least one RESULT, fewer than registered.
- **UNJUDGED**: no RESULT.

A REPORTED or PARTIAL level reports the transcription, each run's wall time, the exec overhead, and for three runs the median, minimum and maximum (no mean, no interval, no rate).
No bar on any wall time is registered: NVIDIA's "~2 minutes" and "~15 minutes" are help text, and a bar picked from them would be the kind of guess `docs/11_WHAT_THIS_MEASURED.md` ("What the targets were based on") records the earlier ones to have been.

### The session verdict, exhaustive and ordered

1. `DCGM DIAG: NO-EVIDENCE` when no `MANIFEST` and no archive came back.
2. `DCGM DIAG: REFUSED` when provenance was never recorded, the readings disagree on the image, the driver or its CUDA major version did not match, host preparation failed (no `nvidia-ctk`, or the GPU-in-a-container check), or the cancellation preflight was not clean.
3. `DCGM DIAG: INCOMPLETE` when evidence came back but all three levels are UNJUDGED; the evidence rows are still reported.
4. `DCGM DIAG: RESULT` otherwise.

Whatever the verdict, all three levels' statuses are printed beside it.

## Cost

**Price read method.**
The runner reads `aws ec2 describe-spot-price-history` for g5.2xlarge `Linux/UNIX` at launch, records it in `spot-prices.txt`, and tries only zones at or under the $1.10 compute cap.
The price is **to be read** on the day; on 2026-11-01 the zones read $0.6769 to $0.6887 an hour (`hack/gpu-fault/2026-11-01-run3/spot-prices.txt`), a value from another day.

**Part 1's phase is sized to every run's worst case**, so no run can be starved by another's overrun:
- per-run overhead, every part bounded (Limits, above): 30 + 30 + 30 + 30 + 15 + 45 + 15 + 100 + 30 = 325 s, the first 30 s being each run's own before rows, identity read and discovery check;
- slots: `-r 3` 1,800 + 325 = 2,125 s; `-r 1` 300 + 325 = 625 s, three of them 1,875 s; `-r 2` 600 + 325 = 925 s, three of them 2,775 s;
- before the first run: the exec overhead 3 x 60 s, engine start and its discovery 60 s, and the first full evidence rows 120 s, 360 s in all (each with its own timeout);
- Part 1 worst case: 360 + 2,125 + 1,875 + 2,775 = **7,135 s**.
`-r 3` runs first, so its slot ends by 360 + 2,125 = 2,485 s into the phase, **4,650 s before the phase ends**: the margin the fifth review found missing (its 1,803 s left against 1,830 s needed) is gone, because nothing runs before `-r 3` except the 360 s preamble.
Whether every part fits its own allowance is a property of the runner, shown only by rehearsing all seven slots with every part made to use its full allowance (free rehearsal item 6).

**Phases, counted from EC2's `LaunchTime`** (conventions of this page; the new runner's constants supersede them, and the arithmetic is re-done from them before freezing):

| phase | ends at | contents |
|---|---:|---|
| host preparation | 1,380 s | boot, cloud-init and fetching the source 300 s (run 3's user-data began 95 s after `LaunchTime`, `GF_START=1793500661` against `L=1793500566` in `hack/gpu-fault/2026-11-01-run3/log.txt:2` and `:35`, so 300 s is a convention three times that); evidence rows and the driver contract 120 s; `nvidia-ctk` check, runtime configure and Docker restart 120 s; the GPU-in-a-container check 60 s; image pull, its limit 600 s; cancellation preflight 120 s; 60 s guard |
| Part 1, diagnostics | 8,515 s | 7,135 s, above |
| evidence | 8,665 s | final archive and `MANIFEST` upload, three attempts, 150 s |
| instance stop | 8,725 s | `shutdown -h now` from the instance's own backstop |

The credentials must therefore outlast 8,725 s plus the termination wait (300 s) plus 30 minutes: 10,825 s, about 180 minutes.

**Expected duration, by component** (estimates, not measurements, each named with its source): boot to user-data 95 s (run 3's, above); host preparation 163 s (the historical span's 2 min 43 s, `hack/m5c-gpu-session.sh:697`, a comment recording an older session's S3 timestamps for a span that also built kind, so taken as an over-estimate); image pull 120 s (assumed, not measured; the image is 1,838,675,060 bytes, `size_bytes` in `4.4.2/image.txt`, its local unpacked size); Part 1 2,220 s (the 360 s preamble at its full limits, then `-r 3` 900 s, `-r 1` 3 x 60 s and `-r 2` 3 x 120 s, durations from the help text's "~15 minutes", "~ seconds" with a 60 s floor assumed, and "~2 minutes", plus 60 s of per-run overhead assumed for each of the seven runs, against the 325 s each is allowed); evidence 120 s (assumed).
Sum: 95 + 163 + 120 + 2,220 + 120 = **2,718 s**.
At the 2026-11-01 zone prices plus the $0.0324 an hour of gp3 and IPv4: (0.6769 + 0.0324) x 2,718 / 3,600 = $0.5355, and (0.6887 + 0.0324) x 2,718 / 3,600 = $0.5444, so about **$0.54** under those assumptions; the price is re-read at launch, and none of the durations except the 95 s is a measurement, and that one is another session's.

**Operating allowance, not a maximum:** (8,725 + 900) s = 2.67 h at the all-in $1.1324 = **$3.03**, conditional on the backstop, the sweeper or the laptop terminating the instance.
If all three fail, spending continues at up to $1.1324 an hour until a person notices.
Two attempts at the allowance are **$6.06**.
The owner's envelope for this item is $3 to $10 (`08-개발방향-재정렬.md`, section 6); a second attempt needs its own approval.

**Termination chain, reused:** the instance's backstop armed first and re-armed from `LaunchTime`; `--instance-initiated-shutdown-behavior terminate`; the sweeper's `study-deadline` tag, set to `LaunchTime` + 8,695 s by convention (30 s after the evidence phase); the laptop's EXIT, INT and TERM traps calling `spot_terminate`, intended to wait for `terminated` until `LaunchTime` + 9,025 s (the stop plus 300 s) and print TERMINATION UNCONFIRMED otherwise; the sweeper acts only on its own schedule, so the tag bounds when it may terminate, not when it will.
The inherited `spot_terminate` does **not** enforce that deadline today: its `aws ec2 terminate-instances` call has no timeout of its own, and its polling deadline starts only after that call returns (`hack/lib/spot-run.sh:203`), so a stalled call delays the warning by as long as it stalls.
Bounding the call and the polling by the remaining absolute deadline is new work (Implementation, item 7), and the deadline is a target until it is done and rehearsed against a stalled and a failed call.
The in-session aborts (driver, cancellation, contaminated card) shut the instance down at once.

**Account constraint.** The SCP `deny-instance-family` in this repository's configuration allows only `t3.*`, `g4dn.*`, `g5.*` and `g7e.*`; that is the committed policy, not a reading of what is attached live today.

## What it does not show

- **Not a defect-detection rate**, and no score of any kind: statuses are transcribed, not classed.
- Not that the card is healthy: it has no known fault.
- Not whether `-r 1/2/3` would flag a real Xid 48, 63/64, 79 or 94/95, degraded memory, a thermal throttle or a downtrained PCIe link: nothing was induced.
- Not a level's isolated cost: the durations are observations in one registered order on a card whose state carries from run to run.
- Not that nothing else touched the card: only foreign compute processes in valid samples at a 2 s cadence, and other host engines once, are checked.
- Not the full kernel history of the boot: only the lines the journal still holds.
- Not a fleet statement: one instance, one card, one driver, one DCGM version, one day.
- Not anything about the platform: no exporter, operator, taint or workload runs, and DCGM 4.4.2 is not what the platform's exporter uses (3.3.9).
- Not about EKS, multi-GPU nodes, NVSwitch, MIG, or H100/B200 diagnostics.

## Implementation work this page needs, none of which exists today

1. A new runner, hack/dcgm-diag-session.sh, with host preparation and Part 1 as phases, reusing the gpu-fault runner's refusals, launch, termination chain and sweeper tag.
2. Host preparation (the `nvidia-ctk` check, runtime configure, Docker restart, the GPU-in-a-container check) and the Part 1 procedure: the engine container, its log and its PID, the discovery check, the diagnostic invocation with its per-run stats path, limits and slots, the engine-kill cancellation, the three-state residual check with the engine's state read first, the isolation monitor with sample validity, before and after rows, the driver contract and the cancellation preflight.
3. Per-run upload with retries and the `MANIFEST`, and the laptop's prefix sync and hash check.
4. The new refusals above, each with a bent-copy test.
5. The two price constants, and the sweeper check over every datapoint (the second is also a defect in the inherited gpu-fault runner, to be fixed there separately).
6. A transcriber that reproduces the transcription rule on the archived bytes, tested on the no-GPU fixture (the error envelope must come out INVALID (output)), on `{}`, `null`, an array and a document with no test (each INVALID (output)), and on hand-built documents in the source's structure with a test lacking results and summary (a valid shape, not a departure), a result whose entity does not join, a document with no `entity_groups`, and a result outside `gpu:0`.
7. A bounded `spot_terminate`: the `terminate-instances` call and the polling both limited by the remaining absolute deadline, tested against a stalled call and a failed one.

## Free rehearsal, before anything is bought

Each item needs no GPU and no AWS spend, and none is a result of the study.
1. **Read the diagnostic image, with an archived transcript.** Done on 2026-11-04 (`hack/dcgm-diag-inspect-image.sh`, `hack/dcgm-diag/2026-11-04-image-inspection`). The script checks the raw index's hash and the registry's digest header against the pinned digest before running the image by that digest; it fails if a required step exits non-zero or prints nothing, if a plugin directory lists no library, if any strings extraction fails or finds nothing, and if a probe expected to fail without a GPU did not run (exit 124, 125 or 126) or did not print the failure it is for; and it refuses an existing output directory. `hack/test/check-dcgm-diag-inspect.sh` shows three of those failures and archives their transcripts in `negative-tests/`: a wrong pinned digest (exit 1), an existing directory (exit 2), and a probe Docker could not run, stubbed to exit 125 (exit 1). It is re-run before registration if the tag's index digest has moved.
2. **The engine and the residual check, on the laptop.** `dcgm-he` started without a GPU, a `sleep` started through `docker exec` and killed past a short limit with the engine container, the engine restarted; the `docker top` header and rows and the `docker inspect` states for a running, stopped and removed container (their real shapes are archived in `negative-tests/docker-top-states.txt`), and with `nvidia-smi` replaced on `PATH` by stubs: (a) no rows, exit 0, and the next run starts; (b) one foreign row, and the contaminated-card abort follows; (c) exit 9, and the same abort follows as **unreadable**.
3. **Isolation sample validity.** A stub that alternates valid and failing samples, and one that fails for 12 s: the first leaves the run verified, the second marks it isolation unverified.
4. **Refusals on bent copies, one at a time on a clean tree.** Image digest absent, `nvvs` or CUDA 13 plugins absent from the committed inspection, wrong instance type, wrong AMI ID, expected driver absent, credentials too short at the late re-read, a sweeper answer with two out-of-order datapoints one of which has an error: each must print `SESSION REFUSED` and exit non-zero before any AWS call that spends. The driver contract, an in-session abort, is shown against a stubbed `nvidia-smi` printing another version and another CUDA major version.
5. **Recovery.** A stubbed S3 that drops one run's upload and corrupts another's file: the laptop must report one NOT-RECOVERED for each, and the rest intact.
6. **All seven slots at their full allowances.** The runner, against stubs, with every part of every slot made to use its whole allowance: every registered run must start, and the phase must end inside its 7,135 s.
7. **Cost and timing arithmetic, re-done from the new runner's constants** rather than from this page's.

## Deferred, not registered

Each needs its own design and its own attack before it is registered, and none is implied by this study's result.

| deferred | why |
|---|---|
| the re-admission runbook (hold, incident capture, drain, decide, return or keep) | each review found new operational gaps in it (r4 five blockers, r5 twelve), and it cannot be written against a diagnostic whose output, test list and card identity nobody here has seen; this study supplies that first |
| exercise Z and exercise A on the real card (injected fault, displaced workload, readmission, acknowledgement) | they need the runbook above, a kind platform on the instance, and the exporter upgrade below; r5 found Z's return and cleanup orders contradictory |
| the hold and return rules (the `diag-hold` taint, the decision rule's ECC, Xid, retirement and identity terms) | the identity term needs to know what the diagnostic names a card by, and the journal term needs a cursor-survival check (r5) that is not designed |
| the `NodeHealth` freshness wait before return | r5 found it can pass on stale controller state when listing `NodeHealth` objects fails (`internal/controller/gpufault_source.go:238`); it belongs to the runbook |
| the exporter upgrade to DCGM 4.4.2 (`nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.1-ubuntu22.04`) | the runbook's platform half would need the exporter and host engine on one version that has CUDA 13 plugins; it changes what the platform reads and needs its own rehearsal that it still serves the fault fields |

## Review dispositions for this revision

The fifth review's twelve findings, against this narrowed page:

| r5 # | finding | disposition |
|---|---|---|
| 1 | the freshness wait can approve stale controller state | moot after narrowing: the wait is deferred with the runbook |
| 2 | the engine check read the wrong stream; the script merged stdout and stderr | accepted and verified: the script now keeps them apart, and the re-run shows the connection error on **stdout**, before the JSON, with stderr empty; the check reads stdout |
| 3 | cleanup could pass while a diagnostic child with another name survived | accepted: the residual check now requires no descendant of the engine in `docker top`, and any compute PID other than the engine's |
| 4 | failed isolation queries had no outcome | accepted: only valid samples count; failed or malformed ones are kept and leave the run isolation unverified |
| 5 | level 3's time was not reserved | accepted and re-derived: `-r 3` runs first and the phase is sized to every slot's worst case (Cost) |
| 6 | the test list, status vocabulary and schema were undefined | accepted: read from the first real output under the transcription rule above, frozen now; nothing is classed or scored |
| 7 | the diagnostic's target was broader than the identity rule | accepted and verified: `-i gpu:0` is explicit, and the no-GPU error then names `entities gpu:0` instead of `*,cpu:*` |
| 8 | a readable journal does not show uninterrupted Xid coverage | moot for scoring after narrowing (no rule reads the journal); the kernel row is narrowed to "the lines the journal still holds" |
| 9 | exercise Z's return and cleanup orders contradicted each other | moot after narrowing: Z is deferred |
| 10 | interruption recovery had no protocol | accepted: per-run upload with retries, a `MANIFEST`, prefix sync, hash checks and NOT-RECOVERED |
| 11 | the archive did not tie the index digest to the inspected image, or list `nvvs` directly | accepted and verified: the raw index, its sha256 and the registry's digest header are archived, its amd64 entry is the inspected image, and `executables.out` and `plugins.out` list `nvvs` and every plugin with hashes |
| 12 | the execution gates had not been completed | accepted as status: the free rehearsal items above are not done, and the page is not registered until they are |

The sixth review's findings, against this revision:

| r6 # | finding | disposition |
|---|---|---|
| 1 | the inspection's stdout files were not committed (`*.out` is ignored) | fixed in `fc4f46b8` with a `.gitignore` negation; all files of the archive are tracked |
| 2 | the transcription rule could miss tests and lose each result's entity | accepted and verified against NVIDIA's 4.4.2 source: the rule now walks the source's structure, keeps every result with its entity, joins it to `entity_groups` for the serial, and lists tests with no result record and expected tests that are missing |
| 3 | the worst-case budget left out uploads, hashing and the second kill wait | accepted: the slot names every bounded part (295 s then, 325 s after r7 #1), and the phase, credentials, allowance and termination times are re-derived from it |
| 4 | `docker top`'s header made the literal check unreadable, and a stopped engine had no affirmative check | accepted and verified on 2026-11-04: the header `PID PPID COMMAND` is checked as the first line, `docker top` exits 1 on a stopped container, and the engine's state is read first with `docker inspect` |
| 5 | host preparation had no container-runtime setup or `--gpus all` check | accepted and verified from run 3's archive: the AMI has `nvidia-ctk`, the run configured Docker's runtime; both steps and a GPU-in-a-container check are registered |
| 6 | the inspection script could pass with failed steps and did not check the digest | fixed: any failed step fails the script, and the digest is checked before anything runs; shown red with a wrong digest |
| 7 | the engine kept no log and the stats path was the working directory | fixed: the engine logs at `ERROR` to a per-start file, and each run has its own stats path; the debug log is encrypted by the tool and archived unread |
| 8 | the image size and the image's CUDA toolkit were not archived | the size is now archived (`size_bytes`); the image-CUDA row is narrowed to the DCGM packages and plugin directories, not a toolkit version |
| 9 | outcome contradictions; `{}` or `null` could be RESULT | fixed: a failed discovery is INVALID and not started, and `{}`, `null`, arrays and documents with no test are INVALID (output) |
| 10 | the expected cost and termination times read as more precise than their sources | narrowed: each estimate names its source or says assumed, and the sweeper's tag bounds when it may act, not when it will |

The seventh review's findings, against this revision (r6 #3 and #6 above were only partly closed; r7 found what was left):

| r7 # | finding | disposition |
|---|---|---|
| 1 | each later run's before rows and checks were outside its slot | fixed: they are the slot's first 30 s (325 s overhead); the phase, allowance and credentials are re-derived; a full-allowance rehearsal of all seven slots is required (free rehearsal item 6) |
| 2 | host preparation started its clock before boot and source retrieval | fixed: 300 s for them, against run 3's measured 95 s from `LaunchTime` to user-data |
| 3 | the inherited `spot_terminate` does not enforce the stated deadline | accepted and verified (`hack/lib/spot-run.sh:203`): the deadline is now stated as a target, and bounding the call is implementation item 7 |
| 4 | the inspection's success did not mean every inspection succeeded (probes, an empty plugin list, the strings block) | fixed and shown: probes must run and print their expected failure, plugin libraries are counted, each strings extraction is checked and recorded; doing so caught a wrong pattern of my own (3.3.9's key is `"DCGM GPU Diagnostic"`); `hack/test/check-dcgm-diag-inspect.sh` archives a probe stubbed to exit 125 failing the inspection |
| 5 | the transcription rule called a valid producer shape a structural departure | fixed: absent `results`, `test_summary` or `entity_groups` is valid; a departure is only a missing or non-array `test_categories`, a test without a name, or a present field of the wrong type |
| 6 | demonstrations and some claims were not in the archive | fixed: the negative tests and the `docker top` states are archived under `negative-tests/`; every exit-status file is now written; the "newest image" wording and the entity claim are qualified (3.3.9 rejects `gpu:0`) |
| 7 | the expected list cannot show completeness | accepted: it is the observed comparison set, and completeness is reported as unknown |

## Decisions for the owner before this is registered

1. Approve the narrowed study: Part 1 only, DCGM 4.4.2, no platform objects.
2. Approve $3.03 as the one-attempt operating allowance (expected about $0.54 at the 2026-11-01 prices, under the assumptions named in Cost), and say whether a second attempt is pre-approved on a void first one.
3. Approve the implementation work and the free rehearsal above as the scope before any purchase.
4. Name another AMI if not `ami-097edab977037f65f`.
