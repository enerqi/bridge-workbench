package bidding

/*
	tags.odin — each named scenario's SYSTEM and GROUPS: whose meanings it uses, and which sets it is in.

	WHY THIS IS A SEPARATE TABLE rather than a fourth field on `cli.Scenario`. Two reasons, one
	mechanical and one about ownership:

	  * Odin has no partial positional literal — `Foo{a, b}` against a four-field struct is an error,
	    not a default — so a field on `cli.Scenario` rewrites all 110 literals in `scenarios.odin`
	    for a property that is not the scenario's definition. (Measured, not assumed: the compiler
	    says "Too few values in structure literal, expected 4, got 3".)
	  * WHICH GROUPS EXIST IS THIS SYSTEM'S EDITORIAL JUDGEMENT, not the framework's. `norn:cli` knows
	    what a scenario IS; that "1c-strong-2s" belongs with the swedish-club machinery is a claim about
	    this repository's bidding system. The same argument that keeps `suit_book` out of norn.

	THE COST of a table keyed by NAME is drift: a renamed scenario silently loses its tags, and a typo
	tags nothing. `test_every_scenario_is_tagged` is what pays it — every tagging must name a real
	scenario AND every scenario must be tagged, so adding one to `registry` fails the build until it has
	been classified. That is the point: the classification is a decision somebody makes, not a default.

	TWO QUESTIONS, and since 2026-11-05 they are two different fields:

	  * WHOSE SYSTEM IS THIS - `system`, one value or none. None ("") is a scenario that never commits to a
	    meaning of anyone's: hand types, partnership totals, the opponents' auctions. Those are shown
	    whichever system the list is set to. `swedish-club` is this repository's system, and covers the
	    1NT, 2NT, 1M and weak-two auctions every system has as well as its own machinery - their MEANINGS
	    are this system's (1NT 16-18, 1M 11-15, 2NT 19-20), so an Acol or 2/1 player picking them would get
	    ours. It was the tags `any-system` / `swedish-club` until then, but a scenario belongs to exactly
	    one system, and a choice of system is made once, like a profile, rather than mixed with topics. See
	    TODO-scenario-create-select-filter.md, "scenarios belong to a SYSTEM".
	  * WHAT IS IT ABOUT - the tags: `competitive`, `preempt`, `slam`. Cross-cutting, so a scenario carries
	    none or several, and `opp-3-level-preempt` is honestly all three.

	SELECTED TAGS COMBINE WITH *OR*, and the text filter narrows what they leave (see `visible_scenarios`
	in `workbench.odin`). Tags widen, typing narrows. `competitive` AND `slam` as an intersection would be
	a near-empty list nobody asked for; picking two groups means wanting to see both.
*/

// A bidding system a scenario can belong to. `badge` is what a list row shows when the list is not set to
// this system; `description` is what the system picker shows beside the name.
System :: struct {
	name:        string,
	badge:       string,
	description: string,
}

// The compiled scenarios' systems. Only one so far: the point of the field is that a second one - written
// as `.scenario` files with a `system:` line - can sit beside it without its rows mixing with these.
systems := []System {
	{"swedish-club", "WSC", "the Swedish Club played here: 1NT 16-18, a 1M of 11-15, 2C a club one-suiter"},
}

// The topics, in the order the picker lists them. The description is what the picker shows beside the
// name - a group nobody can identify is a group nobody selects.
Tag :: struct {
	name:        string,
	description: string,
}

tags := []Tag {
	{"competitive", "both sides bidding"},
	{"preempt", "preempts, and bidding over them"},
	{"slam", "the slam zone"},
}

// One scenario's system and groups. `scenario` is the name in `registry`, which is the key the tables share;
// `system` is "" for a scenario of no system's.
Scenario_Tags :: struct {
	scenario: string,
	system:   string,
	tags:     []string,
}

// Every scenario in `registry`, classified. Ordered as the registry is, so the two read side by side.
taggings := []Scenario_Tags {
	{"1c", "swedish-club", {}},
	{"1c-1n", "swedish-club", {}},
	{"1c-1n_unbal", "swedish-club", {}},
	{"1c-2cd", "swedish-club", {}},
	{"1c-2h-or-2n", "swedish-club", {}},
	{"1c-2h_candidates", "swedish-club", {}},
	{"1c-2s", "swedish-club", {}},
	{"1c-3n-plus", "swedish-club", {}},
	{"1c-3x", "swedish-club", {}},
	{"1c-opp-preempt", "swedish-club", {"competitive", "preempt"}},
	{"1c-opp-preempt-7", "swedish-club", {"competitive", "preempt"}},
	{"1c-strong", "swedish-club", {}},
	{"1c-19plus-or-4441", "swedish-club", {}},
	{"1c-19plus-unbal", "swedish-club", {}},
	{"1c-19plus-two-suiter", "swedish-club", {}},
	{"1c-21plus-unbal", "swedish-club", {}},
	{"1c-strong-opp-overcall", "swedish-club", {"competitive"}},
	{"1c-strong-opp-preempt", "swedish-club", {"competitive", "preempt"}},
	{"1c-18plus-minor_positive", "swedish-club", {}},
	{"1c-strong-1d", "swedish-club", {}},
	{"1c-strong-1d_major-fit", "swedish-club", {}},
	{"1c-strong-1n", "swedish-club", {}},
	{"1c-strong-1n_unbal", "swedish-club", {}},
	{"1c-strong_minor-positive", "swedish-club", {}},
	{"1c-strong-2cd", "swedish-club", {}},
	{"1c-20plus-2cd", "swedish-club", {}},
	{"1c-strong-2h-or-2n", "swedish-club", {}},
	{"1c-strong-2s", "swedish-club", {}},
	{"1c-strong-1n_bal-12plus", "swedish-club", {}},
	{"1c-strong-1n_bal-14plus", "swedish-club", {}},
	{"1c-strong-1hs_major-fit", "swedish-club", {}},
	{"1c-strong-1hs_major-fit-unbal", "swedish-club", {}},
	{"1d-unbal", "swedish-club", {}},
	{"1d-unbal_two-suiter-gf", "swedish-club", {}},
	{"1d-unbal_two-suiter-slam-try", "swedish-club", {"slam"}},
	{"1d_invite-or-inverted", "swedish-club", {}},
	{"1d-jump", "swedish-club", {"preempt"}},
	{"1d_weak-no-major", "swedish-club", {}},
	{"1d-opp-1x_major-fit", "swedish-club", {"competitive"}},
	{"1d-opp-1x_6-card-major", "swedish-club", {"competitive"}},
	{"1cd-opp-1s", "swedish-club", {"competitive"}},
	{"1cd-opp-overcall", "swedish-club", {"competitive"}},
	{"1hs", "swedish-club", {}},
	{"1hs-light", "swedish-club", {}},
	{"1hs_invite", "swedish-club", {}},
	{"1hs_game-force", "swedish-club", {}},
	{"1hs_game-force-3-support", "swedish-club", {}},
	{"1hs_10plus-4-support", "swedish-club", {}},
	{"1hs_splinter", "swedish-club", {}},
	{"1hs_mini-splinter-or-invite", "swedish-club", {}},
	{"1hs_slam-try", "swedish-club", {"slam"}},
	{"1hs-1n_opener-14plus-six", "swedish-club", {}},
	{"1n", "swedish-club", {}},
	{"1n_slam-try", "swedish-club", {"slam"}},
	{"1n_two-suiter", "swedish-club", {}},
	{"1n_unbal", "swedish-club", {}},
	{"2c", "swedish-club", {}},
	{"2c_slam-try", "swedish-club", {"slam"}},
	{"2c_two-suiter-slam-try", "swedish-club", {"slam"}},
	{"2c_unbal", "swedish-club", {}},
	{"2c_positive-9-major-cards", "swedish-club", {}},
	{"2c_positive-two-suiter", "swedish-club", {}},
	{"2c_positive-unbal", "swedish-club", {}},
	{"2c_unbal-slam-try", "swedish-club", {"slam"}},
	{"2d-precision", "swedish-club", {}},
	{"2d-precision_10plus", "swedish-club", {}},
	{"2d-precision_18plus", "swedish-club", {}},
	{"2d-intermediate", "swedish-club", {}},
	{"2d-intermediate_below-invite", "swedish-club", {}},
	{"2d-intermediate-side-major", "swedish-club", {}},
	{"2d-intermediate_16plus", "swedish-club", {}},
	{"2d-intermediate_good-suit-gf", "swedish-club", {}},
	{"2d-intermediate_two-suiter-gf", "swedish-club", {}},
	{"2d-intermediate_unbal-slam-try", "swedish-club", {"slam"}},
	{"2hs-weak", "swedish-club", {"preempt"}},
	{"2hs-weak-5", "swedish-club", {"preempt"}},
	{"2hs-weak-5-or-6", "swedish-club", {"preempt"}},
	{"2hs-weak_12plus", "swedish-club", {"preempt"}},
	{"2hs-weak_20plus", "swedish-club", {"preempt"}},
	{"2hs-weak_16plus-unbal", "swedish-club", {"preempt"}},
	{"2n", "swedish-club", {}},
	{"2n_slam-try", "swedish-club", {"slam"}},
	{"2n_two-suiter", "swedish-club", {}},
	{"2n_unbal", "swedish-club", {}},
	{"3n-gambling", "swedish-club", {"preempt"}},
	{"weak-7-card-suit", "", {"preempt"}},
	{"weak-7-tricks", "", {"preempt"}},
	{"4n", "swedish-club", {}},
	{"weak-8-tricks-7-minor", "", {"preempt"}},
	{"weak-8-tricks", "", {"preempt"}},
	{"8-playing-tricks", "", {"preempt"}},
	{"ns-32plus-opc", "", {"slam"}},
	{"ns-32plus-hcp", "", {"slam"}},
	{"ns-35plus-hcp", "", {"slam"}},
	{"both-balanced", "", {}},
	{"2c-or-2d-or-1d_not-bal-11-13", "swedish-club", {}},
	{"opp-3s-or-4s", "", {"competitive", "preempt"}},
	{"opp-3-level-preempt", "", {"competitive", "preempt"}},
	{"opp-any-preempt", "", {"competitive", "preempt"}},
	{"opp-1n-10-12", "", {"competitive"}},
	{"opp-1n-12-14", "", {"competitive"}},
	{"opp-1n-12-14_partner-invite", "", {"competitive"}},
	{"opp-1n-14-16", "", {"competitive"}},
	{"opp-1n-15-17", "", {"competitive"}},
	{"opp-1cd-prepared", "", {"competitive"}},
	{"opp-1cd-prepared_majors", "", {"competitive"}},
	{"opp-1c-strong-or-1n-17-19", "", {"competitive"}},
	{"opp-1x-unbal", "", {"competitive"}},
	{"opp-1x-unbal_two-suiter", "", {"competitive"}},
	{"opp-1x-unbal_two-suiter-11-15", "", {"competitive"}},
}

// The system a scenario belongs to, "" for none (or if it is not in the table).
system_for :: proc(scenario: string) -> string {
	for tagging in taggings {
		if tagging.scenario == scenario {
			return tagging.system
		}
	}
	return ""
}

// The groups a scenario belongs to, or nothing if it is not in the table. A linear scan, like
// `cli.lookup`: 110 entries answered per row per redraw is tens of microseconds, and an index would be a
// second structure to keep in step for no measurable gain.
tags_for :: proc(scenario: string) -> []string {
	for tagging in taggings {
		if tagging.scenario == scenario {
			return tagging.tags
		}
	}
	return nil
}

// Does this scenario carry any of `wanted`? The OR in "tags widen": an empty `wanted` is not a filter at
// all and admits everything, which is what makes "no group selected" mean "all of them" rather than none.
has_any_tag :: proc(scenario: string, wanted: []string) -> bool {
	if len(wanted) == 0 {
		return true
	}
	carried := tags_for(scenario)
	for want in wanted {
		for tag in carried {
			if tag == want {
				return true
			}
		}
	}
	return false
}
