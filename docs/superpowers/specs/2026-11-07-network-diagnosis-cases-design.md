# Network diagnosis cases: DNS, packet loss and refused connections (M-42A-5, network)

Written 2026-11-07, before any scored run.
Status: **design; not yet run.**
This extends item M-42A-5 of the operations track (`docs/superpowers/specs/2026-10-31-inference-portfolio-roadmap.md`) with the network incident the 2026-11-07 JD review asked for: telling a DNS failure, packet loss and a refused connection apart from evidence, and showing recovery once the cause is removed.
The memory and OOM cases of the same item are `docs/superpowers/specs/2026-11-07-linux-diagnosis-cases-design.md`.

## What it is for

A training rank that cannot reach its rendezvous, or a client that cannot reach an inference Service, reports one of a handful of curl or socket errors.
The same error text can come from different causes, and different causes can look alike from the application: this design picks cases where the error alone misleads and a capture on the client settles it.
Each case is a fault injected on kind, a request from a client Pod with a packet capture and the kernel's retransmit counter around it, the fault removed, and a request that must succeed again.

It licenses statements about kind v1.37 with its default CNI (kindnet) and kube-proxy, at the versions recorded with the run.
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
- **"DNS is down" has two signatures.** With no CoreDNS endpoint, kube-proxy rejects the query and the failure is instant, with ICMP; with DNS dropped on the way, every query goes unanswered and the failure takes the resolver's timeouts (about 12 s here, with `ndots:5` and the search list).
- **"Could not connect" has two causes the error text does not separate.** A Service with no endpoints is answered by the node with ICMP port unreachable; a Pod with nothing listening answers with a RST.
  The first is a selector, readiness or scale problem in the cluster; the second is the process.
- **Partial loss does not fail; it is slow**: all 40 requests succeeded, and the tail sits at the 1 s retransmission timeout, with the retransmit counter as the witness.

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
| B | exit 0, 200; at least one SYN and one SYN-ACK in the capture; recovery not applicable |
| N1a | exit 6; `time_total` under 1 s; at least one query to port 53 and at least one `udp port 53 unreachable`; no SYN to port 80; recovery 200 |
| N1b | exit 6; `time_total` at least 5 s; at least two queries, no DNS answer, no ICMP; no SYN to port 80; recovery 200 |
| N2a | exit 28; at least three SYNs to the Service, no SYN-ACK, no RST; retransmit delta at least 2; recovery 200 |
| N2b | at least 36 of 40 requests 200; retransmit delta at least 5; median `time_total` under 0.5 s and maximum at least 0.9 s; recovery 200 |
| N3a | exit 7; `time_total` under 1 s; at least one `tcp port 80 unreachable`; no RST; the server's EndpointSlice had no ready endpoint; recovery 200 |
| N3b | exit 7; at least one RST from the server Pod's IP; no ICMP; recovery 200 |

N2b's thresholds are wide on purpose: loss is random, and the spike's 40 of 40, +33 and 1.06 s p90 are one draw.
Every rule is pinned by a test in `hack/test/check-net-diag.sh` against copies of the scored run with one thing changed, and each rule is broken once to show its test goes red.

## Not covered

- MTU black holes, TLS failures, and conntrack table exhaustion.
- Other CNIs, kube-proxy in IPVS or nftables mode, and cloud load balancers; the ICMP-versus-RST distinction for a Service without endpoints is kube-proxy's iptables rule here and may differ elsewhere.
- Loss on the client's side or asymmetric loss: the netem is on the server's egress only.
