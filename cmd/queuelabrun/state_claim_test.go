package main

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// armsTheProtocolDefines is the same list TestParseArmAcceptsEveryArmTheProtocolDefines keeps, and it
// carries the same limitation: PolicyVariant refuses an arm it does not know, so a name listed here that
// the protocol dropped fails loudly — but an arm ADDED to the protocol and not added here is simply not
// swept. That gap is item 5 of the resume arms' pre-registration, and no mechanism in this package closes
// it today.
//
// What the tests below do avoid is a second hand-written statement of WHICH arms checkpoint. They ask
// StateFor, so an arm that starts or stops checkpointing changes these expectations without an edit here.
func armsTheProtocolDefines(t *testing.T) []queuelab.Arm {
	t.Helper()
	arms := []queuelab.Arm{
		queuelab.ArmAHonor, queuelab.ArmAIgnore, queuelab.ArmNRef,
		queuelab.ArmDFull, queuelab.ArmDQuarter,
		queuelab.ArmEFresh, queuelab.ArmEResume,
	}
	for _, a := range arms {
		if _, err := a.PolicyVariant(); err != nil {
			t.Fatalf("%s is listed here but the protocol does not define it: %v", a, err)
		}
	}
	return arms
}

// Mutation that turns this red: delete either case from stateRequestFor's switch.
//
// The missing-class half is the registered requirement — a claim created without a class takes the
// cluster's by omission. The superfluous-class half is the failure decideOperatorMode already refuses for
// its own run-only flags: an invocation that looks configured to its author while doing none of it.
func TestStateRequestForRefusesAnArmAndAClassThatDisagree(t *testing.T) {
	const class = "fast-ssd"
	for _, a := range armsTheProtocolDefines(t) {
		plan, err := a.StateFor(queuelab.VictimRow)
		if err != nil {
			t.Fatalf("%s: asking the protocol what it checkpoints: %v", a, err)
		}

		bare, bareErr := stateRequestFor(a, "")
		named, namedErr := stateRequestFor(a, class)

		if plan.Checkpoint {
			if bareErr == nil {
				t.Fatalf("%s checkpoints, so it needs a claim, but no -state-class was accepted", a)
			}
			if !strings.Contains(bareErr.Error(), "-state-class") {
				t.Fatalf("%s: the refusal must name the flag that fixes it: %v", a, bareErr)
			}
			if namedErr != nil {
				t.Fatalf("%s with a class must be accepted: %v", a, namedErr)
			}
			if !named.Needed || named.Class != class {
				t.Fatalf("%s resolved to %+v, which does not ask for the class it was given", a, named)
			}
			continue
		}

		if bareErr != nil {
			t.Fatalf("%s checkpoints nothing and needs no class: %v", a, bareErr)
		}
		if bare.Needed || bare.Class != "" {
			t.Fatalf("%s checkpoints nothing but resolved to %+v", a, bare)
		}
		if namedErr == nil {
			t.Fatalf("%s checkpoints nothing, so -state-class would create no claim and do nothing, "+
				"but it was accepted", a)
		}
		if !strings.Contains(namedErr.Error(), string(a)) {
			t.Fatalf("%s: the refusal must name the arm that made the flag useless: %v", a, namedErr)
		}
	}
}

// stateRequest's Class field is documented as empty exactly when Needed is false, and run relies on that:
// it reaches for state.Class only inside `if state.Needed`. A resolver that could return one without the
// other would make that reliance wrong somewhere no compiler would say so.
//
// Mutation that turns this red: return stateRequest{Needed: true} for a non-checkpointing arm.
func TestAResolvedStateRequestCarriesAClassExactlyWhenItNeedsOne(t *testing.T) {
	for _, a := range armsTheProtocolDefines(t) {
		for _, class := range []string{"", "fast-ssd"} {
			got, err := stateRequestFor(a, class)
			if err != nil {
				// The disagreeing combinations are refused, and the test above is what covers them.
				continue
			}
			if got.Needed != (got.Class != "") {
				t.Fatalf("%s with class %q resolved to %+v, which breaks the field's own invariant",
					a, class, got)
			}
		}
	}
}

// Mutation that turns this red: return nil from checkStorageClass's IsNotFound branch.
//
// Without the check the claim is still created, the apiserver accepts it, and nothing fails until the
// victim has waited out the horizon Pending — on a run that has by then taken a worker and applied
// fixtures.
func TestCheckStorageClassRefusesOneTheClusterDoesNotHave(t *testing.T) {
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).Build()

	err := checkStorageClass(context.Background(), c, "fast-ssd")
	if err == nil {
		t.Fatal("accepted a storage class the cluster does not have")
	}
	if !strings.Contains(err.Error(), "fast-ssd") {
		t.Fatalf("the refusal must name the class the operator asked for: %v", err)
	}
}

// The control. Without it a checkStorageClass that refused everything would satisfy the spec above, and the
// resume arms would be unrunnable on every cluster.
func TestCheckStorageClassAcceptsOneTheClusterHas(t *testing.T) {
	sc := &storagev1.StorageClass{ObjectMeta: metav1.ObjectMeta{Name: "fast-ssd"}}
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(sc).Build()

	if err := checkStorageClass(context.Background(), c, "fast-ssd"); err != nil {
		t.Fatalf("refused a storage class that exists: %v", err)
	}
}

// Everything above tests the pieces. This tests the WIRING, which nothing else did: every other run() test
// passes stateRequest{}, so the claim block was dead code in the whole suite — deleting it left the package
// green. That was found by deleting it, not by reading it.
//
// The refusal lands before the observation window, so this costs no protocol time.
//
// Mutation that turns this red: delete the checkStorageClass call from run(), or report it as anything but
// environment-unqualified.
func TestRunRefusesAClusterWithoutTheClassTheArmAsksFor(t *testing.T) {
	fc := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: fakeSchedulerCreate,
			Watch:  fakeSchedulerWatch,
			List:   fakeSchedulerList,
		}).Build()
	now, sleep := fakeClock(time.Unix(0, 0))

	o, _, res, _, _, _, _, _ := run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmEResume, stateRequest{Needed: true, Class: "fast-ssd"}, "r30", "queuelab-r30",
		"platform-worker", selfCompletingProtocol(), 45*time.Second, "", "", "", io.Discard, now, sleep)

	// A class the cluster does not have is a fact about the cluster, so the operator's move is to look at the
	// cluster — not at this run, which is what setup-failed would send them to.
	if o.Disposition != dispEnvironmentUnqualified {
		t.Fatalf("a cluster with no such storage class is %s, got %s: %s",
			dispEnvironmentUnqualified, o.Disposition, o.Reason)
	}
	if !strings.Contains(o.Reason, "fast-ssd") {
		t.Fatalf("the refusal must name the class the operator asked for: %s", o.Reason)
	}
	if res != nil {
		t.Fatal("a run that refused its environment must hand back no result")
	}

	// The claim must not be standing either: a refusal that leaves a PersistentVolumeClaim behind can leave
	// a provisioned volume behind with it, and that one costs money after the run is over.
	var pvc corev1.PersistentVolumeClaim
	err := fc.Get(context.Background(),
		client.ObjectKey{Namespace: "queuelab-r30", Name: queuelab.StateClaimName}, &pvc)
	if err == nil {
		t.Fatal("the run created the claim before deciding the class was unusable")
	}
}

// The other half of the wiring, and the control: a run whose class exists must actually create the claim,
// in the namespace BuildJob will look in. Without this a run() that refused every checkpointing arm would
// satisfy the test above and make the resume arms unrunnable everywhere.
//
// Mutation that turns this red: delete the createStateClaim call from run().
func TestRunCreatesTheClaimWhenTheArmCheckpoints(t *testing.T) {
	if testing.Short() {
		t.Skip("drives run() past the fixtures, which takes the 45-second observation window")
	}
	sc := &storagev1.StorageClass{ObjectMeta: metav1.ObjectMeta{Name: "fast-ssd"}}
	fc := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil), sc).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: fakeSchedulerCreate,
			Watch:  fakeSchedulerWatch,
			List:   fakeSchedulerList,
		}).Build()
	now, sleep := fakeClock(time.Unix(0, 0))

	o, _, _, _, _, _, _, _ := run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmEResume, stateRequest{Needed: true, Class: "fast-ssd"}, "r31", "queuelab-r31",
		"platform-worker", selfCompletingProtocol(), 45*time.Second, "", "", "", io.Discard, now, sleep)

	// The claim is read back from the cluster rather than asserted from the outcome, because what the victim
	// mounts is the object that exists, not the call that was made. Teardown deletes the namespace, so this
	// asks while the run's own client still holds the fake cluster's state.
	var pvc corev1.PersistentVolumeClaim
	err := fc.Get(context.Background(),
		client.ObjectKey{Namespace: "queuelab-r31", Name: queuelab.StateClaimName}, &pvc)
	if err != nil {
		t.Fatalf("a checkpointing arm ran and no claim was created for it (%s: %s): %v",
			o.Disposition, o.Reason, err)
	}
	if pvc.Spec.StorageClassName == nil || *pvc.Spec.StorageClassName != "fast-ssd" {
		t.Fatalf("the claim does not ask for the class the run was given: %v", pvc.Spec.StorageClassName)
	}
	if pvc.Labels[queuelab.TxLabel] == "" {
		t.Fatal("the claim carries no transaction stamp, so no teardown of this run could recognise it")
	}
}

// createStateClaim must put the claim where BuildJob will look for it: StateVolume names a claim in the
// job's OWN namespace, so a claim created anywhere else leaves the victim Pending with a reason that names
// a claim which does exist, somewhere useless.
//
// Mutation that turns this red: drop Namespace from StateClaim's ObjectMeta.
func TestTheClaimIsCreatedWhereTheJobWillLookForIt(t *testing.T) {
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).Build()
	id := queuelab.FixtureIdentity{TxID: "tx-1", RunID: "r7", Namespace: "queuelab-r7"}

	if err := createStateClaim(context.Background(), c, id, "fast-ssd"); err != nil {
		t.Fatalf("creating the claim: %v", err)
	}

	got, err := queuelab.StateClaim(id, "fast-ssd")
	if err != nil {
		t.Fatalf("rendering the claim to check it back: %v", err)
	}
	if got.Namespace != id.Namespace {
		t.Fatalf("the claim is rendered into namespace %q, not the run's %q", got.Namespace, id.Namespace)
	}
	if got.Name != queuelab.StateClaimName {
		t.Fatalf("the claim is named %q, which is not the name BuildJob mounts", got.Name)
	}
}
