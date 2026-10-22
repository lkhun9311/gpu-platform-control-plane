package main

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

// fakeKubelet is the kubelet's registration endpoint and nothing else, recording every request it is sent.
type fakeKubelet struct {
	pluginapi.UnimplementedRegistrationServer

	requests chan *pluginapi.RegisterRequest
	server   *grpc.Server
}

func (k *fakeKubelet) Register(_ context.Context, req *pluginapi.RegisterRequest) (*pluginapi.Empty, error) {
	k.requests <- req
	return &pluginapi.Empty{}, nil
}

// startFakeKubelet listens on dir/kubelet.sock, as a kubelet does once it has started.
func startFakeKubelet(t *testing.T, dir string) *fakeKubelet {
	t.Helper()
	lis, err := net.Listen("unix", filepath.Join(dir, "kubelet.sock"))
	if err != nil {
		t.Fatalf("listen on fake kubelet.sock: %v", err)
	}
	k := &fakeKubelet{requests: make(chan *pluginapi.RegisterRequest, 16), server: grpc.NewServer()}
	pluginapi.RegisterRegistrationServer(k.server, k)
	go func() { _ = k.server.Serve(lis) }()
	t.Cleanup(k.server.Stop)
	return k
}

// pluginDir is a temporary device-plugin directory short enough for a unix socket path.
//
// A socket path is limited to 108 bytes, and a test's default temporary directory under a long TMPDIR can
// exceed that, which would fail at listen time and read as a defect in the plugin.
func pluginDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "gpusim-")
	if err != nil {
		t.Fatalf("make plugin dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func awaitRegistration(t *testing.T, k *fakeKubelet, within time.Duration) *pluginapi.RegisterRequest {
	t.Helper()
	select {
	case req := <-k.requests:
		return req
	case <-time.After(within):
		t.Fatalf("no registration reached the kubelet within %s", within)
		return nil
	}
}

// listDevices dials the plugin's socket the way the kubelet does and returns the first device list it streams.
func listDevices(t *testing.T, socketPath string) []*pluginapi.Device {
	t.Helper()
	conn, err := grpc.NewClient("unix://"+socketPath, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial plugin socket: %v", err)
	}
	defer conn.Close() //nolint:errcheck
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stream, err := pluginapi.NewDevicePluginClient(conn).ListAndWatch(ctx, &pluginapi.Empty{})
	if err != nil {
		t.Fatalf("ListAndWatch: %v", err)
	}
	resp, err := stream.Recv()
	if err != nil {
		t.Fatalf("receive device list: %v", err)
	}
	return resp.GetDevices()
}

// startPlugin runs the plugin against dir, and returns a stop that ends it and reports what run returned.
//
// The stop runs once whoever calls it first, the test or its cleanup, so a test that stops the plugin itself
// does not leave the cleanup waiting for a second result that never comes.
func startPlugin(t *testing.T, dir string) (func() error, pluginConfig) {
	t.Helper()
	cfg := pluginConfig{
		pluginPath:   dir,
		socketName:   defaultSocketName,
		resource:     defaultResourceName,
		count:        3,
		pollInterval: 20 * time.Millisecond,
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- run(ctx, cfg) }()
	var once sync.Once
	var result error
	stop := func() error {
		once.Do(func() {
			cancel()
			select {
			case result = <-done:
			case <-time.After(5 * time.Second):
				result = errors.New("the plugin did not stop within 5 s of its context ending")
			}
		})
		return result
	}
	t.Cleanup(func() {
		if err := stop(); err != nil {
			t.Errorf("stopping the plugin: %v", err)
		}
	})
	return stop, cfg
}

// A restarted kubelet must get this plugin's registration again, from the same process, on a socket that serves.
//
// The kubelet restart is reproduced as the kubelet performs it: the old registration endpoint goes away, the
// directory is emptied of every socket, this plugin's included, and a new kubelet.sock appears.
// Before this was handled the plugin kept serving an unlinked socket and never registered again, so the node
// advertised no devices while the Pod looked healthy.
//
// Mutation that turns this red: make kubeletRestarted return false.
func TestARestartedKubeletGetsTheRegistrationAgain(t *testing.T) {
	dir := pluginDir(t)
	first := startFakeKubelet(t, dir)
	stop, cfg := startPlugin(t, dir)
	socketPath := filepath.Join(dir, cfg.socketName)

	req := awaitRegistration(t, first, 15*time.Second)
	if req.GetResourceName() != cfg.resource || req.GetEndpoint() != cfg.socketName {
		t.Fatalf("first registration = %q at %q, want %q at %q",
			req.GetResourceName(), req.GetEndpoint(), cfg.resource, cfg.socketName)
	}
	if n := len(listDevices(t, socketPath)); n != cfg.count {
		t.Fatalf("before the restart the plugin listed %d devices, want %d", n, cfg.count)
	}

	first.server.Stop()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read plugin dir: %v", err)
	}
	for _, e := range entries {
		if err := os.Remove(filepath.Join(dir, e.Name())); err != nil && !os.IsNotExist(err) {
			t.Fatalf("empty plugin dir: %v", err)
		}
	}
	second := startFakeKubelet(t, dir)

	req = awaitRegistration(t, second, 15*time.Second)
	if req.GetResourceName() != cfg.resource || req.GetEndpoint() != cfg.socketName {
		t.Fatalf("re-registration = %q at %q, want %q at %q",
			req.GetResourceName(), req.GetEndpoint(), cfg.resource, cfg.socketName)
	}
	if n := len(listDevices(t, socketPath)); n != cfg.count {
		t.Fatalf("after the restart the plugin listed %d devices, want %d", n, cfg.count)
	}

	if err := stop(); err != nil {
		t.Fatalf("after its context ended the plugin returned %v, want nil", err)
	}
}

// A kubelet that did not restart must not be registered with again, however many checks pass.
//
// Without this, a check that always answered "restarted" would pass the test above while tearing the server
// down every poll, which on a node shows up as a device list that keeps vanishing.
//
// Mutation that turns this red: make kubeletRestarted return true.
func TestAnUnchangedKubeletIsRegisteredWithOnce(t *testing.T) {
	dir := pluginDir(t)
	k := startFakeKubelet(t, dir)
	_, cfg := startPlugin(t, dir)

	awaitRegistration(t, k, 15*time.Second)
	// Twenty-five poll intervals, so a check that misfires on every tick, or on any one of them, has the chance.
	select {
	case req := <-k.requests:
		t.Fatalf("an unchanged kubelet was sent a second registration (%q)", req.GetResourceName())
	case <-time.After(25 * cfg.pollInterval):
	}
	if n := len(listDevices(t, filepath.Join(dir, cfg.socketName))); n != cfg.count {
		t.Fatalf("the plugin listed %d devices, want %d", n, cfg.count)
	}
}

// While kubelet.sock is absent the plugin waits rather than deciding, and its own missing socket alone does not
// count, because a kubelet that has not yet listened cannot take a registration.
//
// A replaced kubelet.sock counts even when the plugin's socket survived, which is the second sign the check
// accepts.
func TestKubeletRestartedReadsBothSigns(t *testing.T) {
	dir := pluginDir(t)
	kubeletSock := filepath.Join(dir, "kubelet.sock")
	own := filepath.Join(dir, defaultSocketName)

	if kubeletRestarted(kubeletSock, nil, own) {
		t.Fatalf("with no kubelet.sock and no own socket the check answered restarted")
	}

	if err := os.WriteFile(kubeletSock, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(own, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	registered, err := os.Stat(kubeletSock)
	if err != nil {
		t.Fatal(err)
	}
	if kubeletRestarted(kubeletSock, registered, own) {
		t.Fatalf("with both sockets unchanged the check answered restarted")
	}

	// A new file is created before the old one is removed, so the two cannot share an inode number.
	replacement := kubeletSock + ".new"
	if err := os.WriteFile(replacement, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, kubeletSock); err != nil {
		t.Fatal(err)
	}
	if !kubeletRestarted(kubeletSock, registered, own) {
		t.Fatalf("a replaced kubelet.sock was not read as a restart")
	}

	if err := os.Remove(own); err != nil {
		t.Fatal(err)
	}
	if !kubeletRestarted(kubeletSock, nil, own) {
		t.Fatalf("a missing own socket beside a present kubelet.sock was not read as a restart")
	}
}
