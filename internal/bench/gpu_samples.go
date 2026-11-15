package bench

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
	"time"
)

// The version study's GPU diagnostic: temperature and clocks sampled every 5 s and reported, never controlled
// (docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md, cache policy).
// A treatment that ran on a hotter or throttled card would show it here, beside a verdict the samples do not enter.

// GPUSampleInterval is the registered sampling period.
const GPUSampleInterval = 5 * time.Second

// GPUSampleArgs is the nvidia-smi command line the session runs for the whole campaign, written as one CSV row per sample.
var GPUSampleArgs = []string{
	"--query-gpu=timestamp,temperature.gpu,clocks.sm,clocks.mem,power.draw",
	"--format=csv,noheader,nounits",
	fmt.Sprintf("--loop-ms=%d", GPUSampleInterval.Milliseconds()),
}

// gpuTimestampLayout is nvidia-smi's timestamp, in the instance's local time, which the session sets to UTC.
const gpuTimestampLayout = "2006/01/02 15:04:05.000"

// GPUSample is one nvidia-smi reading.
type GPUSample struct {
	At           time.Time
	TemperatureC float64
	SMClockMHz   float64
	MemClockMHz  float64
	// PowerW is NaN when the card reported "[N/A]", which some drivers do for power alone.
	PowerW float64
}

// ParseGPUSamples reads GPUSampleArgs' output, refusing a row it cannot read rather than skipping it.
//
// A skipped row would look like a quiet card; a refused file says the diagnostic is missing, which is the truth.
func ParseGPUSamples(r io.Reader) ([]GPUSample, error) {
	var out []GPUSample
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		f := strings.Split(line, ",")
		if len(f) != 5 {
			return nil, fmt.Errorf("gpu sample line %d has %d fields, want 5: %q", n, len(f), line)
		}
		for i := range f {
			f[i] = strings.TrimSpace(f[i])
		}
		at, err := time.ParseInLocation(gpuTimestampLayout, f[0], time.UTC)
		if err != nil {
			return nil, fmt.Errorf("gpu sample line %d: %w", n, err)
		}
		s := GPUSample{At: at}
		for i, dst := range []*float64{&s.TemperatureC, &s.SMClockMHz, &s.MemClockMHz} {
			v, err := strconv.ParseFloat(f[i+1], 64)
			if err != nil {
				return nil, fmt.Errorf("gpu sample line %d field %d: %w", n, i+2, err)
			}
			*dst = v
		}
		s.PowerW = math.NaN()
		if f[4] != "[N/A]" {
			v, err := strconv.ParseFloat(f[4], 64)
			if err != nil {
				return nil, fmt.Errorf("gpu sample line %d power: %w", n, err)
			}
			s.PowerW = v
		}
		if len(out) > 0 && !s.At.After(out[len(out)-1].At) {
			return nil, fmt.Errorf("gpu sample line %d at %s does not follow the previous sample", n, s.At.Format(time.RFC3339Nano))
		}
		out = append(out, s)
	}
	return out, sc.Err()
}

// GPUWindow summarizes the samples inside one cell's span.
type GPUWindow struct {
	Samples                      int
	MinTemperatureC, MaxTempC    float64
	MinSMClockMHz, MaxSMClockMHz float64
	// LongestGapSeconds is the longest stretch of the span with no sample, its edges included; above twice the interval the
	// diagnostic did not cover the cell, and the report says so rather than interpolating.
	LongestGapSeconds float64
	Covered           bool
}

// SummarizeGPUWindow reports the samples between from and to, or an error when there is no span to report.
func SummarizeGPUWindow(samples []GPUSample, from, to time.Time) (GPUWindow, error) {
	if !to.After(from) {
		return GPUWindow{}, errors.New("the window does not end after it starts")
	}
	w := GPUWindow{
		MinTemperatureC: math.Inf(1), MaxTempC: math.Inf(-1),
		MinSMClockMHz: math.Inf(1), MaxSMClockMHz: math.Inf(-1),
	}
	prev := from
	for _, s := range samples {
		if s.At.Before(from) || s.At.After(to) {
			continue
		}
		w.Samples++
		w.MinTemperatureC = math.Min(w.MinTemperatureC, s.TemperatureC)
		w.MaxTempC = math.Max(w.MaxTempC, s.TemperatureC)
		w.MinSMClockMHz = math.Min(w.MinSMClockMHz, s.SMClockMHz)
		w.MaxSMClockMHz = math.Max(w.MaxSMClockMHz, s.SMClockMHz)
		w.LongestGapSeconds = math.Max(w.LongestGapSeconds, s.At.Sub(prev).Seconds())
		prev = s.At
	}
	w.LongestGapSeconds = math.Max(w.LongestGapSeconds, to.Sub(prev).Seconds())
	w.Covered = w.Samples > 0 && w.LongestGapSeconds <= 2*GPUSampleInterval.Seconds()
	return w, nil
}
