package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
)

// The prospective-admission pilot's static control, as registered (design page, "Fitting R").
// They are constants, not flags: a fit run at another burst, threshold or margin would fit a control the design
// did not register, and the R it printed would still be read as the registered one.
const (
	pilotStaticBurst     = 30000
	pilotStaticThreshold = 1
	// pilotFitMarginParts is the margin's denominator: a_S <= a_P - 1/20, compared in integers by withinMargin.
	pilotFitMarginParts = 20
	pilotFitMaxRate     = 20000
	pilotPremiumTenant  = "premium-1"
	// pilotFitBlocks is stage A's three P blocks; the rule holds "on every trace", so a fit on fewer is a fit on
	// a different set of traces.
	pilotFitBlocks = 3
)

// cellFlags collects repeated -cell raw.jsonl:record.jsonl arguments.
type cellFlags []string

func (c *cellFlags) String() string     { return strings.Join(*c, ",") }
func (c *cellFlags) Set(v string) error { *c = append(*c, v); return nil }

// fitContender is one contender request of a P cell: when it reached the gateway, what it charged the bucket,
// what it weighs in the registered unit, and whether P admitted it.
type fitContender struct {
	id       string
	arrived  int64
	est      int
	exact    int
	admitted bool
}

// fitCell is one stage A P block, joined from its client rows and its gateway record.
type fitCell struct {
	name        string
	block       string
	contenders  []fitContender
	offeredExct int64
	admittedP   int64
	aP          float64
}

// fitPilotRate fits the static arm's rate R from stage A's P cells (design page, "Fitting R").
//
// For each P block it replays the contenders' gateway-recorded arrival instants through the gateway's own
// static-cap admitter, at threshold 1 and burst 30,000, and predicts S's admitted contender work a_S(R) in exact
// tokens. P's admitted work a_P is read from the same record. R is the largest integer in 1 to 20,000 with
// a_S(R) <= a_P - 0.05 on every block.
//
// Every R is simulated rather than searched by bisection, because a token bucket's admitted work need not be
// monotone in its rate: admitting one request earlier can leave the bucket short for a later, larger one.
//
// It refuses rather than fits when the join is incomplete: a contender with no gateway decision is the
// "unidentifiable" outcome the design names, and fitting around it would choose R on the requests that happened
// to be recorded.
func fitPilotRate(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("fit-pilot-rate", flag.ContinueOnError)
	var cells cellFlags
	fs.Var(&cells, "cell", "a stage A P block as raw.jsonl:gateway-record.jsonl; given once per block")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(cells) != pilotFitBlocks {
		return fmt.Errorf("the fit is registered on stage A's %d P blocks and was given %d", pilotFitBlocks, len(cells))
	}
	var fit []fitCell
	seen := map[string]bool{}
	for _, c := range cells {
		raw, record, ok := strings.Cut(c, ":")
		if !ok || raw == "" || record == "" {
			return fmt.Errorf("-cell %q is not raw.jsonl:gateway-record.jsonl", c)
		}
		fc, err := loadFitCell(raw, record)
		if err != nil {
			return err
		}
		// Each registered block once: the same evidence passed three times, under one path or several, would fit R
		// on one trace and print it as holding on all three (review of 1f2522e).
		if seen[fc.block] {
			return fmt.Errorf("%s is block %s again; the fit needs stage A's three P blocks, each once", raw, fc.block)
		}
		seen[fc.block] = true
		fit = append(fit, fc)
	}
	for b := 1; b <= pilotFitBlocks; b++ {
		if want := fmt.Sprintf("pp-A-prospective-%d", b); !seen[want] {
			return fmt.Errorf("no -cell is block %s; the fit is registered on stage A's P blocks 1 to %d", want, pilotFitBlocks)
		}
	}

	best := 0
	for r := 1; r <= pilotFitMaxRate; r++ {
		ok := true
		for i := range fit {
			if !withinMargin(simulateStaticAdmitted(fit[i].contenders, float64(r)), fit[i].admittedP, fit[i].offeredExct) {
				ok = false
				break
			}
		}
		if ok {
			best = r
		}
	}
	for _, c := range fit {
		line := fmt.Sprintf("%s: contenders=%d a_P=%.4f", c.name, len(c.contenders), c.aP)
		if best > 0 {
			line += fmt.Sprintf(" a_S(R=%d)=%.4f", best, simulateStatic(c.contenders, float64(best)))
		}
		_, _ = fmt.Fprintln(stdout, line)
	}
	if best == 0 {
		return fmt.Errorf("no R in 1..%d gives a_S <= a_P - 1/%d on every block; the outcome is \"stage B not acquired; R unavailable\"",
			pilotFitMaxRate, pilotFitMarginParts)
	}
	_, _ = fmt.Fprintf(stdout, "R=%d\n", best)
	return nil
}

// withinMargin reports a_S <= a_P - 0.05 in integers: 20 a_S_tokens <= 20 a_P_tokens - offered. In floating point
// the boundary itself fails, since 0.7 - 0.05 is slightly below 0.65, and rejects a valid R (review of 1f2522e).
func withinMargin(admittedS, admittedP, offered int64) bool {
	return pilotFitMarginParts*admittedS <= pilotFitMarginParts*admittedP-offered
}

// simulateStatic returns the fraction of the contenders' exact tokens a fresh static bucket at rate r admits.
func simulateStatic(cs []fitContender, r float64) float64 {
	var offered int64
	for _, c := range cs {
		offered += int64(c.exact)
	}
	return float64(simulateStaticAdmitted(cs, r)) / float64(offered)
}

// simulateStaticAdmitted returns the exact tokens a fresh static bucket at rate r admits, driven by the contenders'
// recorded arrival instants.
func simulateStaticAdmitted(cs []fitContender, r float64) int64 {
	var at time.Time
	adm := gateway.NewStaticCapAdmitterAtClock(r, pilotStaticBurst, pilotStaticThreshold, func() time.Time { return at })
	backend := &gateway.BackendRef{Namespace: "sim", Name: "engine", Port: 8000, URL: &url.URL{Scheme: "http", Host: "sim"}}
	var admitted int64
	for _, c := range cs {
		at = time.Unix(0, c.arrived)
		if ok, _ := adm.Admit(context.Background(), gateway.RequestMeta{Model: "sim", EstInputTokens: c.est}, backend, "", "standard"); ok {
			admitted += int64(c.exact)
		}
	}
	return admitted
}

// loadFitCell joins a P cell's contender rows to its gateway record.
func loadFitCell(rawPath, recordPath string) (fitCell, error) {
	fc := fitCell{name: rawPath}
	type gw struct {
		Ev               string `json:"ev"`
		RequestID        string `json:"requestId"`
		Decision         string `json:"decision"`
		ArrivedUnixNanos int64  `json:"arrivedUnixNanos"`
	}
	dones := map[string]gw{}
	dup := 0
	if err := eachJSONLine(recordPath, func(b []byte) error {
		var g gw
		if err := json.Unmarshal(b, &g); err != nil {
			return err
		}
		if g.Ev != "done" {
			return nil
		}
		if _, seen := dones[g.RequestID]; seen {
			dup++
		}
		dones[g.RequestID] = g
		return nil
	}); err != nil {
		return fc, fmt.Errorf("read the gateway record %s: %w", recordPath, err)
	}
	if dup > 0 {
		return fc, fmt.Errorf("%s holds %d request ID(s) with more than one done line, so a contender's decision is ambiguous", recordPath, dup)
	}
	var missing, undecided []string
	if err := eachJSONLine(rawPath, func(b []byte) error {
		var row bench.RawRow
		if err := json.Unmarshal(b, &row); err != nil {
			return err
		}
		if row.Tenant == pilotPremiumTenant {
			return nil
		}
		if row.RequestID == "" || row.PromptLenChars <= 0 || row.ExactInputTokens <= 0 {
			return fmt.Errorf("contender row %d lacks its request ID, prompt length or exact token count", row.Index)
		}
		g, ok := dones[row.RequestID]
		switch {
		case !ok:
			missing = append(missing, row.RequestID)
			return nil
		case g.ArrivedUnixNanos <= 0 || (g.Decision != "admit" && g.Decision != "reject"):
			undecided = append(undecided, row.RequestID)
			return nil
		}
		block := row.RequestID[:strings.LastIndex(row.RequestID, "-")]
		if fc.block == "" {
			fc.block = block
		} else if block != fc.block {
			return fmt.Errorf("its contenders come from two blocks, %s and %s", fc.block, block)
		}
		fc.contenders = append(fc.contenders, fitContender{id: row.RequestID, arrived: g.ArrivedUnixNanos,
			est: bench.EstInputTokensForChars(row.PromptLenChars), exact: row.ExactInputTokens, admitted: g.Decision == "admit"})
		return nil
	}); err != nil {
		return fc, fmt.Errorf("read the client rows %s: %w", rawPath, err)
	}
	if len(missing) > 0 || len(undecided) > 0 {
		return fc, fmt.Errorf("%s: %d contender(s) have no gateway record and %d no recorded arrival and decision (e.g. %s), so P's admissions are unidentifiable and R cannot be fitted",
			rawPath, len(missing), len(undecided), firstOf(append(missing, undecided...)))
	}
	if len(fc.contenders) == 0 {
		return fc, fmt.Errorf("%s holds no contender rows, so there is nothing to fit R on", rawPath)
	}
	sort.SliceStable(fc.contenders, func(i, j int) bool {
		if fc.contenders[i].arrived != fc.contenders[j].arrived {
			return fc.contenders[i].arrived < fc.contenders[j].arrived
		}
		return fc.contenders[i].id < fc.contenders[j].id
	})
	for _, c := range fc.contenders {
		fc.offeredExct += int64(c.exact)
		if c.admitted {
			fc.admittedP += int64(c.exact)
		}
	}
	fc.aP = float64(fc.admittedP) / float64(fc.offeredExct)
	return fc, nil
}

func firstOf(s []string) string {
	if len(s) == 0 {
		return ""
	}
	return s[0]
}

// eachJSONLine calls fn with every non-empty line of path.
func eachJSONLine(path string, fn func([]byte) error) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close() //nolint:errcheck // read-only
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		if len(sc.Bytes()) == 0 {
			continue
		}
		if err := fn(sc.Bytes()); err != nil {
			return err
		}
	}
	return sc.Err()
}
