#!/usr/bin/env python3
"""Score a run of hack/net-diag/run.sh against docs/superpowers/specs/2026-11-07-network-diagnosis-cases-design.md.

Writes verdict.json into the run directory and prints a summary.
A case the instrumentation did not see is INVALID; an observed case reports each expected reading as held or not.
"""

import json
import os
import re
import statistics
import sys

KV = re.compile(r"(\w+)=(\S*)")


class Probe:
    """One probe.sh output: curl's result, the retransmit counter and the capture's lines."""

    def __init__(self, text):
        self.text = text
        self.fields = {}
        self.capture = None
        lines = text.splitlines()
        if "--- capture" in lines and "--- end" in lines:
            a, b = lines.index("--- capture"), lines.index("--- end")
            self.capture = lines[a + 1:b]
            head = lines[:a]
        else:
            head = lines
        for line in head:
            if line.startswith("curl_error="):
                self.fields["curl_error"] = line[len("curl_error="):].strip()
                continue
            for k, v in KV.findall(line):
                self.fields.setdefault(k, v)

    def missing(self):
        """The reasons this probe cannot be read, or an empty list."""
        out = []
        for key in ("capture_ready", "curl_exit", "http", "t_total", "retrans_before", "retrans_after",
                    "kernel_dropped", "tcpdump_read_exit"):
            if key not in self.fields:
                out.append(f"the probe printed no {key}")
        if self.fields.get("capture_ready") == "0":
            out.append("tcpdump was not listening when the request started")
        if self.fields.get("kernel_dropped", "0") != "0":
            out.append(f"the capture dropped {self.fields['kernel_dropped'] or 'an unknown number of'} packets in the kernel")
        if self.capture is None:
            out.append("the probe printed no capture")
        elif self.fields.get("tcpdump_read_exit") not in (None, "0"):
            out.append(f"tcpdump could not read its capture (exit {self.fields['tcpdump_read_exit']})")
        if "exec_exit" in self.fields:
            out.append(f"kubectl exec exited {self.fields['exec_exit']}")
        return out

    @property
    def exit(self):
        return int(self.fields["curl_exit"])

    @property
    def code(self):
        return self.fields["http"]

    @property
    def total(self):
        return float(self.fields["t_total"])

    @property
    def retrans(self):
        return int(self.fields["retrans_after"]) - int(self.fields["retrans_before"])

    def count(self, pattern):
        rx = re.compile(pattern)
        return sum(1 for line in self.capture if rx.search(line))


def burst_of(text):
    """The requests of a burst.sh output and its retransmit delta, or None for the delta when it is missing."""
    reqs = [dict(KV.findall(line)) for line in text.splitlines() if line.startswith("req=")]
    tail = dict(KV.findall(text.strip().splitlines()[-1])) if text.strip() else {}
    delta = int(tail["retrans_after"]) - int(tail["retrans_before"]) if "retrans_after" in tail else None
    return reqs, delta


def succeeded(reqs):
    """The requests that completed: curl exit 0 and HTTP 200, not a 200 printed for a transfer curl then failed."""
    return [r for r in reqs if r.get("exit") == "0" and r.get("http") == "200"]


def max_syn_retries(capture):
    """The most SYNs any one client port sent to port 80: retransmissions of one connection share its tuple."""
    ports = {}
    for line in capture:
        m = re.search(r"IP \S+\.(\d+) > \S+\.80: Flags \[S\],", line)
        if m:
            ports[m.group(1)] = ports.get(m.group(1), 0) + 1
    return max(ports.values(), default=0)


def rst_answers_syn(capture, server_ip, port):
    """Whether the server Pod's IP answered a SYN to PORT with a RST to the same client port."""
    syns = set(re.findall(r"IP \S+\.(\d+) > " + re.escape(server_ip) + r"\." + port + r": Flags \[S\],", "\n".join(capture)))
    rsts = set(re.findall(r"IP " + re.escape(server_ip) + r"\." + port + r" > \S+?\.(\d+): Flags \[R", "\n".join(capture)))
    return bool(syns & rsts)


DNS_QUERY = r"> \S+\.53: \d+\+.* (A|AAAA)\? "
DNS_ANSWER = r"IP \S+\.53 > "
ICMP_DNS = r"ICMP .* udp port 53 unreachable"
ICMP_HTTP = r"ICMP .* tcp port 80 unreachable"
ICMP_ANY = r"ICMP "
SYN_80 = r"\.80: Flags \[S\],"
SYNACK = r"Flags \[S\.\]"
RST = r"Flags \[R"


CASES = ["b", "n1a", "n1b", "n2a", "n2b", "n3a", "n3b"]


def read(path):
    with open(path) as f:
        return f.read()


def rule_count(text):
    """kube-proxy's REJECT rule count as read back, or None when the read-back has no number."""
    m = re.search(r"reject_rules=(\d+)\b", text)
    return int(m.group(1)) if m else None


def judge(d):
    """Return (validity, reasons, readings, expectations) for one case directory."""
    meta = json.loads(read(os.path.join(d, "case.json")))
    case = meta["case"]
    invalid = []
    probe = recovery = None
    if case != "n2b":
        probe = Probe(read(os.path.join(d, "probe.txt")))
        invalid += probe.missing()
    if case != "b":
        recovery = Probe(read(os.path.join(d, "recovery.txt")))
        invalid += ["recovery: " + r for r in recovery.missing()]
    fault = read(os.path.join(d, "fault.txt")) if case != "b" else ""
    # The fault as read back: a case whose fault did not take is not a case at all.
    if case == "n1a" and not ("kube_dns_endpoints=0 " in fault and "kube_dns_pods=0" in fault
                              and (rule_count(fault) or 0) > 0):
        invalid.append("CoreDNS still had endpoints or Pods, or kube-proxy had no REJECT rule for it: " + fault.strip())
    if case == "n1b" and not ("policy=client-only-to-server" in fault and "policy_enforced=1" in fault
                              and "direct_server_http=200" in fault):
        invalid.append("the NetworkPolicy was not shown enforced with the server still reachable: " + fault.strip())
    if case == "n2a" and "loss 100%" not in fault:
        invalid.append("the server's qdisc does not show loss 100%: " + fault.strip())
    if case == "n2b" and "loss 30%" not in fault:
        invalid.append("the server's qdisc does not show loss 30%: " + fault.strip())
    if case == "n3a" and not ("server_endpoints=0 " in fault and (rule_count(fault) or 0) > 0):
        invalid.append("the server Service still had endpoints, or kube-proxy had no REJECT rule for it: " + fault.strip())
    if case in ("n2a", "n2b"):
        removal = read(os.path.join(d, "removal.txt"))
        if "netem" in removal:
            invalid.append("the loss was still on the server's interface after its removal: " + removal.strip())
    if case in ("n1a", "n3a") and rule_count(read(os.path.join(d, "removal.txt"))) != 0:
        invalid.append("kube-proxy's REJECT rule was still there when the recovery was probed")
    if case == "n1b" and "dns_restored=1" not in read(os.path.join(d, "removal.txt")):
        invalid.append("DNS did not answer again after the policy was deleted")
    if case == "n3b" and re.search(r":8081\b", fault):
        invalid.append("something listens on 8081 in the server")
    burst, burst_delta = [], None
    if case in ("b", "n2b"):
        burst, burst_delta = burst_of(read(os.path.join(d, "burst.txt")))
        if len(burst) != 40 or burst_delta is None:
            invalid.append(f"the burst printed {len(burst)} requests of 40, or no retransmit counter")
    rec_burst = []
    if case == "n2b":
        rec_burst, rec_delta = burst_of(read(os.path.join(d, "recovery-burst.txt")))
        if len(rec_burst) != 20 or rec_delta is None:
            invalid.append(f"the recovery burst printed {len(rec_burst)} requests of 20")
    baseline_max = None
    if case == "n2b":
        # The no-loss batch of the same repetition, which the loss tail is read against.
        bdir = os.path.join(os.path.dirname(d), f"b-r{meta['rep']}")
        if not os.path.exists(os.path.join(bdir, "burst.txt")):
            invalid.append("no baseline burst in this repetition")
        else:
            breqs, _ = burst_of(read(os.path.join(bdir, "burst.txt")))
            bok = succeeded(breqs)
            if len(bok) != 40:
                invalid.append(f"the baseline burst completed {len(bok)} of 40")
            else:
                baseline_max = max(float(r["t_total"]) for r in bok)
    if invalid:
        return "INVALID", invalid, {}, []

    exp = []

    def expect(name, ok):
        exp.append({"expected": name, "held": bool(ok)})

    readings = {}
    if probe is not None:
        readings.update({"curl_exit": probe.exit, "http": probe.code, "t_total": probe.total, "retrans": probe.retrans,
                         "curl_error": probe.fields.get("curl_error", ""),
                         "dns_queries": probe.count(DNS_QUERY), "dns_answers": probe.count(DNS_ANSWER),
                         "icmp_dns": probe.count(ICMP_DNS), "icmp_http": probe.count(ICMP_HTTP),
                         "icmp_any": probe.count(ICMP_ANY), "syn_80": probe.count(SYN_80),
                         "synack": probe.count(SYNACK), "rst": probe.count(RST)})
    if recovery is not None:
        readings["recovery_http"] = recovery.code
        # N3b's is a positive control, the same Pod on the port it listens on, not a recovery of the closed port.
        name = "positive control 200" if case == "n3b" else "recovery 200"
        expect(name, recovery.exit == 0 and recovery.code == "200")

    if case == "b":
        expect("exit 0, 200", probe.exit == 0 and probe.code == "200")
        expect("a SYN and a SYN-ACK", probe.count(SYN_80) >= 1 and probe.count(SYNACK) >= 1)
        bok = succeeded(burst)
        readings.update({"burst_ok_of_40": len(bok), "burst_max_t": max((float(r["t_total"]) for r in bok), default=None),
                         "burst_retrans": burst_delta})
        expect("the no-loss batch: 40 of 40 completed, none at 0.5 s or more",
               len(bok) == 40 and all(float(r["t_total"]) < 0.5 for r in bok))
    elif case == "n1a":
        expect("exit 6", probe.exit == 6)
        expect("failed in under 1 s", probe.total < 1.0)
        expect("a query and a udp port 53 unreachable",
               probe.count(DNS_QUERY) >= 1 and probe.count(ICMP_DNS) >= 1)
        expect("no SYN to port 80", probe.count(SYN_80) == 0)
    elif case == "n1b":
        expect("exit 6", probe.exit == 6)
        expect("failed after at least 5 s", probe.total >= 5.0)
        expect("two or more queries, no answer, no ICMP",
               probe.count(DNS_QUERY) >= 2 and probe.count(DNS_ANSWER) == 0 and probe.count(ICMP_ANY) == 0)
        expect("no SYN to port 80", probe.count(SYN_80) == 0)
    elif case == "n2a":
        expect("exit 28", probe.exit == 28)
        readings["max_syns_one_port"] = max_syn_retries(probe.capture)
        expect("three or more SYNs from one client port, no SYN-ACK, no RST",
               max_syn_retries(probe.capture) >= 3 and probe.count(SYNACK) == 0 and probe.count(RST) == 0)
        expect("retransmit delta at least 2", probe.retrans >= 2)
    elif case == "n2b":
        ok = succeeded(burst)
        times = [float(r["t_total"]) for r in ok]
        med = statistics.median(times) if times else None
        mx = max(times) if times else None
        rec_ok = succeeded(rec_burst)
        readings.update({"ok_of_40": len(ok), "failed": [r.get("req") for r in burst if r not in ok],
                         "retrans": burst_delta, "median_t_ok": med, "max_t_ok": mx, "baseline_max_t": baseline_max,
                         "recovery_burst_ok_of_20": len(rec_ok)})
        expect("at least 36 of 40 completed", len(ok) >= 36)
        expect("retransmit delta at least 5", burst_delta >= 5)
        expect("completed requests: median under 0.5 s, maximum at least 0.9 s, the baseline's maximum under 0.5 s",
               med is not None and med < 0.5 and mx >= 0.9 and baseline_max < 0.5)
        expect("after removal: 20 of 20 completed, none at 0.5 s or more",
               len(rec_ok) == 20 and all(float(r["t_total"]) < 0.5 for r in rec_ok))
    elif case == "n3a":
        expect("exit 7", probe.exit == 7)
        expect("failed in under 1 s", probe.total < 1.0)
        expect("a tcp port 80 unreachable and no RST", probe.count(ICMP_HTTP) >= 1 and probe.count(RST) == 0)
    elif case == "n3b":
        expect("exit 7", probe.exit == 7)
        expect("a RST from the server Pod to the port that sent the SYN, and no ICMP",
               rst_answers_syn(probe.capture, meta["server_ip"], "8081") and probe.count(ICMP_ANY) == 0)
    else:
        return "INVALID", [f"unknown case {case}"], readings, []
    return "observed", [], readings, exp


def schedule(run_dir):
    """The (case, repetition) pairs the run was meant to make.

    run.sh writes schedule.json before the first case; a run made before it did is read as every case of the design
    for each repetition any case reached, so a repetition missing from one case still counts as scheduled.
    """
    path = os.path.join(run_dir, "schedule.json")
    if os.path.exists(path):
        sched = json.loads(read(path))
        return [(c, r) for r in range(1, sched["reps"] + 1) for c in sched["cases"]]
    reps = 0
    for name in os.listdir(run_dir):
        m = re.fullmatch(r"([a-z0-9]+)-r(\d+)", name)
        if m and os.path.isdir(os.path.join(run_dir, name)):
            reps = max(reps, int(m.group(2)))
    return [(c, r) for r in range(1, reps + 1) for c in CASES]


def main(run_dir):
    results = []
    for case, rep in schedule(run_dir):
        d = os.path.join(run_dir, f"{case}-r{rep}")
        if not os.path.exists(os.path.join(d, "case.json")):
            validity, reasons, readings, exp = "INVALID", ["scheduled, but the case left no case.json"], {}, []
        else:
            # Evidence that cannot be read or parsed makes this repetition INVALID, never the whole verdict unwritten.
            try:
                validity, reasons, readings, exp = judge(d)
            except (OSError, ValueError, KeyError, IndexError) as e:
                validity, reasons, readings, exp = "INVALID", [f"its evidence could not be read: {type(e).__name__}: {e}"], {}, []
        results.append({"case": case, "rep": rep, "validity": validity, "invalid_reasons": reasons,
                        "readings": readings, "expectations": exp,
                        "all_held": validity == "observed" and all(e["held"] for e in exp)})
    results.sort(key=lambda r: (r["case"], r["rep"]))
    by_case = {}
    for r in results:
        s = by_case.setdefault(r["case"], {"scheduled": 0, "invalid": 0, "all_held": 0})
        s["scheduled"] += 1
        s["invalid"] += r["validity"] == "INVALID"
        s["all_held"] += r["all_held"]
    with open(os.path.join(run_dir, "verdict.json"), "w") as f:
        json.dump({"cases": by_case, "repetitions": results}, f, indent=2, sort_keys=True)
    for case in sorted(by_case):
        s = by_case[case]
        print(f"{case}: held in {s['all_held']} of {s['scheduled']} ({s['invalid']} invalid)")
    for r in results:
        if r["validity"] == "INVALID":
            print(f"  {r['case']} r{r['rep']}: INVALID: {'; '.join(r['invalid_reasons'])}")
        for e in r["expectations"]:
            if not e["held"]:
                print(f"  {r['case']} r{r['rep']}: did not hold: {e['expected']}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check.py RUN_DIR", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
