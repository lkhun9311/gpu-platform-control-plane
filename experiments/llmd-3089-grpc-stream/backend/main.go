// Command backend is a gRPC server-streaming backend for the llm-d#3089 reproduction.
// It implements grpc.testing.TestService/StreamingOutputCall and UnaryCall.
// Each streamed message is sent after the interval the request asks for.
// Each streamed payload body carries the server's send time in Unix nanoseconds.
// With -mode json it instead serves a fixed non-streaming JSON completion over HTTP/1.1 and h2c.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
	"google.golang.org/grpc"
	testpb "google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/metadata"
)

type server struct {
	testpb.UnimplementedTestServiceServer
}

// StreamingOutputCall sends one message per response parameter.
// It sleeps IntervalUs before each send, so the client sees one message per interval.
func (server) StreamingOutputCall(req *testpb.StreamingOutputCallRequest, stream testpb.TestService_StreamingOutputCallServer) error {
	for i, p := range req.GetResponseParameters() {
		time.Sleep(time.Duration(p.GetIntervalUs()) * time.Microsecond)
		body := []byte(strconv.FormatInt(time.Now().UnixNano(), 10))
		if err := stream.Send(&testpb.StreamingOutputCallResponse{
			Payload: &testpb.Payload{Body: body},
		}); err != nil {
			log.Printf("send %d: %v", i, err)
			return err
		}
	}
	return nil
}

// UnaryCall returns ResponseSize deterministic bytes.
// A custom header and trailer carry the payload digest, so a client can check that both survive the proxy unchanged.
func (server) UnaryCall(ctx context.Context, req *testpb.SimpleRequest) (*testpb.SimpleResponse, error) {
	body := make([]byte, req.GetResponseSize())
	for i := range body {
		body[i] = byte(i*31 + 7)
	}
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])
	if err := grpc.SetHeader(ctx, metadata.Pairs("x-backend-header", digest)); err != nil {
		return nil, err
	}
	if err := grpc.SetTrailer(ctx, metadata.Pairs("x-backend-trailer", digest)); err != nil {
		return nil, err
	}
	return &testpb.SimpleResponse{Payload: &testpb.Payload{Body: body}}, nil
}

// jsonCompletion is a fixed OpenAI-style non-streaming response of about 1 KiB.
var jsonCompletion = []byte(`{"id":"cmpl-1","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"` +
	strings.Repeat("lorem ipsum ", 75) + `"}}],"usage":{"prompt_tokens":8,"completion_tokens":150,"total_tokens":158}}`)

func serveJSON(lis net.Listener, delay time.Duration) error {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(delay)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write(jsonCompletion)
	})
	return (&http.Server{Handler: h2c.NewHandler(handler, &http2.Server{}), ReadHeaderTimeout: 10 * time.Second}).Serve(lis)
}

func main() {
	addr := flag.String("addr", ":50051", "listen address")
	mode := flag.String("mode", "grpc", "grpc or json")
	jsonDelay := flag.Duration("json-delay", 20*time.Millisecond, "time before the JSON response is written")
	flag.Parse()
	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("backend listening on %s in %s mode", *addr, *mode)
	if *mode == "json" {
		log.Fatal(serveJSON(lis, *jsonDelay))
	}
	s := grpc.NewServer()
	testpb.RegisterTestServiceServer(s, server{})
	if err := s.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
