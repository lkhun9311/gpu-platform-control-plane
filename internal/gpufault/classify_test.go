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

package gpufault

import (
	"strings"
	"testing"
)

// scrape renders the three fields for one card the way dcgm-exporter 3.3.9 does, modelName comma included.
func scrape(xid, dbe, sbe string) []byte {
	l := `{gpu="0",UUID="GPU-aaaa",device="nvidia0",modelName="NVIDIA A10G, test",Hostname="n1"}`
	var b strings.Builder
	b.WriteString("# HELP DCGM_FI_DEV_XID_ERRORS Value of the last XID error encountered.\n")
	b.WriteString("# TYPE DCGM_FI_DEV_XID_ERRORS gauge\n")
	if xid != "" {
		b.WriteString(FieldXid + l + " " + xid + "\n")
	}
	if dbe != "" {
		b.WriteString(FieldECCDoubleBit + l + " " + dbe + "\n")
	}
	if sbe != "" {
		b.WriteString(FieldECCSingleBit + l + " " + sbe + "\n")
	}
	b.WriteString(`DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-aaaa"} 97` + "\n")
	return []byte(b.String())
}

func assess(t *testing.T, body []byte) Assessment {
	t.Helper()
	r, err := ParseExposition(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	a, err := Assess(r)
	if err != nil {
		t.Fatalf("assess: %v", err)
	}
	return a
}

func TestAssessHealthyCardHasNoFaultAndNothingMissing(t *testing.T) {
	a := assess(t, scrape("0", "0", "0"))
	if len(a.Faults) != 0 || len(a.Missing) != 0 || a.Cards != 1 || a.Fingerprint() != "" {
		t.Fatalf("healthy card read as %+v", a)
	}
}

func TestAssessFatalXidIsAFaultWithItsCode(t *testing.T) {
	a := assess(t, scrape("79", "0", "0"))
	if got := a.Fingerprint(); got != "GPU-aaaa/DCGM_FI_DEV_XID_ERRORS=79" {
		t.Fatalf("fingerprint %q", got)
	}
	if a.Reason() != ReasonXid {
		t.Fatalf("reason %q", a.Reason())
	}
}

// The device plugin's application Xids are about a process, not the card, and must not quarantine a node.
func TestAssessApplicationXidsAreNotFaults(t *testing.T) {
	for _, x := range []string{"13", "31", "43", "45", "68"} {
		if a := assess(t, scrape(x, "0", "0")); len(a.Faults) != 0 {
			t.Errorf("Xid %s read as a fault: %+v", x, a.Faults)
		}
	}
	// 48 is the double-bit ECC Xid and is not in the plugin's list.
	if a := assess(t, scrape("48", "0", "0")); len(a.Faults) != 1 {
		t.Errorf("Xid 48 not read as a fault: %+v", a)
	}
}

func TestAssessDoubleBitCountIsAFaultAndSingleBitNever(t *testing.T) {
	if a := assess(t, scrape("0", "1", "0")); a.Reason() != ReasonECCDoubleBit || a.Fingerprint() != "GPU-aaaa/DCGM_FI_DEV_ECC_DBE_VOL_TOTAL=1" {
		t.Fatalf("double-bit read as %+v", a)
	}
	if a := assess(t, scrape("0", "0", "4000")); len(a.Faults) != 0 {
		t.Fatalf("single-bit count read as a fault: %+v", a)
	}
	if a := assess(t, scrape("79", "2", "0")); a.Reason() != ReasonMultipleFault || len(a.Faults) != 2 {
		t.Fatalf("two faults read as %+v", a)
	}
}

// A card that does not carry a fault field cannot be called healthy; the absence is reported, not filled in.
func TestAssessMissingAndUnavailableFieldsAreReported(t *testing.T) {
	a := assess(t, scrape("0", "", "0"))
	if len(a.Missing) != 1 || a.Missing[0] != "GPU-aaaa/"+FieldECCDoubleBit {
		t.Fatalf("missing %v", a.Missing)
	}
	a = assess(t, scrape("0", "N/A", "0"))
	if len(a.Missing) != 1 {
		t.Fatalf("an unavailable value was read as present: %+v", a)
	}
	// A scrape with none of the fields has no cards, which the caller must not read as healthy.
	a = assess(t, []byte(`DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-aaaa"} 97`+"\n"))
	if a.Cards != 0 {
		t.Fatalf("cards %d", a.Cards)
	}
}

func TestParseRefusesWhatItCannotRead(t *testing.T) {
	for name, body := range map[string]string{
		"no labels":       FieldXid + " 79\n",
		"no value":        FieldXid + `{UUID="GPU-a"}` + "\n",
		"no uuid":         FieldXid + `{gpu="0"} 79` + "\n",
		"label no equals": FieldXid + `{UUID="GPU-a",bad} 79` + "\n",
		"two values":      FieldXid + `{UUID="GPU-a",pod="x"} 79` + "\n" + FieldXid + `{UUID="GPU-a",pod="y"} 0` + "\n",
	} {
		if _, err := ParseExposition([]byte(body)); err == nil {
			t.Errorf("%s: parsed without error", name)
		}
	}
	r, err := ParseExposition([]byte(FieldXid + `{UUID="GPU-a"} 2.5` + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Assess(r); err == nil {
		t.Errorf("a fractional Xid was assessed")
	}
}
