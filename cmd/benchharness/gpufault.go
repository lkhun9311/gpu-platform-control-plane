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

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gpufault"
)

// gpuFaultVerdict scores a fault-reaction session directory and prints the registered verdict.
//
// It exits non-zero when it refuses, so a script that pipes it cannot read a refusal as a verdict; a verdict of
// any kind, DID-NOT-REACT and FALSE-POSITIVE included, is a judgement and exits 0.
func gpuFaultVerdict(args []string) error {
	fs := flag.NewFlagSet("gpu-fault-verdict", flag.ExitOnError)
	dir := fs.String("dir", "", "the session directory, holding reps/ and smoke.env")
	jsonOut := fs.String("json", "", "also write the full report, every repetition included, as JSON to this file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" {
		return fmt.Errorf("--dir is required")
	}
	r, err := gpufault.ScoreSession(*dir)
	if err != nil {
		fmt.Println("GPU FAULT REACTION: UNREADABLE")
		return err
	}
	fmt.Print(r.String())
	if *jsonOut != "" {
		b, err := json.MarshalIndent(r, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(*jsonOut, append(b, '\n'), 0o644); err != nil {
			return err
		}
	}
	if r.Label == "REFUSED" || r.Label == "NO-EVIDENCE" {
		return fmt.Errorf("the session was refused: %v", r.Refuse)
	}
	return nil
}
