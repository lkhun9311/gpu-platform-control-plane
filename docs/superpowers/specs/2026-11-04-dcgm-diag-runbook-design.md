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
2. What evidence of the card's identity and history can be captured around them: driver version, the driver's supported CUDA version, the host's and the image's CUDA toolkits, GPU UUID, serial and PCI bus ID, ECC mode and counters (volatile and aggregate, single-bit and double-bit), retired or remapped rows if the card reports them, and the Xid lines the kernel journal still holds for the current boot?

It is **not** a question about defect detection, and **nothing in the output is scored**.
One card with no known fault cannot show that a diagnostic detects an unhealthy one, how often it misses, or how often it flags a good card.
Such a card can still receive a failing or warning result; that would be transcribed as printed, and it would not be a measured false-positive rate either.
No sensitivity, specificity, miss rate or re-admission rate is computed, quoted or implied by anything on this page.

## What is verified, and what is not (2026-11-04)

Archived by `hack/dcgm-diag-inspect-image.sh`, with no GPU and every container run with `--network none`, in `hack/dcgm-diag/2026-11-04-image-inspection`, one directory per DCGM version; every command's stdout, stderr and exit status are separate files (`<name>.out`, `<name>.err`, `<name>.exit`):
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
- **An explicit entity is honoured even without a GPU.**
  With `-i gpu:0` the error names `entities gpu:0` and "Detected driver major version 0 is not between the required versions 346 and 2000" (`diag-badhost-gpu0.out`); without it, the error names `entities *,cpu:*` (`diag-badhost.out`), so an unselected diagnostic would include CPU entities.
- **The no-GPU failure shape**, from the producer: `{"DCGM Diagnostic" : {"runtime_error" : "...", "version" : "4.4.2"}}` (`diag-default.out`).
  It is the fixture for the error-envelope check below and nothing else; a fixture of external output must come from the producer, and this is the only output the producer has given without a card.
- **What the JSON names a card by is not known.** The lower-case key strings in 4.4.2's `dcgmi` include `entity_id`, `entity_groups`, `serial`, `serial_num`, `device_id`, `results`, `tests`, `test_summary`, `warnings`, `info`, `error_id`, `error_category`, `metadata`, `runtime_error` and `driver_version`, and no `uuid` (`strings.txt`); strings found in a binary are not a schema.

Not verified, and found out only from the session's first real output:
- the `-j` output's nesting, its test names for each level, and its status words;
- whether that output carries the card's serial, UUID, or only an entity index;
- every duration, and whether `-r 3` completes on a g5.2xlarge inside its limit;
- the exact `dcgmi discovery -l` text, and so how its GPU 0 entry names the card;
- whether this card exposes ECC counters and retired or remapped rows, read from `nvidia-smi -q -d ECC,PAGE_RETIREMENT,ROW_REMAPPER` (the display names are confirmed by the session's first command, on the AMI's own `nvidia-smi`).

## The apparatus

One g5.2xlarge Spot instance, the pinned Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) `ami-097edab977037f65f` (run 3's, `hack/gpu-fault/2026-11-01-run3/session-provenance.txt`), and the diagnostic image above.
**No kind cluster, no operator, no exporter, no workload.**
The host runs only the evidence commands and the diagnostic's two containers.

### The host engine and the diagnostic

The diagnostic runs against an explicit host engine, so the engine it used is known and recorded rather than chosen by `dcgmi`:
- the engine is one long-lived container, `dcgm-he`, from the pinned image, started with `--gpus all --network none` and its own entrypoint (`/usr/bin/nv-hostengine`, `image.txt`), with its log bind-mounted out;
  its PID on the host is recorded at start;
- each diagnostic is `timeout -k 30 <L> docker exec dcgm-he dcgmi diag --host localhost:5555 -i gpu:0 -r <N> -j --debugLogFile /out/<run>.log`, its stdout, stderr and exit status kept as separate files on the host, `/out` being a bind-mounted directory;
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
Each run occupies a **slot** of `L` + 30 s (the kill wait) + 60 s (its before and after rows, the residual check, and an engine restart if one is needed), each part with its own timeout.
A run starts only if its whole slot fits before Part 1's phase end; otherwise it is **NOT-RUN**, which is not a failure.
When a run reaches `L`, killing the `docker exec` stops the client, not work the engine started for it, so the **engine container is killed**: `docker kill dcgm-he`, wait up to 30 s, then the host check below; if clean, a new `dcgm-he` is started for the next run, and that run is recorded as on a fresh engine.

After **every** run, timed out or not, the host checks three states, never two:
- **clean**: `pgrep -a nvvs` on the host exits 1 (no match); `docker top dcgm-he -eo pid,ppid,comm` (when the engine is up) lists only the engine process and no descendant of it; and `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` exits 0 and every line it prints, if any, is the engine's recorded PID;
- **residual**: any of them shows a process other than the engine;
- **unreadable**: any of the three exits with another status, or prints a line that is not a process row.

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
| image's CUDA | from the archived inspection (`packages.out`, `plugins.out`) |
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
1. **NOT-RUN**: it was not started (its slot did not fit, the card was contaminated, or the session aborted). Not a failure.
2. **INVALID (identity, engine or interference)**: the `nvidia-smi` read immediately before it does not show exactly one A10G with the session's UUID; the `discovery` check before it failed or did not contain that UUID; its stdout contains "unable to establish a connection"; or a foreign compute process appeared in a valid isolation sample.
3. **TIMED-OUT**: it reached `L` and was cancelled; reported as "not complete inside L", never as a time, whatever its output holds; a clean cancellation and a contaminated one are kept apart.
4. **INVALID (output)**: stdout, stderr and exit status were not all recorded; stdout is not exactly one JSON document; or that document is the error envelope, an object whose only member is `"DCGM Diagnostic"` holding a `runtime_error` (the shape of `diag-default.out`).
5. **RESULT**: otherwise, **whatever the diagnostic itself reported**.
6. **NOT-RECOVERED** replaces any of these when the run's files did not come back intact (above).

### Transcription rule, frozen now

The test list, the status vocabulary and the JSON's structure are **read from the first real output**, under this rule, frozen before launch; nothing is classified or scored before then, and nothing in this registration is scored after then either.
For each RESULT run:
1. Every member path of the JSON whose value is a string, number or boolean is listed with its value, in document order, so the whole document is transcribed with no field chosen in advance.
2. A **test record** is an object holding a member whose value is a string that also appears, as a test or plugin name, in the archived `diag-help.out` or as a plugin library name in `plugins.out`; each test record's name, every string member beside it, and its entity (any `entity_id`, `serial`, `serial_num` or `device_id` in it or its enclosing objects) are copied as printed.
3. Status words are copied as printed and **not classed**: no pass, fail, warn or skip is assigned by this registration.
4. Coverage is reported per level as the set of test-record names that appeared in each repetition, and the names present in one repetition and absent from another; a missing name is reported, never inferred to have passed.
5. The card the output names, if it names one, is reported beside the identity row: whether the output carries the serial or UUID `nvidia-smi` printed for index 0, and if so whether they are equal.

This is a transcription rule, not a parser of known field names: it can be applied by hand to the archived bytes, and a later parser may only reproduce it.
A later registration may class the statuses, using the vocabulary this output shows; it is not this one.

### Per level

- **REPORTED**: every registered repetition is RESULT (3 for `-r 1` and `-r 2`, 1 for `-r 3`).
- **PARTIAL**: at least one RESULT, fewer than registered.
- **UNJUDGED**: no RESULT.

A REPORTED or PARTIAL level reports the transcription, each run's wall time, the exec overhead, and for three runs the median, minimum and maximum (no mean, no interval, no rate).
No bar on any wall time is registered: NVIDIA's "~2 minutes" and "~15 minutes" are help text, and a bar picked from them would be the kind of guess `docs/11_WHAT_THIS_MEASURED.md` ("What the targets were based on") records the earlier ones to have been.

### The session verdict, exhaustive and ordered

1. `DCGM DIAG: NO-EVIDENCE` when no `MANIFEST` and no archive came back.
2. `DCGM DIAG: REFUSED` when provenance was never recorded, the readings disagree on the image, the driver or its CUDA major version did not match, or the cancellation preflight was not clean.
3. `DCGM DIAG: INCOMPLETE` when evidence came back but all three levels are UNJUDGED; the evidence rows are still reported.
4. `DCGM DIAG: RESULT` otherwise.

Whatever the verdict, all three levels' statuses are printed beside it.

## Cost

**Price read method.**
The runner reads `aws ec2 describe-spot-price-history` for g5.2xlarge `Linux/UNIX` at launch, records it in `spot-prices.txt`, and tries only zones at or under the $1.10 compute cap.
The price is **to be read** on the day; on 2026-11-01 the zones read $0.6769 to $0.6887 an hour (`hack/gpu-fault/2026-11-01-run3/spot-prices.txt`), a value from another day.

**Part 1's phase is sized to every run's worst case**, so no run can be starved by another's overrun:
- slots: `-r 3` 1,800 + 30 + 60 = 1,890 s; `-r 1` 300 + 90 = 390 s, three of them 1,170 s; `-r 2` 600 + 90 = 690 s, three of them 2,070 s;
- before the first run: the exec overhead 3 x 60 s, engine start and its discovery 60 s, and the first evidence rows 120 s, 360 s in all (each with its own timeout);
- Part 1 worst case: 360 + 1,890 + 1,170 + 2,070 = **5,490 s**.
`-r 3` runs first, so its slot ends by 360 + 1,890 = 2,250 s into the phase, **3,240 s before the phase ends**: the margin the fifth review found missing (its 1,803 s left against 1,830 s needed) is gone, because nothing runs before `-r 3` except the 360 s preamble.

**Phases, counted from EC2's `LaunchTime`** (conventions of this page; the new runner's constants supersede them, and the arithmetic is re-done from them before freezing):

| phase | ends at | contents |
|---|---:|---|
| host preparation | 900 s | evidence rows, the driver contract 120 s; image pull, its limit 600 s; cancellation preflight 120 s; 60 s guard |
| Part 1, diagnostics | 6,390 s | 5,490 s, above |
| evidence | 6,510 s | final archive and `MANIFEST` upload, 120 s |
| instance stop | 6,570 s | `shutdown -h now` from the instance's own backstop |

**Expected duration, by component** (estimates, not measurements): host preparation 163 s (the historical span's 2 min 43 s, `hack/m5c-gpu-session.sh:697`, a comment recording an older session's S3 timestamps; an over-estimate here, since no kind is built), image pull 120 s (assumed; the amd64 image is 1,838,673,451 bytes unpacked, `docker image inspect`, 2026-11-04), Part 1 2,220 s (the 360 s preamble, `-r 3` 900 s + 60 s, `-r 1` 3 x (60 + 60) s, `-r 2` 3 x (120 + 60) s, durations from the help text's "~ seconds", "~2 minutes" and "~15 minutes", the 60 s floor for `-r 1` assumed), evidence 120 s.
Sum: 163 + 120 + 2,220 + 120 = **2,623 s**.
At the 2026-11-01 zone prices plus the $0.0324 an hour of gp3 and IPv4: (0.6769 + 0.0324) x 2,623 / 3,600 = $0.5168, and (0.6887 + 0.0324) x 2,623 / 3,600 = $0.5254, so about **$0.52–0.53**, to be re-read at launch.

**Operating allowance, not a maximum:** (6,570 + 900) s = 2.075 h at the all-in $1.1324 = **$2.35**, conditional on the backstop, the sweeper or the laptop terminating the instance.
If all three fail, spending continues at up to $1.1324 an hour until a person notices.
Two attempts at the allowance are **$4.70**.
The owner's envelope for this item is $3 to $10 (`08-개발방향-재정렬.md`, section 6); a second attempt needs its own approval.

**Termination chain, reused:** the instance's backstop armed first and re-armed from `LaunchTime`; `--instance-initiated-shutdown-behavior terminate`; the sweeper's `study-deadline` tag (`LaunchTime` + 6,540 s); the laptop's EXIT, INT and TERM traps calling `spot_terminate`, which waits for `terminated` (to `LaunchTime` + 6,870 s) and prints TERMINATION UNCONFIRMED otherwise.
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
2. The Part 1 procedure: the engine container and its PID, the discovery check, the diagnostic invocation, limits and slots, the engine-kill cancellation, the three-state residual check, the isolation monitor with sample validity, before and after rows, the driver contract and the cancellation preflight.
3. Per-run upload with retries and the `MANIFEST`, and the laptop's prefix sync and hash check.
4. The new refusals above, each with a bent-copy test.
5. The two price constants, and the sweeper check over every datapoint (the second is also a defect in the inherited gpu-fault runner, to be fixed there separately).
6. A transcriber that reproduces the transcription rule on the archived bytes, tested on the no-GPU fixture (it must report the error envelope as INVALID (output)).

## Free rehearsal, before anything is bought

Each item needs no GPU and no AWS spend, and none is a result of the study.
1. **Read the diagnostic image, with an archived transcript.** Done on 2026-11-04 (`hack/dcgm-diag-inspect-image.sh`, `hack/dcgm-diag/2026-11-04-image-inspection`); re-run before registration if the tag's index digest has moved.
2. **The engine and the residual check, on the laptop.** `dcgm-he` started without a GPU, a `sleep` started through `docker exec` and killed past a short limit with the engine container, the engine restarted; with `nvidia-smi` replaced on `PATH` by stubs: (a) no rows, exit 0, and the next run starts; (b) one foreign row, and the contaminated-card abort follows; (c) exit 9, and the same abort follows as **unreadable**.
3. **Isolation sample validity.** A stub that alternates valid and failing samples, and one that fails for 12 s: the first leaves the run verified, the second marks it isolation unverified.
4. **Refusals on bent copies, one at a time on a clean tree.** Image digest absent, `nvvs` or CUDA 13 plugins absent from the committed inspection, wrong instance type, wrong AMI ID, expected driver absent, credentials too short at the late re-read, a sweeper answer with two out-of-order datapoints one of which has an error: each must print `SESSION REFUSED` and exit non-zero before any AWS call that spends. The driver contract, an in-session abort, is shown against a stubbed `nvidia-smi` printing another version and another CUDA major version.
5. **Recovery.** A stubbed S3 that drops one run's upload and corrupts another's file: the laptop must report one NOT-RECOVERED for each, and the rest intact.
6. **Cost and timing arithmetic, re-done from the new runner's constants** rather than from this page's.

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

## Decisions for the owner before this is registered

1. Approve the narrowed study: Part 1 only, DCGM 4.4.2, no platform objects.
2. Approve $2.35 as the one-attempt operating allowance (expected about $0.52–0.53 at the 2026-11-01 prices), and say whether a second attempt is pre-approved on a void first one.
3. Approve the implementation work and the free rehearsal above as the scope before any purchase.
4. Name another AMI if not `ami-097edab977037f65f`.
