#!/usr/bin/env python3
"""Score an mlops-lineage run directory against the readings registered in README.md.

Usage: score.py RUN_DIR

Exit 0 only when every validity check passed and every expected file is present. A reading that misses its
registered expectation is reported as missed; it does not void the run, because a missed expectation is a result.
"""
import csv
import glob
import json
import os
import sys

CYCLES = 3


def load(run, name):
    with open(os.path.join(run, name)) as f:
        return json.load(f)


def poll(run, stem):
    with open(os.path.join(run, stem + ".tsv"), newline="") as f:
        rows = [(float(r["t_s"]), float(r["done_s"]), int(r["status"]), r["version"])
                for r in csv.DictReader(f, delimiter="\t")]
    meta = load(run, stem + ".meta")
    return rows, meta


def coverage_ok(rows, meta):
    # Checked against the poller's own count and its wall-clock window, never against the rows alone: rows lost
    # from either end would shrink a window derived from them and pass.
    window = meta["wall_end"] - meta["wall_start"]
    return len(rows) == meta["sent"] and meta["sent"] >= 0.9 * window * meta["rate"], window


def main():
    run = sys.argv[1]
    valid = True

    def void(msg):
        nonlocal valid
        print(f"  INVALID: {msg}")
        valid = False

    try:
        v1, v2 = load(run, "train-v1.json"), load(run, "train-v2.json")
        g1, g2 = load(run, "gate-v1.json"), load(run, "gate-v2.json")
        first = load(run, "pinned-first.json")
        versions = load(run, "registry-versions.json")["model_versions"]
    except (OSError, ValueError, KeyError) as err:
        print(f"  INVALID: a required record is missing or unreadable ({err})")
        print("VOID")
        return 1
    events = {}
    with open(os.path.join(run, "events.tsv")) as f:
        for line in f:
            name, wall = line.split("\t")
            events[name] = float(wall)

    # Validity 1: the two models are what the experiment needs.
    print(f"accuracy: v1 {v1['eval_accuracy']:.4f}, v2 {v2['eval_accuracy']:.4f}")
    if not (v1["eval_accuracy"] >= 0.95 and v2["eval_accuracy"] <= v1["eval_accuracy"] - 0.05):
        void("v1 must reach 0.95 and v2 must be at least 0.05 below it")
    # Validity 3: the served weights are the trained weights.
    if first.get("artifact_sha256") != v1["artifact_sha256"]:
        void("the first pinned answer's weights hash is not the one the v1 training Job printed")

    # Reading, step 2: the gate.
    gate_ok = g1["alias_moved"] and not g2["passes_rule"] and not g2["alias_moved"]
    print(f"gate: v1 promoted={g1['alias_moved']}; v2 passes_rule={g2['passes_rule']} alias_moved={g2['alias_moved']}"
          f" -> {'as registered' if gate_ok else 'MISSED'}")

    # Reading, step 3: the lineage chain, answer -> version -> run -> data, code, commit.
    reg_v1 = next((v for v in versions if v["version"] == "1"), None)
    run_files = glob.glob(os.path.join(run, f"registry-run-{first.get('run_id')}.json"))
    tags = {}
    if run_files:
        with open(run_files[0]) as f:
            tags = {t["key"]: t["value"] for t in json.load(f)["run"]["data"].get("tags", [])}
    links = {
        "answer names version 1": first.get("model_version") == "1",
        "answer's run is the v1 training run": first.get("run_id") == v1["run_id"],
        "registry version 1 points at that run": bool(reg_v1) and reg_v1["run_id"] == v1["run_id"],
        "run's data hash is the trainer's": tags.get("train_data_sha256") == v1["train_data_sha256"],
        "run's code hash is the trainer's": tags.get("code_sha256") == v1["code_sha256"],
        "run's commit is the trainer's": tags.get("git_commit") == v1["git_commit"],
        "run's weights hash is the served one": tags.get("artifact_sha256") == first.get("artifact_sha256"),
    }
    for name, ok in links.items():
        print(f"  lineage: {name}: {'yes' if ok else 'NO'}")
    print(f"lineage -> {'as registered' if all(links.values()) else 'MISSED'}")

    # Reading, step 4: rollback cycles.
    print("cycle\tsent\trecorded\tnon_200\trollback_to_last_v2_s\trollback_to_first_v1_s")
    for c in range(1, CYCLES + 1):
        try:
            rows, meta = poll(run, f"poll-rollback-{c}")
        except OSError:
            void(f"cycle {c} poll file is missing")
            continue
        ok, window = coverage_ok(rows, meta)
        if not ok:
            void(f"cycle {c} recorded {len(rows)} of {meta['sent']} sent over a {window:.1f} s window at {meta['rate']}/s")
        back = events[f"cycle{c}-rollback-v1"] - meta["wall_start"]
        non200 = sum(1 for _, _, s, _ in rows if s != 200)
        # Completion times: the question is when users stopped receiving v2, not when the last request was sent.
        last_v2 = max((d for _, d, s, v in rows if v == "2"), default=None)
        first_v1 = min((d for _, d, s, v in rows if v == "1" and d > back), default=None)
        fmt = lambda x: f"{x - back:.2f}" if x is not None else "-"
        print(f"{c}\t{meta['sent']}\t{len(rows)}\t{non200}\t{fmt(last_v2)}\t{fmt(first_v1)}")

    # Reading, step 5: the alias trap.
    try:
        rows, meta = poll(run, "poll-alias")
        ok, window = coverage_ok(rows, meta)
        if not ok:
            void(f"the alias poll recorded {len(rows)} of {meta['sent']} sent over a {window:.1f} s window")
        forced = events["alias-forced-v2"] - meta["wall_start"]
        restart = events["alias-restart"] - meta["wall_start"]
        during = [v for t, _, s, v in rows if forced < t < restart and s == 200]
        share_v1 = sum(v == "1" for v in during) / len(during) if during else float("nan")
        final = max(rows, key=lambda r: r[1])[3] if rows else ""
        print(f"alias: {len(during)} answers while the alias said v2, {share_v1:.1%} of them v1; last answer v{final}"
              f" -> {'as registered' if share_v1 == 1.0 and final == '2' else 'MISSED'}")
    except (OSError, KeyError) as err:
        void(f"the alias step left no usable record ({err})")

    print("VALID" if valid else "VOID: a validity check failed, so no reading above is a result")
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
