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

// Package monitoring holds the GPU alert rules and dashboard to the series this repository's components emit.
//
// promtool (hack/check-gpu-monitoring.sh) answers whether an expression parses and whether an alert fires on the input
// it is given.
// It cannot answer whether that input will ever exist: a misspelt metric is valid PromQL, the rule loads, the panel
// renders, and both stay silent, which reads as a healthy fleet.
// This file answers that, against the sources rather than against a list someone would have to keep.
package monitoring

import (
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
	ctrlmetrics "sigs.k8s.io/controller-runtime/pkg/metrics"
	kueuemetrics "sigs.k8s.io/kueue/pkg/metrics"
	"sigs.k8s.io/yaml"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gpufault"
)

const (
	rulesFile     = "config/prometheus/gpu_rules.yaml"
	dashboardFile = "config/prometheus/gpu_dashboard.json"
	// opsExporter is the exporter overlay the rules and the dashboard are written for.
	opsExporter = "config/dcgm-exporter-ops/kustomization.yaml"
	// runbookPrefix is where every runbook_url must point: a file of this repository on the branch operators read.
	runbookPrefix = "https://github.com/lkhun9311/gpu-platform-control-plane/blob/main/"
)

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

// rule is every field a Prometheus rule may carry, so that a strict decode refuses anything else.
type rule struct {
	Alert         string            `json:"alert"`
	Record        string            `json:"record"`
	Expr          string            `json:"expr"`
	For           string            `json:"for"`
	KeepFiringFor string            `json:"keep_firing_for"`
	Labels        map[string]string `json:"labels"`
	Annotations   map[string]string `json:"annotations"`
}

func loadRules(t *testing.T) []rule {
	t.Helper()
	var doc struct {
		Kind string `json:"kind"`
		Spec struct {
			Groups []struct {
				Rules []map[string]any `json:"rules"`
			} `json:"groups"`
		} `json:"spec"`
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, rulesFile)), &doc); err != nil {
		t.Fatalf("parse %s: %v", rulesFile, err)
	}
	if doc.Kind != "PrometheusRule" {
		t.Fatalf("%s is a %q, not a PrometheusRule", rulesFile, doc.Kind)
	}
	var out []rule
	for _, g := range doc.Spec.Groups {
		for _, raw := range g.Rules {
			// Strict per rule: a key misspelt as "annotation" would otherwise decode to nothing, and every check on
			// the annotations would pass over an empty map.
			b, err := yaml.Marshal(raw)
			if err != nil {
				t.Fatalf("re-encode a rule of %s: %v", rulesFile, err)
			}
			var r rule
			if err := yaml.UnmarshalStrict(b, &r); err != nil {
				t.Fatalf("%s: %v", rulesFile, err)
			}
			out = append(out, r)
		}
	}
	if len(out) == 0 {
		t.Fatalf("%s declares no rules", rulesFile)
	}
	return out
}

// dashboardExprs returns every target expression, including those of panels nested in a collapsed row.
func dashboardExprs(t *testing.T) []string {
	t.Helper()
	type panel struct {
		Title   string `json:"title"`
		Targets []struct {
			Expr string `json:"expr"`
		} `json:"targets"`
		Panels []panel `json:"panels"`
	}
	var dash struct {
		Panels []panel `json:"panels"`
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, dashboardFile)), &dash); err != nil {
		t.Fatalf("parse %s: %v", dashboardFile, err)
	}
	var out []string
	var walk func([]panel)
	walk = func(ps []panel) {
		for _, p := range ps {
			for _, tg := range p.Targets {
				if strings.TrimSpace(tg.Expr) != "" {
					out = append(out, tg.Expr)
				}
			}
			walk(p.Panels)
		}
	}
	walk(dash.Panels)
	if len(out) == 0 {
		t.Fatalf("%s declares no queries", dashboardFile)
	}
	return out
}

func TestEveryStatPanelAsksForTheCurrentValue(t *testing.T) {
	// A stat panel shows one number for now.
	// Run as a range query, Grafana reduces it to the last non-null value of the window, so a series that stopped being
	// scraped keeps showing its last reading, a green 0 faults among them, instead of the panel's no-data text.
	//
	// Mutation that turns this red: delete one "instant": true from gpu_dashboard.json.
	type panel struct {
		Type    string `json:"type"`
		Title   string `json:"title"`
		Targets []struct {
			Instant bool `json:"instant"`
		} `json:"targets"`
		Panels []panel `json:"panels"`
	}
	var dash struct {
		Panels []panel `json:"panels"`
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, dashboardFile)), &dash); err != nil {
		t.Fatalf("parse %s: %v", dashboardFile, err)
	}
	stats := 0
	var walk func([]panel)
	walk = func(ps []panel) {
		for _, p := range ps {
			if p.Type == "stat" {
				for i, tg := range p.Targets {
					stats++
					if !tg.Instant {
						t.Errorf("stat panel %q target %d is a range query; set \"instant\": true", p.Title, i)
					}
				}
			}
			walk(p.Panels)
		}
	}
	walk(dash.Panels)
	if stats == 0 {
		t.Fatalf("%s has no stat panel targets, so this test checked nothing", dashboardFile)
	}
}

var (
	quoted = regexp.MustCompile(`"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'`)
	braces = regexp.MustCompile(`\{[^{}]*\}`)
	ranges = regexp.MustCompile(`\[[^\[\]]*\]`)
	// The label lists of grouping and matching modifiers name labels, not series.
	grouping = regexp.MustCompile(`\b(by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)`)
	ident    = regexp.MustCompile(`\b[A-Za-z_:][A-Za-z0-9_:]*\b`)
	call     = regexp.MustCompile(`^\s*\(`)
)

// notSeries are PromQL's words that can stand where a series name stands without a parenthesis after them.
var notSeries = map[string]bool{
	"and": true, "or": true, "unless": true, "by": true, "without": true, "on": true, "ignoring": true,
	"group_left": true, "group_right": true, "offset": true, "bool": true, "inf": true, "nan": true,
	"sum": true, "min": true, "max": true, "avg": true, "count": true, "stddev": true, "stdvar": true, "group": true,
	"topk": true, "bottomk": true, "quantile": true, "count_values": true, "limitk": true, "limit_ratio": true,
}

// seriesNames returns the series an expression selects.
//
// It is a lexer, not a parser, and it is deliberately conservative in one direction.
// Anything it cannot classify as a function, an operator or a label is reported as a series, so an unfamiliar word
// fails the test rather than slipping by.
func seriesNames(expr string) []string {
	s := quoted.ReplaceAllString(expr, " ")
	s = braces.ReplaceAllString(s, " ")
	s = ranges.ReplaceAllString(s, " ")
	s = grouping.ReplaceAllString(s, " $1 ")
	names := map[string]bool{}
	for _, loc := range ident.FindAllStringIndex(s, -1) {
		w := s[loc[0]:loc[1]]
		if notSeries[w] || call.MatchString(s[loc[1]:]) {
			continue
		}
		names[w] = true
	}
	return slices.Sorted(maps.Keys(names))
}

func TestSeriesNamesReadsSelectorsAndNothingElse(t *testing.T) {
	got := seriesNames(`max by (Hostname, gpu) (label_replace(DCGM_FI_DEV_XID_ERRORS{job="x"} != 0,` +
		` "field", "xid", "", ""))` +
		` or on (cluster_queue) sum(increase(kueue_admitted_workloads_total[30m])) and kueue_pending_workloads offset 30m` +
		` unless histogram_quantile(0.9, sum by (le) (rate(kueue_admission_wait_time_seconds_bucket[10m:1m])))`)
	want := []string{"DCGM_FI_DEV_XID_ERRORS", "kueue_admission_wait_time_seconds_bucket",
		"kueue_admitted_workloads_total", "kueue_pending_workloads"}
	if !slices.Equal(got, want) {
		t.Fatalf("seriesNames = %v, want %v", got, want)
	}
}

// emitted is every series name the deployed components can produce, mapped to whether it is a histogram.
type emitted map[string]bool

// resolves allows a histogram's _bucket, _sum and _count only for a histogram, so a counter with a histogram's suffix
// is still reported as the series that does not exist.
func (e emitted) resolves(name string) bool {
	if _, ok := e[name]; ok {
		return true
	}
	for _, suffix := range []string{"_bucket", "_sum", "_count"} {
		if base, ok := strings.CutSuffix(name, suffix); ok && e[base] {
			return true
		}
	}
	return false
}

// dcgmFields reads the fields the ops exporter is configured to collect, from its counters CSV.
func dcgmFields(t *testing.T) emitted {
	t.Helper()
	m := regexp.MustCompile(`(?m)^\s*(DCGM_FI_[A-Z0-9_]+)\s*,`).FindAllStringSubmatch(readRepoFile(t, opsExporter), -1)
	if len(m) == 0 {
		t.Fatalf("no DCGM field found in %s; the CSV has moved and this reader must follow it", opsExporter)
	}
	out := emitted{}
	for _, f := range m {
		out[f[1]] = false
	}
	return out
}

// operatorMetrics reads the operator's metric definitions, prefix resolved, as hack/check-dashboard.sh does.
func operatorMetrics(t *testing.T) emitted {
	t.Helper()
	src := readRepoFile(t, "internal/controller/metrics.go")
	prefix := regexp.MustCompile(`const metricPrefix = "([a-z_]+)"`).FindStringSubmatch(src)
	if prefix == nil {
		t.Fatal("metricPrefix not found in internal/controller/metrics.go")
	}
	out := emitted{}
	opts := regexp.MustCompile(`(?s)prometheus\.(\w+)Opts\{(.*?)\n\t\t\}`)
	name := regexp.MustCompile(`Name:\s*metricPrefix\s*\+\s*"([a-z_]+)"`)
	for _, m := range opts.FindAllStringSubmatch(src, -1) {
		if n := name.FindStringSubmatch(m[2]); n != nil {
			out[prefix[1]+n[1]] = m[1] == "Histogram"
		}
	}
	if len(out) == 0 {
		t.Fatal("no metric definition read from internal/controller/metrics.go")
	}
	return out
}

// recorder is a Registerer that keeps what is registered with it instead of serving it.
type recorder struct {
	mu    sync.Mutex
	names emitted
}

var fqName = regexp.MustCompile(`fqName: "([^"]+)"`)

func (r *recorder) Register(c prometheus.Collector) error {
	_, histogram := c.(*prometheus.HistogramVec)
	ch := make(chan *prometheus.Desc, 16)
	go func() { c.Describe(ch); close(ch) }()
	r.mu.Lock()
	defer r.mu.Unlock()
	for d := range ch {
		if m := fqName.FindStringSubmatch(d.String()); m != nil {
			r.names[m[1]] = histogram
		}
	}
	return nil
}

func (r *recorder) MustRegister(cs ...prometheus.Collector) {
	for _, c := range cs {
		_ = r.Register(c)
	}
}

func (r *recorder) Unregister(prometheus.Collector) bool { return false }

func (r *recorder) Gather() ([]*dto.MetricFamily, error) { return nil, nil }

// kueueMetrics asks the Kueue module itself what it registers, by standing in for the registry it registers with.
//
// The module is the one go.mod pins, which is not the release EKS runs: config/kueue-controller vendors v0.18.3 because
// the operator reads kueue.x-k8s.io/v1beta1. Every kueue_ name the rules use was also read in the v0.18.3 source when
// they were written; a rename between the two would surface here only if go.mod moved past it.
func kueueMetrics(t *testing.T) emitted {
	t.Helper()
	rec := &recorder{names: emitted{}}
	saved := ctrlmetrics.Registry
	ctrlmetrics.Registry = rec
	defer func() { ctrlmetrics.Registry = saved }()
	kueuemetrics.Register()
	if len(rec.names) == 0 {
		t.Fatal("Kueue registered no metrics with the stand-in registry")
	}
	return rec.names
}

// builtins are series Prometheus writes itself for every target.
var builtins = emitted{"up": false}

// external are series from components this repository assumes and does not deploy, named one by one so each is a
// decision someone wrote down, not a gap the lexer let through.
// kube_node_status_capacity is kube-state-metrics', shipped by the kube-prometheus-stack the PodMonitors already need;
// GPUExporterNotReporting reads it; the kind rehearsal in hack/gpu-alert-delivery.sh records it with nvidia_com_gpu.
var external = emitted{"kube_node_status_capacity": false}

func TestEverySeriesTheRulesAndDashboardReadIsOneSomethingEmits(t *testing.T) {
	known := emitted{}
	for _, src := range []emitted{dcgmFields(t), operatorMetrics(t), kueueMetrics(t), builtins, external} {
		maps.Copy(known, src)
	}
	check := func(where, expr string) {
		names := seriesNames(expr)
		if len(names) == 0 {
			t.Errorf("%s: no series read from %q; the lexer missed it or the expression selects nothing", where, expr)
		}
		for _, n := range names {
			if !known.resolves(n) {
				t.Errorf("%s reads %s, which nothing this repository deploys emits", where, n)
			}
		}
	}
	for _, r := range loadRules(t) {
		check(rulesFile+" "+r.Alert+r.Record, r.Expr)
	}
	for i, e := range dashboardExprs(t) {
		check(fmt.Sprintf("%s query %d", dashboardFile, i), e)
	}
}

// The operator's fault path reads three fields; an exporter deployed from the ops overlay must carry all of them, or
// the operator would report FieldMissing on every node the dashboard calls covered.
func TestTheOpsExporterCollectsWhatTheFaultPathReads(t *testing.T) {
	fields := dcgmFields(t)
	for _, f := range []string{gpufault.FieldXid, gpufault.FieldECCDoubleBit, gpufault.FieldECCSingleBit} {
		if _, ok := fields[f]; !ok {
			t.Errorf("%s does not collect %s, which internal/gpufault reads", opsExporter, f)
		}
	}
}

// GPUExporterNotReporting joins a node's name to the exporter's Hostname label, and dcgm-exporter fills Hostname from
// $NODE_NAME, falling back to the Pod's own hostname, which is the Pod name.
// Without NODE_NAME from spec.nodeName every GPU node would read as unwatched while its exporter reported normally.
//
// Mutation that turns this red: delete the NODE_NAME env from config/dcgm-exporter/daemonset.yaml, or read it from
// another field.
func TestTheExporterNamesTheNodeTheExporterAlertJoinsOn(t *testing.T) {
	var ds struct {
		Spec struct {
			Template struct {
				Spec struct {
					Containers []struct {
						Name string
						Env  []struct {
							Name      string
							ValueFrom struct {
								FieldRef struct {
									FieldPath string `json:"fieldPath"`
								} `json:"fieldRef"`
							} `json:"valueFrom"`
						}
					}
				}
			}
		}
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, "config/dcgm-exporter/daemonset.yaml")), &ds); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range ds.Spec.Template.Spec.Containers {
		if c.Name != "exporter" {
			continue
		}
		for _, e := range c.Env {
			found = found || e.Name == "NODE_NAME" && e.ValueFrom.FieldRef.FieldPath == "spec.nodeName"
		}
	}
	if !found {
		t.Error("the exporter container does not set NODE_NAME from spec.nodeName, so its Hostname label is the Pod name")
	}
	joined := false
	for _, r := range loadRules(t) {
		if r.Alert == "GPUExporterNotReporting" {
			joined = strings.Contains(r.Expr, `"node", "$1", "Hostname", "(.*)"`)
		}
	}
	if !joined {
		t.Errorf("%s has no GPUExporterNotReporting joining Hostname to node", rulesFile)
	}
}

// The alert and the operator must agree on which Xids are faults, and the operator's list is unexported.
// So the list is recovered from Assess, by asking it about every Xid, and compared with the values the rule excludes.
func TestTheXidAlertExcludesExactlyTheXidsTheOperatorIgnores(t *testing.T) {
	ignored := []int64{}
	for xid := int64(1); xid < 1024; xid++ {
		a, err := gpufault.Assess(map[string]*gpufault.GPUReading{"GPU-0": {
			UUID:   "GPU-0",
			Values: map[string]float64{gpufault.FieldXid: float64(xid), gpufault.FieldECCDoubleBit: 0},
		}})
		if err != nil {
			t.Fatalf("Assess(xid %d): %v", xid, err)
		}
		if len(a.Faults) == 0 {
			ignored = append(ignored, xid)
		}
	}
	if len(ignored) == 0 {
		t.Fatal("Assess ignored no Xid at all; the probe is not reaching the policy")
	}
	excludedBy := func(where, expr string) {
		m := regexp.MustCompile(`DCGM_FI_DEV_XID_ERRORS((?:\s*!=\s*\d+)+)`).FindStringSubmatch(expr)
		if m == nil {
			t.Errorf("%s: no DCGM_FI_DEV_XID_ERRORS != ... chain found", where)
			return
		}
		var got []int64
		for _, v := range regexp.MustCompile(`\d+`).FindAllString(m[1], -1) {
			n, _ := strconv.ParseInt(v, 10, 64)
			if n != 0 {
				got = append(got, n)
			}
		}
		slices.Sort(got)
		if !slices.Equal(got, ignored) {
			t.Errorf("%s excludes Xids %v; the operator ignores %v", where, got, ignored)
		}
	}
	found := false
	for _, r := range loadRules(t) {
		if r.Alert == "GPUFaultSignalPresent" {
			excludedBy(rulesFile+" GPUFaultSignalPresent", r.Expr)
			found = true
		}
	}
	if !found {
		t.Fatalf("%s has no GPUFaultSignalPresent", rulesFile)
	}
	for i, e := range dashboardExprs(t) {
		if strings.Contains(e, "DCGM_FI_DEV_XID_ERRORS !=") {
			excludedBy(fmt.Sprintf("%s query %d", dashboardFile, i), e)
		}
	}
}

// githubAnchor is the fragment GitHub gives a Markdown heading.
func githubAnchor(heading string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(heading)) {
		switch {
		case r == ' ':
			b.WriteRune('-')
		case r == '-' || r == '_' || ('a' <= r && r <= 'z') || ('0' <= r && r <= '9') || r > 127:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Every alert names a runbook, and the runbook is a heading that exists in this tree.
func TestEveryAlertLinksARunbookHeadingThatExists(t *testing.T) {
	heading := regexp.MustCompile(`(?m)^#{1,6}\s+(.+?)\s*$`)
	for _, r := range loadRules(t) {
		if r.Alert == "" {
			continue
		}
		url := r.Annotations["runbook_url"]
		rest, ok := strings.CutPrefix(url, runbookPrefix)
		if !ok {
			t.Errorf("%s: runbook_url %q does not start with %s", r.Alert, url, runbookPrefix)
			continue
		}
		path, anchor, ok := strings.Cut(rest, "#")
		if !ok || anchor == "" {
			t.Errorf("%s: runbook_url %q names no heading", r.Alert, url)
			continue
		}
		var anchors []string
		for _, h := range heading.FindAllStringSubmatch(readRepoFile(t, path), -1) {
			anchors = append(anchors, githubAnchor(strings.Trim(h[1], "`")))
		}
		if !slices.Contains(anchors, anchor) {
			t.Errorf("%s: %s has no heading with anchor #%s", r.Alert, path, anchor)
		}
	}
}
