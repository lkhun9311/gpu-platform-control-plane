package queuelab

import (
	"strings"
	"testing"
)

// realScrape is the shape a DCGM exporter actually emits, including the series this ignores, an idle card
// with no Pod labels, and a model name containing a comma.
const realScrape = `# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (in %).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-aaaa",device="nvidia0",modelName="NVIDIA A10G",Hostname="w1",container="trainer",namespace="queuelab-r1",pod="a2-borrow-x7k2p"} 97
DCGM_FI_DEV_GPU_UTIL{gpu="1",UUID="GPU-bbbb",device="nvidia1",modelName="NVIDIA A100-SXM4-40GB, MIG 1g.5gb",Hostname="w1",container="trainer",namespace="queuelab-r1",pod="b1-owner-m4t9q"} 3
DCGM_FI_DEV_GPU_UTIL{gpu="2",UUID="GPU-cccc",device="nvidia2",modelName="NVIDIA A10G",Hostname="w1"} 0
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-aaaa",Hostname="w1",namespace="queuelab-r1",pod="a2-borrow-x7k2p"} 8192
`

// resolver maps the two Pods the collector would have observed.
func resolver(ns, name string) string {
	switch ns + "/" + name {
	case "queuelab-r1/a2-borrow-x7k2p":
		return "victim-uid"
	case "queuelab-r1/b1-owner-m4t9q":
		return "owner-uid"
	}
	return ""
}

// The ordinary scrape: two attributed samples, the idle card skipped, the other metric ignored, and the
// comma inside a model name not breaking the label split.
func TestParseDCGMTakesUtilisationAndAttributesIt(t *testing.T) {
	got, unattributed, err := ParseDCGMUtilisation([]byte(realScrape), 5_000_000_000, resolver)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if unattributed != 0 {
		t.Fatalf("unattributed = %d, want 0: every labelled Pod is one the resolver knows", unattributed)
	}
	if len(got) != 2 {
		t.Fatalf("samples = %d, want 2 (the idle card has no Pod and DCGM_FI_DEV_FB_USED is not utilisation): %+v",
			len(got), got)
	}
	byUID := map[string]DeviceSample{}
	for _, s := range got {
		byUID[s.PodUID] = s
	}
	if v := byUID["victim-uid"]; v.DeviceUUID != "GPU-aaaa" || v.UtilisationPercent != 97 || v.AtNs != 5_000_000_000 {
		t.Fatalf("victim sample = %+v", v)
	}
	// The card whose model name contains a comma must still parse; a naive split on commas produces a
	// fragment with no '=' and turns a good scrape into an error.
	if o := byUID["owner-uid"]; o.DeviceUUID != "GPU-bbbb" || o.UtilisationPercent != 3 {
		t.Fatalf("owner sample = %+v; the model name's comma broke the label split", o)
	}
}

// A card nobody is using carries no Pod labels every scrape. That is not an attribution failure and must not
// be counted as one, or every observation would look partial.
func TestAnIdleCardIsNotAnAttributionFailure(t *testing.T) {
	_, unattributed, err := ParseDCGMUtilisation(
		[]byte(`DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-cccc",Hostname="w1"} 0`+"\n"), 1, resolver)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if unattributed != 0 {
		t.Fatalf("an idle card counted as unattributed (%d); an observation would read as partial every scrape",
			unattributed)
	}
}

// A Pod the collector never saw is evidence, not noise: the observer and the run disagree about what was on
// the node, and dropping it silently would report a clean observation of a cluster nobody fully saw.
func TestAPodTheCollectorNeverSawIsCounted(t *testing.T) {
	line := `DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-dddd",namespace="other",pod="stranger-9xk"} 55` + "\n"
	got, unattributed, err := ParseDCGMUtilisation([]byte(line), 1, resolver)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("an unresolvable Pod produced a sample: %+v", got)
	}
	if unattributed != 1 {
		t.Fatalf("unattributed = %d, want 1", unattributed)
	}
}

// A sample naming a Pod but no card cannot say which device did anything, and that is an error rather than a
// skip: silently dropping it would hide a broken exporter behind a thinner observation.
func TestASampleWithoutADeviceUUIDIsAnError(t *testing.T) {
	line := `DCGM_FI_DEV_GPU_UTIL{gpu="0",namespace="queuelab-r1",pod="a2-borrow-x7k2p"} 40` + "\n"
	if _, _, err := ParseDCGMUtilisation([]byte(line), 1, resolver); err == nil {
		t.Fatal("a sample naming no device parsed")
	}
}

// Anything the parser cannot read is an error. A dependency that silently accepted malformed lines would
// turn a broken observer into a quiet one.
func TestMalformedScrapesAreRefusedRatherThanSkipped(t *testing.T) {
	for name, line := range map[string]string{
		"no label set":    `DCGM_FI_DEV_GPU_UTIL 97`,
		"non-integer":     `DCGM_FI_DEV_GPU_UTIL{UUID="G",namespace="queuelab-r1",pod="a2-borrow-x7k2p"} 97.5`,
		"out of range":    `DCGM_FI_DEV_GPU_UTIL{UUID="G",namespace="queuelab-r1",pod="a2-borrow-x7k2p"} 4000`,
		"label with no =": `DCGM_FI_DEV_GPU_UTIL{UUID="G",broken,namespace="queuelab-r1",pod="a2-borrow-x7k2p"} 10`,
		"no value at all": `DCGM_FI_DEV_GPU_UTIL{UUID="G",namespace="queuelab-r1",pod="a2-borrow-x7k2p"}`,
	} {
		if _, _, err := ParseDCGMUtilisation([]byte(line+"\n"), 1, resolver); err == nil {
			t.Errorf("%s: parsed without error", name)
		}
	}
}

// The observer labels by name; something else has to say which object that name referred to. Without a
// resolver there is nothing to attribute to, and inventing an identity is the one thing this must not do.
func TestParsingWithoutAResolverIsRefused(t *testing.T) {
	_, _, err := ParseDCGMUtilisation([]byte(realScrape), 1, nil)
	if err == nil {
		t.Fatal("a scrape parsed with nothing to resolve Pod identity")
	}
	if !strings.Contains(err.Error(), "which object that name referred to") {
		t.Fatalf("the refusal does not say what is missing: %v", err)
	}
}
