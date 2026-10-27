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

// Package gpufault reads the GPU fault fields a DCGM exporter serves, decides which of them mean the card is
// faulted, and scores the fault-reaction study registered in
// docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md.
//
// It is a package of its own, and not part of internal/queuelab, because the two read the same exporter for
// opposite purposes: queuelab asks whether a card did work, this asks whether a card can be trusted with any.
package gpufault

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"math"
	"slices"
	"sort"
	"strconv"
	"strings"
)

// The three series this package reads, by the names dcgm-exporter gives DCGM fields 230, 311 and 310
// (dcgmlib/dcgm_fields.h; the exporter's default-counters.csv).
const (
	// FieldXid is the value of the last Xid error DCGM recorded for the card, 0 when there has been none.
	FieldXid = "DCGM_FI_DEV_XID_ERRORS"
	// FieldECCDoubleBit is the volatile count of uncorrected double-bit ECC errors since the driver loaded.
	FieldECCDoubleBit = "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL"
	// FieldECCSingleBit is the volatile count of corrected single-bit ECC errors, which is never a fault here.
	FieldECCSingleBit = "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL"
)

// Reasons a fault carries, which the controller copies into the GPUHealthy condition.
const (
	ReasonXid           = "XidError"
	ReasonECCDoubleBit  = "EccDoubleBitError"
	ReasonMultipleFault = "MultipleFaults"
)

// faultFields are the fields whose absence means the card's health cannot be judged.
//
// The single-bit count is not among them: it is read so the benign arm can show a change that is ignored,
// and a card that does not export it has lost nothing the policy needs.
var faultFields = []string{FieldXid, FieldECCDoubleBit}

// applicationXids are the Xids NVIDIA's device plugin ignores as application errors.
//
// Borrowed rather than chosen, from k8s-device-plugin v0.16.2 internal/rm/health.go ("Application errors: the
// GPU should still be healthy"), so that this platform's quarantine and the plugin's own unhealthy rule agree
// on which Xids are about the card. Every other non-zero Xid is a fault.
var applicationXids = map[int64]bool{13: true, 31: true, 43: true, 45: true, 68: true}

// GPUReading is what one scrape said about one card.
type GPUReading struct {
	// UUID identifies the card across scrapes; the gpu index can be renumbered, the UUID cannot.
	UUID string
	// GPU is the exporter's index label, kept for messages.
	GPU string
	// Values holds every fault-relevant field the scrape carried a readable value for.
	Values map[string]float64
	// Unavailable names the fault-relevant fields the scrape carried with a value this parser cannot read.
	Unavailable map[string]bool
}

// errUnreadable marks one sample line whose value is not a number, as distinct from a malformed scrape.
var errUnreadable = errors.New("value is not a number")

// ParseExposition reads the three fields out of one exporter scrape, keyed by card UUID.
//
// A line that is malformed is an error for the whole scrape, because a parser that skipped what it could not
// read would turn a broken exporter into a healthy-looking one.
// A value DCGM renders as unavailable is recorded as such, not skipped, for the same reason.
func ParseExposition(body []byte) (map[string]*GPUReading, error) {
	out := map[string]*GPUReading{}
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name := metricName(line)
		if name != FieldXid && name != FieldECCDoubleBit && name != FieldECCSingleBit {
			continue
		}
		labels, value, err := parseSample(line)
		if err != nil && !errors.Is(err, errUnreadable) {
			return nil, err
		}
		uuid := labels["UUID"]
		if uuid == "" {
			return nil, fmt.Errorf("a %s sample names no card UUID: %q", name, line)
		}
		r := out[uuid]
		if r == nil {
			r = &GPUReading{UUID: uuid, GPU: labels["gpu"], Values: map[string]float64{}, Unavailable: map[string]bool{}}
			out[uuid] = r
		}
		// The exporter emits one series per card and field, but with Kubernetes mapping on it emits one per
		// Pod as well; the values are the card's either way, and two that disagree mean the scrape cannot be
		// trusted for this card.
		if errors.Is(err, errUnreadable) {
			r.Unavailable[name] = true
			continue
		}
		if prev, ok := r.Values[name]; ok && prev != value {
			return nil, fmt.Errorf("card %s carries two different %s values in one scrape: %v and %v", uuid, name, prev, value)
		}
		r.Values[name] = value
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read scrape: %w", err)
	}
	return out, nil
}

// metricName returns the series name of an exposition line.
func metricName(line string) string {
	if i := strings.IndexAny(line, "{ "); i >= 0 {
		return line[:i]
	}
	return line
}

// parseSample splits one exposition line into its labels and value.
//
// It refuses rather than guesses: no label set, a label with no value, or nothing after the label set.
// A trailing Prometheus timestamp is allowed and ignored, because the value is what is read.
func parseSample(line string) (map[string]string, float64, error) {
	open := strings.IndexByte(line, '{')
	closeAt := strings.LastIndexByte(line, '}')
	if open < 0 || closeAt < open {
		return nil, 0, fmt.Errorf("no label set in %q", line)
	}
	labels := map[string]string{}
	for _, pair := range splitLabels(line[open+1 : closeAt]) {
		if strings.TrimSpace(pair) == "" {
			continue
		}
		k, v, ok := strings.Cut(pair, "=")
		if !ok {
			return nil, 0, fmt.Errorf("label %q in %q has no value", pair, line)
		}
		labels[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"`)
	}
	rest := strings.Fields(line[closeAt+1:])
	if len(rest) == 0 {
		return nil, 0, fmt.Errorf("no value in %q", line)
	}
	v, err := strconv.ParseFloat(rest[0], 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return labels, 0, errUnreadable
	}
	return labels, v, nil
}

// splitLabels splits a label set on commas outside quoted values.
//
// DCGM's modelName can carry commas, and a naive split would make a good scrape a parse error.
func splitLabels(s string) []string {
	var out []string
	var cur strings.Builder
	inQuote, escaped := false, false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case escaped:
			escaped = false
			cur.WriteByte(c)
		case c == '\\' && inQuote:
			escaped = true
			cur.WriteByte(c)
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

// Fault is one field on one card that the policy calls a fault.
type Fault struct {
	UUID   string
	GPU    string
	Field  string
	Value  int64
	Reason string
}

// Assessment is the policy's reading of one scrape.
type Assessment struct {
	// Faults is sorted by card UUID and then field, so the fingerprint is the same for the same state.
	Faults []Fault
	// Missing names "UUID/field" for each fault field a card did not carry a readable value for.
	Missing []string
	// Cards is how many cards the scrape carried any of the three fields for.
	Cards int

	// nonZero is true when a fault field read non-zero without being a fault: an application Xid.
	nonZero bool
	// reading is "UUID/field=value" for every readable field, sorted.
	reading string
	// uuids are the cards the scrape carried, sorted.
	uuids []string
}

// Pristine reports whether every card carried every fault field and each read zero: no Xid recorded and no
// double-bit error counted since the host engine or the driver last started.
//
// It is what releases a latched fault, and "no fault" is not enough for that. The Xid field holds the last Xid
// only, so an application Xid arriving after a fatal one replaces it and reads as no fault while nothing about
// the card was repaired; zero is the value a GPU reset or a driver reload leaves.
func (a Assessment) Pristine() bool {
	return a.Cards > 0 && len(a.Missing) == 0 && len(a.Faults) == 0 && !a.nonZero
}

// Covers reports whether the scrape carried every card a fingerprint names.
//
// A latch may be released only by a reading of the cards it is about: a node whose faulted card dropped out of
// the scrape while a healthy one stayed would otherwise read pristine and clear (codex review, finding 2).
func (a Assessment) Covers(fingerprint string) bool {
	for part := range strings.SplitSeq(fingerprint, ",") {
		uuid, _, ok := strings.Cut(part, "/")
		if !ok || !slices.Contains(a.uuids, uuid) {
			return false
		}
	}
	return true
}

// Reading names every value the scrape carried, the single-bit count included, so that a change the policy
// ignores is still a change the platform can be shown to have read.
func (a Assessment) Reading() string { return a.reading }

// Fingerprint names the fault state exactly: two scrapes have the same fingerprint when the same cards carry
// the same fault values.
//
// It is what an operator acknowledges, so a new fault -- another card, another Xid, a higher count -- changes
// it and is not covered by an acknowledgement of the old one.
func (a Assessment) Fingerprint() string {
	parts := make([]string, 0, len(a.Faults))
	for _, f := range a.Faults {
		parts = append(parts, fmt.Sprintf("%s/%s=%d", f.UUID, f.Field, f.Value))
	}
	return strings.Join(parts, ",")
}

// Reason is the condition reason for the faults: the one kind when there is one, MultipleFaults otherwise.
func (a Assessment) Reason() string {
	reason := ""
	for _, f := range a.Faults {
		switch {
		case reason == "":
			reason = f.Reason
		case reason != f.Reason:
			return ReasonMultipleFault
		}
	}
	return reason
}

// Assess applies the fault policy to one scrape's readings.
//
// An Xid is a fault unless it is one of the application Xids; a double-bit count above zero is a fault; the
// single-bit count is never one. A value that is not a whole non-negative number is refused, because a field
// DCGM defines as an Xid code or a count cannot honestly be anything else and rounding it would invent one.
func Assess(readings map[string]*GPUReading) (Assessment, error) {
	var a Assessment
	uuids := make([]string, 0, len(readings))
	for u := range readings {
		uuids = append(uuids, u)
	}
	sort.Strings(uuids)
	a.Cards = len(uuids)
	a.uuids = uuids
	var reading []string
	for _, u := range uuids {
		r := readings[u]
		for _, field := range []string{FieldXid, FieldECCDoubleBit, FieldECCSingleBit} {
			if v, ok := r.Values[field]; ok {
				reading = append(reading, fmt.Sprintf("%s/%s=%s", u, field, strconv.FormatFloat(v, 'f', -1, 64)))
			}
		}
		for _, field := range faultFields {
			v, ok := r.Values[field]
			if !ok {
				a.Missing = append(a.Missing, u+"/"+field)
				continue
			}
			if v < 0 || v != math.Trunc(v) {
				return Assessment{}, fmt.Errorf("card %s: %s is %v, not a whole non-negative number", u, field, v)
			}
			n := int64(v)
			switch {
			case field == FieldXid && n != 0 && !applicationXids[n]:
				a.Faults = append(a.Faults, Fault{UUID: u, GPU: r.GPU, Field: field, Value: n, Reason: ReasonXid})
			case field == FieldECCDoubleBit && n > 0:
				a.Faults = append(a.Faults, Fault{UUID: u, GPU: r.GPU, Field: field, Value: n, Reason: ReasonECCDoubleBit})
			case n != 0:
				a.nonZero = true
			}
		}
	}
	a.reading = strings.Join(reading, ",")
	return a, nil
}
