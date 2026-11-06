package scenario_dsl

/*
	scenario_dsl — scenarios written as TEXT, parsed at startup instead of compiled in.

	WHY THIS EXISTS. A `cli.Scenario` holds a condition, and until now that condition could only be an
	Odin proc: adding a scenario meant editing `bidding/scenarios.odin` and rebuilding, which is fine for
	the author of this repository and a dead end for anybody else. This package is the other half — a
	small expression language, parsed once into a tree and walked per deal, so a scenario can arrive as a
	file in a directory the user chose.

	IT ADDS, IT DOES NOT REPLACE. All 110 compiled scenarios stay exactly as they are, and a parsed one is
	the same `cli.Scenario` to everything downstream: the same registry, the same list, the same chips,
	the same `--frequency`. `norn.Condition` is what makes that true — the union whose other arm is a
	compiled predicate (see `cli/scenario.odin`).

	THE SHAPE OF A FILE. One or more scenarios, each a header line and an indented body:

		scenario 1c-then-5hearts "strong 1C; South 5+ hearts, 8-11"
		  system: swedish-club
		  tags: mine, competitive
		  north: is_strong_1c
		  south: hearts >= 5 and hcp in 8..11 and not balanced

	Seat lines AND together, which is the common case ("opener is X, responder is Y") and is what the
	compiled registry does with `&&`. Within a seat line the operators are `and`, `or`, `not` and
	parentheses, over two kinds of atom:

	  * GENERIC — `hcp`, `spades`/`hearts`/`diamonds`/`clubs`, `controls`, `longest` (and `seat`, below), compared with
	    `< <= = != >= >` or a range (`hcp in 15..17`), plus `balanced` and `holds(spades, ace)`;
	  * NAMED — the bidding system's own vocabulary (`is_strong_1c`, `is_2cd_swedish_club_resp`, …),
	    supplied by the CONSUMER through `set_vocabulary`. That is what lets a user compose THIS system
	    without compiling it, and what a form of HCP-and-shape ranges fundamentally cannot express.

	PARTNERSHIP LINES are the deal-level half. `north-south:` and `east-west:` take the same grammar, but
	every quantity reads the TWO HANDS TOGETHER:

			scenario slam-zone "N-S hold 32+ between them and a major fit"
			  north-south: hcp >= 32 and (spades >= 8 or hearts >= 8)

	`hcp` and `controls` are the side's combined count, a suit is the side's combined length (so `>= 8` is
	the usual meaning of "a fit"), `longest` is the side's longest COMBINED suit, and `holds(spades, ace)`
	asks whether either hand has it. The evaluator needed nothing new for that: a hand summary is four
	rank sets, the two hands of a side are disjoint, so the side IS the union of its two summaries and
	norn's own `hcp` / `suit_length` / `holds` read it correctly as it stands. `balanced` and the named
	helpers are the exceptions — they describe ONE hand's shape or bid, and a 26-card "hand" would answer
	them with nonsense rather than an error — so on a partnership line they are a parse diagnostic.

	What partnership lines do NOT express is a condition that relates the two hands' INDIVIDUAL holdings,
	like "3+ spades opposite 4+, or 3+ hearts opposite 4+": seat lines AND, so an `or` across seats has
	nowhere to live. That would need seat-qualified atoms (`north.spades`), not added until a scenario
	asks for one.

	THE TABLE - who dealt and who is vulnerable - for the meanings that depend on it (a third-seat preempt is
	lighter than a first-seat one; the rule of 2-3-4 is loose at favourable and sound at unfavourable):

			scenario weak-2-third-seat "weak two in third seat, light"
			  north: seat = 3 and longest = 6 and hcp in 3..10
			  north: favourable or not vulnerable

	`seat` is the hand's place in the auction, 1 for the dealer; `vulnerable`, `favourable` (not vulnerable,
	the opponents are) and `unfavourable` are the vulnerability as that hand's side sees it, and also read on
	a partnership line. A scenario can FIX either half instead of testing it:

			  dealer: south                # South deals every board
			  vulnerability: east-west     # none, north-south, east-west or both

	A scenario using any of this has each deal checked at the dealer and vulnerability it is then SHOWN with
	(`norn.Table_Draw`): whatever is not fixed is drawn at random per deal, and a deal at the wrong table is
	thrown away like a deal with the wrong hand. The run's own "North deals" setting does not apply to it.

	ALTERNATIVES say what a scenario lets in BEYOND its strict definition, and name it:

			scenario 1nt "1NT 15-17, and the hands some would open 1NT anyway"
			  north: hcp in 15..17 and balanced
			  south: hcp >= 8
			  also "14, five-card suit" north: hcp = 14 and balanced and longest = 5
			  also "18, flat" north: hcp = 18 and balanced and longest = 4

	An `also` line REPLACES the scenario's own lines for its seat (or side) - every `north:` line above, here -
	and keeps the rest, so a deal is kept when the scenario's lines hold, or when any one alternative's do.
	Several `also` lines with one name are one alternative. A deal kept ONLY by an alternative carries its name
	on its card (`explain`, norn's `Contextual_Explain`), so the debatable deals are marked rather than either
	shut out or passed off as textbook, and `check` counts what each alternative adds. Too wide beats too
	narrow: a hand someone would open and the scenario refuses leaves no trace, one they would not is skipped.

	SYSTEMS AND NAMED MEANINGS - `system 2over1` blocks whose `meaning nt-opening: ...` lines a scenario uses by
	name, and `system ours extends 2over1` overriding one - are systems.odin's.

	A DOUBLE-DUMMY LINE asks the solver about the WHOLE deal, after the seat lines have accepted it:

			scenario slam-zone "N-S hold 32+ between them and a major fit"
			  north-south: hcp >= 32 and (spades >= 8 or hearts >= 8)
			  double-dummy: north-south make slam

	`<north-south|east-west> make <game|slam|grand>` - game is 3NT, four of a major or five of a minor, slam
	12 tricks and grand 13, in any strain with either hand declaring. A deal the side cannot make it on is
	thrown away, and each kept deal's page shows its par and what each side makes. It is the expensive line:
	every deal the seat lines accept is solved, so the seat lines should do most of the narrowing. This
	package only RECORDS it (`Program.double_dummy`) - the solver is linked by the consumer (`sim_hooks`),
	which keeps this language free of it.

	WHY THE VOCABULARY IS INJECTED rather than imported: this package would otherwise depend on
	`bidding`, which is this repository's editorial content, and a language is not. Same seam as
	`combo.set_suit_book(suit_book.provider())`. It depends on `norn` freely — that IS the generic layer.

	DIAGNOSTICS CARRY FILE, LINE AND COLUMN, because a scenario file is something a person edits and a
	typo in one should read like a typo in a `.bml` does — not like a stack trace.
*/

import "base:runtime"
import "core:strings"
import "norn:norn"

// A source position, for diagnostics. Lines and columns are 1-based, as an editor counts them.
Position :: struct {
	file: string,
	line: int,
	col:  int,
}

Diagnostic :: struct {
	pos:     Position,
	message: string,
}

// ---------------------------------------------------------------------------------------------------
// The tree
//
// Deliberately small, and FLAT: every node is a value in one array and the operators hold indices rather
// than pointers. A scenario's whole program is a handful of nodes, so this keeps `eval` a switch over a
// slice, keeps the program one allocation, and makes it trivially copyable to a worker thread.

// Which number a generic atom reads off a hand.
Quantity :: enum {
	Hcp,
	Controls,
	Spades,
	Hearts,
	Diamonds,
	Clubs,
	Longest, // the length of the longest suit — the one shape question people ask most
	Seat, // the hand's place in the auction: 1 for the dealer, 2 for the dealer's left, ... (a TABLE word)
	// A partnership's combined OPC total (norn's `combined_opc`, no trump suit named): only on a partnership line
	// or in a side's group, since it is a judgement of two hands together and not a sum of two numbers.
	Opc,
}

Comparison :: enum {
	Less,
	Less_Equal,
	Equal,
	Not_Equal,
	Greater_Equal,
	Greater,
}

// `hcp >= 15`, or `hcp in 15..17` (the same node with `is_range` and both bounds).
Compare_Node :: struct {
	quantity: Quantity,
	op:       Comparison,
	value:    int,
	// A RANGE is one node rather than an `and` of two, because `hcp in 15..17` is one thought and one
	// diagnostic: bounds the wrong way round should complain about the range, not about half of it.
	is_range: bool,
	high:     int,
}

// HAND NUMBERS AGAINST EACH OTHER: `spades > hearts`, `spades + hearts >= 9`, `clubs + diamonds in 9..11`. A side
// is a SUM of one or more of a hand's numbers; the right is a number or another sum. What a rule like "the
// longer major first" or "nine cards in the majors" needs, and the one thing a range of fixed numbers cannot say.
// `seat` and `opc` are not summed: one is a place at the table, the other a judgement of two hands. (A single
// number against a plain number stays a `Compare_Node`.)
SUM_TERMS_MAX :: 4

Sum :: struct {
	terms: [SUM_TERMS_MAX]Quantity,
	count: int,
}

Sum_Compare_Node :: struct {
	left:      Sum,
	op:        Comparison,
	right:     Sum, // count 0: compare with `value`
	value:     int,
	is_range:  bool, // `left in value..high`
	high:      int,
}

// `is_strong_1c` — a name from the consumer's vocabulary, resolved at PARSE time so an unknown one is a
// diagnostic with a position rather than a silent false in a million-iteration generate loop.
Named_Node :: struct {
	name:  string,
	index: int, // into the vocabulary table
}

// A system's NAMED MEANING (`nt-opening`), expanded where it is used: `root` is its condition, in this
// program's own nodes; `system` is the system whose definition was used, `overrides` the next one up that
// defines it too ("" if none). See systems.odin.
Meaning_Node :: struct {
	name:         string,
	system:       string,
	overrides:    string,
	amended_by:   string, // the nearest system that amends it (`meaning x` with no condition), "" if none
	root:         int, // the core
	// The NAMED ALTERNATIVES in force (systems.odin): the meaning holds when its core does or any of these does,
	// and a deal kept only through one carries its name.
	alternatives: []Meaning_Alternative,
}

Meaning_Alternative :: struct {
	name: string,
	root: int,
}

// `holds(spades, ace)`
Holds_Node :: struct {
	suit: norn.Suit,
	rank: norn.Rank,
}

// `balanced` — norn's own definition, so the language and the compiled helpers agree on the word.
Balanced_Node :: struct {}

// The vulnerability as the hand's own side sees it - the way a player says it ("I'm at favourable"). TABLE words.
Vulnerability_Word :: enum {
	Vulnerable, // this side is vulnerable
	Favourable, // this side is not, the opponents are
	Unfavourable, // this side is, the opponents are not
}

Vulnerability_Node :: struct {
	word: Vulnerability_Word,
}

// `north(spades >= 5)`, `east-west(hcp < 15)`: a condition about ONE hand or side, inside a `deal:` line (or a
// meaning used there), which names the hand for every atom it holds. What lets one condition OR across seats:
// `north(spades >= 5) and south(spades >= 4) or north(hearts >= 5) and south(hearts >= 4)`. With `pair` set the
// group is a side, read as one combined hand like a partnership line.
Hand_Node :: struct {
	seat:  norn.Seat,
	pair:  bool,
	child: int,
}

// The operators index back into the same array. `-1` is "no child"; only a malformed tree has one, and
// `eval` treats it as false rather than indexing out of bounds.
Not_Node :: struct {
	child: int,
}

And_Node :: struct {
	left:  int,
	right: int,
}

Or_Node :: struct {
	left:  int,
	right: int,
}

Node :: union {
	Compare_Node,
	Sum_Compare_Node,
	Named_Node,
	Meaning_Node,
	Holds_Node,
	Balanced_Node,
	Vulnerability_Node,
	Hand_Node,
	Not_Node,
	And_Node,
	Or_Node,
}

// A `double-dummy:` line: which side, and what it must make. See the header.
Makes_Side :: enum {
	North_South,
	East_West,
}

Makes_Goal :: enum {
	Game,
	Slam,
	Grand,
}

Double_Dummy :: struct {
	side: Makes_Side,
	goal: Makes_Goal,
}

// One seat's condition: which seat, and the root of its tree. With `pair` set it is a PARTNERSHIP line —
// `seat` and its partner read as one combined hand — and `seat` is then North or East, the first word of
// `north-south` / `east-west`. `also` is 0 for the scenario's own lines and k for a line of its k-th
// ALTERNATIVE (`Program.alternatives[k - 1]`).
//
// A `deal:` line (`deal` set) belongs to no one seat: every atom in it is inside a hand's group (`Hand_Node`),
// and `seat`/`pair` are unused.
Seat_Rule :: struct {
	seat: norn.Seat,
	pair: bool,
	deal: bool,
	root: int,
	also: int,
}

/*
A parsed scenario: its metadata, its rules, and the arena the rules point into.

OWNED, and it says by whom. The strings are cloned out of the source text because the source is dropped
as soon as it is parsed and a scenario lives for the whole run; `allocator` is remembered so
`destroy_program` gives the memory back to the one it came from without the caller having to.
*/
Program :: struct {
	name:         string,
	description:  string,
	// The bidding system whose meanings the scenario uses (`system: 2over1`), "" for none: a hand type or a
	// partnership total that any system shares. The workbench's system picker shows a scenario under its
	// own system and, with "" here, under every one.
	system:       string,
	// The auction as a player writes it (`label:`), shown on the list's row; "" shows the name. And the name
	// before a rename (`formerly:`), which a lookup by name still answers.
	label:        string,
	formerly:     string,
	tags:         []string,
	rules:        []Seat_Rule,
	nodes:        []Node,
	double_dummy: Maybe(Double_Dummy), // the `double-dummy:` line, if the scenario has one
	// THE TABLE: a `dealer:` / `vulnerability:` line fixes that half; a `seat` or vulnerability word on a line
	// reads it. Either makes the scenario one whose deals are checked at their table (`norn.Table_Draw`).
	dealer:        Maybe(norn.Seat),
	vulnerability: Maybe(norn.Vulnerability),
	reads_table:   bool,
	// The names of the scenario's ALTERNATIVES (`also "<name>" <seat>: ...`), in the order they first appear.
	alternatives:  []string,
	// The names of the alternatives of the MEANINGS it uses, each once, in the order they first appear: what a
	// deal kept through one of them is labelled with (`explain`).
	meaning_alternatives: []string,
	source:       string, // the file it came from, for diagnostics and for the UI to show
	allocator:    runtime.Allocator,
}

destroy_program :: proc(program: ^Program) {
	delete(program.name, program.allocator)
	delete(program.description, program.allocator)
	delete(program.system, program.allocator)
	delete(program.label, program.allocator)
	delete(program.formerly, program.allocator)
	for tag in program.tags {
		delete(tag, program.allocator)
	}
	delete(program.tags, program.allocator)
	for node in program.nodes {
		// Only `Named_Node` owns a string; the rest are plain values.
		#partial switch n in node {
		case Named_Node:
			delete(n.name, program.allocator)
		case Meaning_Node:
			delete(n.name, program.allocator)
			delete(n.system, program.allocator)
			delete(n.overrides, program.allocator)
			delete(n.amended_by, program.allocator)
			for alternative in n.alternatives {
				delete(alternative.name, program.allocator)
			}
			delete(n.alternatives, program.allocator)
		}
	}
	delete(program.nodes, program.allocator)
	delete(program.rules, program.allocator)
	for name in program.alternatives {
		delete(name, program.allocator)
	}
	delete(program.alternatives, program.allocator)
	for name in program.meaning_alternatives {
		delete(name, program.allocator)
	}
	delete(program.meaning_alternatives, program.allocator)
	delete(program.source, program.allocator)
	program^ = {}
}

// ---------------------------------------------------------------------------------------------------
// The vocabulary
//
// The consumer's named predicates. `bidding` knows its own helpers; this package must not.

Vocabulary_Entry :: struct {
	name:        string,
	description: string,
	// Takes ONE seat's summary. Every helper in `bidding` has this shape
	// (`is_any_1c_opener(b[.North])`), which is why a seat line is the unit a name is written in.
	call:        proc(hand: norn.Hand_Summary) -> bool,
}

@(private)
g_vocabulary: []Vocabulary_Entry

/*
Install the named predicates a scenario file may use.

Called once at startup by the consumer. Names are resolved at PARSE time, so anything installed after a
file is parsed is invisible to it — which is the right way round: a file naming something unknown should
fail when it is read, with a position, rather than quietly evaluate to false for the length of a run.
*/
set_vocabulary :: proc(entries: []Vocabulary_Entry) {
	g_vocabulary = entries
}

vocabulary :: proc() -> []Vocabulary_Entry {
	return g_vocabulary
}

@(private)
find_in_vocabulary :: proc(name: string) -> (index: int, ok: bool) {
	for entry, i in g_vocabulary {
		if entry.name == name {
			return i, true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------------------------------
// Words the grammar knows

// The quantity a word names, if it names one.
@(private)
quantity_of :: proc(word: string) -> (quantity: Quantity, ok: bool) {
	switch word {
	case "hcp":
		return .Hcp, true
	case "controls":
		return .Controls, true
	case "spades":
		return .Spades, true
	case "hearts":
		return .Hearts, true
	case "diamonds":
		return .Diamonds, true
	case "clubs":
		return .Clubs, true
	case "longest":
		return .Longest, true
	case "seat":
		return .Seat, true
	case "opc":
		return .Opc, true
	}
	return {}, false
}

// A vulnerability word, both spellings: the language is written by players on either side of the Atlantic.
@(private)
vulnerability_word_of :: proc(word: string) -> (v: Vulnerability_Word, ok: bool) {
	switch word {
	case "vulnerable":
		return .Vulnerable, true
	case "favourable", "favorable":
		return .Favourable, true
	case "unfavourable", "unfavorable":
		return .Unfavourable, true
	}
	return {}, false
}

// The value of a `vulnerability:` line: who is vulnerable, named as the board's own vulnerability is.
@(private)
board_vulnerability_of :: proc(word: string) -> (v: norn.Vulnerability, ok: bool) {
	switch word {
	case "none", "nobody", "love-all":
		return .None, true
	case "north-south":
		return .North_South, true
	case "east-west":
		return .East_West, true
	case "both", "all":
		return .Both, true
	}
	return {}, false
}

/*
The `norn.Condition` a program is generated and measured with: its walker and the program, plus - when it
reads or fixes the table - what the table draw fixes. ONE place builds it, so the loader and the editor's check
cannot disagree about whether a scenario's deals are dealt at a table.
*/
condition :: proc(program: ^Program) -> norn.Condition {
	predicate := norn.Interpreted_Predicate {
		call = evaluate,
		data = program,
	}
	if len(program.alternatives) > 0 {
		predicate.explain = explain // a deal only an alternative kept is labelled with its name
	}
	if program.reads_table {
		predicate.table = norn.Table_Draw {
			dealer        = program.dealer,
			vulnerability = program.vulnerability,
		}
	}
	return predicate
}

// The seat a word names. FULL NAMES ONLY: `n`/`e`/`s`/`w` were considered and left out, because `s` for
// South beside `spades` in the same grammar is an ambiguity the reader has to carry.
@(private)
seat_of :: proc(word: string) -> (seat: norn.Seat, ok: bool) {
	switch word {
	case "north":
		return .North, true
	case "east":
		return .East, true
	case "south":
		return .South, true
	case "west":
		return .West, true
	}
	return {}, false
}

// The partnership a word names, as the seat that starts it. Spelled out like the seats, and in the one
// order bridge writes them: `ns` would be the abbreviation the seats already refused, and accepting
// `south-north` as well would give one condition two spellings for no reader's benefit.
@(private)
pair_of :: proc(word: string) -> (seat: norn.Seat, ok: bool) {
	switch word {
	case "north-south":
		return .North, true
	case "east-west":
		return .East, true
	}
	return {}, false
}

// North with South, East with West.
@(private)
partner_of :: proc(seat: norn.Seat) -> norn.Seat {
	switch seat {
	case .North:
		return .South
	case .East:
		return .West
	case .South:
		return .North
	case .West:
		return .East
	}
	return .South
}

// A side's two hands as ONE summary. The hands are disjoint, so the union per suit is exact: the combined
// length is the sum, the combined hcp is the sum, and `holds` is "either hand has it".
@(private)
combined :: proc(a, b: norn.Hand_Summary) -> (side: norn.Hand_Summary) {
	for suit in norn.Suit {
		side.suits[suit] = a.suits[suit] + b.suits[suit]
	}
	return
}

@(private)
suit_of :: proc(word: string) -> (suit: norn.Suit, ok: bool) {
	switch word {
	case "clubs":
		return .Clubs, true
	case "diamonds":
		return .Diamonds, true
	case "hearts":
		return .Hearts, true
	case "spades":
		return .Spades, true
	}
	return {}, false
}

@(private)
rank_of :: proc(word: string) -> (rank: norn.Rank, ok: bool) {
	switch word {
	case "two", "2":
		return .Two, true
	case "three", "3":
		return .Three, true
	case "four", "4":
		return .Four, true
	case "five", "5":
		return .Five, true
	case "six", "6":
		return .Six, true
	case "seven", "7":
		return .Seven, true
	case "eight", "8":
		return .Eight, true
	case "nine", "9":
		return .Nine, true
	case "ten", "10", "t":
		return .Ten, true
	case "jack", "j":
		return .Jack, true
	case "queen", "q":
		return .Queen, true
	case "king", "k":
		return .King, true
	case "ace", "a":
		return .Ace, true
	}
	return {}, false
}

// Lower-cased in temp memory. The language is case-insensitive in its keywords and seat names for the
// same reason BML is forgiving about spacing: it is written by hand, in a text editor, by someone who is
// thinking about bridge.
@(private)
folded :: proc(word: string) -> string {
	return strings.to_lower(word, context.temp_allocator)
}
