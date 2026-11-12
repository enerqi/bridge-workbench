package lead_problem

/*
	THE CHOSEN CONTRACT (LEAD_PROBLEM_PLAN.md, "Better than par"): when no contract is given, the one the
	declaring side would BID, from its own 26 cards on each layout, by rules; the most common result over the
	layouts is the contract. Par sees all 52 cards (it plays 3NT because the defenders' hearts split), so it is
	only the comparison.

	STRAIN, the first rule that applies:
	  1. an 8+ card major fit plays in the major (the longer fit; spades when the two are equal);
	  2. a 10+ card minor fit with a shortage (a singleton or void in either hand) plays in the minor;
	  3. notrump, when every suit is stopped (A, Kx, Qxx or Jxxx in either hand);
	  4. a 7-card major fit, since some suit is not stopped (3NT's known weakness);
	  5. otherwise the longest minor fit (diamonds when equal).

	LEVEL, by the side's combined OPC in that strain against OPC's points-to-tricks table (`NT_COUNTS`,
	`SUIT_COUNTS`, the middle "about even money" column). GAME is reached a step lower (`GAME_COUNTS`, the table's
	40-45% column): borderline games are what real partnerships bid, and where the lead matters most. Game is a
	CEILING: the levels between game and slam are never chosen. A SLAM needs the six-level count AND no control
	hole: every suit but trumps controlled to the second round in either hand (an ace or king; in a suit contract
	a singleton or void too), at most one ace missing; a grand needs the seven-level count, every ace, and the
	trump king and queen (in notrump every king). A slam count that fails the check plays the game.
*/

import "core:fmt"
import "core:slice"
import "core:strings"

import "norn:norn"
import "../par_caption"

// A contract without its declarer: what the rules choose.
Bid :: struct {
	level:  int,
	strain: norn.Contract_Strain,
}

// OPC's points-to-tricks table, the middle count of each level (index = level; below the two level is one).
NT_COUNTS := [8]f32{0, 0, 23, 26, 29, 32, 34, 37}
SUIT_COUNTS := [8]f32{0, 0, 21, 24, 27, 30, 33, 36}

// The count that reaches GAME: the table's lower column at the game level.
GAME_COUNTS := [norn.Contract_Strain]f32 {
	.Clubs    = 29,
	.Diamonds = 29,
	.Hearts   = 26,
	.Spades   = 26,
	.NoTrumps = 25,
}

GAME_LEVEL := [norn.Contract_Strain]int {
	.Clubs    = 5,
	.Diamonds = 5,
	.Hearts   = 4,
	.Spades   = 4,
	.NoTrumps = 3,
}

@(private = "file")
fit :: proc(a, b: norn.Hand_Summary, suit: norn.Suit) -> int {
	return norn.suit_length(a, suit) + norn.suit_length(b, suit)
}

// A suit is stopped when either hand holds the ace, Kx, Qxx or Jxxx.
stopped :: proc(a, b: norn.Hand_Summary, suit: norn.Suit) -> bool {
	for hand in ([2]norn.Hand_Summary{a, b}) {
		cards, length := hand.suits[suit], norn.suit_length(hand, suit)
		if .Ace in cards || (.King in cards && length >= 2) || (.Queen in cards && length >= 3) || (.Jack in cards && length >= 4) {
			return true
		}
	}
	return false
}

// The strain the side plays in, by the rules above.
choose_strain :: proc(a, b: norn.Hand_Summary) -> norn.Contract_Strain {
	spades, hearts := fit(a, b, .Spades), fit(a, b, .Hearts)
	clubs, diamonds := fit(a, b, .Clubs), fit(a, b, .Diamonds)
	major: norn.Contract_Strain = .Spades if spades >= hearts else .Hearts
	major_fit := max(spades, hearts)
	minor: norn.Contract_Strain = .Diamonds if diamonds >= clubs else .Clubs
	minor_fit := max(clubs, diamonds)
	if major_fit >= 8 {
		return major
	}
	if minor_fit >= 10 {
		for suit in norn.Suit {
			if norn.suit_length(a, suit) <= 1 || norn.suit_length(b, suit) <= 1 {
				return minor
			}
		}
	}
	all_stopped := true
	for suit in norn.Suit {
		all_stopped &&= stopped(a, b, suit)
	}
	if all_stopped {
		return .NoTrumps
	}
	if major_fit >= 7 {
		return major
	}
	return minor
}

@(private = "file")
strain_suit :: proc(strain: norn.Contract_Strain) -> Maybe(norn.Suit) {
	switch strain {
	case .Clubs:
		return .Clubs
	case .Diamonds:
		return .Diamonds
	case .Hearts:
		return .Hearts
	case .Spades:
		return .Spades
	case .NoTrumps:
	}
	return nil
}

// No control hole for a slam in `strain` (a grand when `grand`): see the package note.
slam_controls :: proc(a, b: norn.Hand_Summary, strain: norn.Contract_Strain, grand: bool) -> bool {
	trump, is_suit := strain_suit(strain).?
	aces, kings := 0, 0
	for suit in norn.Suit {
		held := a.suits[suit] | b.suits[suit]
		aces += 1 if .Ace in held else 0
		kings += 1 if .King in held else 0
		if is_suit && suit == trump {
			continue
		}
		short := is_suit && (norn.suit_length(a, suit) <= 1 || norn.suit_length(b, suit) <= 1)
		if .Ace not_in held && .King not_in held && !short {
			return false
		}
	}
	if !grand {
		return aces >= 3
	}
	if aces < 4 {
		return false
	}
	if is_suit {
		held := a.suits[trump] | b.suits[trump]
		return .King in held && .Queen in held
	}
	return kings == 4
}

// The level the side bids to in `strain`, by its combined OPC (see the package note).
choose_level :: proc(a, b: norn.Hand_Summary, strain: norn.Contract_Strain) -> int {
	trump := strain_suit(strain)
	opc := norn.combined_opc(a, b, trump)
	counts := NT_COUNTS if strain == .NoTrumps else SUIT_COUNTS
	if opc >= counts[6] && slam_controls(a, b, strain, false) {
		return 7 if opc >= counts[7] && slam_controls(a, b, strain, true) else 6
	}
	game := GAME_LEVEL[strain]
	if opc >= GAME_COUNTS[strain] {
		return game
	}
	level := 1
	for l in 2 ..< game {
		if opc >= counts[l] {
			level = l
		}
	}
	return level
}

// The contract a side with hands `a` and `b` bids.
choose_bid :: proc(a, b: norn.Hand_Summary) -> Bid {
	strain := choose_strain(a, b)
	return {choose_level(a, b, strain), strain}
}

/*
Which of the side's two seats declares `strain`: the longer trumps, in notrump the more high-card points, and
the first of `seats` when they are equal. Decided once, on the problem's deal, because the leader's seat (and so
the hand that is the problem) depends on it.
*/
choose_declarer :: proc(deal: norn.Deal_Summary, seats: [2]norn.Seat, strain: norn.Contract_Strain) -> norn.Seat {
	a, b := deal[seats[0]], deal[seats[1]]
	if trump, is_suit := strain_suit(strain).?; is_suit {
		la, lb := norn.suit_length(a, trump), norn.suit_length(b, trump)
		if la != lb {
			return seats[0] if la > lb else seats[1]
		}
	}
	return seats[1] if norn.hcp(b) > norn.hcp(a) else seats[0]
}

// The bids the rules chose over the layouts, and how par compared.
Choice :: struct {
	counts:     [8][norn.Contract_Strain]int, // layouts per bid
	layouts:    int,
	par_agrees: int, // layouts whose par for the declaring side includes the chosen bid
	pars:       int, // layouts with a par result
	par_counts: [8][norn.Contract_Strain]int, // the declaring side's first par contract, per layout (makes only)
	par_other:  int, // layouts whose par is the other side's contract, or a sacrifice
}

choice_add :: proc(choice: ^Choice, a, b: norn.Hand_Summary) {
	bid := choose_bid(a, b)
	choice.counts[bid.level][bid.strain] += 1
	choice.layouts += 1
}

// The most common bid; `share` of the layouts.
most_common :: proc(counts: [8][norn.Contract_Strain]int) -> (bid: Bid, count: int) {
	for level in 1 ..= 7 {
		for strain in norn.Contract_Strain {
			if counts[level][strain] > count {
				bid, count = {level, strain}, counts[level][strain]
			}
		}
	}
	return
}

@(private = "file")
PAR_STRAIN := [par_caption.Denom]norn.Contract_Strain {
	.NT       = .NoTrumps,
	.Spades   = .Spades,
	.Hearts   = .Hearts,
	.Diamonds = .Diamonds,
	.Clubs    = .Clubs,
}

@(private = "file")
seats_include :: proc(seats: par_caption.Seats, declarer: norn.Seat) -> bool {
	switch seats {
	case .N:
		return declarer == .North
	case .E:
		return declarer == .East
	case .S:
		return declarer == .South
	case .W:
		return declarer == .West
	case .NS:
		return declarer == .North || declarer == .South
	case .EW:
		return declarer == .East || declarer == .West
	}
	return false
}

/*
Compare one layout's par with the chosen contract: `par` is DDS's par with the DECLARING side bidding first. It
agrees when one of its contracts is the chosen bid played by declarer's side; its first contract that the side
makes is counted, and a par that is the other side's (or a sacrifice) is counted apart.
*/
choice_add_par :: proc(choice: ^Choice, par: par_caption.Par, chosen: Bid, declarer: norn.Seat) {
	par := par
	choice.pars += 1
	counted := false
	for c in par.contracts[:par.number] {
		ours := seats_include(c.seats, declarer) && c.under_tricks == 0
		if ours && c.level == chosen.level && PAR_STRAIN[c.denom] == chosen.strain {
			choice.par_agrees += 1
			break
		}
	}
	for c in par.contracts[:par.number] {
		if seats_include(c.seats, declarer) && c.under_tricks == 0 {
			choice.par_counts[c.level][PAR_STRAIN[c.denom]] += 1
			counted = true
			break
		}
	}
	if !counted {
		choice.par_other += 1
	}
}

// `4♠`.
write_bid :: proc(b: ^strings.Builder, bid: Bid) {
	fmt.sbprintf(b, "%d%s", bid.level, STRAIN_WORDS[bid.strain])
}

/*
How the contract was chosen, for the report:

	The contract, chosen from North-South's cards on each layout: 4♠ 62%, 3NT 21%, 3♠ 9%, 5♣ 4%, others 4%
	Par agrees on 48% of the layouts; par itself is most often 4♠ (40%), the other side's on 6%
*/
write_choice :: proc(b: ^strings.Builder, choice: Choice, declarer: norn.Seat) {
	SHOWN :: 4
	side := "North-South" if declarer == .North || declarer == .South else "East-West"
	fmt.sbprintf(b, "The contract, chosen by simple bidding rules from %s's cards on each layout:", side)
	write_spread(b, choice.counts, choice.layouts, SHOWN)
	strings.write_byte(b, '\n')
	if choice.pars == 0 {
		return
	}
	n := f64(choice.pars)
	fmt.sbprintf(b, "Par agrees on %.0f%% of the layouts; par itself:", f64(choice.par_agrees) * 100 / n)
	write_spread(b, choice.par_counts, choice.pars, SHOWN - 1)
	if choice.par_other > 0 {
		fmt.sbprintf(b, ", the other side's or a sacrifice %.0f%%", f64(choice.par_other) * 100 / n)
	}
	strings.write_byte(b, '\n')
}

@(private = "file")
write_spread :: proc(b: ^strings.Builder, counts: [8][norn.Contract_Strain]int, total, shown: int) {
	Entry :: struct {
		bid:   Bid,
		count: int,
	}
	entries := make([dynamic]Entry, 0, 35, context.temp_allocator)
	for level in 1 ..= 7 {
		for strain in norn.Contract_Strain {
			if counts[level][strain] > 0 {
				append(&entries, Entry{{level, strain}, counts[level][strain]})
			}
		}
	}
	slice.stable_sort_by(entries[:], proc(x, y: Entry) -> bool {return x.count > y.count})
	rest := 0
	for entry, i in entries {
		if i >= shown {
			rest += entry.count
			continue
		}
		strings.write_string(b, " " if i == 0 else ", ")
		write_bid(b, entry.bid)
		write_share(b, entry.count, total)
	}
	if rest > 0 {
		strings.write_string(b, ", others")
		write_share(b, rest, total)
	}
}

// ` 12%`, and ` <1%` for a share that is there but rounds to nothing.
@(private = "file")
write_share :: proc(b: ^strings.Builder, count, total: int) {
	share := f64(count) * 100 / f64(total)
	if count > 0 && share < 0.5 {
		strings.write_string(b, " <1%")
	} else {
		fmt.sbprintf(b, " %.0f%%", share)
	}
}
