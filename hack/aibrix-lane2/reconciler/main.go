// Command reconciler runs gpuaas's InferenceDeployment reconciler, and only it, against the cluster of its kubeconfig.
//
// The AIBrix lane-2 lab (hack/aibrix-lane2.sh) needs the code that renders the serving Deployment and decides who
// writes its replicas, and nothing else of the manager.
// The full manager also starts the admission webhooks and the Kueue-backed controllers, which need certificates and
// CRDs the lab does not install, and none of which touches a Deployment's replicas.
// So this is the same reconciler type the manager registers, wired to a manager of its own.
package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/clientcmd"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/controller"
)

func main() {
	// controller-runtime registers --kubeconfig itself, so this reads that flag rather than defining a second one.
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	log := ctrl.Log.WithName("aibrix-lane2-reconciler")

	// An empty path would fall back to ~/.kube/config, which is exactly the file this lab promises not to touch.
	kubeconfig := ""
	if f := flag.Lookup("kubeconfig"); f != nil {
		kubeconfig = f.Value.String()
	}
	if kubeconfig == "" {
		log.Info("refusing to start without --kubeconfig")
		os.Exit(2)
	}
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		log.Error(err, "load kubeconfig")
		os.Exit(1)
	}

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(platformv1.AddToScheme(scheme))

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
	})
	if err != nil {
		log.Error(err, "create manager")
		os.Exit(1)
	}
	r := &controller.InferenceDeploymentReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme()}
	if err := r.SetupWithManager(mgr); err != nil {
		log.Error(err, "set up InferenceDeployment reconciler")
		os.Exit(1)
	}
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Error(err, "manager exited")
		os.Exit(1)
	}
}
