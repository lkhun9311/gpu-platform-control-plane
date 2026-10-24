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

package bench

import (
	"fmt"
	"strings"
	"testing"
)

const (
	mpsPodA = "0b6f4c1e-2d3a-4b5c-8d9e-0f1a2b3c4d5e"
	mpsPodB = "9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4"
)

// The process section in the layout NVIDIA's drivers print it, with the server and two clients. No table from this
// card is archived in the repository, so this is the documented layout and not a capture; a row this layout does not
// fit is read as unmeasured, never as no process.
func mpsTable(rows ...string) string {
	return "+-----------------------------------------------------------------------------------------+\n" +
		"| Processes:                                                                              |\n" +
		"|  GPU   GI   CI        PID   Type   Process name                              GPU Memory |\n" +
		"|        ID   ID                                                               Usage      |\n" +
		"|=========================================================================================|\n" +
		strings.Join(rows, "\n") + "\n" +
		"+-----------------------------------------------------------------------------------------+\n"
}

func mpsRow(pid int, kind, name string) string {
	return fmt.Sprintf("|    0   N/A  N/A    %6d    %3s   %-40s %8s |", pid, kind, name, "10230MiB")
}

// A cgroup v2 path as a kind node nested in docker writes it, with the systemd driver's underscores.
func mpsCgroup(uid string) string {
	return "0::/system.slice/docker-3f1e.scope/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod" +
		strings.ReplaceAll(uid, "-", "_") + ".slice/cri-containerd-77aa.scope\n"
}

func passingMPSTable() MPSProcessTableInput {
	return MPSProcessTableInput{
		Table: mpsTable(mpsRow(4242, "C", "nvidia-cuda-mps-server"), mpsRow(5151, "M+C", "/usr/bin/python3"), mpsRow(6161, "M+C", "/usr/bin/python3")),
		Cgroups: map[int]string{
			4242: "0::/system.slice/nvidia-mps.scope\n",
			5151: mpsCgroup(mpsPodA),
			6161: mpsCgroup(mpsPodB),
		},
		EngineA: mpsPodA,
		EngineB: mpsPodB,
	}
}

func TestJudgeMPSProcessTable(t *testing.T) {
	type tc struct {
		name   string
		edit   func(*MPSProcessTableInput)
		want   string
		detail string
	}
	cases := []tc{
		{"one server and one client in each engine", func(*MPSProcessTableInput) {}, "pass", "pid 5151 in Pod " + mpsPodA},
		// The server's type is recorded and not judged: M+C on the server must not refuse a working arrangement.
		{"the server shown as M+C", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(4242, "M+C", "nvidia-cuda-mps-server"), mpsRow(5151, "M+C", "/usr/bin/python3"), mpsRow(6161, "M+C", "/usr/bin/python3"))
		}, "pass", "of type M+C"},
		{"no server", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(5151, "M+C", "/usr/bin/python3"), mpsRow(6161, "M+C", "/usr/bin/python3"))
		}, "fail", "exactly one server"},
		// Clients that run without MPS are type C; seeing them is a failed bar, not an unmeasured one.
		{"two plain C processes", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(4242, "C", "nvidia-cuda-mps-server"), mpsRow(5151, "C", "/usr/bin/python3"), mpsRow(6161, "C", "/usr/bin/python3"))
		}, "fail", "exactly two M+C clients"},
		{"two servers", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(4242, "C", "nvidia-cuda-mps-server"), mpsRow(4343, "C", "nvidia-cuda-mps-server"), mpsRow(5151, "M+C", "/usr/bin/python3"), mpsRow(6161, "M+C", "/usr/bin/python3"))
		}, "fail", "exactly one server"},
		// One engine attached and the other running without MPS is the half-working case this bar exists for.
		{"one engine an M+C client and the other plain C", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(4242, "C", "nvidia-cuda-mps-server"), mpsRow(5151, "M+C", "/usr/bin/python3"), mpsRow(6161, "C", "/usr/bin/python3"))
		}, "fail", "exactly two M+C clients"},
		{"three M+C clients", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(4242, "C", "nvidia-cuda-mps-server"), mpsRow(5151, "M+C", "/usr/bin/python3"), mpsRow(6161, "M+C", "/usr/bin/python3"), mpsRow(7171, "M+C", "/usr/bin/python3"))
			in.Cgroups[7171] = mpsCgroup(mpsPodB)
		}, "fail", "exactly two M+C clients"},
		{"both clients in one engine", func(in *MPSProcessTableInput) { in.Cgroups[6161] = mpsCgroup(mpsPodA) }, "fail", "must hold exactly one client"},
		{"a client in neither engine", func(in *MPSProcessTableInput) { in.Cgroups[6161] = mpsCgroup("11111111-2222-4333-8444-555555555555") }, "fail", "must hold exactly one client"},
		{"a client with no cgroup record", func(in *MPSProcessTableInput) { delete(in.Cgroups, 6161) }, "fail", "no cgroup record"},
		{"a client cgroup naming no Pod", func(in *MPSProcessTableInput) { in.Cgroups[6161] = "0::/user.slice\n" }, "fail", "names 0 Pod UIDs"},
		{"no running processes", func(in *MPSProcessTableInput) {
			in.Table = mpsTable("|  No running processes found                                                             |")
		}, "fail", "0 process row(s)"},
		{"a row this layout cannot read", func(in *MPSProcessTableInput) {
			in.Table = mpsTable(mpsRow(4242, "C", "nvidia-cuda-mps-server"), "|    0      5151    M+C   python3   10230MiB |", mpsRow(6161, "M+C", "/usr/bin/python3"))
		}, "unmeasured", "could not be read"},
		{"no Processes section", func(in *MPSProcessTableInput) {
			in.Table = "Failed to initialize NVML: Driver/library version mismatch\n"
		}, "unmeasured", "no Processes section"},
		{"the table command failed", func(in *MPSProcessTableInput) { in.TableExit = 9 }, "unmeasured", "exited 9"},
		{"the compute-apps query failed", func(in *MPSProcessTableInput) { in.QueryExit = 6 }, "unmeasured", "query 6"},
		{"the engine UIDs are the same", func(in *MPSProcessTableInput) { in.EngineB = mpsPodA }, "unmeasured", "not two distinct"},
	}
	for _, c := range cases {
		in := passingMPSTable()
		c.edit(&in)
		got := JudgeMPSProcessTable(in)
		if got.Result != c.want || !strings.Contains(got.Detail, c.detail) {
			t.Errorf("%s: got %s %q, want %s with %q", c.name, got.Result, got.Detail, c.want, c.detail)
		}
	}
}

func mpsRaw(tenant string, status int, extra string) string {
	return fmt.Sprintf(`{"index":0,"arm":"mps","tenant":%q,"isNoisy":false,"scheduledOffsetMs":0,"sendUnixNanos":1,"estInputTokens":1,"outputTokens":1,"httpStatus":%d,"study":"mps-capability-2026-10-24"%s}`, tenant, status, extra)
}

func TestJudgeMPSReplay(t *testing.T) {
	pass := strings.Join([]string{mpsRaw("premium-1", 200, ""), mpsRaw("premium-1", 200, ""), mpsRaw("standard-noisy", 200, "")}, "\n") + "\n"
	cases := []struct {
		name, raw string
		exit      int
		want      string
		detail    string
	}{
		{"both tenants answered", pass, 0, "pass", "premium-1 2, standard-noisy 1"},
		// 4xx and timeouts are counted, not judged: the page asked for no 5xx and nothing more.
		{"a 4xx and a timeout beside", pass + mpsRaw("premium-1", 429, "") + "\n" + mpsRaw("premium-1", 200, `,"errorKind":"timeout"`) + "\n", 0, "pass", "1 4xx, 0 with no status, 1 with an errorKind"},
		{"one 5xx among many answers", pass + mpsRaw("standard-noisy", 503, "") + "\n", 0, "fail", "no row may carry a 5xx"},
		{"the contender never served", mpsRaw("premium-1", 200, "") + "\n", 0, "fail", "both tenants"},
		{"no rows", "", 0, "fail", "no rows"},
		{"the replay exited non-zero", pass, 1, "fail", "must exit 0"},
		{"a row that does not parse", pass + "{\"arm\":\n", 0, "unmeasured", "does not parse"},
		{"a row of the sharing study", pass + strings.Replace(mpsRaw("premium-1", 200, ""), StudyMPSCapability, StudySharingMatrix, 1) + "\n", 0, "unmeasured", "not mps-capability-2026-10-24 mps"},
		{"a row of another arm", pass + strings.Replace(mpsRaw("premium-1", 200, ""), `"arm":"mps"`, `"arm":"timeSlicing"`, 1) + "\n", 0, "unmeasured", `arm "timeSlicing"`},
	}
	for _, c := range cases {
		got := JudgeMPSReplay(strings.NewReader(c.raw), c.exit)
		if got.Result != c.want || !strings.Contains(got.Detail, c.detail) {
			t.Errorf("%s: got %s %q, want %s with %q", c.name, got.Result, got.Detail, c.want, c.detail)
		}
	}
}
