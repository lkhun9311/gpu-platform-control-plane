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
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

// resourceName is the extended resource this plugin advertises.
//
// It is the one node-capacity name the rest of the platform already schedules
// against (GPUQuotaPolicy, InferenceDeployment), so nothing downstream needs
// to change to consume it.
const resourceName = "nvidia.com/gpu"

// socketName is the file this plugin listens on inside the device-plugin directory.
//
// The kubelet learns this name from the RegisterRequest and dials back to
// path.Join(DevicePluginPath, socketName), so the name only has to be stable,
// not standardized.
const socketName = "gpu-simulator.sock"

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
	socketPath := filepath.Join(pluginPath, socketName)

	// A prior instance's socket can survive a crash or a plain container restart.
	//
	// net.Listen on a unix path fails with "address already in use" if the
	// file is still there, so it is removed first.
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		log.Error(err, "remove stale socket", "path", socketPath)
		os.Exit(1)
	}

	lis, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Error(err, "listen on device plugin socket", "path", socketPath)
		os.Exit(1)
	}

	grpcServer := grpc.NewServer()
	pluginapi.RegisterDevicePluginServer(grpcServer, &gpuSimulator{devices: fakeDevices(count)})

	serveErr := make(chan error, 1)
	go func() {
		log.Info("serving device plugin", "socket", socketPath)
		serveErr <- grpcServer.Serve(lis)
	}()

	// The kubelet must be able to dial socketName before Register is called.
	//
	// That ordering is why registration happens after Serve starts, not before.
	if err := registerWithKubelet(pluginPath, socketName); err != nil {
		log.Error(err, "register with kubelet")
		grpcServer.Stop()
		os.Exit(1)
	}
	log.Info("registered with kubelet", "resource", resourceName, "devices", count)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	select {
	case <-ctx.Done():
		log.Info("shutting down")
		grpcServer.GracefulStop()
	case err := <-serveErr:
		if err != nil {
			log.Error(err, "device plugin server stopped")
			os.Exit(1)
		}
	}
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

// registerWithKubelet dials the kubelet's registration socket and
// advertises resourceName at pluginPath/endpoint.
//
// The kubelet socket is derived from pluginPath rather than
// pluginapi.KubeletSocket, so that a DEVICE_PLUGIN_PATH override applies
// consistently to both sides of the handshake.
func registerWithKubelet(pluginPath, endpoint string) error {
	target := "unix://" + filepath.Join(pluginPath, "kubelet.sock")
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("dial kubelet registration socket: %w", err)
	}
	defer conn.Close() //nolint:errcheck

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req := &pluginapi.RegisterRequest{
		Version:      pluginapi.Version,
		Endpoint:     endpoint,
		ResourceName: resourceName,
		Options:      &pluginapi.DevicePluginOptions{},
	}
	if _, err := pluginapi.NewRegistrationClient(conn).Register(ctx, req); err != nil {
		return fmt.Errorf("call kubelet register: %w", err)
	}
	return nil
}

// envOr returns the environment value for key or def when unset.
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
// context is done.
func (p *gpuSimulator) ListAndWatch(_ *pluginapi.Empty, stream pluginapi.DevicePlugin_ListAndWatchServer) error {
	if err := stream.Send(&pluginapi.ListAndWatchResponse{Devices: p.devices}); err != nil {
		return fmt.Errorf("send device list: %w", err)
	}
	<-stream.Context().Done()
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
