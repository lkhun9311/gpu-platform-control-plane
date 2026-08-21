package queuelab

import (
	"bufio"
	"bytes"
	"fmt"
	"strconv"
	"strings"
)

// dcgmUtilisationMetric is the one series this reads.
//
// DCGM exports dozens; this takes GPU utilisation because it is the only one that answers the question the
// axis asks -- did the card do work -- rather than how much memory was reserved, which is allocation again
// under a different name.
const dcgmUtilisationMetric = "DCGM_FI_DEV_GPU_UTIL"

// PodResolver maps a namespace and Pod NAME to the Pod's UID, or "" when the caller never observed it.
//
// The split is the honest part of this design. DCGM labels its samples with a Pod name because that is what
// the kubelet told it; the API is what says which object that name referred to. Letting the observer supply
// the UID as well would make it the authority on both what the card did AND whose card it was, and the second
// half is not its to assert.
//
// The caller builds this from its own watch rather than a live lookup, because by the time a run is
// reconstructed the Pod is gone and a live lookup would resolve nothing -- or worse, resolve a name that has
// since been reused.
type PodResolver func(namespace, name string) string

// ParseDCGMUtilisation turns one scrape of a DCGM exporter into samples, and reports how many it could not
// attribute.
//
// The unattributed count is returned rather than logged because it is evidence. A scrape naming Pods the
// collector never saw means the observer and the run disagree about what was on the node, and a caller that
// silently dropped those would be reporting a clean observation of a cluster it did not fully see. Samples
// with no Pod label at all are a different thing and are not counted: an idle card belongs to nobody, and
// DCGM emits it every scrape.
func ParseDCGMUtilisation(body []byte, atNs int64, resolve PodResolver) ([]DeviceSample, int, error) {
	if resolve == nil {
		return nil, 0, fmt.Errorf("no Pod resolver: the observer labels by name and something else has to say " +
			"which object that name referred to")
	}
	var out []DeviceSample
	unattributed := 0
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || !strings.HasPrefix(line, dcgmUtilisationMetric) {
			continue
		}
		labels, value, err := splitMetricLine(line)
		if err != nil {
			return nil, 0, fmt.Errorf("scrape at %d ns: %w", atNs, err)
		}
		// An idle card carries no Pod labels. It is not an attribution failure, it is a card nobody is using.
		if labels["pod"] == "" {
			continue
		}
		uid := resolve(labels["namespace"], labels["pod"])
		if uid == "" {
			unattributed++
			continue
		}
		if labels["UUID"] == "" {
			return nil, 0, fmt.Errorf("scrape at %d ns: a sample for pod %s/%s names no device UUID",
				atNs, labels["namespace"], labels["pod"])
		}
		out = append(out, DeviceSample{
			AtNs:               atNs,
			DeviceUUID:         labels["UUID"],
			PodUID:             uid,
			UtilisationPercent: value,
		})
	}
	if err := sc.Err(); err != nil {
		return nil, 0, fmt.Errorf("read scrape at %d ns: %w", atNs, err)
	}
	return out, unattributed, nil
}

// splitMetricLine pulls the labels and the value out of one Prometheus exposition line.
//
// It is hand-written rather than pulled from a parsing library because the whole surface is one metric with
// quoted label values and an integer, and because a dependency that silently accepts a malformed line would
// turn a broken observer into a quiet one. Anything it cannot read is an error rather than a skip.
func splitMetricLine(line string) (map[string]string, int, error) {
	open := strings.IndexByte(line, '{')
	closeAt := strings.LastIndexByte(line, '}')
	if open < 0 || closeAt < open {
		return nil, 0, fmt.Errorf("no label set in %q", line)
	}
	labels := map[string]string{}
	for _, pair := range splitLabels(line[open+1 : closeAt]) {
		eq := strings.IndexByte(pair, '=')
		if eq < 0 {
			return nil, 0, fmt.Errorf("label %q in %q has no value", pair, line)
		}
		labels[strings.TrimSpace(pair[:eq])] = strings.Trim(strings.TrimSpace(pair[eq+1:]), `"`)
	}
	raw := strings.TrimSpace(line[closeAt+1:])
	// Utilisation is an integer percent. A float would parse and then round somewhere invisible, so it is
	// refused here where the reason can be given.
	v, err := strconv.Atoi(raw)
	if err != nil {
		return nil, 0, fmt.Errorf("value %q in %q is not an integer percent", raw, line)
	}
	if v < 0 || v > 100 {
		return nil, 0, fmt.Errorf("utilisation %d in %q is outside 0-100", v, line)
	}
	return labels, v, nil
}

// splitLabels splits a label set on commas that are not inside a quoted value.
//
// DCGM's modelName carries commas on some cards ("NVIDIA A100-SXM4-40GB, MIG 1g.5gb"), and a naive split
// would produce a fragment with no '=' and turn a perfectly good scrape into a parse error.
func splitLabels(s string) []string {
	var out []string
	var cur strings.Builder
	inQuote := false
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '"':
			inQuote = !inQuote
			cur.WriteByte(c)
		case c == ',' && !inQuote:
			out = append(out, cur.String())
			cur.Reset()
		default:
			cur.WriteByte(c)
		}
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}
