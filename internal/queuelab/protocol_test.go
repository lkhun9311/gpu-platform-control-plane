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

package queuelab

import "testing"

func TestArmPolicyVariant(t *testing.T) {
	for _, tc := range []struct {
		arm  Arm
		want string
	}{
		{ArmAHonor, "Any"},
		{ArmAIgnore, "Any"},
		{ArmNRef, "Never"},
	} {
		got, err := tc.arm.PolicyVariant()
		if err != nil {
			t.Fatalf("%s: %v", tc.arm, err)
		}
		if got != tc.want {
			t.Fatalf("%s policy = %q, want %q", tc.arm, got, tc.want)
		}
	}
	if _, err := Arm("nonsense").PolicyVariant(); err == nil {
		t.Fatal("an unknown arm must be rejected, not silently defaulted")
	}
}

// TestArmContractIsPerRow is the point of the whole type: the treatment is the victim's behaviour, so the
// two Any arms must differ on exactly one row and agree on the other two.
func TestArmContractIsPerRow(t *testing.T) {
	rows := []string{OwnRow, VictimRow, OwnerRow}
	diff := 0
	for _, row := range rows {
		h, err := ArmAHonor.ContractFor(row)
		if err != nil {
			t.Fatalf("A-honor %s: %v", row, err)
		}
		i, err := ArmAIgnore.ContractFor(row)
		if err != nil {
			t.Fatalf("A-ignore %s: %v", row, err)
		}
		if h != i {
			diff++
			if row != VictimRow {
				t.Fatalf("the arms differ on row %q; only the victim may differ", row)
			}
		}
	}
	if diff != 1 {
		t.Fatalf("A-honor and A-ignore differ on %d rows, want exactly 1 (the victim)", diff)
	}

	if c, _ := ArmAIgnore.ContractFor(VictimRow); c != IgnoresSIGTERM {
		t.Fatalf("A-ignore victim contract = %v, want IgnoresSIGTERM", c)
	}
	// N-ref exists to show what happens without reclamation, so its workloads must match A-honor exactly.
	for _, row := range rows {
		n, _ := ArmNRef.ContractFor(row)
		h, _ := ArmAHonor.ContractFor(row)
		if n != h {
			t.Fatalf("N-ref row %q contract = %v, want the same as A-honor (%v)", row, n, h)
		}
	}
	if _, err := ArmAHonor.ContractFor("not-a-row"); err == nil {
		t.Fatal("an unknown row must be rejected")
	}
}
