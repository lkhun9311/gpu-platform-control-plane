package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// senderConfig is the replay's resolved sending configuration, written beside its raw rows.
//
// The pilot compares it across a block's arms and refuses a difference (design page, build item 26). An
// arm-dependent sender setting would otherwise pass into the measured dispatch lag, and from there into the
// thresholds the pilot's formulas set. The arm label, the request-ID prefix and the paths are expected to
// differ, and the analysis normalises them; everything else must match.
type senderConfig struct {
	Study               string         `json:"study"`
	Arm                 string         `json:"arm"`
	ConnMode            string         `json:"connMode"`
	MaxIdleConnsPerHost int            `json:"maxIdleConnsPerHost"`
	DrainForReuse       bool           `json:"drainForReuse"`
	TimeoutMs           int            `json:"timeoutMs"`
	Model               string         `json:"model"`
	Target              string         `json:"target"`
	Priorities          map[string]int `json:"priorities"`
	RequestIDPrefix     string         `json:"requestIdPrefix"`
	// BinarySHA256 is the hash of the running harness, so two arms run by different builds are told apart.
	BinarySHA256 string `json:"binarySha256"`
}

// writeSenderConfig writes c to path, filling in the running binary's hash.
func writeSenderConfig(path string, c senderConfig) error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate the running harness to hash it: %w", err)
	}
	f, err := os.Open(exe)
	if err != nil {
		return fmt.Errorf("open the running harness to hash it: %w", err)
	}
	h := sha256.New()
	_, err = io.Copy(h, f)
	_ = f.Close()
	if err != nil {
		return fmt.Errorf("hash the running harness: %w", err)
	}
	c.BinarySHA256 = hex.EncodeToString(h.Sum(nil))
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
		return fmt.Errorf("write sender configuration %s: %w", path, err)
	}
	return nil
}
