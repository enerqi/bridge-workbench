package lead_problem

/*
	lead_problem — "what do I lead?", the LEADER's question, without the solver (LEAD_PROBLEM_PLAN.md).

	One defender's hand known, the other three dealt to fit a scenario, and every card of the known hand solved
	double dummy as the opening lead over those layouts. This package holds what needs no solver: the contract
	and who leads, the opening position as DDS's deal, the cards grouped into leads DDS cannot tell apart, the
	tally of each layout's answer and the ranking. The solves are `deal_solve.solve_leads`; the dealing is norn's;
	`sim --lead` puts them together.

	THE GROUPS start as a hand's SEQUENCES: cards of one suit with no rank between them, like ♦987 or ♠KQ. At the
	opening lead nothing is played, so two cards of a sequence always take the same tricks, whatever the layout.
	Then the ranking JOINS the leads of a suit that took the same tricks on EVERY layout (♦52 when the ♦3 and ♦4
	never mattered): one row, since nothing in the sample tells them apart. (DDS's own `equals` joins more on one
	layout, but a row has to mean the same lead on all of them, so the joining is done over the whole tally.)

	THE NUMBERS are the DEFENCE's tricks (DDS scores the side on lead): a lead BEATS the contract on a layout
	when the defence takes `8 - level` or more.
*/

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import "norn:norn"
import "../replay"

// What is led against: the contract and its declarer. The leader is declarer's left-hand opponent.
Lead_Contract :: struct {
	level:    int,
	strain:   norn.Contract_Strain,
	declarer: norn.Seat,
}

leader :: proc(c: Lead_Contract) -> norn.Seat {
	return norn.Seat((int(c.declarer) + 1) % norn.SEAT_COUNT)
}

// The defence's tricks that beat it.
tricks_to_beat :: proc(c: Lead_Contract) -> int {
	return 8 - c.level
}

/*
`4S:south`, `4S by south`, `3nt:n`: a level 1..7, a strain (`C D H S N NT`, any case), and the declarer by name
or initial. `bad` says what is wrong, "" when nothing.
*/
parse_lead_contract :: proc(text: string) -> (c: Lead_Contract, bad: string) {
	USAGE :: "expected a contract and its declarer: `4S:south`, `3NT by north`"
	lowered := strings.to_lower(strings.trim_space(text), context.temp_allocator)
	contract_text, seat_text := lowered, ""
	if colon := strings.index_byte(lowered, ':'); colon >= 0 {
		contract_text, seat_text = lowered[:colon], lowered[colon + 1:]
	} else if by := strings.index(lowered, " by "); by >= 0 {
		contract_text, seat_text = lowered[:by], lowered[by + len(" by "):]
	}
	contract_text, seat_text = strings.trim_space(contract_text), strings.trim_space(seat_text)
	if len(contract_text) < 2 || contract_text[0] < '1' || contract_text[0] > '7' || seat_text == "" {
		return {}, USAGE
	}
	c.level = int(contract_text[0] - '0')
	switch contract_text[1:] {
	case "c":
		c.strain = .Clubs
	case "d":
		c.strain = .Diamonds
	case "h":
		c.strain = .Hearts
	case "s":
		c.strain = .Spades
	case "n", "nt":
		c.strain = .NoTrumps
	case:
		return {}, USAGE
	}
	switch seat_text {
	case "n", "north":
		c.declarer = .North
	case "e", "east":
		c.declarer = .East
	case "s", "south":
		c.declarer = .South
	case "w", "west":
		c.declarer = .West
	case:
		return {}, USAGE
	}
	return c, ""
}

/*
What `--lead` asks for: a contract and its declarer (`4S:south`), or only who declares (`south`), or only the
declaring side (`north-south`, `ns`), the contract then chosen by the rules (`choose.odin`). `seats` are the
seats that may declare: one, or a side's two. `bad` says what is wrong, "" when nothing.
*/
Lead_Request :: struct {
	contract: Maybe(Lead_Contract),
	seats:    [2]norn.Seat,
	one_seat: bool,
	scoring:  Scoring, // how the leads are ranked (scoring.odin); not part of the text, set by the caller
}

parse_lead_request :: proc(text: string) -> (req: Lead_Request, bad: string) {
	switch strings.to_lower(strings.trim_space(text), context.temp_allocator) {
	case "n", "north":
		return {seats = {.North, .North}, one_seat = true}, ""
	case "e", "east":
		return {seats = {.East, .East}, one_seat = true}, ""
	case "s", "south":
		return {seats = {.South, .South}, one_seat = true}, ""
	case "w", "west":
		return {seats = {.West, .West}, one_seat = true}, ""
	case "ns", "n-s", "north-south":
		return {seats = {.North, .South}}, ""
	case "ew", "e-w", "east-west":
		return {seats = {.East, .West}}, ""
	}
	c, why := parse_lead_contract(text)
	if why != "" {
		return {}, "expected a contract and its declarer (`4S:south`), a declarer (`south`) or a side (`north-south`)"
	}
	return {contract = c, seats = {c.declarer, c.declarer}, one_seat = true}, ""
}

// The opening lead's position as DDS's deal: nothing played, declarer's left-hand opponent on lead.
opening_position :: proc(deal: norn.Deal, c: Lead_Contract) -> (dl: replay.Dds_Deal) {
	dl.trump = replay.dds_strain(c.strain)
	dl.first = i32(leader(c))
	for seat in norn.Seat {
		for card in deal[seat] {
			dl.remain_cards[int(seat)][3 - int(norn.card_suit(card))] |= u32(1) << (u32(norn.card_rank(card)) + 2)
		}
	}
	return
}

// One lead: a sequence of the leader's hand, top card first in `cards`.
Lead :: struct {
	suit:  norn.Suit,
	cards: norn.Rank_Set,
	top:   norn.Rank,
}

// The leader's hand as its leads, in the order a hand is written: spades to clubs, high to low.
leads_of :: proc(hand: norn.Hand_Summary, allocator := context.allocator) -> []Lead {
	out := make([dynamic]Lead, 0, 13, allocator)
	for suit in ([4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}) {
		current: Lead
		open := false
		for r := int(max(norn.Rank)); r >= 0; r -= 1 {
			rank := norn.Rank(r)
			if rank not_in hand.suits[suit] {
				if open {
					append(&out, current)
					open = false
				}
				continue
			}
			if !open {
				current = Lead{suit = suit, top = rank}
				open = true
			}
			current.cards += {rank}
		}
		if open {
			append(&out, current)
		}
	}
	return out[:]
}

// How each lead did over the layouts tallied so far.
Tally :: struct {
	leads:   []Lead,
	beats:   []int, // layouts where the lead beat the contract
	tricks:  []int, // the defence's tricks, summed over the layouts
	layouts: int,
	// Each layout's tricks for every lead, `len(leads)` a layout: what tells two leads apart.
	each:    [dynamic]i8,
}

make_tally :: proc(leads: []Lead, allocator := context.allocator) -> Tally {
	return Tally {
		leads = leads,
		beats = make([]int, len(leads), allocator),
		tricks = make([]int, len(leads), allocator),
		each = make([dynamic]i8, 0, 200 * len(leads), allocator),
	}
}

destroy_tally :: proc(t: ^Tally, allocator := context.allocator) {
	delete(t.beats, allocator)
	delete(t.tricks, allocator)
	delete(t.each)
}

/*
Add one layout's answer: DDS's `futureTricks` for the opening position, asked for every card (`solutions` 3). Each
entry is a card, the lower cards it is equal to (`equals`, a rank bitmask) and the defence's tricks. False when the
answer does not cover every lead (a failed solve), and the layout is then not counted.
*/
tally_layout :: proc(t: ^Tally, c: Lead_Contract, fut: replay.Dds_Future) -> bool {
	scores: [norn.Suit][norn.Rank]int
	known: [norn.Suit]norn.Rank_Set
	for k in 0 ..< int(fut.cards) {
		suit := norn.Suit(3 - int(fut.suit[k]))
		ranks := fut.equals[k] | (u32(1) << u32(fut.rank[k]))
		for r in 0 ..< norn.RANK_COUNT {
			if ranks & (u32(1) << u32(r + 2)) != 0 {
				scores[suit][norn.Rank(r)] = int(fut.score[k])
				known[suit] += {norn.Rank(r)}
			}
		}
	}
	for lead in t.leads {
		if lead.top not_in known[lead.suit] {
			return false
		}
	}
	for lead, i in t.leads {
		tricks := scores[lead.suit][lead.top]
		append(&t.each, i8(tricks))
		t.tricks[i] += tricks
		if tricks >= tricks_to_beat(c) {
			t.beats[i] += 1
		}
	}
	t.layouts += 1
	return true
}

// A lead's line in the ranking.
Row :: struct {
	lead:   Lead,
	beats:  f64, // share of layouts it beats the contract on, 0..1
	margin: f64, // a 95% interval's half-width on `beats`
	tricks: f64, // the defence's mean tricks
	cost:   f64, // mean tricks below the best lead's mean, >= 0
	index:  int, // the tally's lead this row stands for (its first, when leads were joined)
	// Against the field's lead (`score_rows`, scoring.odin): the mean IMPs and matchpoints (0..1) a layout, each
	// with its 95% margin; whether this is the field's lead.
	imps:       f64,
	imp_margin: f64,
	mp:         f64,
	mp_margin:  f64,
	field:      bool,
	// What the ranking is by (`beats` until `score_rows` says otherwise), and the paired 95% margin on the gap
	// between this row and the top row in it.
	key:        f64,
	key_margin: f64,
}

// The leads ranked: most often beating the contract first, then most tricks. Leads of one suit that took the same
// tricks on every layout are one row.
rank :: proc(t: Tally, allocator := context.allocator) -> []Row {
	if t.layouts == 0 {
		return {}
	}
	count := len(t.leads)
	same :: proc(t: Tally, a, b: int) -> bool {
		count := len(t.leads)
		for layout in 0 ..< t.layouts {
			if t.each[layout * count + a] != t.each[layout * count + b] {
				return false
			}
		}
		return true
	}
	rows := make([dynamic]Row, 0, count, allocator)
	joined := make([]bool, count, context.temp_allocator)
	n := f64(t.layouts)
	best := 0.0
	for i in 0 ..< count {
		if joined[i] {
			continue
		}
		lead := t.leads[i]
		for j in i + 1 ..< count {
			if !joined[j] && t.leads[j].suit == lead.suit && same(t, i, j) {
				joined[j] = true
				lead.cards += t.leads[j].cards
			}
		}
		p := f64(t.beats[i]) / n
		row := Row {
			lead   = lead,
			beats  = p,
			margin = 1.96 * math.sqrt(p * (1 - p) / n),
			tricks = f64(t.tricks[i]) / n,
			index  = i,
			key    = p,
		}
		best = max(best, row.tricks)
		append(&rows, row)
	}
	for &row in rows {
		row.cost = best - row.tricks
	}
	slice.stable_sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.beats != b.beats {
			return a.beats > b.beats
		}
		return a.tricks > b.tricks
	})
	return rows[:]
}

// The defence's tricks for a row's lead on one layout of the tally.
row_tricks :: proc(t: Tally, row: Row, layout: int) -> int {
	return int(t.each[layout * len(t.leads) + row.index])
}

/*
What a row is measured against when its worst layouts are shown: the top row, and for the top row itself the
next one down (the layouts where the best lead's edge came from). -1 when there is no other row.
*/
rival :: proc(rows: []Row, r: int) -> int {
	if len(rows) < 2 {
		return -1
	}
	return 1 if r == 0 else 0
}

/*
The layouts where row `r` did WORST against its rival (`rival`): those where the rival's lead took more tricks,
the biggest gaps first (a gap that changes beating the contract before one that does not), at most `limit`.
Layout indices into the tally, in `allocator`.
*/
worst_layouts :: proc(t: Tally, c: Lead_Contract, rows: []Row, r: int, limit: int, allocator := context.allocator) -> []int {
	other := rival(rows, r)
	if other < 0 || limit <= 0 {
		return {}
	}
	Gap :: struct {
		layout, tricks: int,
		swings:         bool,
	}
	gaps := make([dynamic]Gap, 0, t.layouts, context.temp_allocator)
	need := tricks_to_beat(c)
	for layout in 0 ..< t.layouts {
		mine, theirs := row_tricks(t, rows[r], layout), row_tricks(t, rows[other], layout)
		if theirs > mine {
			append(&gaps, Gap{layout, theirs - mine, theirs >= need && mine < need})
		}
	}
	slice.stable_sort_by(gaps[:], proc(a, b: Gap) -> bool {
		if a.swings != b.swings {
			return a.swings
		}
		return a.tricks > b.tricks
	})
	out := make([]int, min(limit, len(gaps)), allocator)
	for &layout, i in out {
		layout = gaps[i].layout
	}
	return out
}

SUIT_GLYPHS := [norn.Suit]string {
	.Clubs    = "♣",
	.Diamonds = "♦",
	.Hearts   = "♥",
	.Spades   = "♠",
}

STRAIN_WORDS := [norn.Contract_Strain]string {
	.Clubs    = "♣",
	.Diamonds = "♦",
	.Hearts   = "♥",
	.Spades   = "♠",
	.NoTrumps = "NT",
}

SEAT_WORDS := [norn.Seat]string {
	.North = "North",
	.East  = "East",
	.South = "South",
	.West  = "West",
}

// `♦987`: a lead as its suit and cards.
write_lead :: proc(b: ^strings.Builder, lead: Lead) {
	strings.write_string(b, SUIT_GLYPHS[lead.suit])
	for r := int(max(norn.Rank)); r >= 0; r -= 1 {
		if norn.Rank(r) in lead.cards {
			strings.write_rune(b, norn.rank_char(norn.Rank(r)))
		}
	}
}

// `♠KJ32 ♥A54 ♦Q987 ♣T3`, a void as `-`.
write_hand :: proc(b: ^strings.Builder, hand: norn.Hand_Summary) {
	for suit, i in ([4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}) {
		if i > 0 {
			strings.write_byte(b, ' ')
		}
		strings.write_string(b, SUIT_GLYPHS[suit])
		if hand.suits[suit] == {} {
			strings.write_byte(b, '-')
		}
		for r := int(max(norn.Rank)); r >= 0; r -= 1 {
			if norn.Rank(r) in hand.suits[suit] {
				strings.write_rune(b, norn.rank_char(norn.Rank(r)))
			}
		}
	}
}

VULNERABILITY_WORDS := [norn.Vulnerability]string {
	.None        = "Neither side vulnerable",
	.North_South = "North-South vulnerable",
	.East_West   = "East-West vulnerable",
	.Both        = "Both sides vulnerable",
}

// How the ranking is scored, for a line under the heading: "" for the plain beats-it ranking.
SCORING_LINES := [Scoring]string {
	.Beats       = "",
	.Imps        = "Scored at IMPs against the field, which leads the card taking the most tricks",
	.Matchpoints = "Scored at matchpoints against the field, which leads the card taking the most tricks",
}

// A row's figure in the scoring's own column: `+0.42` IMPs, `48%` matchpoints, `field` for the field's lead.
write_scored :: proc(b: ^strings.Builder, row: Row, scoring: Scoring) {
	switch {
	case row.field:
		strings.write_string(b, "field")
	case scoring == .Imps:
		fmt.sbprintf(b, "%+.2f", row.imps)
	case scoring == .Matchpoints:
		fmt.sbprintf(b, "%.0f%%", row.mp * 100)
	}
}

// `4♠ by South`.
write_contract :: proc(b: ^strings.Builder, c: Lead_Contract) {
	fmt.sbprintf(b, "%d%s by %s", c.level, STRAIN_WORDS[c.strain], SEAT_WORDS[c.declarer])
}

/*
The report, as text:

	West leads against 4♠ by South: ♠KJ32 ♥A54 ♦Q987 ♣T3
	200 layouts (2,431 deals dealt to find them)

	lead     beats it      tricks   cost
	♣T        41% ± 7       3.42      -
	♦987      38% ± 7       3.35    0.07
*/
write_report :: proc(
	b: ^strings.Builder,
	c: Lead_Contract,
	hand: norn.Hand_Summary,
	rows: []Row,
	layouts, dealt: int,
	scoring := Scoring.Beats,
	vulnerability := norn.Vulnerability.None,
) {
	fmt.sbprintf(b, "%s leads against ", SEAT_WORDS[leader(c)])
	write_contract(b, c)
	strings.write_string(b, ": ")
	write_hand(b, hand)
	fmt.sbprintf(b, "\n%s", VULNERABILITY_WORDS[vulnerability])
	if SCORING_LINES[scoring] != "" {
		fmt.sbprintf(b, " · %s", SCORING_LINES[scoring])
	}
	fmt.sbprintf(b, "\n%d layouts (%d deals dealt to find them)\n\n", layouts, dealt)
	strings.write_string(b, "lead       beats it      tricks    cost")
	switch scoring {
	case .Beats:
	case .Imps:
		strings.write_string(b, "     IMPs")
	case .Matchpoints:
		strings.write_string(b, "       MP")
	}
	strings.write_byte(b, '\n')
	for row in rows {
		lead := strings.builder_make(context.temp_allocator)
		write_lead(&lead, row.lead)
		text := strings.to_string(lead)
		strings.write_string(b, text)
		// The suit glyph is one column but three bytes: pad by what is SEEN.
		for _ in strings.rune_count(text) ..< 10 {
			strings.write_byte(b, ' ')
		}
		fmt.sbprintf(b, " %3.0f%% ± %-3.0f   %5.2f   ", row.beats * 100, row.margin * 100, row.tricks)
		if row.cost < 0.005 {
			strings.write_string(b, "    -")
		} else {
			fmt.sbprintf(b, "%5.2f", row.cost)
		}
		if scoring != .Beats {
			scored := strings.builder_make(context.temp_allocator)
			write_scored(&scored, row, scoring)
			fmt.sbprintf(b, "%9s", strings.to_string(scored))
		}
		strings.write_byte(b, '\n')
	}
	strings.write_string(
		b,
		"\nDouble dummy: every layout is played seeing all 52 cards, which flatters attacking leads.\n",
	)
}
