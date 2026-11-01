# What the reconcile queue does when a namespace fills up

Scripted in [`queue-drain-under-load.sh`](queue-drain-under-load.sh). Runs on kind with Prometheus scraping
the operator. No GPU.

## Why this run exists

Two documents listed this as the first unmeasured thing. The benchmark that found the O(N) lookup measured
it **isolated**, in envtest, one call at a time. It did not show queue behaviour, and the O(N²) claim needs
queue behaviour: every reconciler here runs at `MaxConcurrentReconciles=1`, so a per-item cost proportional
to namespace size drains the queue quadratically **if** the per-item cost really is proportional.

## Result

400 MLTrainingJobs created into one namespace:

```
created            400 objects in 5,312ms      (75 objects/sec)
reconciles         1,437
peak queue depth   0
drain              10,054ms
throughput         143.7 reconciles/sec   (as printed; 1,437 / 10.054 s is 142.9, see below)
reconcile p99      24.5ms
errors             0
```

## The queue never backed up, and the reason is the load generator

142.9 reconciles per second against 75 objects per second of creation.
The run printed 143.7: its `bc` truncated the 10,054 ms drain to 10.0 s before dividing, which the script no longer does. **The operator consumed work faster
than `kubectl apply` produced it**, so the queue had nothing to accumulate.

That is a real measurement of absorption rate and a failed attempt at the thing it set out to test. Reading
`peakQueueDepth: 0` as "the queue is fine under load" would be wrong: this load was never load.

Two limits, both recorded in the run's own record:

- **Sampling.** Queue depth is read from Prometheus every 5 seconds, and Prometheus scrapes every 15. A
  spike between two scrapes is invisible, so the peak is a lower bound rather than a measurement.
- **The index is already in.** A flat drain here is consistent with the field index working. It is not
  evidence the previous code was quadratic; measuring that contrast would mean deploying a knowingly slower
  operator, which is a separate exercise.

## What it does establish

**This operator absorbs about 144 reconciles per second at a p99 of 24.5ms with a single worker, and
sustained zero errors across 1,437 reconciles**, in one 400-object burst. Because the queue never backed up,
that is a rate the operator kept up with, not a demonstrated ceiling, and it counts reconciles, not jobs; it is
where a capacity argument starts, and it did not exist before this run.

## What would actually stress it

- create faster than 144/sec, which needs a client that is not `kubectl apply` in batches
- or make each reconcile slower, which is what reverting the field index would do
- or raise the object count until creation and consumption overlap long enough for depth to persist across a
  scrape interval
- or scrape the operator's `/metrics` directly at sub-second intervals instead of going through Prometheus,
  which removes the sampling limit above

The last one is the cheapest and is the next step.
