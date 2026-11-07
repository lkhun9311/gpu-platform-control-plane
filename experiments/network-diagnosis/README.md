# Network diagnosis cases: DNS, packet loss and refused connections — the results

The design, written before the scored run and reviewed by gpt-6-astra, is `docs/superpowers/specs/2026-11-07-network-diagnosis-cases-design.md`.
The run is `hack/net-diag-20261107T004649Z/` (2026-11-07 00:46 UTC), scored by `hack/net-diag/check.py`; `hack/test/check-net-diag.sh` pins every rule of the checker against copies of this run with one thing changed.
One throwaway single-node cluster: Kubernetes v1.37.0 on a kind node image, kube-proxy in iptables mode, kindnet `v20260820-69b56db7`, CoreDNS v1.14.6, host kernel 7.0.0-31.
The client is curl 8.14.1 on musl, resolving through c-ares 1.34.5, with `ndots:5` and the cluster search list (`versions.txt`).
Every case: a capture on the client's `eth0` that was listening before the request and dropped nothing, the kernel's retransmit counter around it, the fault read back from the dataplane, the fault removed and read back, and a request that must succeed again.

## The headline

**The same error text has two causes in each pair, and the capture tells them apart in one look.**

| curl says | cause | what the client's capture shows | how fast |
|---|---|---|---|
| (6) Could not resolve host | CoreDNS has no endpoint | three queries, each answered by `ICMP … udp port 53 unreachable` from the node | 0.23 ms |
| (6) Could not resolve host | DNS dropped on the way (a NetworkPolicy) | six queries (A and AAAA, three times), no answer, no ICMP | 11.2 to 12.6 s |
| (7) Could not connect to server | the Service has no endpoint | one SYN to the ClusterIP and `ICMP … tcp port 80 unreachable` from the node, no RST | 0.4 ms |
| (7) Could not connect to server | the Pod listens on nothing at that port | one SYN and a RST from the Pod's own IP to the same client port | 0.1 ms |
| (28) Connection timed out | all packets from the server lost | seven SYNs from one client port, no SYN-ACK, no RST; client retransmit counter +6 | curl's 8 s deadline |

An instant "no endpoint" (ICMP from the node) points at the cluster: a selector, readiness or scale problem.
A RST points at the process. Silence points at the path.
Both DNS failures print the same message, and only the time and the presence of ICMP separate a missing CoreDNS from a policy or path that drops DNS.

**Partial loss does not fail requests; it makes some of them slow.**
With 30% loss on the server's egress, 40 of 40 requests completed in every repetition, but 16 or 17 of each 40 took 0.5 s or more, the slowest 2.7, 3.1 and 4.7 s; the median was 0.21, 0.0012 and 0.10 s.
The client's retransmit counter rose by 39, 21 and 32 and the server's by 76, 74 and 86.
The same batch with no loss, in the same repetition, never exceeded 1.1 ms.
After the loss was removed, 20 of 20 requests completed under 0.5 s.
A success-rate alert sees nothing here; a latency percentile or the retransmit counter does.

## Every case held in 3 of 3, none invalid

| case | fault | held | invalid |
|---|---|---:|---:|
| B | none; plus a no-loss batch of 40 | 3 of 3 | 0 |
| N1a | CoreDNS scaled to 0 | 3 of 3 | 0 |
| N1b | NetworkPolicy: the client may reach only the server Pod | 3 of 3 | 0 |
| N2a | netem `loss 100%` on the server's egress | 3 of 3 | 0 |
| N2b | netem `loss 30%` on the server's egress, 40 requests | 3 of 3 | 0 |
| N3a | the server Pod relabelled, the Service has no endpoint | 3 of 3 | 0 |
| N3b | a request to the server Pod's IP on port 8081 | 3 of 3 | 0 |

## What the first rehearsals found, which the runner now checks

- **"No ready endpoint" is not "nothing answers".** With CoreDNS scaled to 0 and its EndpointSlice reporting no ready endpoint, the first rehearsal's request still resolved: a terminating Pod that still serves stays in the slice, and kube-proxy sends traffic to it when nothing is ready. The runner now waits for the Pods to be gone, the slice to hold no endpoint at all, and kube-proxy's REJECT rule for the Service to be in the node's iptables.
- **A ready endpoint is not yet a dataplane without the REJECT rule.** The second rehearsal's DNS recovery failed while the rule was still there. Each removal is now read back from iptables before the recovery request.
- **A Ready server Pod is not yet a Service that answers.** The third rehearsal's baseline, taken just after the Pod became Ready, met the REJECT rule of a Service kube-proxy had not yet given its endpoint. The run starts only after a request has returned 200.

All three are the same lesson an operator meets: the API object and the dataplane disagree for a moment, and a probe in that moment reads as a different fault.

## The commands

| question | command, from a debug Pod with `NET_RAW` |
|---|---|
| what stage did it fail at | `tcpdump -i eth0 -n 'port 53 or port 80 or icmp'` around one `curl` |
| is DNS missing or dropped | `dig +time=1 +tries=1 kubernetes.default.svc.cluster.local`: an instant "connection refused" (ICMP) against a timeout |
| does the Service have endpoints at all | `kubectl get endpointslices -l kubernetes.io/service-name=<svc> -o yaml`, every endpoint and its conditions, not only ready ones |
| has kube-proxy acted on it | on the node: `iptables-save -t filter \| grep '<ns>/<svc>.* has no endpoints'` |
| is the path losing packets | `nstat -asz TcpRetransSegs` before and after, on both ends |
| is the process listening | in the Pod: `ss -ltn` |

## What this does not say

- Nothing about other CNIs, kube-proxy in IPVS or nftables mode, or cloud load balancers: the ICMP for a Service without endpoints is kube-proxy's iptables REJECT rule here and may be absent elsewhere.
- Nothing about loss from client to server, MTU, TLS or conntrack exhaustion.
- The 11 to 13 s of the dropped-DNS case is c-ares with this resolver configuration; another resolver or `ndots` gives another figure.
- The captures show the stage a request failed at; that the cause was the injected fault is established by each fault's read-back, not by the capture alone.

## The record

The captures hold only the throwaway cluster's Pod, Service and bridge addresses.
gpt-6-astra read the design before the run and returned twelve findings; all were taken, two of them (3 and 10) only in part, as the design records.
The checker's fifteen rules were each broken once and its test went red each time (2026-11-07). A bare astra review of the branch then found three ways the checker mishandled incomplete evidence (a repetition with no `case.json` dropped from the count, unreadable evidence aborting the whole verdict, an empty REJECT read-back accepted); all three were fixed, pinned and broken once, and the committed verdict is unchanged.
