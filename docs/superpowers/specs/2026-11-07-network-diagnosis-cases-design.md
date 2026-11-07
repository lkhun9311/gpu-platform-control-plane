# Network diagnosis cases: DNS, packet loss and refused connections (M-42A-5, network)

Written 2026-11-07, before any scored run.
Status: **design; not yet run.**
This extends item M-42A-5 of the operations track (`docs/superpowers/specs/2026-10-31-inference-portfolio-roadmap.md`) with the network incident the 2026-11-07 JD review asked for: telling a DNS failure, packet loss and a refused connection apart from evidence, and showing recovery once the cause is removed.
The memory and OOM cases of the same item are `docs/superpowers/specs/2026-11-07-linux-diagnosis-cases-design.md`.

## What it is for

A training rank that cannot reach its rendezvous, or a client that cannot reach an inference Service, reports one of a handful of curl or socket errors.
The same error text can come from different causes, and different causes can look alike from the application: this design picks cases where the error alone misleads and a capture on the client shows the stage at which the request failed (no DNS answer, no SYN-ACK, a RST, an ICMP from the node); which fault caused it is established by the fault's own read-back, not by the capture.
Each case is a fault injected on kind, a request from a client Pod with a packet capture and the kernel's retransmit counter around it, the fault removed, and a request that must succeed again.

It licenses statements about Kubernetes v1.37.0 on a kind node image, with kind's default CNI (kindnet), kube-proxy in iptables mode and the client's curl, whose resolver is c-ares (`curl -V`), at the versions recorded with the run.
It does not license statements about other CNIs, cloud load balancers, MTU or TLS, which are under "Not covered".

## What spikes already showed (2026-11-07, one run each, not scored)

One single-node kind v1.37.0 cluster; a server Pod running `python3 -m http.server 8080` behind a ClusterIP Service on port 80; a client Pod with `NET_ADMIN` and `NET_RAW`; both on `nicolaka/netshoot` pinned by digest.
The client ran tcpdump on its `eth0`, one curl, and read `TcpRetransSegs` from `nstat` before and after.

| fault | curl | time | what the capture held |
|---|---|---|---|
| none | 200 | ms | DNS query and answer, SYN, SYN-ACK, data |
| CoreDNS scaled to 0 | exit 6, "Could not resolve host" | < 1 ms | three queries to `10.96.0.10:53` and three `ICMP … udp port 53 unreachable` from the node's gateway address; no SYN |
| a NetworkPolicy denying the client's egress except to the server | exit 6, "Could not resolve host" | 11.86 s | six queries (three A, three AAAA) and no answer and no ICMP; no SYN |
| netem `loss 100%` on the server's `eth0` | exit 28, "Connection timed out after 8002 milliseconds" | 8.0 s | seven SYNs to the ClusterIP, no SYN-ACK, no RST; retransmit counter +6 |
| netem `loss 30%`, 40 requests | 40 of 40 returned 200 | median 5 ms, p90 1.06 s, max 2.25 s | retransmit counter +33 |
| the server Pod relabelled so the Service has no endpoints | exit 7, "Could not connect to server" | < 1 ms | one SYN to the ClusterIP and `ICMP … tcp port 80 unreachable` from the node's gateway address; no RST |
| the server Pod's IP on a port nothing listens on | exit 7, "Could not connect to server" | 0 ms | one SYN and one RST from the Pod's IP |

Two things in that table are the reason for the cases below:
- **"DNS is down" has two signatures.** With no CoreDNS endpoint, kube-proxy rejects the query and the failure is instant, with ICMP; with DNS dropped on the way, every query goes unanswered and the failure takes the resolver's timeouts (11.86 s here; the run records the resolver and its configuration rather than explaining the figure).
- **"Could not connect" has two causes the error text does not separate.** A Service with no endpoints is answered by the node with ICMP port unreachable; a Pod with nothing listening answers with a RST.
  The first is a selector, readiness or scale problem in the cluster; the second is the process.
- **Partial loss mostly does not fail; it is slow**: in the spike all 40 requests succeeded, the slowest at 1.06 s (p90) and 2.25 s, with the retransmit counter as the witness; the scored run reports the success fraction it saw.

## Cases

| id | fault | the source that misleads | the source that settles it |
|---|---|---|---|
| B | none | — | the baseline: SYN, SYN-ACK, 200 |
| N1a | CoreDNS scaled to 0 | "Could not resolve host", as in N1b | ICMP udp port 53 unreachable, and how fast it failed |
| N1b | a NetworkPolicy that lets the client reach only the server Pod | the same error | queries with no answer and no ICMP, and a failure at the resolver's timeouts |
| N2a | netem `loss 100%` on the server's interface | a timeout, which could be a slow server | SYNs retransmitted with no SYN-ACK; the retransmit counter |
| N2b | netem `loss 30%` on the server's interface, 40 requests | every request succeeded | the retransmit counter and a latency tail at the retransmission timeout |
| N3a | the server Pod relabelled, so the Service has no endpoints | "Could not connect", as in N3b | ICMP tcp port 80 unreachable from the node, no RST; the EndpointSlice empty |
| N3b | a request to the server Pod's IP on port 8081, where nothing listens | the same error | a RST from the Pod's IP |

After each fault is removed the client makes one more request, which must return 200; N3b's recovery is the same Pod on its listening port.
The cases run in the order above within a repetition, three repetitions on one cluster, so no case's recovery is assumed: each next case starts from a measured 200.

## What is captured per case

- The fault as applied and read back: `tc qdisc show dev eth0` in the server for N2, the kube-dns EndpointSlice for N1a, the NetworkPolicy for N1b, the server's EndpointSlice for N3a.
- From the client: curl's exit code, HTTP code and its `time_total`, `time_namelookup` and `time_connect`; `TcpRetransSegs` before and after; the capture as tcpdump's text, read back from the pcap file the client wrote.
- For N2b, each of the 40 requests' exit code, HTTP code and `time_total`.
- The recovery request's line.
- Kubelet, kube-proxy mode, kindnet and CoreDNS images, recorded once per run.

The captures hold only Pod, Service and node-bridge addresses of the throwaway cluster.

## The checker

`hack/net-diag/check.py` reads a run directory and writes `verdict.json`.
**INVALID**, kept apart from "did not hold": the fault's read-back does not show the fault; the capture is missing or tcpdump failed; the probe output is missing a line it always prints.
Otherwise each expected reading **held** or **did not hold**, with the value seen.
Every scheduled repetition is reported, three per case, with no re-run.

| case | expected |
|---|---|
| B | exit 0, 200; at least one SYN and one SYN-ACK in the capture; the no-loss batch 40 of 40 completed, each under 0.5 s |
| N1a | exit 6; `time_total` under 1 s; at least one query to port 53 and at least one `udp port 53 unreachable`; no SYN to port 80; recovery 200 |
| N1b | exit 6; `time_total` at least 5 s; at least two queries, no DNS answer, no ICMP; no SYN to port 80; recovery 200 |
| N2a | exit 28; at least three SYNs from one client port, no SYN-ACK, no RST; retransmit delta at least 2; recovery 200 |
| N2b | at least 36 of 40 completed (exit 0 and 200); retransmit delta at least 5; over completed requests the median under 0.5 s and the maximum at least 0.9 s, with B's maximum under 0.5 s; recovery 200, and a batch of 20 after removal all completed under 0.5 s |
| N3a | exit 7; `time_total` under 1 s; at least one `tcp port 80 unreachable`; no RST; recovery 200 |
| N3b | exit 7; a RST from the server Pod's IP to the client port that sent the SYN; no ICMP; positive control 200 |

N2b's thresholds are wide on purpose: loss is random, and the spike's 40 of 40, +33 and 1.06 s p90 are one draw.
Every rule is pinned by a test in `hack/test/check-net-diag.sh` against copies of the scored run with one thing changed, and each rule is broken once to show its test goes red.

Rules added after the first rehearsals and the design review (below):
- **Each fault is read back from the dataplane, not only from the API**: for N1a and N3a the Service has no endpoint at all (a terminating Pod that still serves stays in the slice and kube-proxy routes to it once nothing is ready; the first rehearsal's N1a still got DNS answers while CoreDNS's ready endpoints were 0) and kube-proxy's REJECT rule for it is in the node's iptables; for N1b the cluster DNS has stopped answering a `dig` and the server Pod is still reachable directly; for N2 the qdisc shows the loss.
- **The run starts from a Service that answers**: no REJECT rule for it and one request returning 200, recorded; the third rehearsal's baseline, taken just after the server Pod became Ready, met the REJECT rule of a Service kube-proxy had not yet given its endpoint.
- **Each removal is read back too** before the recovery request: the REJECT rule gone (the second rehearsal's N1a recovery ran while the rule was still there), DNS answering again, the qdisc without netem.
- **The capture must be complete**: tcpdump says it is listening before the request starts, and its kernel drop count is 0, or the case is INVALID; it captures whole packets (`-s 0`).
- **Packets are bound to flows**: N2a's SYNs are counted per client port, N3b's RST must answer the client port that sent the SYN.
- **Deadlines**: curl gets 10 s for B and the recoveries, 20 s for N1a, 30 s for N1b (longer than the resolver's own failure, so exit 6 is the resolver's and not curl's deadline), 8 s for N2a, N3a and N3b, and 5 s per burst request; curl runs with `-q` and `--noproxy '*'`.
- **Retransmit counters** are read absolute (`nstat -asz`) on the client, and on the server around N2; the client's counter counts only its own retransmissions.
- **N2b's latency is read over completed requests only** (exit 0 and 200), failures are listed apart, and B carries a no-loss batch of 40 whose maximum must stay under 0.5 s; N2b's recovery is a batch of 20 that must all complete under 0.5 s.
- **N3b's second request is a positive control**, the same Pod on the port it listens on, not a recovery of the closed port.

## Not covered

- MTU black holes, TLS failures, and conntrack table exhaustion.
- Other CNIs, kube-proxy in IPVS or nftables mode, and cloud load balancers; the ICMP-versus-RST distinction for a Service without endpoints is kube-proxy's iptables rule here and may differ elsewhere.
- Loss on the client's side: the netem is on the server's egress only, so the loss covered is one direction, server to client.

## Review before the run

gpt-6-astra read the first draft on 2026-11-07, without direction, and returned twelve findings.
Taken: NetworkPolicy enforcement shown, not assumed (1); capture readiness and drop count (2); SYNs and the RST bound to the probe's flow (3), though DNS transaction ids and ICMP's quoted packet are matched by port only, since the client sends nothing else; "no endpoint at all" and the REJECT rule (4); the capture shows a failure stage and the read-back the cause (5, as wording); the resolver recorded (6: it is c-ares in curl, not glibc as the draft implied); per-case deadlines and `-q`/`--noproxy` (7); absolute counters and the server's counter (8); completed-only latency and listed failures (9); a no-loss batch to read the tail against (10; the packet-level gap analysis it also asked for is not done); removal read back and N2b's recovery a batch, N3b's second request named a positive control (11); the version and direction wording (12).
Not taken: none outright; the partial takes are said above.
