package v1

import (
	"context"
	"errors"
	"strings"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// job builds a valid MLTrainingJob the individual specs then break in one way each.
func job(mutate func(*platformv1.MLTrainingJob)) *platformv1.MLTrainingJob {
	mltj := &platformv1.MLTrainingJob{
		Name: "trainer", Namespace: "default",
		Spec: platformv1.MLTrainingJobSpec{
			Queue: "team-a", Image: "trainer:v1", GPUCount: 1, Parallelism: 1, Completions: 1,
		},
	}
	if mutate != nil {
		mutate(mltj)
	}
	return mltj
}

// validatorWith builds a validator whose client holds the given objects.
func validatorWith(t *testing.T, objs ...runtime.Object) *MLTrainingJobValidator {
	t.Helper()
	if err := platformv1.AddToScheme(scheme.Scheme); err != nil {
		t.Fatalf("add scheme: %v", err)
	}
	return &MLTrainingJobValidator{
		Reader: fake.NewClientBuilder().WithScheme(scheme.Scheme).WithRuntimeObjects(objs...).Build(),
	}
}

// ownedJob is the Job the reconciler creates, which is what makes the template-derived fields unchangeable.
func ownedJob() *batchv1.Job {
	return &batchv1.Job{Name: "trainer", Namespace: "default"}
}

// causes lists the field paths an Invalid error blames.
func causes(t *testing.T, err error) []string {
	t.Helper()
	var status apierrors.APIStatus
	if !errors.As(err, &status) || status.Status().Details == nil {
		t.Fatalf("expected a structured API error, got %v", err)
	}
	fields := make([]string, 0, len(status.Status().Details.Causes))
	for _, c := range status.Status().Details.Causes {
		fields = append(fields, c.Field)
	}
	return fields
}

func TestValidateCreateRejectsWhatTheSchemaAdmits(t *testing.T) {
	// Both of these reach the webhook as empty strings through a schema that considers them valid, because
	// +required means the field is PRESENT rather than populated. internal/controller's immutability specs
	// assert the apiserver really does accept them, so these rows close a measured gap rather than a guessed one.
	//
	// Mutation that turns this red: drop either TrimSpace check from validateRunnable.
	rows := []struct {
		name   string
		break_ func(*platformv1.MLTrainingJob)
		want   string
	}{
		{"blank image", func(m *platformv1.MLTrainingJob) { m.Spec.Image = "" }, "spec.image"},
		{"whitespace image", func(m *platformv1.MLTrainingJob) { m.Spec.Image = "   " }, "spec.image"},
		{"blank queue", func(m *platformv1.MLTrainingJob) { m.Spec.Queue = "" }, "spec.queue"},
		{"whitespace queue", func(m *platformv1.MLTrainingJob) { m.Spec.Queue = "\t\n" }, "spec.queue"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			v := validatorWith(t)
			_, err := v.ValidateCreate(context.Background(), job(row.break_))
			if err == nil {
				t.Fatalf("accepted %s, which no Job could run with", row.name)
			}
			if got := causes(t, err); len(got) != 1 || got[0] != row.want {
				t.Fatalf("blamed %v, want exactly [%s]", got, row.want)
			}
		})
	}
}

func TestValidateCreateAcceptsARunnableSpec(t *testing.T) {
	// The control. Without it, a validator that rejected everything would pass every rejection spec above.
	v := validatorWith(t)
	if _, err := v.ValidateCreate(context.Background(), job(nil)); err != nil {
		t.Fatalf("rejected a spec with an image and a queue: %v", err)
	}
}

func TestValidateUpdateAllowsBakedEditsBeforeTheJobExists(t *testing.T) {
	// Before the Job is created there is nothing the reconciler cannot still apply, so the immutability rule
	// must not fire. This is the control that separates "refuses edits it cannot apply" from "refuses edits".
	//
	// Mutation that turns this red: drop the ownedJobExists check and always append bakedFieldEdits.
	v := validatorWith(t)
	updated := job(func(m *platformv1.MLTrainingJob) { m.Spec.Image = "trainer:v2"; m.Spec.GPUCount = 4 })
	if _, err := v.ValidateUpdate(context.Background(), job(nil), updated); err != nil {
		t.Fatalf("refused an edit made before the Job existed: %v", err)
	}
}

func TestValidateUpdateRefusesBakedEditsOnceTheJobExists(t *testing.T) {
	// Each of these is silently ignored today: the write is stored, the next reconcile reports success, and
	// the running Job keeps the old value. Rejecting is what makes the divergence visible.
	//
	// Mutation that turns this red: remove any one field's comparison from bakedFieldEdits.
	rows := []struct {
		name string
		edit func(*platformv1.MLTrainingJob)
		want string
	}{
		{"image", func(m *platformv1.MLTrainingJob) { m.Spec.Image = "trainer:v2" }, "spec.image"},
		{"gpuCount", func(m *platformv1.MLTrainingJob) { m.Spec.GPUCount = 8 }, "spec.gpuCount"},
		{"gpuClass", func(m *platformv1.MLTrainingJob) { m.Spec.GPUClass = "h100" }, "spec.gpuClass"},
		{"command", func(m *platformv1.MLTrainingJob) { m.Spec.Command = []string{"python", "train.py"} }, "spec.command"},
		// Queue is not in the pod template, so it fails differently from the four above: the reconciler DOES
		// re-apply it, on every pass, and Kueue's own webhook then refuses the change on a Job it has already
		// admitted. The edit is stored and the controller loops on it forever, which reads as a controller bug
		// rather than as the rejected edit it is.
		{"queue", func(m *platformv1.MLTrainingJob) { m.Spec.Queue = "team-b" }, "spec.queue"},
		// Completions is immutable on a batch/v1 Job; parallelism is not. Confirmed against a real apiserver
		// in envtest, which accepts a parallelism change and answers "field is immutable" for completions.
		{"completions", func(m *platformv1.MLTrainingJob) { m.Spec.Completions = 4 }, "spec.completions"},
		// The state volume is built into the pod template like the first four, so attaching one to a job whose
		// Job already exists is stored and then ignored. It is the field a resuming workload depends on, which
		// makes the silent version of this failure a run that restores nothing and reports success.
		{"stateVolume", func(m *platformv1.MLTrainingJob) {
			m.Spec.StateVolume = &platformv1.StateVolume{ClaimName: "resume-state", MountPath: "/state"}
		}, "spec.stateVolume"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			v := validatorWith(t, ownedJob())
			_, err := v.ValidateUpdate(context.Background(), job(nil), job(row.edit))
			if err == nil {
				t.Fatalf("accepted an edit to %s that the running Job would never pick up", row.name)
			}
			if got := causes(t, err); len(got) != 1 || got[0] != row.want {
				t.Fatalf("blamed %v, want exactly [%s]", got, row.want)
			}
		})
	}
}

func TestValidateUpdateAllowsFieldsTheReconcilerStillSyncs(t *testing.T) {
	// Parallelism is written on EVERY reconcile and the apiserver accepts the change, so refusing it would
	// block something the controller honours. Completions is written on every reconcile too and the apiserver
	// does NOT accept it — the reconciler makes no distinction and this spec used to repeat that mistake by
	// asserting both were allowed.
	//
	// Mutation that turns this red: add Parallelism to bakedFieldEdits.
	v := validatorWith(t, ownedJob())
	updated := job(func(m *platformv1.MLTrainingJob) { m.Spec.Parallelism = 4 })
	if _, err := v.ValidateUpdate(context.Background(), job(nil), updated); err != nil {
		t.Fatalf("refused an edit the reconciler re-applies every pass: %v", err)
	}
}

// Re-submitting the same state volume is not an edit, and must not be refused as one.
//
// The rule compares the volume by VALUE. Compared by pointer it would fire on every update that carried a
// freshly decoded spec -- which is every update, since the apiserver hands the validator a new object each
// time -- and the field would become unwritable rather than immutable-after-create. That failure is
// invisible to the table above, because every row there changes something.
//
// Mutation that turns this red: compare oldSpec.StateVolume != newSpec.StateVolume as pointers.
func TestValidateUpdateAllowsAStateVolumeResubmittedUnchanged(t *testing.T) {
	v := validatorWith(t, ownedJob())
	withVolume := func(m *platformv1.MLTrainingJob) {
		m.Spec.StateVolume = &platformv1.StateVolume{ClaimName: "resume-state", MountPath: "/state"}
	}
	if _, err := v.ValidateUpdate(context.Background(), job(withVolume), job(withVolume)); err != nil {
		t.Fatalf("refused an update that re-sent the same state volume, so the field cannot be written at "+
			"all rather than only after the Job exists: %v", err)
	}
}

// erroringClient fails every Get, standing in for an apiserver that is briefly unreachable.
type erroringClient struct {
	client.Client
}

func (erroringClient) Get(_ context.Context, _ client.ObjectKey, _ client.Object, _ ...client.GetOption) error {
	return errors.New("apiserver unreachable")
}

// List fails the same way, because the GPU guards reach the apiserver through it.
//
// Without this the embedded nil client.Client answers the call and the test passes for the wrong reason —
// or panics — which is the shape of a fail-closed test that never exercised the path it names.
func (erroringClient) List(_ context.Context, _ client.ObjectList, _ ...client.ListOption) error {
	return errors.New("apiserver unreachable")
}

func TestValidateUpdateFailsClosedWhenTheJobLookupFails(t *testing.T) {
	// A rule that quietly stopped applying whenever the lookup failed would let through exactly the edits it
	// exists to catch, and it would do so at the least visible moment.
	//
	// Mutation that turns this red: treat a lookup error as "no Job exists" and carry on.
	v := &MLTrainingJobValidator{Reader: erroringClient{}}
	_, err := v.ValidateUpdate(context.Background(), job(nil), job(func(m *platformv1.MLTrainingJob) {
		m.Spec.Image = "trainer:v2"
	}))
	if err == nil {
		t.Fatal("admitted an edit without establishing whether the Job existed")
	}
	if !strings.Contains(err.Error(), "unreachable") {
		t.Fatalf("error lost the cause: %v", err)
	}
}

// A cached read answers NotFound for a Job that exists but has not reached the informer yet, and NotFound is
// not an error — so the fail-closed path above never runs and the immutability rules are simply skipped.
//
// This spec pins the CONSEQUENCE of reading through a lagging cache, which is why the validator is wired with
// mgr.GetAPIReader() rather than mgr.GetClient(). It is the shape of the bug, held still: an edit that must be
// refused is admitted, with no error anywhere, in the window right after creation where it does the most harm.
//
// Mutation that turns this red: make the rules apply regardless of whether the Job was found, which would
// also refuse legitimate pre-creation edits.
func TestALaggingReadSilentlySkipsTheImmutabilityRules(t *testing.T) {
	// The Job exists on the cluster; this reader has not seen it. No error is produced, which is the whole
	// problem — there is nothing for the fail-closed branch to catch.
	v := &MLTrainingJobValidator{Reader: coldCache{}}

	_, err := v.ValidateUpdate(context.Background(), job(nil), job(func(m *platformv1.MLTrainingJob) {
		m.Spec.Image = "trainer:v2"
	}))
	if err != nil {
		t.Fatalf("a reader that reports NotFound should skip the baked-field rules, so this edit is admitted "+
			"under it; the spec exists to record that, not to assert the opposite: %v", err)
	}

	// And with a reader that can see it, the same edit is refused. The two together say the outcome turns
	// entirely on whether the read was current.
	warm := validatorWith(t, ownedJob())
	if _, err := warm.ValidateUpdate(context.Background(), job(nil), job(func(m *platformv1.MLTrainingJob) {
		m.Spec.Image = "trainer:v2"
	})); err == nil {
		t.Fatal("an edit to a baked field was admitted even though the Job was visible")
	}
}

// coldCache reports every Job as absent, standing in for an informer that has not caught up.
type coldCache struct {
	client.Client
}

func (coldCache) Get(_ context.Context, key client.ObjectKey, _ client.Object, _ ...client.GetOption) error {
	return apierrors.NewNotFound(schema.GroupResource{Group: "batch", Resource: "jobs"}, key.Name)
}

func TestValidateDeleteAllowsEveryDelete(t *testing.T) {
	// Teardown belongs to the finalizer. A webhook able to refuse a delete could strand an object no one can
	// remove, which is a worse failure than anything it would prevent.
	v := validatorWith(t, ownedJob())
	if _, err := v.ValidateDelete(context.Background(), job(nil)); err != nil {
		t.Fatalf("refused a delete: %v", err)
	}
}

// An object being deleted must be able to finish being deleted, whatever its spec says.
//
// This validator refuses to intercept DELETE precisely so it cannot strand an object. That guard was in the
// wrong place: the finalizer comes off with an ordinary UPDATE, so a spec this validator calls unrunnable —
// an empty image on something created before the webhook existed — could never complete the update that ends
// its deletion. The object would sit in Terminating with no way out, held there by a rule about what a Job
// would run.
//
// Mutation that turns this red: drop the DeletionTimestamp early return from ValidateUpdate.
func TestValidateUpdateNeverBlocksDeletion(t *testing.T) {
	deleting := func(mutate func(*platformv1.MLTrainingJob)) *platformv1.MLTrainingJob {
		now := metav1.Now()
		j := job(mutate)
		j.DeletionTimestamp = &now
		j.Finalizers = []string{"platform.lkhun9311.github.io/mltrainingjob"}
		return j
	}

	rows := []struct {
		name string
		spec func(*platformv1.MLTrainingJob)
	}{
		// The legacy shapes: created before this webhook, so they hold values it would refuse today.
		{"empty image", func(m *platformv1.MLTrainingJob) { m.Spec.Image = "" }},
		{"empty queue", func(m *platformv1.MLTrainingJob) { m.Spec.Queue = "" }},
		{"both empty", func(m *platformv1.MLTrainingJob) { m.Spec.Image = ""; m.Spec.Queue = "" }},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			// The owned Job exists, so the immutability rule would also fire on an ordinary update.
			v := validatorWith(t, ownedJob())
			old := deleting(row.spec)
			// What the controller actually does: same object, one finalizer fewer.
			updated := deleting(row.spec)
			updated.Finalizers = nil

			if _, err := v.ValidateUpdate(context.Background(), old, updated); err != nil {
				t.Fatalf("finalizer removal was refused, so the object can never be deleted: %v", err)
			}
		})
	}

	// The control: with no deletion under way the same spec must still be refused, or the bypass has swallowed
	// the rule rather than scoped it.
	v := validatorWith(t, ownedJob())
	broken := job(func(m *platformv1.MLTrainingJob) { m.Spec.Image = "" })
	if _, err := v.ValidateUpdate(context.Background(), job(nil), broken); err == nil {
		t.Fatal("an empty image was accepted on a live object; the deletion bypass is too wide")
	}
}

func TestADistributedJobNeedsANameItsRendezvousServiceCanCarry(t *testing.T) {
	// The CR's name is a DNS-1123 subdomain and the Service's must be a DNS-1035 label, so these are names the API
	// accepts and the controller could never build a Service for.
	//
	// Mutation that turns this red: return nil from distributedName before IsDNS1035Label.
	rows := []struct {
		name  string
		bad   bool
		label string
	}{
		{"0trainer", true, "a leading digit"},
		{"trainer.v2", true, "a dot"},
		{strings.Repeat("a", 60), true, "60 characters, one more than -ddp leaves room for"},
		{strings.Repeat("a", 59), false, "59 characters, the most that fits"},
		{"trainer", false, "an ordinary name"},
	}
	for _, row := range rows {
		t.Run(row.label, func(t *testing.T) {
			v := validatorWith(t)
			_, err := v.ValidateCreate(context.Background(), job(func(m *platformv1.MLTrainingJob) {
				m.Name = row.name
				m.Spec.Distributed = &platformv1.Distributed{WorldSize: 2}
			}))
			switch {
			case row.bad && err == nil:
				t.Fatalf("accepted %q for a distributed job", row.name)
			case row.bad:
				if got := causes(t, err); len(got) != 1 || got[0] != "metadata.name" {
					t.Fatalf("blamed %v, want exactly [metadata.name]", got)
				}
			case err != nil:
				t.Fatalf("refused %q: %v", row.name, err)
			}
		})
	}
}

func TestAnOrdinaryJobKeepsTheNamesItAlwaysHad(t *testing.T) {
	// The name rule is for distributed jobs only; an ordinary job creates no Service, and refusing its names would
	// break callers that never asked for anything new.
	//
	// Mutation that turns this red: drop the Distributed == nil guard in distributedName.
	for _, name := range []string{"0trainer", "trainer.v2", strings.Repeat("a", 60)} {
		v := validatorWith(t)
		if _, err := v.ValidateCreate(context.Background(), job(func(m *platformv1.MLTrainingJob) { m.Name = name })); err != nil {
			t.Fatalf("refused the non-distributed name %q: %v", name, err)
		}
	}
}

// claim is a PersistentVolumeClaim named "ckpt" in the job's namespace with the given access modes and nothing else,
// so the access mode is the only thing a row varies.
func claim(modes ...corev1.PersistentVolumeAccessMode) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{Name: "ckpt", Namespace: "default",
		Spec: corev1.PersistentVolumeClaimSpec{AccessModes: modes}}
}

// distributedWithClaim is a distributed job that restarts and keeps its checkpoints on claim "ckpt".
func distributedWithClaim(m *platformv1.MLTrainingJob) {
	m.Spec.Distributed = &platformv1.Distributed{WorldSize: 2, MaxRestarts: 1}
	m.Spec.StateVolume = &platformv1.StateVolume{ClaimName: "ckpt", MountPath: "/ckpt"}
}

func TestADistributedStateVolumeMustBeReadWriteMany(t *testing.T) {
	// Ranks run on different nodes and every one of them reads and writes the checkpoint, so a claim only one
	// node can mount would leave all but one rank Pending — or, on a provisioner that ignores the mode, give each
	// node its own copy and a restart that loads a checkpoint nobody else wrote.
	//
	// Mutation that turns this red: return nil from the access-mode check.
	rows := []struct {
		label string
		objs  []runtime.Object
		bad   string
	}{
		{"ReadWriteOnce", []runtime.Object{claim(corev1.ReadWriteOnce)}, "ReadWriteMany"},
		{"ReadWriteOncePod", []runtime.Object{claim(corev1.ReadWriteOncePod)}, "ReadWriteMany"},
		{"no claim", nil, "not found"},
		{"ReadWriteMany", []runtime.Object{claim(corev1.ReadWriteMany)}, ""},
		{"ReadWriteMany among others", []runtime.Object{claim(corev1.ReadWriteOnce, corev1.ReadWriteMany)}, ""},
	}
	for _, row := range rows {
		t.Run(row.label, func(t *testing.T) {
			_, err := validatorWith(t, row.objs...).ValidateCreate(context.Background(), job(distributedWithClaim))
			switch {
			case row.bad == "" && err != nil:
				t.Fatalf("refused: %v", err)
			case row.bad != "" && err == nil:
				t.Fatal("accepted")
			case row.bad != "":
				if !strings.Contains(err.Error(), row.bad) {
					t.Fatalf("error does not say %q: %v", row.bad, err)
				}
				if got := causes(t, err); len(got) != 1 || got[0] != "spec.stateVolume.claimName" {
					t.Fatalf("blamed %v, want exactly [spec.stateVolume.claimName]", got)
				}
			}
		})
	}
}

func TestTheClaimCheckFailsClosed(t *testing.T) {
	// A lookup that fails must not read as a claim that is fine.
	//
	// Mutation that turns this red: treat a lookup error as success.
	v := &MLTrainingJobValidator{Reader: erroringClient{}}
	if _, err := v.ValidateCreate(context.Background(), job(distributedWithClaim)); err == nil {
		t.Fatal("admitted a distributed stateVolume without reading its claim")
	}
}

func TestAClaimChangedBeforeTheJobExistsIsCheckedToo(t *testing.T) {
	// Before the first Job the template is not yet written, so the claim may still change; a check only on create
	// would let an accepted job be pointed at a claim the create would have refused.
	// An unchanged claim is not read again, so a claim deleted after admission does not block the finalizer's update.
	//
	// Mutation that turns this red: drop the claim check from ValidateUpdate.
	other := func(modes ...corev1.PersistentVolumeAccessMode) *corev1.PersistentVolumeClaim {
		c := claim(modes...)
		c.Name = "other"
		return c
	}
	rows := []struct {
		label string
		objs  []runtime.Object
		to    string
		bad   string
	}{
		{"to ReadWriteOnce", []runtime.Object{claim(corev1.ReadWriteMany), other(corev1.ReadWriteOnce)}, "other", "ReadWriteMany"},
		{"to a missing claim", []runtime.Object{claim(corev1.ReadWriteMany)}, "other", "not found"},
		{"to ReadWriteMany", []runtime.Object{claim(corev1.ReadWriteMany), other(corev1.ReadWriteMany)}, "other", ""},
		{"unchanged and since deleted", nil, "ckpt", ""},
	}
	for _, row := range rows {
		t.Run(row.label, func(t *testing.T) {
			oldJob := job(distributedWithClaim)
			newJob := job(func(m *platformv1.MLTrainingJob) {
				distributedWithClaim(m)
				m.Spec.StateVolume.ClaimName = row.to
			})
			_, err := validatorWith(t, row.objs...).ValidateUpdate(context.Background(), oldJob, newJob)
			switch {
			case row.bad == "" && err != nil:
				t.Fatalf("refused: %v", err)
			case row.bad != "" && err == nil:
				t.Fatal("accepted")
			case row.bad != "" && !strings.Contains(err.Error(), row.bad):
				t.Fatalf("error does not say %q: %v", row.bad, err)
			}
		})
	}
}

func TestARestartableJobNeedsANameEveryAttemptsServiceCanCarry(t *testing.T) {
	// Attempt n's rendezvous Service is <name>-ddp-a<n>, and the last attempt is maxRestarts+1, so the name must
	// leave room for that suffix, not just for -ddp.
	//
	// Mutation that turns this red: check only <name>-ddp for a restartable job.
	for _, row := range []struct {
		name string
		bad  bool
	}{
		{strings.Repeat("a", 55), false}, // 55 + len("-ddp-a10") = 63
		{strings.Repeat("a", 56), true},
	} {
		v := validatorWith(t, claim(corev1.ReadWriteMany))
		_, err := v.ValidateCreate(context.Background(), job(func(m *platformv1.MLTrainingJob) {
			distributedWithClaim(m)
			m.Name = row.name
			m.Spec.Distributed.MaxRestarts = 9
		}))
		if row.bad != (err != nil) {
			t.Fatalf("name of %d characters: err=%v, want refused=%v", len(row.name), err, row.bad)
		}
	}
}

func TestTemplateFieldsStayFrozenBetweenAttempts(t *testing.T) {
	// Between two attempts no Job exists, which is exactly when the old rule let template fields change; the
	// recorded attempt is what still says a run started under them.
	//
	// Mutation that turns this red: decide the freeze on the Job's existence alone.
	v := validatorWith(t)
	old := job(func(m *platformv1.MLTrainingJob) {
		distributedWithClaim(m)
		m.Status.Attempts = []platformv1.TrainingAttempt{{Number: 1, State: "Stopped"}}
	})
	_, err := v.ValidateUpdate(context.Background(), old, job(func(m *platformv1.MLTrainingJob) {
		distributedWithClaim(m)
		m.Spec.Image = "trainer:v2"
	}))
	if err == nil {
		t.Fatal("changed the image between two attempts of one job")
	}
}

func TestAnOrdinaryStateVolumeIsNotLookedUp(t *testing.T) {
	// A single-Pod job's claim has always been left to the kubelet, where a missing one leaves the Pod Pending;
	// reading it here would refuse jobs created before their claim, which nothing used to refuse.
	//
	// Mutation that turns this red: check the claim whether or not the job is distributed.
	v := &MLTrainingJobValidator{Reader: erroringClient{}}
	if _, err := v.ValidateCreate(context.Background(), job(func(m *platformv1.MLTrainingJob) {
		m.Spec.StateVolume = &platformv1.StateVolume{ClaimName: "ckpt", MountPath: "/ckpt"}
	})); err != nil {
		t.Fatalf("an ordinary job's claim was read: %v", err)
	}
}
