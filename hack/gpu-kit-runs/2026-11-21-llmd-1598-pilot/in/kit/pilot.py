"""The llm-d-router #1598 pilot: 18 cells on four engines behind one EPP and Envoy, as the design's "Pilot" section lays out.

run.sh installs and builds, then runs this; it writes every cell under OUT/cells and the pilot's own measurements to
OUT/pilot.json, and verdict.py judges them.
With --mode offline the engines are test/fake_engine.py processes and the plan runs with shortened windows; the EPP and
Envoy are the same binaries either way.
"""

import argparse
import hashlib
import http.client
import json
import os
import shutil
import statistics
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analysis  # noqa: E402
import logs  # noqa: E402
import sampler  # noqa: E402
import sender  # noqa: E402
import workloads as W  # noqa: E402

ENVOY_PORT, ENVOY_ADMIN, EPP_GRPC, EPP_HEALTH, EPP_METRICS = 18080, 19000, 19002, 19003, 19090
# Engine configurations: (max_model_len, num_gpu_blocks_override or None for vLLM's own sizing).
ENGINE_CFG = {"AK": (4096, 4096), "B": (2048, 400), "W": (8192, None)}
CELL_BOUND = {"A": 65, "B": 75, "K": 99, "W942": 180}
RAMP_AB = [10, 20, 40, 80]


class Pilot:
    def __init__(self, a):
        self.a = a
        self.out = a.out
        self.cells_dir = os.path.join(self.out, "cells")
        os.makedirs(self.cells_dir, exist_ok=True)
        self.deadline = time.time() + a.budget_s
        self.engine_procs = []
        self.engine_cfg = None
        base = 8000 if a.mode == "gpu" else 18100
        self.engines = [f"127.0.0.1:{base + i}" for i in range(4)]
        self.names = {f"default/vllm-{i}": e for i, e in enumerate(self.engines)}
        self.state = {"mode": a.mode, "cells": [], "skipped": [], "timings": {}, "calibration": {}, "ramps": {}}
        self.endpoints_file = os.path.join(self.out, "endpoints.yaml")
        with open(self.endpoints_file, "w") as f:
            f.write("endpoints:\n")
            for i, e in enumerate(self.engines):
                h, p = e.split(":")
                f.write(f'- name: vllm-{i}\n  address: "{h}"\n  port: "{p}"\n')
        if a.mode == "offline":
            # Shorter windows so the whole plan runs in minutes on fakes; the request shapes and rules stay the same.
            W.BLOCKS = {k: (v[0], v[1], v[2], v[3] * a.time_scale, v[4] * a.time_scale, v[5]) for k, v in W.BLOCKS.items()}
            W.W942["phase2_s"] *= a.time_scale
            W.K_BURSTS = max(2, int(W.K_BURSTS * a.time_scale * 2))

    # ------------------------------------------------------------------ bookkeeping
    def log(self, msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        with open(os.path.join(self.out, "pilot.log"), "a") as f:
            f.write(line + "\n")

    def save(self):
        with open(os.path.join(self.out, "pilot.json"), "w") as f:
            json.dump(self.state, f, indent=1, sort_keys=True)

    def left(self):
        return self.deadline - time.time()

    # ------------------------------------------------------------------ engines
    def stop_engines(self):
        for p in self.engine_procs:
            p.terminate()
        for p in self.engine_procs:
            try:
                p.wait(30)
            except subprocess.TimeoutExpired:
                p.kill()
        self.engine_procs = []

    def start_engines(self, cfg):
        t0 = time.time()
        self.stop_engines()
        mml, blocks = ENGINE_CFG[cfg]
        for i, e in enumerate(self.engines):
            port = e.split(":")[1]
            logf = open(os.path.join(self.out, f"engine-{cfg}-{i}.log"), "w")
            if self.a.mode == "gpu":
                cmd = ["taskset", "-c", f"{8 * i}-{8 * i + 7}", os.path.join(self.a.venv, "bin", "vllm"), "serve", self.a.model_dir,
                       "--served-model-name", sender.MODEL, "--host", "127.0.0.1", "--port", port, "--block-size", "16",
                       "--max-num-seqs", "16", "--enable-prefix-caching", "--enable-prompt-tokens-details",
                       "--max-model-len", str(mml), "--seed", "0"]
                if blocks:
                    cmd += ["--num-gpu-blocks-override", str(blocks)]
                env = dict(os.environ, CUDA_VISIBLE_DEVICES=str(i), VLLM_SERVER_DEV_MODE="1", HF_HUB_OFFLINE="1")
            else:
                cmd = [sys.executable, "-I", self.a.fake_engine, "--port", port, "--blocks", str(blocks or 24576),
                       "--max-seqs", "16", "--prefill-us", "200", "--itl-ms", "4"] + sum((["--fault", x] for x in self.a.fault), [])
                env = dict(os.environ)
            with open(os.path.join(self.out, f"engine-{cfg}-{i}.cmd"), "w") as f:
                f.write(" ".join(cmd) + "\n")
            self.engine_procs.append(subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, env=env))
        limit = 420 if self.a.mode == "gpu" else 30
        for e in self.engines:
            while True:
                if self.http(e, "GET", "/health")[0] == 200:
                    break
                if time.time() - t0 > limit or any(p.poll() is not None for p in self.engine_procs):
                    raise RuntimeError(f"engines {cfg} not healthy after {time.time() - t0:.0f} s")
                time.sleep(1)
        info = {}
        for e in self.engines:
            text = sampler.scrape(e)
            lb = sampler.labels(text, "vllm:cache_config_info")
            info[e] = lb
            if lb.get("enable_prefix_caching") != "True":
                raise RuntimeError(f"{e}: prefix caching is not on: {lb}")
            if blocks and lb.get("num_gpu_blocks") != str(blocks):
                raise RuntimeError(f"{e}: num_gpu_blocks {lb.get('num_gpu_blocks')} is not {blocks}")
        self.engine_cfg = cfg
        self.state["timings"][f"engines_{cfg}_s"] = round(time.time() - t0, 1)
        self.state.setdefault("cache_config", {})[cfg] = info
        self.log(f"engines {cfg} ready in {time.time() - t0:.0f} s")

    def http(self, hostport, method, path, body=None, timeout=5):
        h, p = hostport.split(":")
        try:
            c = http.client.HTTPConnection(h, int(p), timeout=timeout)
            c.request(method, path, body)
            r = c.getresponse()
            return r.status, r.read()
        except Exception:  # noqa: BLE001
            return None, b""

    def idle(self, wait=30):
        t0 = time.time()
        while time.time() - t0 < wait:
            loads = [sampler.parse(sampler.scrape(e)) for e in self.engines]
            if all(x.get("vllm:num_requests_running", 0) == 0 and x.get("vllm:num_requests_waiting", 0) == 0 for x in loads):
                return True
            time.sleep(0.5)
        return False

    def reset(self):
        res = {}
        for e in self.engines:
            st, body = self.http(e, "POST", "/reset_prefix_cache", b"")
            try:
                res[e] = st == 200 and json.loads(body or b"{}").get("success") is True
            except ValueError:
                res[e] = False
        return res

    # ------------------------------------------------------------------ router
    def start_router(self, arm, verbosity, cdir):
        binary = {"A1": self.a.epp_a1, "A2": self.a.epp_a2, "A3": self.a.epp_a1}[arm]
        tmpl = "a3.yaml.tmpl" if arm == "A3" else "a1-a2.yaml.tmpl"
        peak = self.state["calibration"].get("peak_prefill_tps")
        if arm != "A3" and not peak:
            raise RuntimeError("A1 and A2 need the measured peakPrefillThroughput first")
        with open(os.path.join(HERE, "configs", tmpl)) as f:
            cfg = f.read().replace("@ENDPOINTS@", self.endpoints_file).replace("@PEAK@", str(int(round(peak or 0))))
        cfg_path = os.path.join(cdir, "epp-config.yaml")
        with open(cfg_path, "w") as f:
            f.write(cfg)
        with open(os.path.join(HERE, "configs", "envoy.yaml.tmpl")) as f:
            env_cfg = (f.read().replace("@ADMIN_PORT@", str(ENVOY_ADMIN)).replace("@LISTEN_PORT@", str(ENVOY_PORT))
                       .replace("@EPP_PORT@", str(EPP_GRPC)).replace("@ACCESS_LOG@", os.path.join(cdir, "access.log")))
        with open(os.path.join(cdir, "envoy.yaml"), "w") as f:
            f.write(env_cfg)
        pin = ["taskset", "-c", "32-35"] if self.a.mode == "gpu" else []
        epp = subprocess.Popen(pin + [binary, "--pool-name", "kit", "--pool-namespace", "kit", "--config-file", cfg_path,
                                      "--grpc-port", str(EPP_GRPC), "--grpc-health-port", str(EPP_HEALTH),
                                      "--metrics-port", str(EPP_METRICS), "--secure-serving=false", f"-v={verbosity}",
                                      "--zap-encoder", "json"],
                               stdout=open(os.path.join(cdir, "epp.log"), "w"), stderr=subprocess.STDOUT)
        envoy = subprocess.Popen(pin + [self.a.envoy, "-c", os.path.join(cdir, "envoy.yaml"), "--log-level", "warn",
                                        "--concurrency", "4"],
                                 stdout=open(os.path.join(cdir, "envoy.log"), "w"), stderr=subprocess.STDOUT)
        t0 = time.time()
        while time.time() - t0 < 30:
            if (self.http(f"127.0.0.1:{EPP_METRICS}", "GET", "/metrics")[0] == 200
                    and self.http(f"127.0.0.1:{ENVOY_ADMIN}", "GET", "/ready")[0] == 200):
                break
            if epp.poll() is not None or envoy.poll() is not None:
                break
            time.sleep(0.2)
        if epp.poll() is not None or envoy.poll() is not None:
            self.stop_router((epp, envoy))
            raise RuntimeError(f"router did not start for {arm}; see {cdir}")
        # The EPP scrapes engine metrics every 50 ms by default; a second lets it see all four before the first request.
        time.sleep(1.0)
        return epp, envoy, hashlib.sha256(cfg.encode()).hexdigest(), sha256_file(binary)

    def stop_router(self, procs):
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()

    # ------------------------------------------------------------------ one cell
    def cell(self, name, arm, block, verbosity=5, reqs=None, rate=None, seed=1, kind="steady", stagger=0.0, k_preloads=True):
        bound = CELL_BOUND["K" if kind == "K" else block]
        if self.left() < bound:
            self.state["skipped"].append({"cell": name, "why": f"{self.left():.0f} s left, bound {bound} s"})
            self.log(f"skip {name}: not enough time")
            return None
        cdir = os.path.join(self.cells_dir, name)
        os.makedirs(cdir, exist_ok=True)
        meta = {"cell": name, "arm": arm, "block": block, "rate": rate, "seed": seed, "kind": kind, "verbosity": verbosity,
                "stagger": stagger, "engine_cfg": self.engine_cfg, "engines": self.engines, "start": time.time()}
        meta["idle_at_start"] = self.idle()
        meta["reset"] = self.reset()
        procs = None
        try:
            epp, envoy, meta["config_sha256"], meta["epp_sha256"] = self.start_router(arm, verbosity, cdir)
            procs = (epp, envoy)
            before = {e: sampler.counters(sampler.scrape(e)) for e in self.engines}
            smp = sampler.Sampler(self.engines, os.path.join(cdir, "samples.jsonl")).start()
            meta["window"] = [time.time(), None]
            rows = []
            if kind == "steady":
                meta["schedule_sha256"] = W.schedule_hash(reqs)
                timeout = W.BLOCKS[block][5] if block in W.BLOCKS else W.W942["timeout"]
                rows = sender.run("127.0.0.1", ENVOY_PORT, reqs, time.time() + 0.5, timeout)
            elif kind == "K":
                rows, meta["bursts"] = self.k_cell(name, seed, stagger, k_preloads)
            elif kind == "probe":
                rows = self.sequential(reqs, W.BLOCKS.get(block, (0, 0, 0, 0, 0, 45.0))[5])
            meta["window"][1] = time.time()
            smp.stop()
            # The EPP's own scheduling histogram, for the logging rule; read before the EPP process goes away.
            with open(os.path.join(cdir, "epp-metrics.prom"), "w") as f:
                f.write(self.http(f"127.0.0.1:{EPP_METRICS}", "GET", "/metrics")[1].decode(errors="replace"))
            self.idle(30)
            after = {e: sampler.counters(sampler.scrape(e)) for e in self.engines}
            meta["deltas"] = {e: sampler.delta(before[e], after[e]) for e in self.engines}
        finally:
            if procs:
                self.stop_router(procs)
        with open(os.path.join(cdir, "rows.jsonl"), "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        meta["end"] = time.time()
        meta["duration_s"] = round(meta["end"] - meta["start"], 1)
        with open(os.path.join(cdir, "cell.json"), "w") as f:
            json.dump(meta, f, indent=1)
        self.state["cells"].append(name)
        self.save()
        self.log(f"cell {name} {arm} {block} rate={rate} v={verbosity}: {len(rows)} rows in {meta['duration_s']} s")
        return rows

    def sequential(self, reqs, timeout):
        pool = sender.Pool("127.0.0.1", ENVOY_PORT, 1, timeout)
        rows = []
        for r in reqs:
            rows.append(sender.one(pool, r, time.time()))
        pool.close()
        return rows

    def k_cell(self, name, seed, stagger, with_preloads):
        """K's bursts: three in-prefill preloads sent through the router one after another, then 64 requests at once."""
        rows, bursts = [], []
        for b, burst in enumerate(W.k_bursts(seed, name)):
            pre_rows, threads = [], []
            pool = sender.Pool("127.0.0.1", ENVOY_PORT, 3, W.K_TIMEOUT)
            if with_preloads:
                for p in W.preloads(seed, name, b):
                    t = threading.Thread(target=lambda p=p: pre_rows.append(sender.one(pool, p, time.time())), daemon=True)
                    t.start()
                    threads.append(t)
                    # The EPP adds a preload to its in-flight tokens at PreRequest, within milliseconds of receiving it.
                    time.sleep(0.05)
            brows = sender.run("127.0.0.1", ENVOY_PORT, burst, time.time() + 0.02, W.K_TIMEOUT, stagger=stagger)
            for t in threads:
                t.join(W.K_TIMEOUT + 5)
            pool.close()
            for r in brows:
                r["burst"] = b
            for r in pre_rows:
                r["burst"] = b
            bursts.append({"burst": b, "rids": [r["rid"] for r in brows], "preloads": [r["rid"] for r in pre_rows]})
            rows += pre_rows + brows
            self.idle(10)
            time.sleep(1.0)
        return rows, bursts

    # ------------------------------------------------------------------ the plan
    def calibrate_peak(self):
        rows = self.cell("calib-peak", "A3", "A", kind="probe", reqs=W.cold_probe("calib", 20, 2048, 1))
        tt = [analysis.ttft(r) for r in (rows or []) if analysis.completed(r)]
        if len(tt) < 15:
            raise RuntimeError(f"calibration: {len(tt)} of 20 completed")
        med = statistics.median(tt)
        self.state["calibration"]["peak_prefill_tps"] = 2048 / med
        self.state["calibration"]["peak_median_ttft_s"] = med

    def isolated(self, block, length, max_tokens, tag):
        cold = self.cell(f"iso-{tag}-cold", "A3", block, kind="probe", reqs=W.cold_probe(tag, 20, length, max_tokens))
        warm = self.cell(f"iso-{tag}-warm", "A3", block, kind="probe", reqs=W.warm_probe(tag, 20, length, max_tokens))
        ct = [analysis.ttft(r) for r in (cold or [])]
        wt = [analysis.ttft(r) for r in (warm or [])[1:]]
        self.state["calibration"][f"slo_{tag}_s"] = analysis.slo_from_cold(ct)
        self.state["calibration"][f"cold_p50_{tag}_s"] = analysis.nearest_rank(ct, 50)
        self.state["calibration"][f"warm_p50_{tag}_s"] = analysis.nearest_rank(wt, 50)

    def ramp(self, block, rates, slo_key):
        slo = self.state["calibration"].get(slo_key)
        results = []
        for rate in rates:
            if block == "W942":
                reqs = W.w942(942, rate, f"ramp-{block}-{rate}")
            else:
                reqs = W.steady(block, 1, rate, f"ramp-{block}-{rate}")
            rows = self.cell(f"ramp-{block}-{rate:g}", "A3", block, reqs=reqs, rate=rate, seed=1)
            if rows is None:
                break
            ev = [r for r in rows if r["population"] == "eval"]
            ok = slo is not None and analysis.passes_slo(ev, slo)
            results.append((rate, ok))
            if not ok:
                break
        r, kind = analysis.bracket(results)
        self.state["ramps"][block] = {"results": results, "r": r, "kind": kind, "slo_s": slo}
        return r

    def run(self):
        t0 = time.time()
        self.start_engines("AK")
        self.calibrate_peak()
        self.isolated("A", 544, 32, "A")
        # The preload's isolated prefill time says how long K's preloads stay visible to the scorer.
        pre = self.cell("iso-preload", "A3", "A", kind="probe", reqs=W.cold_probe("preload", 3, W.PRELOAD_TOKENS, 1))
        self.state["calibration"]["preload_ttft_s"] = [analysis.ttft(r) for r in (pre or [])]
        # x2 steps from the thread's per-engine 2.5/s (10/s): four cells span 8x, which the offline run showed a x1.5 ladder
        # (10 to 33.75/s) can fail to bracket.
        r_a = self.ramp("A", RAMP_AB, "slo_A_s")
        rate = round(0.9 * r_a, 2) if r_a else 10
        self.cell("log-A-A1-v2", "A1", "A", verbosity=2, reqs=W.steady("A", 1, rate, "log-A-A1-v2"), rate=rate)
        self.cell("log-A-A1-v5", "A1", "A", verbosity=5, reqs=W.steady("A", 1, rate, "log-A-A1-v5"), rate=rate)
        self.cell("log-K-A1-v2", "A1", "K", verbosity=2, kind="K", seed=1)
        self.cell("log-K-A1-v5", "A1", "K", verbosity=5, kind="K", seed=1)
        self.cell("switch-A-A2", "A2", "A", reqs=W.steady("A", 1, rate, "switch-A-A2"), rate=rate)
        self.cell("switch-A-A3", "A3", "A", reqs=W.steady("A", 1, rate, "switch-A-A3"), rate=rate)
        self.start_engines("B")
        self.isolated("B", 288, 32, "B")
        self.ramp("B", RAMP_AB, "slo_B_s")
        self.cell("pressure-B-A1", "A1", "B", reqs=W.steady("B", 1, 10, "pressure-B-A1"), rate=10)
        self.start_engines("W")
        self.isolated("W942", W.W942["prefix"] + W.W942["suffix"], 64, "W942")
        self.ramp("W942", [1.75, 2.9, 4.4], "slo_W942_s")
        self.stop_engines()
        self.state["timings"]["plan_s"] = round(time.time() - t0, 1)
        self.save()


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", choices=["gpu", "offline"], required=True)
    ap.add_argument("--budget-s", type=float, required=True)
    ap.add_argument("--epp-a1", required=True)
    ap.add_argument("--epp-a2", required=True)
    ap.add_argument("--envoy", required=True)
    ap.add_argument("--venv", default="")
    ap.add_argument("--model-dir", default="")
    ap.add_argument("--fake-engine", default="")
    ap.add_argument("--fault", action="append", default=[])
    ap.add_argument("--time-scale", type=float, default=1.0)
    a = ap.parse_args()
    p = Pilot(a)
    rc = 0
    try:
        p.run()
    except Exception as e:  # noqa: BLE001 - the verdict reads what was measured before the stop
        p.state["stopped"] = f"{type(e).__name__}: {e}"
        p.log(f"STOPPED {p.state['stopped']}")
        rc = 1
    finally:
        p.stop_engines()
        p.save()
    return rc


if __name__ == "__main__":
    sys.exit(main())
