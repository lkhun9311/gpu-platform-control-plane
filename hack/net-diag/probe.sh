# Runs inside the client Pod (bash, from stdin): a capture around one HTTP request, and the kernel's retransmit counter.
# URL and TIMEOUT come from the environment. Every line it prints is read by hack/net-diag/check.py.
tcpdump -i eth0 -n -U -s 0 -w /tmp/cap.pcap 'port 53 or port 80 or port 8080 or port 8081 or icmp' > /tmp/td.log 2>&1 &
td=$!
# The request starts only once tcpdump says it is listening, so an absence in the capture is not a late start.
for _ in $(seq 1 50); do grep -q "listening on" /tmp/td.log && break; sleep 0.1; done
grep -q "listening on" /tmp/td.log && echo "capture_ready=1" || echo "capture_ready=0"
# Absolute counters (-a), not written back to nstat's history (-s), so two reads subtract cleanly.
r0=$(nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}')
curl -q -sS --noproxy '*' -m "$TIMEOUT" -o /dev/null -w 'http=%{http_code} t_total=%{time_total} t_dns=%{time_namelookup} t_connect=%{time_connect} local_port=%{local_port}\n' "$URL" > /tmp/curl.out 2> /tmp/curl.err
rc=$?
r1=$(nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}')
echo "curl_exit=$rc"
cat /tmp/curl.out
echo "curl_error=$(tr '\n' ' ' < /tmp/curl.err)"
echo "retrans_before=$r0 retrans_after=$r1"
sleep 1
kill -INT "$td"
wait "$td"
# tcpdump prints its own drop count when it stops; a capture the kernel dropped from is not evidence of absence.
echo "kernel_dropped=$(awk '/dropped by kernel/{print $1}' /tmp/td.log)"
tcpdump -n -r /tmp/cap.pcap > /tmp/td.txt 2> /tmp/td.err
echo "tcpdump_read_exit=$?"
echo "--- capture"
cat /tmp/td.txt
echo "--- end"
