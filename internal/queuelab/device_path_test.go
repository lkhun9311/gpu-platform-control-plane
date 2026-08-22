package queuelab

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// buildFakeCUDA compiles testdata/fake_libcuda.c into a libcuda.so.1 the workload will load.
//
// It skips rather than fails when there is no compiler, because the value here is the check itself and a
// build environment without gcc is not evidence about the workload. It does NOT skip when the compile
// fails: that is the shim being broken, and a silently skipped shim is exactly the reassurance this file
// exists to refuse.
func buildFakeCUDA(t *testing.T) string {
	t.Helper()
	cc, err := exec.LookPath("gcc")
	if err != nil {
		if cc, err = exec.LookPath("cc"); err != nil {
			t.Skip("no C compiler on this host, so the fake libcuda cannot be built here")
		}
	}
	dir := t.TempDir()
	so := filepath.Join(dir, "libcuda.so.1")
	out, err := exec.Command(cc, "-shared", "-fPIC", "-o", so, "testdata/fake_libcuda.c").CombinedOutput()
	if err != nil {
		t.Fatalf("the fake libcuda did not compile, so nothing below verifies anything: %v\n%s", err, out)
	}
	return dir
}

// runWorkload executes the SHIPPED command with the fake driver on the library path.
func runWorkload(t *testing.T, libDir string, env []string, seconds, arm string) (string, int) {
	t.Helper()
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3 on this host")
	}
	job, err := RenderMLTrainingJobWithContract(TrainingTraceRow{
		Index: 0, Name: "probe", Tenant: "lab", GPUCount: 1, DurationSec: 1,
	}, "queuelab", IgnoresSIGTERM)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	args := append([]string{}, job.Spec.Command[1:]...)
	args[len(args)-2], args[len(args)-1] = seconds, arm
	cmd := exec.Command(python, args...)
	cmd.Env = append(append(os.Environ(), "LD_LIBRARY_PATH="+libDir), env...)
	out, err := cmd.CombinedOutput()
	code := 0
	var exit *exec.ExitError
	if err != nil {
		if !stderrAs(err, &exit) {
			t.Fatalf("the workload did not run: %v\n%s", err, out)
		}
		code = exit.ExitCode()
	}
	return strings.TrimSpace(string(out)), code
}

func stderrAs(err error, target **exec.ExitError) bool {
	e, ok := err.(*exec.ExitError)
	if ok {
		*target = e
	}
	return ok
}

// The workload's DEVICE path, executed. Nothing in this repository had ever run it.
//
// TestTheShippedWorkloadActuallyRunsAndReportsWhatTheParserExpects runs on a host with no libcuda.so.1, so
// it takes the fallback branch at the first line of cuda() and never constructs a kernel argument, never
// loads the PTX, never launches anything. Its own comment claims nothing else can do what it does; that was
// true only of the fallback.
//
// The shim asserts, from the C side and with distinct exit statuses so a failure cannot be mistaken for a
// broken GPU: the module image is this file's PTX and targets sm_75, the kernel is named burn, the
// allocation is exactly THREADS*4 bytes, the memset pattern is 1.0f, the launch geometry is 1024x256 with
// no shared memory, and kernelParams[0] and [1] dereference to the pointer cuMemAlloc returned and to
// 20000.
//
// That last pair is the one worth having. kernelParams is an array of raw addresses; ctypes copies the
// integer and keeps no reference, so a build whose argument objects go out of scope hands the driver two
// dangling pointers. This test dereferences them on every launch.
func TestTheWorkloadsDevicePathRunsAgainstAFakeDriver(t *testing.T) {
	lib := buildFakeCUDA(t)
	out, code := runWorkload(t, lib, nil, "1", "ignore")
	if code != 0 {
		t.Fatalf("the device path exited %d:\n%s", code, out)
	}
	final := lastLine(out)
	iters, kind, device := ReportFromMessage(strings.TrimSpace(strings.TrimPrefix(final, "finished ")))
	if iters == nil {
		t.Fatalf("the device path left no readable report: %q\n%s", final, out)
	}
	if kind != KindCUDAFMA || device != DeviceOK {
		t.Fatalf("the workload reported kind=%q dev=%q against a driver that accepted everything", kind, device)
	}
	if *iters <= 0 {
		t.Fatalf("the device path reported %d launches", *iters)
	}
}

// Each way the driver can refuse produces its own token, and the tokens are what send an operator to the
// right place. They were a closed set nobody had ever driven from the driver's side.
func TestEachDriverRefusalProducesItsOwnToken(t *testing.T) {
	lib := buildFakeCUDA(t)
	for _, tc := range []struct{ symbol, token string }{
		{"cuInit", "cuinit-failed"},
		{"cuDeviceGet", "no-device"},
		{"cuCtxCreate_v2", "ctx-failed"},
		{"cuModuleLoadData", "ptx-load-failed"},
		{"cuModuleGetFunction", "no-kernel"},
		{"cuMemAlloc_v2", "alloc-failed"},
		{"cuMemsetD32_v2", "memset-failed"},
		{"cuLaunchKernel", "launch-failed"},
	} {
		t.Run(tc.symbol, func(t *testing.T) {
			out, _ := runWorkload(t, lib, []string{"SHIM_FAIL_AT=" + tc.symbol}, "1", "ignore")
			final := strings.TrimSpace(strings.TrimPrefix(lastLine(out), "finished "))
			_, kind, device := ReportFromMessage(final)
			if device != tc.token {
				t.Fatalf("a driver refusing %s reported dev=%q, want %q\n%s", tc.symbol, device, tc.token, out)
			}
			// Every pre-launch refusal returns before the kind is set, so the workload must report the
			// fallback -- and the parser's cross-token rule refuses any other pairing outright.
			if kind != KindCPUFloat {
				t.Fatalf("a refusal at %s left kind=%q, which the parser pairs with no pre-launch failure",
					tc.symbol, kind)
			}
		})
	}

	// A card that works and then stops is the one failure that keeps the device kind, and it is the only
	// path to a non-zero exit from the loop rather than from the handler.
	out, code := runWorkload(t, lib, []string{"SHIM_FAIL_LAUNCH_AFTER=3"}, "5", "ignore")
	final := strings.TrimSpace(strings.TrimPrefix(lastLine(out), "aborted "))
	_, kind, device := ReportFromMessage(final)
	if kind != KindCUDAFMA || device != "launch-failed-midrun" {
		t.Fatalf("a mid-run launch failure reported kind=%q dev=%q\n%s", kind, device, out)
	}
	if code == 0 {
		t.Fatal("a workload whose card stopped mid-run exited zero, so a run would count it as a completion")
	}
}

// The kernel arguments must outlive the function that built them.
//
// This is a STRUCTURAL check, and the reason is worth stating: the defect is undefined behaviour that does
// not reproduce. `args._objects` is nil and the closure's free variables are `('args',)`, so the two
// argument objects are freed when cuda() returns and every launch dereferences reclaimed memory -- but the
// loop allocates nothing that lands on those blocks, and 2.9 million launches under two different Python
// allocators read the correct values. Forcing the reuse by hand corrupts them immediately.
//
// So the shim above cannot catch it, and a test that waited for it to bite would pass on a broken build.
// What is checked instead is the property that makes it safe: the launch closure keeps a reference. That is
// a weaker kind of test and it is the honest one for a bug whose manifestation is a matter of allocator
// luck on a machine costing money by the hour.
func TestTheKernelArgumentsOutliveTheirBuilder(t *testing.T) {
	script := workloadScript
	if !strings.Contains(script, "args=(ctypes.c_void_p*2)(") {
		t.Fatal("the workload no longer builds a kernelParams array; this test is checking a shape that " +
			"has moved, and must be rewritten rather than deleted")
	}
	i := strings.Index(script, "def launch(")
	if i < 0 {
		t.Fatal("the workload has no launch closure")
	}
	signature := script[i : strings.Index(script[i:], "\n")+i]
	for _, held := range []string{"buf", "inner", "args"} {
		if !strings.Contains(signature, held) {
			t.Fatalf("the launch closure does not hold %q: %s\n\nkernelParams stores raw addresses and keeps "+
				"no reference, so an argument object the closure does not name is freed when cuda() returns "+
				"and the driver is handed a dangling pointer", held, signature)
		}
	}
}

// The PTX is compiled, rather than asserted to have been compiled.
//
// A comment in submit.go used to claim it had been checked with ptxas for three architectures. There was no
// such check anywhere in the repository -- no test, no target, no script -- so the one verification the file
// named as available without a GPU was the one it did not have.
func TestTheEmbeddedPTXCompiles(t *testing.T) {
	ptxas, err := exec.LookPath("ptxas")
	if err != nil {
		t.Skip("no ptxas on this host; install nvidia-cuda-nvcc to run this check (it needs no GPU)")
	}
	script := workloadScript
	start := strings.Index(script, `PTX=b"""`)
	if start < 0 {
		t.Fatal("the workload carries no PTX")
	}
	body := script[start+len(`PTX=b"""`):]
	body = body[:strings.Index(body, `"""`)]
	f := filepath.Join(t.TempDir(), "burn.ptx")
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if out, err := exec.Command(ptxas, "-arch=sm_75", "-o", os.DevNull, f).CombinedOutput(); err != nil {
		t.Fatalf("the shipped PTX does not compile for sm_75, which is the architecture of the card this "+
			"study rents: %v\n%s", err, out)
	}
}
