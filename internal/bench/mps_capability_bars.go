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
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"regexp"
	"sort"
	"strings"
)

// B4 and B5 of the MPS capability session, judged from what the session captured, by the 2026-10-24 amendment of
// docs/superpowers/specs/2026-09-25-can-mps-engage-on-this-card-at-all.md.
//
// Each judge returns pass, fail or unmeasured with a detail line, and the session journals exactly that.
// Unmeasured is kept for an instrument that did not run or could not be read; a capture that ran and shows the wrong
// thing is a failure, because the amendment says not knowing why must not erase a measurement.

// MPSBarJudgement is one bar's result and what it read.
type MPSBarJudgement struct {
	Result string
	Detail string
}

// The plain process table's rows: GPU, GI, CI, PID, type, process name, memory.
// The GI and CI columns are N/A on a card without MIG, which is this card.
var mpsProcessRow = regexp.MustCompile(`^\|\s+(\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+?)\s+(\d+MiB|N/A)\s+\|$`)

// A line in the process section that starts with a GPU index, which every process row does, in any driver's column
// layout, and the headers, borders and "No running processes found" do not.
var mpsUnreadProcessRow = regexp.MustCompile(`^\|\s+\d+\s`)

// A Pod's UID as the kubelet writes it into a cgroup path, with dashes or, under the systemd driver, underscores.
var mpsCgroupPodUID = regexp.MustCompile(`pod([0-9a-f]{8}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{12})`)

// MPSProcessTableInput is what the session captured for B4 while both engines were Ready.
type MPSProcessTableInput struct {
	// Table is the plain `nvidia-smi` output and TableExit its exit status.
	Table     string
	TableExit int
	// QueryExit is the exit status of `nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv`,
	// which the page names beside the table; it has no type column, so it is required to have run and is not judged.
	QueryExit int
	// Cgroups maps a PID from the table to the contents of its /proc/<pid>/cgroup, read on the host.
	Cgroups map[int]string
	// EngineA and EngineB are the two engine Pods' UIDs, from the Pods B2 decided on.
	EngineA, EngineB string
}

// JudgeMPSProcessTable decides B4: one nvidia-cuda-mps-server, and two M+C processes, one in each engine Pod.
// The server's type is recorded and not judged, because NVIDIA's documentation does not give it.
func JudgeMPSProcessTable(in MPSProcessTableInput) MPSBarJudgement {
	if in.TableExit != 0 || in.QueryExit != 0 {
		return MPSBarJudgement{"unmeasured", fmt.Sprintf("nvidia-smi exited %d and its compute-apps query %d, so the table was not read", in.TableExit, in.QueryExit)}
	}
	if in.EngineA == "" || in.EngineB == "" || in.EngineA == in.EngineB {
		return MPSBarJudgement{"unmeasured", fmt.Sprintf("the engine Pods' UIDs are not two distinct values (%q, %q), so no process can be attributed", in.EngineA, in.EngineB)}
	}
	type proc struct {
		pid        int
		kind, name string
	}
	var procs []proc
	inProcesses := false
	for line := range strings.SplitSeq(in.Table, "\n") {
		line = strings.TrimRight(line, " \r")
		if strings.Contains(line, "Processes:") {
			inProcesses = true
			continue
		}
		m := mpsProcessRow.FindStringSubmatch(line)
		if m == nil {
			// A row of the process section this pattern cannot read is a parser that does not fit this driver's table,
			// and reading it as no process would turn a working MPS into a failed bar.
			if inProcesses && mpsUnreadProcessRow.MatchString(line) {
				return MPSBarJudgement{"unmeasured", fmt.Sprintf("a process row could not be read: %q", line)}
			}
			continue
		}
		var pid int
		_, _ = fmt.Sscanf(m[4], "%d", &pid)
		procs = append(procs, proc{pid: pid, kind: m[5], name: m[6]})
	}
	var servers, clients []proc
	for _, p := range procs {
		if path.Base(p.name) == "nvidia-cuda-mps-server" {
			servers = append(servers, p)
		} else if p.kind == "M+C" {
			clients = append(clients, p)
		}
	}
	read := fmt.Sprintf("%d process row(s): %d nvidia-cuda-mps-server, %d M+C client(s)", len(procs), len(servers), len(clients))
	if !inProcesses {
		return MPSBarJudgement{"unmeasured", "the table has no Processes section, so it is not the table B4 names"}
	}
	if len(servers) != 1 {
		return MPSBarJudgement{"fail", read + "; exactly one server is required"}
	}
	read += fmt.Sprintf("; the server is pid %d of type %s", servers[0].pid, servers[0].kind)
	if len(clients) != 2 {
		return MPSBarJudgement{"fail", read + "; exactly two M+C clients are required"}
	}
	owners := map[string]int{}
	var where []string
	for _, c := range clients {
		cg, ok := in.Cgroups[c.pid]
		if !ok {
			return MPSBarJudgement{"fail", read + fmt.Sprintf("; client pid %d has no cgroup record, so it cannot be attributed to an engine Pod", c.pid)}
		}
		uids := map[string]bool{}
		for _, m := range mpsCgroupPodUID.FindAllStringSubmatch(cg, -1) {
			uids[strings.ReplaceAll(m[1], "_", "-")] = true
		}
		if len(uids) != 1 {
			return MPSBarJudgement{"fail", read + fmt.Sprintf("; client pid %d's cgroup names %d Pod UIDs, not one", c.pid, len(uids))}
		}
		for uid := range uids {
			owners[uid]++
			where = append(where, fmt.Sprintf("pid %d in Pod %s", c.pid, uid))
		}
	}
	sort.Strings(where)
	read += "; " + strings.Join(where, ", ")
	if owners[in.EngineA] != 1 || owners[in.EngineB] != 1 {
		return MPSBarJudgement{"fail", read + fmt.Sprintf("; each engine Pod (%s, %s) must hold exactly one client", in.EngineA, in.EngineB)}
	}
	return MPSBarJudgement{"pass", read}
}

// The two tenants the frozen trace generates; B5 requires rows from both, so that both engines served.
var mpsReplayTenants = []string{"premium-1", "standard-noisy"}

// JudgeMPSReplay decides B5 from the replay's exit status and its raw rows: the replay exited 0, every row parses as
// a row of this study's mps arm, both tenants have rows, and none carries a 5xx.
// 4xx, transport failures and rows with an errorKind are counted and printed, not judged, as the amendment fixes.
func JudgeMPSReplay(raw io.Reader, replayExit int) MPSBarJudgement {
	sc := bufio.NewScanner(raw)
	sc.Buffer(make([]byte, 0, 64*1024), 16<<20)
	n := 0
	byTenant := map[string]int{}
	var s5xx, s4xx, transport, errorKind int
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		n++
		var r RawRow
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			return MPSBarJudgement{"unmeasured", fmt.Sprintf("raw row %d does not parse: %v", n, err)}
		}
		// A row of another study or arm is the wrong file, which says nothing about this cell.
		if r.Study != StudyMPSCapability || r.Arm != ArmMPS {
			return MPSBarJudgement{"unmeasured", fmt.Sprintf("raw row %d is study %q arm %q, not %s %s", n, r.Study, r.Arm, StudyMPSCapability, ArmMPS)}
		}
		byTenant[r.Tenant]++
		switch {
		case r.HTTPStatus >= 500:
			s5xx++
		case r.HTTPStatus >= 400:
			s4xx++
		case r.HTTPStatus == 0:
			transport++
		}
		if r.ErrorKind != "" {
			errorKind++
		}
	}
	if err := sc.Err(); err != nil {
		return MPSBarJudgement{"unmeasured", fmt.Sprintf("reading the raw rows: %v", err)}
	}
	var tenants []string
	for _, t := range mpsReplayTenants {
		tenants = append(tenants, fmt.Sprintf("%s %d", t, byTenant[t]))
	}
	read := fmt.Sprintf("replay exit %d, %d row(s) (%s), %d 5xx, %d 4xx, %d with no status, %d with an errorKind",
		replayExit, n, strings.Join(tenants, ", "), s5xx, s4xx, transport, errorKind)
	switch {
	case replayExit != 0:
		return MPSBarJudgement{"fail", read + "; the replay must exit 0"}
	case n == 0:
		return MPSBarJudgement{"fail", read + "; the replay wrote no rows"}
	case byTenant[mpsReplayTenants[0]] == 0 || byTenant[mpsReplayTenants[1]] == 0:
		return MPSBarJudgement{"fail", read + "; both tenants must have rows, or one engine did not serve"}
	case s5xx > 0:
		return MPSBarJudgement{"fail", read + "; no row may carry a 5xx"}
	}
	return MPSBarJudgement{"pass", read}
}
