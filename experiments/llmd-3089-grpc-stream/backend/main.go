// Command backend is a gRPC server-streaming backend for the llm-d#3089 reproduction.
// It implements grpc.testing.TestService/StreamingOutputCall.
// Each response message is sent after the interval the request asks for.
// Each payload body carries the server's send time in Unix nanoseconds.
package main

import (
	"flag"
	"log"
	"net"
	"strconv"
	"time"

	"google.golang.org/grpc"
	testpb "google.golang.org/grpc/interop/grpc_testing"
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

func main() {
	addr := flag.String("addr", ":50051", "listen address")
	flag.Parse()
	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	s := grpc.NewServer()
	testpb.RegisterTestServiceServer(s, server{})
	log.Printf("backend listening on %s", *addr)
	if err := s.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
