// Command client calls StreamingOutputCall and prints one JSON line of receive timings.
// ttfm_ms is the time from the call to the first message.
// gaps_ms are the times between consecutive messages as the client received them.
// lag_ms is receive time minus the backend's send time, per message.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	testpb "google.golang.org/grpc/interop/grpc_testing"
)

type result struct {
	Arm     string    `json:"arm"`
	Run     int       `json:"run"`
	N       int       `json:"n"`
	TTFMms  float64   `json:"ttfm_ms"`
	TotalMs float64   `json:"total_ms"`
	GapsMs  []float64 `json:"gaps_ms"`
	LagMs   []float64 `json:"lag_ms"`
	Err     string    `json:"err,omitempty"`
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func main() {
	target := flag.String("target", "localhost:50051", "host:port")
	authority := flag.String("authority", "", "optional :authority override")
	arm := flag.String("arm", "", "arm label")
	run := flag.Int("run", 0, "run index")
	n := flag.Int("n", 18, "messages")
	interval := flag.Duration("interval", 80*time.Millisecond, "backend send interval")
	flag.Parse()

	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	if *authority != "" {
		opts = append(opts, grpc.WithAuthority(*authority))
	}
	conn, err := grpc.NewClient(*target, opts...)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	c := testpb.NewTestServiceClient(conn)

	params := make([]*testpb.ResponseParameters, *n)
	for i := range params {
		params[i] = &testpb.ResponseParameters{IntervalUs: int32(interval.Microseconds())}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	res := result{Arm: *arm, Run: *run}
	start := time.Now()
	stream, err := c.StreamingOutputCall(ctx, &testpb.StreamingOutputCallRequest{ResponseParameters: params})
	if err == nil {
		var last time.Time
		for {
			msg, rerr := stream.Recv()
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				err = rerr
				break
			}
			now := time.Now()
			if res.N == 0 {
				res.TTFMms = ms(now.Sub(start))
			} else {
				res.GapsMs = append(res.GapsMs, ms(now.Sub(last)))
			}
			if sent, perr := strconv.ParseInt(string(msg.GetPayload().GetBody()), 10, 64); perr == nil {
				res.LagMs = append(res.LagMs, ms(now.Sub(time.Unix(0, sent))))
			}
			last = now
			res.N++
		}
	}
	res.TotalMs = ms(time.Since(start))
	if err != nil {
		res.Err = err.Error()
	}
	out, _ := json.Marshal(res)
	fmt.Println(string(out))
	if err != nil {
		os.Exit(1)
	}
}
