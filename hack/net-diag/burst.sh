# Runs inside the client Pod (bash, from stdin): N requests one after another and the retransmit counter around them.
r0=$(nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}')
for i in $(seq 1 "$N"); do
  curl -q -sS --noproxy '*' -m 5 -o /dev/null -w "req=$i http=%{http_code} t_total=%{time_total} t_connect=%{time_connect}" "$URL" 2> /tmp/err
  echo " exit=$?"
done
r1=$(nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}')
echo "retrans_before=$r0 retrans_after=$r1"
