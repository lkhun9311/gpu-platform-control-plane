/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Command gpu-simulator is a CPU-only fake device plugin for nvidia.com/gpu.
//
// Design rationale (docs/09_AWS_INFRA_ARCHITECTURE.md): on EKS the kubelet, not the apiserver, owns node capacity.
//
// A kind cluster can fake that capacity with a kubectl patch, but EKS recomputes
// it from what the kubelet reports, so nothing short of a real device-plugin
// registration sticks there.
//
// This binary speaks the kubelet device-plugin v1beta1 gRPC API and registers a
// fixed number of always-healthy fake devices under nvidia.com/gpu, so
// GPU-shaped scheduling can be exercised on nodes with no real GPU hardware.
package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/go-logr/logr"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

// defaultResourceName is the extended resource this plugin advertises unless told otherwise.
//
// It is the one node-capacity name the rest of the platform already schedules
// against (GPUQuotaPolicy, InferenceDeployment), so nothing downstream needs
// to change to consume it.
//
// FAKE_RESOURCE_NAME overrides it, which is what lets one node advertise several
// profile-shaped keys from several instances of this binary. The default is the
// old constant, so a DaemonSet that sets nothing behaves exactly as before.
const defaultResourceName = "nvidia.com/gpu"

// socketName is the file this plugin listens on inside the device-plugin directory.
//
// The kubelet learns this name from the RegisterRequest and dials back to
// path.Join(DevicePluginPath, socketName), so the name only has to be stable,
// not standardized.
const defaultSocketName = "gpu-simulator.sock"

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log.WithName("gpu-simulator")

	count, err := deviceCount()
	if err != nil {
		log.Error(err, "read FAKE_GPU_COUNT")
		os.Exit(1)
	}

	// DEVICE_PLUGIN_PATH lets tests and non-standard kubelet layouts override the mount point.
	//
	// Production always leaves it unset and gets the standard kubelet path.
	pluginPath := envOr("DEVICE_PLUGIN_PATH", pluginapi.DevicePluginPath)

	// Two instances on one node must not share a socket.
	//
	// The kubelet dials back to the endpoint given in RegisterRequest, and the plugin removes a stale socket
	// at that path on startup -- so a second instance reusing the name would delete the first one's socket
	// and silently take over its resource. The socket defaults to a name derived from the resource, which
	// keeps the single-resource deployment on its historical path and makes collisions impossible to reach
	// by accident.
	resource := envOr("FAKE_RESOURCE_NAME", defaultResourceName)
	socketName := envOr("FAKE_SOCKET_NAME", socketNameFor(resource))
	log = log.WithValues("resource", resource, "socket", socketName)

	// The logger travels in the context, which is the one place every function below already reads.
	ctx, stop := signal.NotifyContext(logr.NewContext(context.Background(), log), os.Interrupt, syscall.SIGTERM)
	cfg := pluginConfig{
		pluginPath:   pluginPath,
		socketName:   socketName,
		resource:     resource,
		count:        count,
		pollInterval: kubeletPollInterval,
	}
	err = run(ctx, cfg)
	stop()
	if err != nil {
		log.Error(err, "device plugin stopped")
		os.Exit(1)
	}
}

// kubeletPollInterval is how often the plugin checks whether the kubelet has restarted.
//
// Until the check after a restart, the node advertises none of this plugin's devices, so the interval is the
// longest that gap lasts beyond the kubelet's own start; two stat calls a second is what it costs.
const kubeletPollInterval = 1 * time.Second

// pluginConfig is what one plugin instance serves, and where.
type pluginConfig struct {
	pluginPath   string
	socketName   string
	resource     string
	count        int
	pollInterval time.Duration
}

// run serves the plugin and registers it, and does both again each time the kubelet restarts, until ctx ends.
//
// A starting kubelet deletes every socket in the device-plugin directory, this plugin's included, and keeps no
// record of earlier registrations, so a plugin that registered once is forgotten by the restarted kubelet.
// On kind on 2026-09-29 that left a simulator Pod Running with 0 restarts while its node advertised 0 GPUs,
// because nothing in this binary noticed.
// Real device plugins watch kubelet.sock for the same reason; this one polls, which needs no new dependency.
func run(ctx context.Context, cfg pluginConfig) error {
	for {
		restarted, err := serveOnce(ctx, cfg)
		if err != nil || !restarted {
			return err
		}
		logr.FromContextOrDiscard(ctx).Info("kubelet restarted, serving and registering again")
	}
}

// serveOnce listens, registers and serves until ctx ends (false), the server fails (an error), or the kubelet
// restarts (true).
func serveOnce(ctx context.Context, cfg pluginConfig) (bool, error) {
	log := logr.FromContextOrDiscard(ctx)
	socketPath := filepath.Join(cfg.pluginPath, cfg.socketName)

	// A prior instance's socket can survive a crash or a plain container restart.
	//
	// net.Listen on a unix path fails with "address already in use" if the
	// file is still there, so it is removed first.
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		return false, fmt.Errorf("remove stale socket %s: %w", socketPath, err)
	}

	lis, err := net.Listen("unix", socketPath)
	if err != nil {
		return false, fmt.Errorf("listen on device plugin socket %s: %w", socketPath, err)
	}

	grpcServer := grpc.NewServer()
	simulator := &gpuSimulator{devices: fakeDevices(cfg.count), stop: make(chan struct{})}
	pluginapi.RegisterDevicePluginServer(grpcServer, simulator)

	serveErr := make(chan error, 1)
	go func() {
		// The logger already carries resource and socket name; this adds the full path, under its own key.
		log.Info("serving device plugin", "path", socketPath)
		serveErr <- grpcServer.Serve(lis)
	}()

	// The kubelet must be able to dial socketName before Register is called.
	//
	// That ordering is why registration happens after Serve starts, not before.
	if err := registerWithKubeletRetry(ctx, cfg.pluginPath, cfg.socketName, cfg.resource); err != nil {
		grpcServer.Stop()
		// A SIGTERM that arrives while a registration is retried is a shutdown, not a failed registration.
		if ctx.Err() != nil {
			return false, nil
		}
		return false, err
	}
	log.Info("registered with kubelet", "devices", cfg.count)

	// The kubelet socket as it was when the registration succeeded, to tell a later one apart from it.
	//
	// A failed stat leaves it nil, and the check then relies on this plugin's own socket alone, which a
	// restarting kubelet removes in any case.
	kubeletSock := filepath.Join(cfg.pluginPath, "kubelet.sock")
	registeredWith, err := os.Stat(kubeletSock)
	if err != nil {
		registeredWith = nil
	}

	ticker := time.NewTicker(cfg.pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Info("shutting down")

			// ListAndWatch only returns when its stream context ends or this
			// channel closes, and the stream context never ends on its own.
			//
			// Closing it here, before GracefulStop, is what lets the in-flight
			// ListAndWatch call return so GracefulStop can finish instead of
			// blocking until the kubelet sends SIGKILL.
			close(simulator.stop)
			grpcServer.GracefulStop()
			return false, nil
		case err := <-serveErr:
			if err != nil {
				return false, fmt.Errorf("device plugin server stopped: %w", err)
			}
			return false, nil
		case <-ticker.C:
			if kubeletRestarted(kubeletSock, registeredWith, socketPath) {
				// Stop, not GracefulStop: the kubelet holding the old streams is gone, and nothing it had open
				// is worth waiting for.
				close(simulator.stop)
				grpcServer.Stop()
				return true, nil
			}
		}
	}
}

// kubeletRestarted reports whether the kubelet this plugin registered with has been replaced.
//
// Nothing is decided while kubelet.sock is absent, because a kubelet that has not created it yet cannot take a
// registration.
// Once it is there, either sign counts: this plugin's own socket is gone, which is what a starting kubelet's
// cleanup of the directory leaves, or kubelet.sock is a different file from the one registered with.
// The first is the one relied on, because a recreated file can be given the old inode number and then compare
// as the same file, which is what happened in this package's restart test on a tmpfs /tmp when the first sign
// was disabled.
func kubeletRestarted(kubeletSock string, registeredWith os.FileInfo, ownSocket string) bool {
	now, err := os.Stat(kubeletSock)
	if err != nil {
		return false
	}
	if _, err := os.Stat(ownSocket); errors.Is(err, fs.ErrNotExist) {
		return true
	}
	return registeredWith != nil && !os.SameFile(registeredWith, now)
}

// deviceCount reads FAKE_GPU_COUNT, defaulting to one fake device.
//
// One is enough to make nvidia.com/gpu schedulable at all, which is the
// minimum this simulator promises.
func deviceCount() (int, error) {
	raw := envOr("FAKE_GPU_COUNT", "1")
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("parse FAKE_GPU_COUNT %q: %w", raw, err)
	}
	if n < 1 {
		return 0, fmt.Errorf("invalid FAKE_GPU_COUNT %q: must be at least 1", raw)
	}
	return n, nil
}

// fakeDevices builds n always-healthy devices with stable, predictable IDs.
//
// Allocate never inspects these IDs, since there is no real device behind
// them, so the only requirement is that each ID stay unique for the
// lifetime of the process.
func fakeDevices(n int) []*pluginapi.Device {
	devices := make([]*pluginapi.Device, 0, n)
	for i := range n {
		devices = append(devices, &pluginapi.Device{
			ID:     fmt.Sprintf("fake-gpu-%d", i),
			Health: pluginapi.Healthy,
		})
	}
	return devices
}

// registerRetryBackoff is the pause between failed kubelet registration attempts.
const registerRetryBackoff = 1 * time.Second

// registerWithKubeletRetry retries registerWithKubelet until it succeeds or
// the overall 10-second timeout expires.
//
// The very first registration attempt can lose a race with a kubelet
// restart, since kubelet.sock is briefly unreachable while the kubelet
// comes back up.
//
// Retrying inside the same startup recovers from that race in seconds,
// rather than leaving recovery to the pod's much slower restart backoff.
//
// It takes the caller's context so that a SIGTERM during a re-registration ends the wait at once.
func registerWithKubeletRetry(parent context.Context, pluginPath, endpoint, resource string) error {
	log := logr.FromContextOrDiscard(parent)
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()

	var lastErr error
	for {
		err := registerWithKubelet(ctx, pluginPath, endpoint, resource)
		if err == nil {
			return nil
		}
		lastErr = err

		log.V(1).Info("retrying kubelet registration", "error", lastErr)

		select {
		case <-ctx.Done():
			return fmt.Errorf("register with kubelet: %w", lastErr)
		case <-time.After(registerRetryBackoff):
		}
	}
}

// registerWithKubelet dials the kubelet's registration socket and
// advertises resource at pluginPath/endpoint.
//
// The resource travels as an argument because it stopped being a constant: one binary now serves whichever
// key FAKE_RESOURCE_NAME names, and a helper reading a package-level default would quietly advertise the
// wrong one for every instance but the first.
//
// The kubelet socket is derived from pluginPath rather than
// pluginapi.KubeletSocket, so that a DEVICE_PLUGIN_PATH override applies
// consistently to both sides of the handshake.
func registerWithKubelet(ctx context.Context, pluginPath, endpoint, resource string) error {
	target := "unix://" + filepath.Join(pluginPath, "kubelet.sock")
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("dial kubelet registration socket: %w", err)
	}
	defer conn.Close() //nolint:errcheck

	req := &pluginapi.RegisterRequest{
		Version:      pluginapi.Version,
		Endpoint:     endpoint,
		ResourceName: resource,
		Options:      &pluginapi.DevicePluginOptions{},
	}
	if _, err := pluginapi.NewRegistrationClient(conn).Register(ctx, req); err != nil {
		return fmt.Errorf("call kubelet register: %w", err)
	}
	return nil
}

// envOr returns the environment value for key or def when unset.
// socketNameFor derives a socket file name from a resource name.
//
// "nvidia.com/gpu" keeps the historical "gpu-simulator.sock" so an existing deployment is byte-identical;
// anything else is slugified, because a socket path cannot contain the slashes and dots a resource name does.
func socketNameFor(resource string) string {
	if resource == defaultResourceName {
		return defaultSocketName
	}
	slug := strings.NewReplacer("/", "-", ".", "-").Replace(resource)
	return "gpu-simulator-" + slug + ".sock"
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// gpuSimulator implements the kubelet device-plugin v1beta1 gRPC API with no backing hardware.
//
// It embeds UnimplementedDevicePluginServer, which is required for forward
// compatibility with the interface and is never itself called since every
// method below is overridden.
type gpuSimulator struct {
	pluginapi.UnimplementedDevicePluginServer

	devices []*pluginapi.Device

	// stop is closed once, from main's shutdown path, to unblock every
	// in-flight ListAndWatch call.
	//
	// Without it, ListAndWatch would only return when the stream's own
	// context ends, which never happens on a normal SIGTERM, so
	// GracefulStop would hang until the kubelet gives up and sends SIGKILL.
	stop chan struct{}
}

// GetDevicePluginOptions reports that this plugin needs no
// PreStartContainer calls and offers no preferred allocation hints.
func (p *gpuSimulator) GetDevicePluginOptions(
	context.Context, *pluginapi.Empty,
) (*pluginapi.DevicePluginOptions, error) {
	return &pluginapi.DevicePluginOptions{}, nil
}

// ListAndWatch streams the fixed device list once and then blocks.
//
// A real plugin re-sends the list whenever a device's health changes, but
// these fake devices never change health, so there is nothing to watch for.
//
// The stream must still be held open for as long as the kubelet expects to
// receive updates on it, which is why this returns only when the stream's
// context ends or the process is shutting down.
//
// Selecting on p.stop as well as the stream context is what lets a normal
// SIGTERM unblock this call, since the stream context alone never ends on
// its own, and an always-blocked ListAndWatch would otherwise deadlock
// grpcServer.GracefulStop() until the kubelet resorts to SIGKILL.
func (p *gpuSimulator) ListAndWatch(_ *pluginapi.Empty, stream pluginapi.DevicePlugin_ListAndWatchServer) error {
	if err := stream.Send(&pluginapi.ListAndWatchResponse{Devices: p.devices}); err != nil {
		return fmt.Errorf("send device list: %w", err)
	}
	select {
	case <-stream.Context().Done():
	case <-p.stop:
	}
	return nil
}

// GetPreferredAllocation returns no preference, deferring the allocation
// choice entirely to the kubelet.
func (p *gpuSimulator) GetPreferredAllocation(
	context.Context, *pluginapi.PreferredAllocationRequest,
) (*pluginapi.PreferredAllocationResponse, error) {
	return &pluginapi.PreferredAllocationResponse{}, nil
}

// Allocate returns one empty response per requested container.
//
// A real plugin would inject device nodes, mounts, or environment variables
// here, but there is no real device behind a fake GPU, so an empty
// ContainerAllocateResponse is the whole answer.
func (p *gpuSimulator) Allocate(
	_ context.Context, req *pluginapi.AllocateRequest,
) (*pluginapi.AllocateResponse, error) {
	resp := &pluginapi.AllocateResponse{
		ContainerResponses: make([]*pluginapi.ContainerAllocateResponse, len(req.GetContainerRequests())),
	}
	for i := range resp.ContainerResponses {
		resp.ContainerResponses[i] = &pluginapi.ContainerAllocateResponse{}
	}
	return resp, nil
}

// PreStartContainer does nothing, since GetDevicePluginOptions already
// declared PreStartRequired false.
func (p *gpuSimulator) PreStartContainer(
	context.Context, *pluginapi.PreStartContainerRequest,
) (*pluginapi.PreStartContainerResponse, error) {
	return &pluginapi.PreStartContainerResponse{}, nil
}
