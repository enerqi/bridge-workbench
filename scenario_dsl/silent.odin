package scenario_dsl

import "core:strings"
import "norn:norn"

/*
`silent(1, hearts)`: THE HAND PASSED when it could have acted - a defender's silence, as a condition. The ladder
(`LEAD_PROBLEM_PLAN.md`, "The ladder's numbers") lists the hands nearly every player would have bid with at that
point, and `silent` is true of every hand that is NOT one of them. Borderline hands stay in: excluding too much
skews the layouts as surely as excluding nothing.

The arguments are the LEVEL the hand's first chance to act came at (1, 2, or 3 for three and up) and the suits
the opponents had bid by then (`silent(1, clubs, hearts)` after `1♣ – pass – 1♥`), or `notrump` for a notrump
opening (`silent(2, notrump)` over 1NT: the first overcall is at the two level). Length in THEIR suits is never
held against the hand - the trap pass is a real way to be silent. Only that first chance is judged: a later
balancing chance is not, and vulnerability does not enter yet.
*/
Silent_Node :: struct {
	level:   int,
	over:    bit_set[norn.Suit], // the opponents' suits; empty with `notrump`
	notrump: bool,
}

SILENT_LEVEL_MAX :: 3 // three is "three and up"

// The hand would have acted, by the ladder: overcall, weak jump, takeout double, two-suiter or strength.
would_act :: proc(hand: norn.Hand_Summary, node: Silent_Node) -> bool {
	hcp := norn.hcp(hand)
	level := clamp(node.level, 1, SILENT_LEVEL_MAX)
	unbid := ~node.over

	// STRENGTH, any shape: it doubles, or bids notrump. Against a notrump opening the double is for penalty.
	strong := [SILENT_LEVEL_MAX + 1]int{0, 16, 17, 18}
	if node.notrump && level == 2 {
		strong[2] = 16
	}
	if hcp >= strong[level] {
		return true
	}

	five_card_suits := 0
	for suit in unbid {
		length := norn.suit_length(hand, suit)
		if length >= 5 {
			five_card_suits += 1
		}
		honours := card(hand.suits[suit] & {.Ace, .King, .Queen, .Jack})
		top_three := card(hand.suits[suit] & {.Ace, .King, .Queen})
		major := suit == .Spades || suit == .Hearts
		switch level {
		case 1:
			if major && length >= 5 && honours >= 2 && hcp >= 8 {return true} // a good major
			if length >= 5 && hcp >= 10 {return true}
			if length >= 6 && hcp >= 8 {return true}
			if length >= 6 && top_three >= 2 && hcp >= 6 {return true} // the weak jump
			if length >= 7 && hcp >= 5 {return true}
		case 2:
			if length >= 5 && hcp >= 12 {return true}
			if length >= 6 && hcp >= 10 {return true}
		case:
			if length >= 6 && hcp >= 13 {return true}
			if length >= 7 && hcp >= 10 {return true}
		}
	}

	// TWO-SUITER (Michaels, the unusual notrump): 5-5 in two unbid suits. Not at three and up.
	two_suited := [SILENT_LEVEL_MAX + 1]int{0, 8, 10, 99}
	if five_card_suits >= 2 && hcp >= two_suited[level] {
		return true
	}

	// TAKEOUT DOUBLE: at most a doubleton in their suits, and either 3+ in every unbid suit or the unbid majors
	// covered (two unbid majors 4-3 or better, one unbid major 4+). Over notrump a double is not for takeout.
	takeout := [SILENT_LEVEL_MAX + 1]int{0, 12, 13, 15}
	if !node.notrump && node.over != {} && hcp >= takeout[level] {
		short := true
		for suit in node.over {
			short = short && norn.suit_length(hand, suit) <= 2
		}
		support := true
		for suit in unbid {
			support = support && norn.suit_length(hand, suit) >= 3
		}
		spades, hearts := norn.suit_length(hand, .Spades), norn.suit_length(hand, .Hearts)
		covered := false
		switch {
		case .Spades in unbid && .Hearts in unbid:
			covered = max(spades, hearts) >= 4 && min(spades, hearts) >= 3
		case .Spades in unbid:
			covered = spades >= 4
		case .Hearts in unbid:
			covered = hearts >= 4
		}
		if short && (support || covered) {
			return true
		}
	}
	return false
}

// `silent(` .. `)`: a level, then their suits or `notrump`.
@(private)
parse_silent :: proc(p: ^Parser, start_col: int) -> (root: int, ok: bool) {
	USAGE :: "`silent` takes the level the hand could first act at and the opponents' suits: `silent(1, hearts)`, `silent(1, clubs, hearts)`, `silent(2, notrump)`"
	skip_spaces(p)
	if !strings.has_prefix(p.text, "(") {
		report(p, p.line_index, p.col, USAGE)
		return 0, false
	}
	advance(p, 1)
	skip_spaces(p)
	level_col := p.col
	level_word, _ := take_word(p)
	node: Silent_Node
	switch level_word {
	case "1":
		node.level = 1
	case "2":
		node.level = 2
	case "3":
		node.level = 3
	case:
		report(p, p.line_index, level_col, "expected the level first: 1, 2, or 3 for three and up")
		return 0, false
	}
	for {
		skip_spaces(p)
		if strings.has_prefix(p.text, ")") {
			break
		}
		if !strings.has_prefix(p.text, ",") {
			report(p, p.line_index, p.col, "expected `,` and a suit, or `)`")
			return 0, false
		}
		advance(p, 1)
		skip_spaces(p)
		col := p.col
		word, _ := take_word(p)
		lowered := folded(word)
		if lowered == "notrump" || lowered == "nt" {
			node.notrump = true
		} else if suit, is_suit := suit_of(lowered); is_suit {
			node.over += {suit}
		} else {
			report(p, p.line_index, col, "expected a suit the opponents bid - clubs, diamonds, hearts, spades - or `notrump`")
			return 0, false
		}
	}
	advance(p, 1)
	if node.notrump && node.over != {} {
		report(p, p.line_index, start_col, "`silent` is over a notrump opening or over suits, not both")
		return 0, false
	}
	if !node.notrump && node.over == {} {
		report(p, p.line_index, start_col, USAGE)
		return 0, false
	}
	return add_node(p, node), true
}

@(private)
write_silent :: proc(b: ^strings.Builder, node: Silent_Node) {
	strings.write_string(b, "silent(")
	strings.write_int(b, node.level)
	if node.notrump {
		strings.write_string(b, ", notrump")
	}
	for suit in norn.Suit {
		if suit in node.over {
			strings.write_string(b, ", ")
			strings.write_string(b, suit_word(suit))
		}
	}
	strings.write_byte(b, ')')
}
