# Can the stock engine time an iteration — an instrument-validation registration

Date: 2026-10-05 · Registered **before** any card time is bought for it, and frozen from the moment the first cell is bought; later changes are appended as dated amendments.

**Why it exists.** The workload-queue predictor failed in the mixing of the two tenants (`2026-10-05-a-workload-queue-predictor-computational.md`), and the question it left is whether an admission controller should run an iteration-level simulator against measured parameters instead of applying a rule. That simulator cannot be trusted as it stands: its solitary decode step is `C0 + D` = 7.3 ms, while the median inter-token time of a request whose lifetime overlaps no other is 14.817, 14.861 and 15.495 ms on the card at 256, 2,048 and 8,192 tokens (269, 236 and 153 such requests in the R1 cells of the archives hack/m5c-20261004-164307, hack/m5c-20261005-015855 and hack/m5c-20261004-164415), yet it matched the card's TTFT tails within a few percent — two errors may be cancelling. Re-measuring its timing needs per-iteration records, and whether the stock engine can produce them is a question about an instrument, so it is answered first and on its own. **No simulator study is bought until this page passes.**

## 1. What the stock engine records — read in source

Every statement here was read in the v0.27.1 source by me and, independently, by codex `gpt-6-astra`; neither relied on the other's reading.

| Fact | Where, at tag v0.27.1 |
|---|---|
| `--enable-logging-iteration-details` logs one line per engine step: context requests and tokens, generation requests and tokens, `elapsed_ms`, KV-cache usage | `vllm/config/observability.py:73`, `vllm/v1/metrics/loggers.py:168-196` |
| "Context tokens" are the tokens **scheduled** in the step, later prefill chunks included — not a request's accumulated context | `vllm/v1/utils.py`, the function that computes the iteration details (read by astra) |
| No request id, no per-request context length | `vllm/v1/metrics/stats.py:171-182` |
| The timer starts **after** the batch is submitted and stops when its result is retrieved; scheduling and the scheduler update are outside it | `vllm/v1/engine/core.py:597-612` |
| With async scheduling — the default for these engine arguments — a step retrieves an already-overlapping batch, so `elapsed_ms` is a residual wait, not a duration | `vllm/config/vllm.py:540-550,1095-1143`; `vllm/v1/engine/core.py:625-714` |
| The single-GPU executor runs `execute_model` inline even when asked not to block, so in synchronous mode host-side input preparation and kernel launch are also outside the timer | `vllm/v1/executor/uniproc_executor.py:96-105` |

So `elapsed_ms` is a **partial window** in either mode. Turning async scheduling off removes the overlap, not the missing boundary. The paid runs so far passed no async flag (applied-values.tsv in the archive hack/m5c-20261005-015855), so they ran the async default; the resolved value was not recorded.

## 2. The configuration, and what it costs

Profiling and every later validation cell run with `--no-async-scheduling` and `--enable-logging-iteration-details`, everything else as in the paid runs: Qwen2.5-3B, `--max-num-batched-tokens=2048`, `--max-num-seqs=64`, prefix caching off, CUDA graphs and compilation left on (`--enforce-eager` disables both and is not used).

**What a pass can say is about that synchronous engine.** It says nothing about the async engine the earlier archives measured, and those archives are not pooled with anything bought under this page. An async control is bought once, published, and never used to fit or correct anything.

## 3. The independent clock

`elapsed_ms` is checked against the client, which timestamps send, first token and end for every request.

- **Prefill steps.** A request sent into a drained engine runs alone. Its client TTFT minus the summed `elapsed_ms` of its context steps is `a + b·k`, where `k` is its number of context steps (one at 256 to 2,048 tokens, four at 8,192), `a` is the fixed request-path delay and `b` the per-step time the timer omits. The engine counts exactly 256, 2,048 and 8,192 input tokens for those prompts (`engineInputTokens` in the raw rows), so at a budget of 2,048 the six lengths take one, one, one, one, two and four context steps, and two distinct step counts above one identify both.
- **Decode steps.** In the same lone request, the client's median inter-token interval minus the median `elapsed_ms` of its generation steps is the per-decode-step omitted time `b'`. A constant transport delay shifts arrival times and not their spacing, so it cancels here; it does not cancel in the prefill equation, which is why `a` is fitted there.

Requests are attributed to log lines by order: in a drained serial episode each request's lines are a run of context lines followed by generation lines, and the next request starts the next context run. A count that does not match `ceil(L / 2048)` context lines and `outputTokens − 1` generation lines refuses the episode.

## 4. The first session

One g5.2xlarge, one engine, cells of about 180 s of replayed episodes. Within each block the cell order is randomised.

| Cell | Engine | Logging | Episodes |
|---|---|---|---|
| S-on | sync | on | **serial** — one request at a time, drained between: lengths 256, 512, 1,024, 2,048, 4,096, 8,192 × output caps 1, 16, 64 |
| S-off | sync | off | the identical serial trace |
| B-on / B-off | sync | on / off | **bursts** — homogeneous, drained between: 1, 4, 16 concurrent at 256, 2,048, 8,192 tokens, and 64 at 256 |
| T-on / T-off | sync | on / off | **staggered, one tenant** — 1, 4 or 16 decoders established at a fixed context, then a 256-, 2,048- or 8,192-token prefill introduced |
| A-off | async | off | the serial, burst and staggered traces once each, published only |

Three complete blocks of the six sync cells, then the three async cells: **21 cells**. The traces are generated and frozen before launch, and each block replays the same bytes.

## 5. The gates, fixed now

| Gate | Criterion | Refusal |
|---|---|---|
| **I1 logging overhead** | For each episode type, the paired on/off change across blocks: median client TTFT and median inter-token time within ±2%, client p99 TTFT within ±5%, each as a 95% episode-bootstrap interval | an interval outside, **or one too wide to decide** |
| **I2 accounting** | No missing or repeated iteration index; every serial request's context and generation line counts as in section 3; no failed request; no preemption | any one |
| **I3 timing completeness** | The section-3 fits explain client time: residual of `TTFT − Σelapsed − a − b·k` within 5% of TTFT for every serial setting; `b'` stable within 5% across lengths | any setting outside |
| **I4 context** | In bursts at the same `(P, n)` and different decoder context, mean `elapsed_ms` per step differs by at most 5% — if not, the timing family must carry a context term, and only design-known contexts (homogeneous bursts) may fit it | published; decides the family, does not fail the page |
| **I5 stability** | The first and last blocks' serial medians within 5% | any setting outside |

**I1, I2, I3 and I5 all pass:** the synchronous engine's records, with `a`, `b` and `b'` added back, time an iteration. The next registration fits the timing family astra proposed and section 6 records — intercept, piecewise-linear prefill with knots at 256, 512, 1,024 and 2,048, decode terms in `n` and `n²`, a prefill–decode interaction, and a context term if I4 requires it — on held-out episodes, and calibrates the simulator study computationally before any shared cell is bought.

**Any of them fails:** the stock records cannot time an iteration on this engine. No simulator study is bought. A patched engine that records request-level step membership is a separate decision, with its own cost, put to the user.

## 6. Who established what

The source facts in section 1 were read by both engines independently. The decode discrepancy (7.3 against 14.8 ms) is astra's observation and my measurement from the raw rows. The timer's boundary in synchronous mode (`uniproc_executor.py`) was astra's finding, which I then read myself. The prefill clock in section 3 — regressing `TTFT − Σelapsed` on the number of steps — is mine; astra's position was that client cadence cannot separate engine time from transport, and the decode clock above is restricted to spacing for that reason. The I1–I5 bounds are astra's proposal, adopted; they are registration choices, not facts about vLLM.

## 7. What this cannot establish

- Anything about the async engine, or about any other model, card, batch budget or vLLM version.
- That the timing family fitted afterwards is correct; this page only establishes that its inputs are measured.
- Per-request context lengths in mixed traffic. The records do not carry them; only episodes whose contexts are known by construction can supply them.

## Amendment, 2026-10-05, before any cell is bought — the cells are sized by cycles, and I1 is defined per setting

**The staggered design as registered does not fit in a cell.** Under the spacing rule the episode generator uses — the gap after an episode is the larger of 2 s and twice a conservative bound of its duration, 270 ms per 2,048-token chunk plus 30 ms per output token — one cycle of the 27 staggered episodes takes 619 s, so a cell of about 180 s would contain under a third of the settings. The bursts take 102 s a cycle. Two changes, both made before anything was bought:

| | Registered | Now |
|---|---|---|
| Staggered episodes | 1, 4, 16 decoders × context 256, 2,048, 8,192 × prefill 256, 2,048, 8,192; decoder cap not fixed | 1, 4, 16 decoders × context 256, 8,192 × prefill 256, 8,192 = **12 episodes**; decoders capped at 128 output tokens, the prefill at 16 |
| Cell length | about 180 s | **exactly three complete cycles**, each its own seeded permutation: serial 18 episodes, 54 s a cycle; bursts 10, 102 s; staggered 12, 202 s; replay durations 180, 330 and 630 s |

A decoder capped at 128 tokens outlives the longest prefill it is staggered against: an 8,192-token prefill beside 16 decoders takes five mixed steps. Every setting now appears three times in every cell, so every block measures the same settings the same number of times. The 21 cells replay for about 2.2 hours in total.

**I1 as registered is not well defined.** "Median and p99 client TTFT for each episode type" pools settings that differ by a factor of 25 in TTFT: a pooled p99 of the serial cell is an 8,192-token request's, and a pooled median can fall in the gap between two lengths. I1 is therefore taken **per setting** — a setting is an episode's parameters and the request's role in it (a decoder or the staggered prefill):

- `d(s, b)` = log of the ratio of the logging-on cell's median to the logging-off cell's median over setting `s`'s three requests in block `b`, separately for client TTFT and for inter-token time (requests with at least two output tokens).
- **I1 passes** when, for each episode type and each of the two quantities, the 95% interval of the mean of `d` over settings and blocks — 2,000 bootstrap resamples of requests within each setting and cell — lies within ±2%, **and** every setting's mean of `d` over the three blocks lies within ±5%. An interval wider than the bound refuses, as registered.
- The p99 bound is replaced by the per-setting bound: three requests per cell cannot estimate a p99, and the per-setting bound is what catches an overhead that falls on one kind of step.

**Is that decidable, before buying.** From the requests in the R1 cells of the three async archives whose lifetimes overlapped no other — 269, 236 and 153 of them at 256, 2,048 and 8,192 tokens — drawing three per cell for three blocks, with no true difference, the 95% range of one setting's mean `d` for TTFT is ±2.1%, ±0.4% and ±0.1%, and of the mean over six settings ±0.9%, ±0.2% and ±0.04%; for inter-token time one setting's range is ±0.03%, ±0.03% and ±0.04%. So a null logging overhead passes the ±2% pooled bound and the ±5% per-setting bound with room. This uses the async engine's dispersion as a stand-in for the synchronous engine's, which is an assumption, and the gate refuses rather than passes if the synchronous engine turns out noisier.

**I3's decode clause, made exact by the evaluator.** "`b'` stable within 5% across lengths" did not say 5% of what. `b'` is the difference of two medians a few milliseconds apart and may be near zero, so a ratio of `b'` to itself would refuse noise. `hack/tail-crossing-model/instrument_gates.py` reads it as: the widest spread of `b'` across lengths, in any serial-log cell, is at most 5% of the median inter-token time of the serial-log cells. Its prefill clause takes the largest single-request residual, which is stricter than "every serial setting". I4 is not computed by that script; it is published from the burst logs and gates nothing.

## Amendment, 2026-10-05, before any cell is bought — the decode clock is a regression, and the episode must be shown drained

An independent review of the evaluator by codex `gpt-6-astra`, run without instructions on commit `551e147`, found three defects; I reproduced each before changing anything.

- **Section 3's decode clock compared mismatched statistics.** It set the client's mean spacing against the median logged step, so one decode step 150 ms slower, seen by both clocks, moved `b'` from 1.5 to 11.5 ms. The client also stamps a request's end after the stream's usage chunk and `[DONE]` (`internal/bench/httpsender.go`), not at its last token. The decode clock is now the prefill clock's twin: per length, `end − first token − Σ generation elapsed` is regressed on the number of generation steps, the slope is `b'` and the intercept the end delay. The serial output caps of 1, 16 and 64 give zero, fifteen and sixty-three steps, so both are identified at every length.
- **A failed request was dropped rather than refused**, which left the accounting consistent and the fit clean. It is refused, as I2 says.
- **Drained was assumed from the order of sends.** A request queued behind its predecessor still produces lone steps in order, and its queueing would be booked as omitted engine time. A serial episode in which any request is sent before its predecessor's end is refused.

Each fix has a self-test case that fails when the fix is reverted.

## Amendment, 2026-10-05 — what is bought, before it is bought

The user approved the purchase on 2026-10-05. Written before the session is launched:

| | |
|---|---|
| Session | one g5.2xlarge spot instance, `hack/m5c-gpu-session.sh`, `PURPOSE=new-measurement` |
| Cells | `REPS=3`, the nine arms: three blocks of the six synchronous arms, each block in its own order, then the three async arms once — 21 cells |
| Traces | one trace per episode type, seed 11, replayed in every block and by all three modes of that type (`TracesVaryByRepetition` is false, as section 4 says); 54, 381 and 288 requests per serial, burst and staggered trace, every setting exactly three times, checked by `PLAN_ONLY` with the real binary |
| Lengths | 256, 512, 1,024, 2,048, 4,096 and 8,192 tokens, resolved inside the pinned serving image; the three already in the table reproduced byte for byte |
| Deadline | `HARD_STOP_SECONDS=27000`, `BACKSTOP_SECONDS=27600`. The cold projection before any cell is 394 minutes (8 minutes beyond each cell's replay, plus 20%); replay alone is 133 minutes, and the earlier sessions spent about 3 minutes per cell beyond replay, so about four hours is expected |
| Cost | expected about $3 at the $0.68–0.70 spot price of 2026-10-04/05; bounded by the script's $1.10/hour cap and the backstop at about $8.40 |

**Stopping rule.** One session. The evaluator `hack/tail-crossing-model/instrument_gates.py`, as committed before launch, is run once on what comes back, and its verdict is the answer. A failed gate is not re-bought to make it pass. A session that ends early — the deadline, a spot reclaim, a refusal — is reported as incomplete with what it did produce, and buying again needs a further amendment saying why.

**Rehearsed on kind before launch.** `IV=1 hack/test/rehearse-m5c-matrix.sh` ran `serial-log`, `serial-nolog` and `serial-async` end to end on a stub engine that answers vLLM's three flags the way v0.27.1 does: each cell deployed its own engine, the recorded process line showed that arm's configuration, the logged cell's 432 iteration lines (54 requests × one context and seven generation steps) passed `iterlog.py`'s accounting, and the two unlogged cells held none. Its first attempt was refused after the first replay because the stub labelled the exclusive engine `vllm-shared` where `config/vllm/deployment.yaml` says `vllm`, so the harness found no pod to read restart counts from — a stub that differed from the real manifest, fixed in the stub. What the rehearsal does not cover: the burst and staggered lengths, any number, and real vLLM's own output.

## Amendment, 2026-10-05, during the session and before any burst or staggered cell is read — a request's role in a burst is its rank

**I1 as amended above could not pass on bursts.** It took a setting to be an episode's parameters and the request's role, and gave every request of a burst the same role. They are not alike: the sixteenth request of a 16 × 8,192 burst waits for fifteen prompts, and the engine, not the trace, decides which request that is. A bootstrap that resamples them moves each median between positions. The fit code's author, a Claude subagent, reported it from its synthetic archives; I reproduced it in `instrument_gates.py` with bursts whose TTFT grows with a randomly drawn admission position and **no overhead**: the burst TTFT interval was ±14% and I1 failed. My decidability check in the earlier amendment drew only lone requests, which is why it missed this.

**A request's role inside a burst, or among a staggered episode's decoders, is now its rank by TTFT within its episode.** Each setting then holds one value per cycle, as a serial setting does, and the same reproduction gives an interval of −0.17% to −0.01%. The self-test pins that case, and reverting the ranking turns it red.

**What had been read when this was decided.** Only serial cells of block 1: the client TTFTs of `serial-nolog` (to confirm the engine reported `'async_scheduling': False` and every request succeeded) and the iteration log of `serial-log` (format and accounting only — `iterlog.py` parsed its 1,494 lines, found the indices contiguous and attributed all 54 requests; no clock fit was computed). No burst or staggered cell had been opened, and the change touches only how those cells are grouped.

**And the ranks of one episode are resampled together.** An independent review by codex `gpt-6-astra`, run without instructions on the change above, found that ranks resampled one by one are treated as independent although they move together when a whole burst is slower: with every cycle scaled alike in both arms, the ranked gate passed at about ±1% where resampling whole episodes gives about ±6%. I1's bootstrap now draws whole episodes — one index per episode type per cell, applied to every rank and, in a staggered episode, to its decoders and its prefill together. The self-test pins the case at a size where the two methods fall on opposite sides of the 2% bound (±2.7% against ±1.4% in its ten-setting archive), and resampling rank by rank turns it red. Still no burst or staggered cell had been read.

## Result, 2026-10-05 — the instrument fails I1 and I3; no simulator study is bought on these records

The session ran on one g5.2xlarge in ap-northeast-2d from about 17:54 to 21:16 KST and completed all 21 cells: every arm returned evidence, no request failed, no cell was refused. The archive is hack/m5c-20261005-085339. `instrument_gates.py` at `3b00eb1` — the evaluator as amended above — was run once on it:

| Gate | Result | Reading |
|---|---|---|
| I1 serial TTFT | **fail** | mean `d` +0.14%, 95% interval −2.45% to +2.68%: too wide to decide at ±2% |
| I1 serial inter-token | pass | +0.35%, interval +0.26% to +0.46% |
| I1 burst TTFT | pass | +0.53%, interval −1.19% to +1.51%; worst setting +4.2% |
| I1 burst inter-token | pass | +0.12%, interval +0.02% to +0.28% |
| I1 staggered TTFT | **fail** | +0.10%, interval −5.45% to +3.71%; worst setting (4 decoders at 8,192, prefill 256) −12.0% |
| I1 staggered inter-token | pass | +0.09%, interval +0.03% to +0.20% |
| I2 | pass | no failed request or preemption in any paired cell; every logged cell's iterations contiguous |
| I3 prefill clock | **fail** | `a` 10.4–10.8 ms, `b` 21.8–22.2 ms per context step; worst single-request residual 48.6% of TTFT |
| I3 decode clock | pass | `b'` 1.32–1.38 ms at every length; widest spread 0.057 ms against a 16.1 ms median inter-token time |
| I5 | pass | worst first-to-last drift 1.05% |
| I4 (published) | — | decode step at 8,192 against 256 tokens: +4.95% with 1 decoder, +15.6% with 4, +55.4% with 16 |

**The registered verdict is FAIL: I1, I3.** The evaluator as committed at launch (`b348f37`), run in a separate worktree for comparison, gives the same verdict; it differs only in the burst rows, where its pooled grouping gave ±14% intervals. As registered, the timing fit refuses on this archive (`timing_fit.py`: "the instrument gates do not pass on this archive (FAIL: I1, I3)"), no simulator study is bought on these records, and the failure is not re-bought.

**Diagnostics, after the verdict and not part of it.**

- **The first request of every cell is a cold engine's.** In all seven serial cells the request at position 0 — the same 2,048-token request, because every block replays the same bytes — has a TTFT of 453–456 ms against a median of 231 ms for its length, in the logged, unlogged and async engines alike. Its context step logged 201 ms, so the extra time is outside the timer. The harness deploys a fresh engine per cell and sends no warm-up request, and the registration did not exclude one. This single request is the 48.6% I3 residual, and it widens the serial I1 interval.
- **The omitted time is per prefill step, not a fixed delay plus a constant step.** Excluding that request, `TTFT − Σ context elapsed` is 24.9, 25.3, 27.0 and 29.2 ms for one-step prompts of 256 to 2,048 tokens, 52.6 ms for two steps and 98.4 ms for four (block 1 medians). The intercept is near zero and each prefill step leaves about 25 ms outside the timer, rising with chunk size, so the registered line `a + b·k` misfits the one-step lengths by up to 21% even without the cold request. A decode step leaves only about 1.35 ms outside it.
- **A staggered prefill's TTFT is bimodal.** In the worst setting the values fall near 69 ms or near 85 ms in both arms, apparently by where the prefill lands in the decoders' step cycle; three per cell cannot resolve 5% between two modes 23% apart. That, not the logging, is the −12%.
- **The logging overhead itself is small.** Every mean `d` is within 0.6% of zero, and of the intervals narrow enough to decide, none reaches ±2%; the serial inter-token time is 0.35% slower with logging, an interval that excludes zero — a real but small cost.

**What this leaves.** The records are internally sound — every iteration accounted for, the decode clock stable, no drift — but this registration could not certify them, for three reasons found only on the card: a cold first request, a clock whose form was wrong, and bimodal staggered settings measured three times. A second session would need a warm-up request excluded from analysis, a per-step prefill clock registered before the data, and more repetitions of the staggered settings. That is a new registration and a new purchase decision, not a re-run of this one.
