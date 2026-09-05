package bench

import (
	"fmt"
	"slices"
)

// A Study is one pre-registered experiment: the arms it admits, and the order a report prints them in.
//
// Arm names used to live in one closed map shared by every experiment this repository runs, which was
// fine while there was one experiment. It stops being fine the moment a second one wants a name the
// first already used. M5-b's "off" was the gateway with its admission guard disabled. The
// price-of-protection run's control is the engine at its own default batch budget with no gateway in
// the path at all. Those are different conditions that would produce comparable-looking rows, and the
// pre-registration's own wording invites the confusion by calling the new control "off" as well.
//
// So an arm belongs to a study, the study travels with the evidence, and a report refuses to pool rows
// from two of them. Guarding by name would only work until someone picked a name that collided.
type Study struct {
	// ID is the immutable identifier raw evidence carries.
	//
	// Changing it orphans every record already written, so it is dated rather than versioned by
	// meaning: a study that needs different arms is a different study.
	ID string
	// Arms are the canonical arm names, in the order a report prints them.
	//
	// Order is a property of the study rather than of the names. The price-of-protection sweep wants
	// its isolated ceiling and its control first and its eight cells after, which no sort of those
	// strings produces.
	Arms []string
}

const (
	// StudyM5BGateway is the four-condition gateway experiment M5-b measured: an isolated baseline, the
	// guard disabled, a static admission cap, and the KV-occupancy guard.
	//
	// Evidence written before studies existed carries no identifier at all, and is read as this one.
	StudyM5BGateway = "m5b-gateway-v1"
	// StudyPriceOfProtection is the engine-configuration sweep pre-registered in
	// docs/superpowers/specs/2026-09-05-the-price-of-protection.md.
	//
	// No gateway is in the path. The factors are vLLM's batch budget and its scheduling policy.
	StudyPriceOfProtection = "price-of-protection-2026-09-05"
)

// The factors the price-of-protection sweep crosses.
//
// 8192 is absent deliberately: the scheduler microtest measured both policies degenerating there
// (11.83x), and 256 is present because the pattern between 512 and 2048 is non-monotone and
// unexplained, so a point below the only budget that worked is worth more than a fourth point above.
var (
	priceOfProtectionBudgets  = []int{256, 512, 1024, 2048}
	priceOfProtectionPolicies = []string{"fcfs", "priority"}
)

// PremiumTenant is the tenant whose tail every pre-registered criterion is about.
//
// Named once because a literal spelled at each use is the copy that eventually differs by a hyphen, and
// this repository has already paid twice for hand-kept copies of a tenant list drifting apart.
const PremiumTenant = "premium-1"

// ArmR1 is the isolated premium baseline every study measures as its ceiling.
//
// It replays the same trace with the contending tenant filtered out, so its record count legitimately
// differs from every other arm's and identity checks have to exclude it.
const ArmR1 = "R1"

// ArmDefaultFCFS is the price-of-protection control: the engine at its own default batch budget under
// first-come-first-served, which is what an operator who configures nothing gets.
//
// It is NOT named "off" even though the pre-registration's readings use that word for it. M5-b's "off"
// arm ran through a gateway, and giving the two the same name would make raw evidence from a
// no-gateway run indistinguishable from evidence that crossed a proxy hop.
const ArmDefaultFCFS = "default-fcfs"

// priceOfProtectionArms generates the sweep's arm names from the factors rather than listing them.
//
// A hand-written list of ten strings is a fifth copy of the factor definitions, and this repository has
// already paid twice for hand-kept lists drifting apart. The budget is zero-padded so that lexical
// order is numeric order: b256 would sort after b1024 and put the table in an order no reader expects.
func priceOfProtectionArms() []string {
	arms := make([]string, 0, 2+len(priceOfProtectionBudgets)*len(priceOfProtectionPolicies))
	arms = append(arms, ArmR1, ArmDefaultFCFS)
	for _, budget := range priceOfProtectionBudgets {
		for _, policy := range priceOfProtectionPolicies {
			arms = append(arms, PriceOfProtectionArm(budget, policy))
		}
	}
	return arms
}

// PriceOfProtectionArm is the canonical name of one cell of the sweep.
//
// "mbt" is max_num_batched_tokens, spelled short because the name sits in a fixed-width report column
// and spelled consistently because a reader who has to decode two abbreviations for one factor will
// eventually decode one of them wrong.
func PriceOfProtectionArm(budget int, policy string) string {
	return fmt.Sprintf("mbt-%04d-%s", budget, policy)
}

// studies is the registry every arm name is validated against.
var studies = map[string]Study{
	StudyM5BGateway: {
		ID:   StudyM5BGateway,
		Arms: []string{ArmR1, "off", "static-cap", "kv-aware"},
	},
	StudyPriceOfProtection: {
		ID:   StudyPriceOfProtection,
		Arms: priceOfProtectionArms(),
	},
}

// CanonicalStudyID resolves an identifier as recorded to the identifier it means.
//
// Evidence written before the study field existed carries an empty string, and LookupStudy already reads
// that as the gateway experiment. Comparisons have to use the SAME normalization, or a file labelled
// "m5b-gateway-v1" and an unlabelled file from the same experiment are refused as different studies --
// which is what happened, because the pooling check compared the raw strings.
func CanonicalStudyID(id string) string {
	if id == "" {
		return StudyM5BGateway
	}
	return id
}

// LookupStudy returns the study with this ID.
//
// An empty ID is the evidence written before studies existed, and resolves to the M5-b gateway
// experiment, which is the only thing it can be.
func LookupStudy(id string) (Study, bool) {
	if id == "" {
		id = StudyM5BGateway
	}
	s, ok := studies[id]
	return s, ok
}

// KnownStudyIDs lists the registered studies, for a refusal that has to name the alternatives.
func KnownStudyIDs() []string {
	// Listed rather than ranged over the map, because a refusal message whose order changes between
	// runs is a refusal message that cannot be tested.
	return []string{StudyM5BGateway, StudyPriceOfProtection}
}

// Admits reports whether arm is one of this study's conditions.
func (s Study) Admits(arm string) bool {
	return slices.Contains(s.Arms, arm)
}

// ArmColumnWidth is the width of the report's arm column: the longest arm name any study defines.
//
// It was the literal 12, which fitted M5-b's four names and silently misaligned anything longer --
// "mbt-0512-priority" is 17 characters and would have pushed every column after it out of line in the
// one table a reader actually looks at. Derived from the registry so that adding a study cannot break
// the report by a mechanism nobody thinks to check.
var ArmColumnWidth = widestArmName()

func widestArmName() int {
	w := len("arm")
	for _, s := range studies {
		for _, a := range s.Arms {
			if len(a) > w {
				w = len(a)
			}
		}
	}
	return w
}
