# Why fixed-S kept its tail at long in C3's block 2 — exploratory

Written 2026-10-26, after C3's main study was scored (`2026-10-25-c3-headroom-main.md`, "Result, 2026-10-26").
**Exploratory.** The question was chosen after seeing the result, nothing here was registered, and nothing here revises the registered verdicts or extends what they license.
It reads the three sessions' archives (release `evidence-c3-main-2026-10-26`) and replays the gate's model; it bought nothing.
Every figure below I re-derived from those files; astra's cold attack on the first draft is reconciled at the end.

## The question

The main study's primary verdict pools three blocks.
At long, fixed-S's per-block upper p99 was 1,393, 479 and 1,509 ms, against hold-cap's 414, 405 and 480: in block 2, seed 892, fixed-S's tail stayed near hold-cap's.
Block 2's d(long) also cleared S = 1,680.4 ms by the least, 42.3 ms against 81.2 and 75.3.
Is block 2 noise, an effect of that smaller margin, or something else?
None of this is a verdict on fixed-S: the registered lines hold for it everywhere, and at long its pooled tail was still at least 16% below off's.

## What the replay says

**Before purchase, the gate's replay already split the seeds this way** (`replay-per-seed.tsv`, from the committed `gate-*.json` and `sensitivity-gate-*.json`).
At the gate's frozen nominal pace, 1.0275, it gave fixed-S at long 1,610, 470 and 1,548 ms for seeds 882, 892 and 893.
At each card's pace measured after the sessions (1.0306, 1.0304 and 1.0269 at long, `card-pace-main.jsonl`) the same model gives 1,522, 496 and 1,587 ms (`replay-substitution.tsv`); the cards measured 1,393, 479 and 1,509.
Those paces are inferred from hold-cap's prefill median, not from fixed-S's own execution.

**Across seeds, the margin alone does not order fixed-S's tail.**
Seed 892 keeps it at 555 to 647 ms at paces 1.045 to 1.05, where its d(long) clears S by 72 to 77 ms, close to the 81 and 75 ms blocks 1 and 3 measured;
seeds 882 and 893 reach 791 and 1,048 ms at pace 1.0, where theirs clears S by 12 ms.
Within each seed the tail broadly rises with the margin, not monotonically (seed 882: 954 ms at 1.005, 817 at 1.01).
This shows the margin is not sufficient to explain the split; it does not show the smaller margin contributed nothing.

**In the model, the contender schedule decides the split and the premium schedule moves it** (`replay-substitution.tsv`).
Each seed's contenders were replayed under every seed's premium schedule, at the contenders' card's pace.
Seed 892's contenders give 496 to 569 ms under all three; seed 882's give 1,197 to 1,781, and seed 893's 1,550 to 1,670.
So the premium arrivals shift the tail by up to about 580 ms, and do not change which side of the split a contender schedule lands on.

## What the sessions show

**The queue is the trace's.** The queue a 1,680.4 ms spacing builds from the contender arrivals alone, with no engine (`trace-queue.tsv`), holds 116, 94 and 109 of the 172, 148 and 163 contenders and makes the longest wait 8,870, 4,501 and 9,868 ms;
the gateway measured 116, 94 and 109 held, and 8,878, 4,507 and 9,882 ms (`measured-queue.tsv`).
Its longest run of back-to-back admissions is 16, 9 and 27 contenders.

**In the engine, at most two contenders prefill at once in every block** (`engine-steps.tsv`, from the step log: a contender owed prompt tokens in a step is prefilling in it).
A long prefill takes longer than S, so a contender admitted back to back starts before the previous one has finished.
What separates the blocks is how often that happens: steps carrying two contenders' prompt work number 328, 79 and 364, and in 258, 50 and 312 of them the two filled the whole 512-token budget with no premium prompt work in the step.
The gateway sees three admitted contenders awaiting first content at once in blocks 1 and 3; the third has not started in the engine.
Premium requests waiting more than 1,000 ms from arrival to first content, a measure of mine and not the registered endpoint: 118 of 3,917 (3.0%), none of 3,887, and 153 of 3,942 (3.9%).

Two contrasts from the same sessions:
- size-aware at long spaces contenders 1,830.8 ms apart, above its own median long prefill in every block (1,732.7, 1,656.0 and 1,739.9 ms) but not above all of them: 10, 3 and 23 of its contenders took longer, and block 3's p95 was 1,863.8 ms. It had two contenders' prompt work in 2, 0 and 6 steps, two of them crowding out premium work, and no premium request past 1,000 ms;
- hold-cap admits the next contender once the previous one releases at first content. The engine never had two of its contenders prefilling; the gateway's view overlaps them for 1.4, 0.2 and 1.7 ms in all.

## Reading

Block 2 was not a chance outlier in the model's terms: the replay, frozen before purchase, put seed 892 on the other side of the split, and the measured cells agree with it.
What the evidence is consistent with: where S is shorter than the long prefill, a contender schedule whose bursts keep the spacing's queue busy for long runs puts two contender prefills in the same steps often, those steps leave no room for premium prompt work, and once more than 1% of premium requests are caught that way, the p99 is set by them.
Seed 892's contender arrivals came in shorter bursts, and its cell had a fifth to a sixth as many crowded steps.

That is an account, not an identified cause. It rests on three sessions and a model, and the burst lengths 16, 9 and 27 are three points.
They are confounded with each seed's contender count (172, 148, 163) and its margin over S, and the sessions differ also in their premium schedules, decode load and the gaps that let the queue drain, their card (one per seed) and their cell order.
For the registered result, it says what the pooled verdict hides: hold-cap's large advantage over the frozen spacing at long appeared on the two seeds whose contender schedules kept that spacing's queue busy, and not on the third.
A confirmatory test would register the contender schedule's burst structure as the factor, with traces built to vary it at a fixed margin and a fixed premium schedule, and is not proposed here.

## astra's cold attack, reconciled

astra (`gpt-6-astra`, high) attacked the first draft cold, from the page and the archives, with no pointer to what to check (`data/2026-10-26-c3-block2/astra-attack-prompt.txt`, its reply `astra-attack.txt`).
I re-derived each finding before acting on it, and all seven hold:
1. The draft's "three contenders in prefill at once" was the gateway's proxy; the step log shows at most two in every block. Replaced by `engine-steps.py` and the crowded-step counts, which I reproduced as astra gave them (258, 50, 312).
2. "Not noise" and "the margin is not what spared it" overreached, and confounds were missing. Softened; the confounds named; the premium substitution astra ran, reproduced and extended to every pair (`replay-substitution.py`).
3. The quoted predictions were all at pace 1.0306, not at each card's. Replaced by each card's pace (1,522, 496, 1,587, reproduced), with the frozen gate's 1.0275 figures beside them.
4. Run lengths counted the waits, one fewer than the admissions (16, 9, 27), and the draft listed the contender counts out of block order. Both fixed.
5. Size-aware's spacing exceeds the median long prefill, not every one (10, 3 and 23 longer; p95 1,863.8 in block 3). Fixed.
6. Hold-cap's gateway overlap is 1.4, 0.2 and 1.7 ms, not zero; the column now prints milliseconds.
7. "Fixed-S failed" read as a new verdict. Removed; the page states fixed-S's registered lines hold and its pooled tail at long was still at least 16% below off's.
These are astra's reading and my re-derivations; the figures on this page are mine.

## Files

`data/2026-10-26-c3-block2/`: `replay-per-seed.py`, `replay-substitution.py`, `trace-queue.py`, `measured-queue.py` and `engine-steps.py`, each with its `.tsv`.
The last three take the three blocks' `m5c-run` directories, in block order, from the release's assets; `replay-substitution.py` takes the gate's trace root, whose long traces are byte-identical to the archived ones.
