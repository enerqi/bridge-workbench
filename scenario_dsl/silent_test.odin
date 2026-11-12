#+build !js
package scenario_dsl

import "core:strings"
import "core:testing"
import "norn:norn"

@(private = "file")
parse_silent_one :: proc(t: ^testing.T, source: string) -> (program: Program, ok: bool) {
	programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
	for diagnostic in diagnostics {
		testing.expectf(t, false, "unexpected diagnostic: %s", diagnostic_text(diagnostic, context.temp_allocator))
	}
	if len(programs) != 1 {
		return {}, false
	}
	return programs[0], true
}

// A hand from PBN's dotted form, spades first: `KJ832.32.Q43.K32`.
@(private = "file")
hand_of :: proc(text: string) -> (hand: norn.Hand_Summary) {
	for group, i in strings.split(text, ".", context.temp_allocator) {
		if group != "-" {
			hand.suits[SUITS_SPADES_FIRST[i]], _ = ranks_of(group)
		}
	}
	return
}

/*
THE LADDER, HAND BY HAND (`LEAD_PROBLEM_PLAN.md`, "The ladder's numbers"): each settled threshold on both sides of
its line, plus the rules round it - length in their suit never counts against the hand, a doubleton is fine for a
takeout double, over notrump a double is for penalty.
*/
@(test)
test_silent_is_the_ladder :: proc(t: ^testing.T) {
	over_hearts := Silent_Node{level = 1, over = {.Hearts}}
	cases := []struct {
		hand:   string,
		node:   Silent_Node,
		acts:   bool,
		reason: string,
	} {
		{"KJ832.32.Q43.K32", over_hearts, true, "a 5-card major, 2 honours, 9 hcp: overcalls"},
		{"K9832.32.Q43.K32", over_hearts, false, "one honour and 8 hcp: may pass"},
		{"KT832.32.Q43.K32", over_hearts, false, "the ten is no honour"},
		{"32.KJ832.Q43.K32", Silent_Node{level = 1, over = {.Spades}}, true, "hearts the same over spades"},
		{"32.32.KJ832.AQ32", over_hearts, true, "a minor needs 10 hcp, and has 10"},
		{"32.32.KJ832.Q432", over_hearts, false, "a minor with 6 hcp: may pass"},
		{"KQJ432.2.432.32", over_hearts, true, "the weak jump: 6 cards, 2 of the top 3"},
		{"Q98432.2.432.32", over_hearts, false, "six to the queen, 2 hcp"},
		{"2.32.KQ432.QJ432", over_hearts, true, "5-5 in the minors, 8 hcp: the unusual notrump"},
		{"KJ32.Q2.A432.K32", over_hearts, true, "takeout with a doubleton in their suit"},
		{"KJ3.Q32.A432.K32", over_hearts, false, "three of their suit, 13 balanced: may pass"},
		{"32.AKJ32.KQ2.432", over_hearts, false, "the trap pass: length in their suit"},
		{"AKQ.K432.K32.Q32", over_hearts, true, "16+ any shape"},
		{"AQ32.K32.KQ3.Q32", Silent_Node{level = 2, notrump = true}, true, "16 over 1NT: the penalty double"},
		{"AQ32.K32.QJ3.Q32", Silent_Node{level = 2, notrump = true}, false, "14 over 1NT: may pass"},
		{"KJ832.32.Q43.K32", Silent_Node{level = 2, over = {.Hearts}}, false, "the good major at the two level needs more"},
		{"KQ8432.32.Q43.K2", Silent_Node{level = 2, over = {.Hearts}}, true, "six cards, 10 hcp at the two level"},
		{"KQ8432.32.Q43.K2", Silent_Node{level = 3, over = {.Hearts}}, false, "but not at the three level"},
	}
	for c in cases {
		testing.expectf(t, would_act(hand_of(c.hand), c.node) == c.acts, "%s: %s", c.hand, c.reason)
	}
}

// `silent(...)` is a seat line's condition like any other: parsed, judged against the deal, written back as typed.
@(test)
test_silent_reads_and_writes :: proc(t: ^testing.T) {
	cases := []struct {
		written: string,
		node:    Silent_Node,
	} {
		{"silent(1, hearts)", {level = 1, over = {.Hearts}}},
		{"silent(1, clubs, hearts)", {level = 1, over = {.Clubs, .Hearts}}},
		{"silent(2, notrump)", {level = 2, notrump = true}},
	}
	for c in cases {
		source := strings.concatenate({"scenario p\n  east: ", c.written, " and hcp >= 6\n"}, context.temp_allocator)
		program, ok := parse_silent_one(t, source)
		if !ok {continue}
		defer destroy_program(&program)
		testing.expect_value(t, write_program(&program, context.temp_allocator), source)
		found := false
		for node in program.nodes {
			if silent, is_silent := node.(Silent_Node); is_silent {
				found = true
				testing.expect_value(t, silent, c.node)
			}
		}
		testing.expectf(t, found, "%s: a silent node", c.written)
	}

	// Judged on the deal: north's hand on `north: silent(1, hearts)` is the ladder's verdict.
	program, ok := parse_silent_one(t, "scenario p\n  north: silent(1, hearts)\n")
	if !ok {return}
	defer destroy_program(&program)
	for text in ([]string{"KJ832.32.Q43.K32", "K9832.32.Q43.K32"}) {
		summary: norn.Deal_Summary
		summary[.North] = hand_of(text)
		testing.expectf(t, evaluate(summary, {}, &program) == !would_act(summary[.North], {level = 1, over = {.Hearts}}), "%s", text)
	}
}

@(test)
test_a_bad_silent_is_reported :: proc(t: ^testing.T) {
	cases := []struct {
		line: string,
		says: string,
	} {
		{"north: silent", "takes the level"},
		{"north: silent(4, hearts)", "expected the level first"},
		{"north: silent(1)", "takes the level"},
		{"north: silent(1, trumps)", "expected a suit"},
		{"north: silent(1, notrump, hearts)", "not both"},
		{"north-south: silent(1, hearts)", "describes one hand"},
	}
	for c in cases {
		programs, diagnostics := parse(
			strings.concatenate({"scenario s\n  ", c.line, "\n"}, context.temp_allocator),
			"s.scenario",
			context.temp_allocator,
		)
		testing.expectf(t, len(programs) == 0 && len(diagnostics) >= 1, "%q: %d programs, %v", c.line, len(programs), diagnostics[:])
		if len(diagnostics) > 0 {
			testing.expectf(t, strings.contains(diagnostics[0].message, c.says), "%q: %s", c.line, diagnostics[0].message)
		}
	}
}
