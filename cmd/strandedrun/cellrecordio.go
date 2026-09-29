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
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// LoadCellRecord reads one recorded attempt, refusing a file whose keys this build does not know.
//
// DisallowUnknownFields, for the reason the protocol reader learned: a mistyped key under the lenient decoder
// is dropped and the field keeps its zero value. One transposed letter in `invalidated_because` would produce a
// record that reads as a cell which STANDS -- the zero value of that field is "valid" -- so the typo would
// silently promote a discarded attempt into the comparison. That is the worst direction for this field to fail
// in, which is why the refusal lives here rather than in a reviewer's attention.
//
// This comment originally spelled the mistyped key out as an example and `misspell` failed the build on it. A
// gate firing on an illustration rather than on a defect is worth knowing about: the example was reworded, and
// nothing about the code changed.
func LoadCellRecord(path string) (CellRecord, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return CellRecord{}, fmt.Errorf("could not read the cell record at %s: %w; a campaign may not count an "+
			"attempt nobody read", path, err)
	}
	var r CellRecord
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return CellRecord{}, fmt.Errorf("the cell record at %s does not parse: %w; a key this build does not "+
			"know is refused rather than dropped, because the zero value of invalidated_because is \"this cell "+
			"stands\" and a typo there would promote a discarded attempt into the comparison", path, err)
	}
	// One JSON document per file. A second document after the first would be read by nothing and would look
	// like a record that had been written twice, with only the first taking effect.
	if dec.More() {
		return CellRecord{}, fmt.Errorf("the cell record at %s holds more than one JSON document; only the "+
			"first would be judged and the rest would be evidence nothing read", path)
	}
	return r, nil
}

// LoadCellRecords reads every attempt in a directory, in a stable order, and returns their paths beside them.
//
// Every .json file is read and none is skipped. The protocol publishes every attempt including the invalid
// ones, so a loader that quietly ignored a file it could not parse would be deciding which attempts the
// campaign remembers -- and the campaign's whole defence against retaking on the outcome is that it remembers
// all of them.
func LoadCellRecords(dir string) ([]CellRecord, []string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, fmt.Errorf("could not read the records directory %s: %w", dir, err)
	}
	var paths []string
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		paths = append(paths, filepath.Join(dir, e.Name()))
	}
	if len(paths) == 0 {
		return nil, nil, fmt.Errorf("%s holds no .json cell records; an empty directory is not a campaign, and "+
			"reading it as one would report a comparison from nothing", dir)
	}
	// Sorted by name so a verdict naming "attempt 3 of 6" means the same thing on every machine. Directory
	// order is not specified, and a campaign whose refusal moves between runs cannot be acted on.
	sort.Strings(paths)

	records := make([]CellRecord, 0, len(paths))
	for _, p := range paths {
		r, rErr := LoadCellRecord(p)
		if rErr != nil {
			return nil, nil, rErr
		}
		records = append(records, r)
	}
	return records, paths, nil
}
