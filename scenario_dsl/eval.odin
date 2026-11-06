package scenario_dsl

/*
	eval.odin — walking a parsed `Program` against a deal.

	THIS IS THE PROC THAT NEEDED `userdata`. Odin procs do not capture, so `evaluate` cannot be a
	`norn.Predicate`: it has to be told WHICH program to walk. That is exactly what
	`norn.Interpreted_Predicate` carries — the walker plus its tree — and why `norn.Condition` is a union
	rather than a proc pointer (see `cli/scenario.odin`).

	COST. A seat rule is a handful of nodes and the arena is contiguous, so a walk is a switch over a few
	array elements — nanoseconds against a deal shuffle plus a summarise. The plan predicted this would be
	a non-issue and said to measure rather than assume; `--frequency` on an interpreted scenario is the
	measurement, and it is the same number a compiled one reports.

	NO ALLOCATION and NO CONTEXT USE in the hot path: `evaluate` reads the tree and the summary and
	nothing else, which is what makes it safe to hand the same program to every worker thread.
*/

import "norn:norn"

/*
The `norn.Contextual_Predicate` for a program. Pair it with the program itself:

	condition := norn.Interpreted_Predicate{scenario_dsl.evaluate, program}

Seat rules AND together — the compiled registry's `&&` between "North opens" and "South responds", said
in the grammar instead of in Odin.
*/
evaluate :: proc(summary: norn.Deal_Summary, table: norn.Table, userdata: rawptr) -> bool {
	program := (^Program)(userdata)
	if program == nil {
		return false
	}
	for also in 0 ..= len(program.alternatives) {
		if lines_hold(program, summary, table, also, {}) {
			return true
		}
	}
	return false
}

/*
WHICH ALTERNATIVES OF THE MEANINGS COUNT while a line is evaluated: all of them (generating), none (the core
alone), or just one (which one kept this deal?). Only `explain` asks for anything but all.
*/
Meaning_Mode :: struct {
	core_only: bool,
	only:      string, // with `core_only`: this alternative as well
}

/*
WHY a kept deal was kept: "" when the scenario's own lines hold, else the name of the first alternative whose
lines do (norn's `Contextual_Explain`, asked only of kept deals). Alternatives are tried in the order the file
names them, so a deal two of them admit carries the first one's name.
*/
//
// THE MEANINGS' ALTERNATIVES come first: a deal the scenario's own lines keep only through one of them carries
// that alternative's name, the first in `program.meaning_alternatives` that keeps it on its own.
explain :: proc(summary: norn.Deal_Summary, table: norn.Table, userdata: rawptr) -> string {
	program := (^Program)(userdata)
	if program == nil {
		return ""
	}
	if len(program.meaning_alternatives) == 0 {
		if lines_hold(program, summary, table, 0, {}) {
			return ""
		}
	} else {
		if lines_hold(program, summary, table, 0, {core_only = true}) {
			return ""
		}
		if lines_hold(program, summary, table, 0, {}) {
			for name in program.meaning_alternatives {
				if lines_hold(program, summary, table, 0, {core_only = true, only = name}) {
					return name
				}
			}
			return ""
		}
	}
	for name, i in program.alternatives {
		if lines_hold(program, summary, table, i + 1, {}) {
			return name
		}
	}
	return ""
}

// Do the lines of alternative `also` hold (0: the scenario's own)? An alternative's lines REPLACE the scenario's
// lines for the same seat or side, and the scenario's other lines still apply.
@(private)
lines_hold :: proc(program: ^Program, summary: norn.Deal_Summary, table: norn.Table, also: int, mode: Meaning_Mode) -> bool {
	for rule in program.rules {
		if rule.also != also && (rule.also != 0 || replaced_in(program, rule, also)) {
			continue
		}
		// A `deal:` line names its hands in its groups (`Hand_Node`); every other line is one hand or side's.
		at := at_hand(summary, table, rule.seat, rule.pair) if !rule.deal else At{summary = summary, table = table}
		at.mode = mode
		if !eval_node(program, rule.root, &at) {
			return false
		}
	}
	return true
}

// Does alternative `also` have a line for the seat (or side) this line of the scenario's own is about?
@(private)
replaced_in :: proc(program: ^Program, own: Seat_Rule, also: int) -> bool {
	if also == 0 {
		return false
	}
	for rule in program.rules {
		if rule.also == also && rule.deal == own.deal && (own.deal || rule.seat == own.seat && rule.pair == own.pair) {
			return true
		}
	}
	return false
}

// What a line is evaluated against: the hand (or the side's two, combined), whose it is, and the board's table.
// The whole deal too, for a hand's group to pick its hand from (`Hand_Node`), and on a side the two hands apart,
// for the one judgement of a side that is not a sum (`opc`).
@(private)
At :: struct {
	hand:    norn.Hand_Summary,
	seat:    norn.Seat,
	pair:    bool,
	table:   norn.Table,
	summary: norn.Deal_Summary,
	mode:    Meaning_Mode,
}

// The hand a line or group of `seat` reads: that seat's, or with `pair` the side's two as one (see `combined` for
// why that is exact).
@(private)
at_hand :: proc(summary: norn.Deal_Summary, table: norn.Table, seat: norn.Seat, pair: bool) -> At {
	hand := summary[seat]
	if pair {
		hand = combined(hand, summary[partner_of(seat)])
	}
	return At{hand = hand, seat = seat, pair = pair, table = table, summary = summary}
}

// The seat's place in the auction, 1 for the dealer, going round clockwise; 0 at a table with no dealer, which
// only a condition that never asked for a table sees (and then no `seat` word is in it).
seat_position :: proc(seat: norn.Seat, table: norn.Table) -> int {
	dealer, ok := table.dealer.?
	if !ok {
		return 0
	}
	return (int(seat) - int(dealer) + len(norn.Seat)) %% len(norn.Seat) + 1
}

@(private)
vulnerability_holds :: proc(word: Vulnerability_Word, seat: norn.Seat, table: norn.Table) -> bool {
	ours := norn.vulnerable(table.vulnerability, seat)
	theirs := norn.vulnerable(table.vulnerability, left_hand_opponent(seat))
	switch word {
	case .Vulnerable:
		return ours
	case .Favourable:
		return !ours && theirs
	case .Unfavourable:
		return ours && !theirs
	}
	return false
}

// An opponent of `seat`: the next seat round.
@(private)
left_hand_opponent :: proc(seat: norn.Seat) -> norn.Seat {
	return norn.Seat((int(seat) + 1) %% len(norn.Seat))
}

/*
One node against one hand.

An out-of-range index is FALSE rather than a crash. Only a malformed tree produces one and the parser
does not emit malformed trees — but this runs a million times inside a generate loop on a worker thread,
and "reject the deal" is a better answer there than taking the process down.
*/
@(private)
eval_node :: proc(program: ^Program, index: int, at: ^At) -> bool {
	if index < 0 || index >= len(program.nodes) {
		return false
	}
	hand := at.hand
	switch node in program.nodes[index] {
	case Compare_Node:
		if node.quantity == .Seat {
			return compare(node, seat_position(at.seat, at.table))
		}
		if node.quantity == .Opc {
			// The parser allows `opc` only where the hand is a side's, so `at.pair` holds here.
			return compare_opc(node, norn.combined_opc(at.summary[at.seat], at.summary[partner_of(at.seat)], nil))
		}
		return compare(node, quantity_value(node.quantity, hand))

	case Sum_Compare_Node:
		left := sum_value(node.left, hand)
		if node.is_range {
			return left >= node.value && left <= node.high
		}
		right := sum_value(node.right, hand) if node.right.count > 0 else node.value
		return compare(Compare_Node{op = node.op, value = right}, left)

	case Vulnerability_Node:
		return vulnerability_holds(node.word, at.seat, at.table)

	case Named_Node:
		// Resolved at parse time, but the table could in principle have been swapped since; a name that
		// no longer resolves rejects rather than indexing out of bounds.
		vocabulary := g_vocabulary
		if node.index < 0 || node.index >= len(vocabulary) {
			return false
		}
		entry := vocabulary[node.index]
		return entry.call != nil && entry.call(hand)

	case Meaning_Node:
		if eval_node(program, node.root, at) {
			return true
		}
		for alternative in node.alternatives {
			if (!at.mode.core_only || alternative.name == at.mode.only) && eval_node(program, alternative.root, at) {
				return true
			}
		}
		return false

	case Holds_Node:
		return norn.holds(hand, node.suit, node.rank)

	case Balanced_Node:
		return norn.is_balanced(hand)

	case Hand_Node:
		inner := at_hand(at.summary, at.table, node.seat, node.pair)
		inner.mode = at.mode
		return eval_node(program, node.child, &inner)

	case Not_Node:
		return !eval_node(program, node.child, at)

	case And_Node:
		return eval_node(program, node.left, at) && eval_node(program, node.right, at)

	case Or_Node:
		return eval_node(program, node.left, at) || eval_node(program, node.right, at)
	}
	return false
}

@(private)
sum_value :: proc(sum: Sum, hand: norn.Hand_Summary) -> int {
	total := 0
	for i in 0 ..< sum.count {
		term := sum.terms[i]
		total += quantity_value(term, hand)
	}
	return total
}

@(private)
quantity_value :: proc(quantity: Quantity, hand: norn.Hand_Summary) -> int {
	switch quantity {
	case .Hcp:
		return norn.hcp(hand)
	case .Controls:
		return norn.controls(hand)
	case .Spades:
		return norn.suit_length(hand, .Spades)
	case .Hearts:
		return norn.suit_length(hand, .Hearts)
	case .Diamonds:
		return norn.suit_length(hand, .Diamonds)
	case .Clubs:
		return norn.suit_length(hand, .Clubs)
	case .Longest:
		longest := 0
		for suit in norn.Suit {
			longest = max(longest, norn.suit_length(hand, suit))
		}
		return longest
	case .Seat, .Opc:
		return 0 // read off the table, or off the two hands apart: `eval_node` answers these
	}
	return 0
}

// `compare` for a fractional value: OPC counts in halves and quarters, and `opc >= 32` means what it says.
@(private)
compare_opc :: proc(node: Compare_Node, value: f32) -> bool {
	low, high := f32(node.value), f32(node.high)
	if node.is_range {
		return value >= low && value <= high
	}
	switch node.op {
	case .Less:
		return value < low
	case .Less_Equal:
		return value <= low
	case .Equal:
		return value == low
	case .Not_Equal:
		return value != low
	case .Greater_Equal:
		return value >= low
	case .Greater:
		return value > low
	}
	return false
}

@(private)
compare :: proc(node: Compare_Node, value: int) -> bool {
	if node.is_range {
		return value >= node.value && value <= node.high
	}
	switch node.op {
	case .Less:
		return value < node.value
	case .Less_Equal:
		return value <= node.value
	case .Equal:
		return value == node.value
	case .Not_Equal:
		return value != node.value
	case .Greater_Equal:
		return value >= node.value
	case .Greater:
		return value > node.value
	}
	return false
}
