// Command simshim lets llm-d-inference-sim run as the generic serving container an InferenceDeployment renders.
//
// That container is started as `--model <name> --model-path <uri>` and probed on its port named http, 8080 by default.
// The simulator has no --model-path and listens on 8000, so it exits on the first flag and would never become ready.
// The shim drops --model-path and its value, keeps every other argument, and appends SIM_EXTRA_ARGS, which the lab's
// image sets to the port and the fake metrics the replay needs.
// It then replaces itself with the simulator, so the simulator is the container's process and its exit is the pod's.
package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
)

const simulator = "/app/llm-d-inference-sim"

// simArgs is the simulator's argument list for the arguments the container was started with.
func simArgs(in []string, extra string) []string {
	out := []string{simulator}
	for i := 0; i < len(in); i++ {
		switch {
		case in[i] == "--model-path":
			i++
		case strings.HasPrefix(in[i], "--model-path="):
		default:
			out = append(out, in[i])
		}
	}
	// Split on whitespace only, so the JSON of --fake-metrics must be written without spaces.
	return append(out, strings.Fields(extra)...)
}

func main() {
	args := simArgs(os.Args[1:], os.Getenv("SIM_EXTRA_ARGS"))
	if err := syscall.Exec(simulator, args, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "simshim: exec %s: %v\n", simulator, err)
		os.Exit(1)
	}
}
