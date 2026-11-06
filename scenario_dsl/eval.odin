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
		if lines_hold(program, summary, table, also) {
			return true
		}
	}
	return false
}

/*
WHY a kept deal was kept: "" when the scenario's own lines hold, else the name of the first alternative whose
lines do (norn's `Contextual_Explain`, asked only of kept deals). Alternatives are tried in the order the file
names them, so a deal two of them admit carries the first one's name.
*/
explain :: proc(summary: norn.Deal_Summary, table: norn.Table, userdata: rawptr) -> string {
	program := (^Program)(userdata)
	if program == nil || lines_hold(program, summary, table, 0) {
		return ""
	}
	for name, i in program.alternatives {
		if lines_hold(program, summary, table, i + 1) {
			return name
		}
	}
	return ""
}

// Do the lines of alternative `also` hold (0: the scenario's own)? An alternative's lines REPLACE the scenario's
// lines for the same seat or side, and the scenario's other lines still apply.
@(private)
lines_hold :: proc(program: ^Program, summary: norn.Deal_Summary, table: norn.Table, also: int) -> bool {
	for rule in program.rules {
		if rule.also != also && (rule.also != 0 || replaced_in(program, rule, also)) {
			continue
		}
		// A partnership line reads its two hands as one — see `combined` for why that is exact.
		hand := summary[rule.seat]
		if rule.pair {
			hand = combined(hand, summary[partner_of(rule.seat)])
		}
		at := At{hand = hand, seat = rule.seat, table = table}
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
		if rule.also == also && rule.seat == own.seat && rule.pair == own.pair {
			return true
		}
	}
	return false
}

// What a line is evaluated against: the hand (or the side's two, combined), whose it is, and the board's table.
@(private)
At :: struct {
	hand:  norn.Hand_Summary,
	seat:  norn.Seat,
	table: norn.Table,
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
		return compare(node, quantity_value(node.quantity, hand))

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
		return eval_node(program, node.root, at)

	case Holds_Node:
		return norn.holds(hand, node.suit, node.rank)

	case Balanced_Node:
		return norn.is_balanced(hand)

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
	case .Seat:
		return 0 // read off the table, not the hand: `eval_node` answers it
	}
	return 0
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
