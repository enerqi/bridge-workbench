package scenario_dsl

/*
	dsl_test.odin — the language, without a window or a bidding system in the way.

	The vocabulary is INJECTED, so these tests supply their own two-entry one rather than importing
	`bidding`: what is under test is the language, and a test that needed this repository's bidding system
	to run would be testing the wrong thing. The real vocabulary is wired at startup by the consumer.

	★ THE ONE THAT MATTERS is `test_a_parsed_condition_agrees_with_the_compiled_one` at the bottom — the
	parity oracle. Every other test here says the parser did what the grammar says; that one says the
	INTERPRETED scenario accepts exactly the deals a hand-written Odin predicate accepts, over a seeded
	run. It is the same trick that verified the whole deal.exe → norn port, and it is what turns "does my
	expression mean what I think" from an opinion into a test.
*/

import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "norn:cli"
import "norn:norn"

// ---- a vocabulary to parse against ---------------------------------------------------------------

@(private = "file")
big_hand :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.hcp(hand) >= 16
}

@(private = "file")
five_spades :: proc(hand: norn.Hand_Summary) -> bool {
	return norn.suit_length(hand, .Spades) >= 5
}

@(private = "file")
install_test_vocabulary :: proc() {
	@(static) entries := [2]Vocabulary_Entry{}
	entries[0] = {"is_big", "16+ hcp", big_hand}
	entries[1] = {"is_five_spades", "5+ spades", five_spades}
	set_vocabulary(entries[:])
}

@(private = "file")
parse_one :: proc(t: ^testing.T, source: string) -> (program: Program, ok: bool) {
	install_test_vocabulary()
	programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
	for diagnostic in diagnostics {
		testing.expectf(t, false, "unexpected diagnostic: %s", diagnostic_text(diagnostic, context.temp_allocator))
	}
	if len(programs) != 1 {
		testing.expectf(t, false, "expected one scenario, parsed %d", len(programs))
		return {}, false
	}
	return programs[0], true
}

// ---- the grammar ---------------------------------------------------------------------------------

@(test)
test_a_scenario_parses_its_header_body_and_tags :: proc(t: ^testing.T) {
	program, ok := parse_one(
		t,
		`scenario my-1c "strong 1C; South 5+ hearts"
  tags: mine, slam
  north: is_big
  south: hearts >= 5
`,
	)
	if !ok {return}
	testing.expect_value(t, program.name, "my-1c")
	testing.expect_value(t, program.description, "strong 1C; South 5+ hearts")
	testing.expect_value(t, len(program.tags), 2)
	testing.expect_value(t, program.tags[0], "mine")
	testing.expect_value(t, program.tags[1], "slam")
	// TWO SEAT RULES, which AND together — the compiled registry's `&&`, said in the grammar.
	testing.expect_value(t, len(program.rules), 2)
	testing.expect_value(t, program.rules[0].seat, norn.Seat.North)
	testing.expect_value(t, program.rules[1].seat, norn.Seat.South)
}

// The operators, checked by what they ACCEPT rather than by the shape of the tree: a test that asserted
// node indices would pin the parser's internals rather than the language's meaning.
@(test)
test_the_operators_mean_what_they_say :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		expression: string,
		hcp:        int,
		spades:     int,
		expected:   bool,
	} {
		{"hcp >= 15", 15, 3, true},
		{"hcp >= 15", 14, 3, false},
		{"hcp in 15..17", 16, 3, true},
		{"hcp in 15..17", 18, 3, false},
		{"hcp > 10 and spades >= 5", 12, 5, true},
		{"hcp > 10 and spades >= 5", 12, 4, false},
		{"hcp > 20 or spades >= 5", 12, 5, true},
		{"not hcp > 20", 12, 5, true},
		{"not (hcp > 10 or spades >= 5)", 12, 5, false},
		// PRECEDENCE: `or` binds loosest, so this is `a or (b and c)` and the low hcp cannot fail it.
		{"hcp >= 30 or spades >= 5 and hcp >= 10", 12, 5, true},
		{"is_big", 16, 3, true},
		{"is_big", 15, 3, false},
		{"is_big and is_five_spades", 16, 5, true},
	}
	for c in cases {
		source := strings.concatenate({"scenario x \"y\"\n  north: ", c.expression, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		if len(diagnostics) != 0 || len(programs) != 1 {
			testing.expectf(t, false, "%q did not parse", c.expression)
			continue
		}
		program := programs[0]
		summary := norn.Deal_Summary{}
		summary[.North] = hand_with(c.hcp, c.spades)
		got := evaluate(summary, {}, &program)
		testing.expectf(
			t,
			got == c.expected,
			"%q with %d hcp and %d spades gave %v",
			c.expression,
			c.hcp,
			c.spades,
			got,
		)
	}
}

/*
A hand with a chosen hcp AND a chosen spade length — the two things the cases above vary.

WRITTEN TWICE. The first version put the honours in SPADES, so "15 hcp with 3 spades" asked for more
points than three spade cards can hold (A+K+Q is 9) and five cases failed against a language that was
working correctly. Honours go wherever there is room now: each suit takes them from the top while points
remain, and the shape is fixed first so the two are independent.
*/
@(private = "file")
hand_with :: proc(hcp: int, spades: int) -> norn.Hand_Summary {
	hand: norn.Hand
	counts := [4]int{}
	counts[0] = spades // spades
	rest := 13 - spades
	for i in 1 ..< 4 {
		share := rest / (4 - i)
		counts[i] = share
		rest -= share
	}

	suits := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}
	honours := []norn.Rank{.Ace, .King, .Queen, .Jack}
	values := []int{4, 3, 2, 1}
	low := []norn.Rank{.Two, .Three, .Four, .Five, .Six, .Seven, .Eight, .Nine, .Ten}

	remaining := hcp
	placed := 0
	for suit, s in suits {
		used := [4]bool{} // which honours this suit has already spent
		lows := 0
		for _ in 0 ..< counts[s] {
			// THE BEST AFFORDABLE honour, not the next one in order. Taking them strictly A-K-Q-J meant a
			// suit that could not afford a King stopped placing honours entirely, stranding the last two
			// points and making several cases unbuildable — which read as the language being wrong.
			best := -1
			for value, h in values {
				if !used[h] && value <= remaining && (best < 0 || value > values[best]) {
					best = h
				}
			}
			rank: norn.Rank
			if best >= 0 {
				rank = honours[best]
				remaining -= values[best]
				used[best] = true
			} else {
				rank = low[lows]
				lows += 1
			}
			hand[placed] = norn.make_card(suit, rank)
			placed += 1
		}
	}
	return norn.summarize(hand)
}

@(test)
test_holds_and_balanced_read_norns_own_definitions :: proc(t: ^testing.T) {
	program, ok := parse_one(t, "scenario x \"y\"\n  north: holds(spades, ace) and not balanced\n")
	if !ok {return}
	testing.expect_value(t, len(program.rules), 1)
	testing.expect_value(t, len(program.nodes), 4) // holds, balanced, not, and
}

// ---- diagnostics ---------------------------------------------------------------------------------

// A BAD SCENARIO COSTS ONE DIAGNOSTIC AND DOES NOT EAT THE NEXT ONE. That is the bargain the header
// promises, and the reason parsing continues rather than stopping at the first problem.
@(test)
test_a_broken_scenario_does_not_lose_the_ones_after_it :: proc(t: ^testing.T) {
	install_test_vocabulary()
	programs, diagnostics := parse(
		`scenario broken "this one is wrong"
  north: hcp >= banana

scenario fine "this one is not"
  north: hcp >= 12
`,
		"test.scenario",
		context.temp_allocator,
	)
	testing.expect(t, len(diagnostics) > 0, "the bad condition should be reported")
	testing.expect_value(t, len(programs), 1)
	if len(programs) == 1 {
		testing.expect_value(t, programs[0].name, "fine")
	}
}

// EVERY DIAGNOSTIC CARRIES A PLACE. A scenario file is edited by hand, so "something is wrong" without a
// line is barely better than nothing.
@(test)
test_a_diagnostic_names_its_line_and_column :: proc(t: ^testing.T) {
	install_test_vocabulary()
	_, diagnostics := parse(
		"scenario x \"y\"\n  north: hcp >= 12\n  south: not_a_thing\n",
		"mine.scenario",
		context.temp_allocator,
	)
	testing.expect_value(t, len(diagnostics), 1)
	if len(diagnostics) != 1 {return}
	testing.expect_value(t, diagnostics[0].pos.line, 3)
	testing.expect(t, diagnostics[0].pos.col > 1, "the column should point at the word, not the line start")
	text := diagnostic_text(diagnostics[0], context.temp_allocator)
	testing.expect(t, strings.contains(text, "mine.scenario:3:"), text)
	testing.expect(t, strings.contains(text, "not_a_thing"), text)
}

// An unknown KEY is reported rather than ignored: a misspelled `tag:` that did nothing would be a
// scenario quietly missing from a group, which is the class of bug nobody notices.
@(test)
test_an_unknown_key_is_reported :: proc(t: ^testing.T) {
	install_test_vocabulary()
	_, diagnostics := parse(
		"scenario x \"y\"\n  tag: mine\n  north: hcp >= 12\n",
		"f.scenario",
		context.temp_allocator,
	)
	testing.expect_value(t, len(diagnostics), 1)
}

// A range the wrong way round is a mistake about the RANGE, so it is reported once as one.
@(test)
test_a_backwards_range_is_one_diagnostic :: proc(t: ^testing.T) {
	install_test_vocabulary()
	programs, diagnostics := parse("scenario x \"y\"\n  north: hcp in 17..15\n", "f.scenario", context.temp_allocator)
	testing.expect_value(t, len(diagnostics), 2) // the range, and then "no seat condition"
	testing.expect_value(t, len(programs), 0)
	testing.expect(t, strings.contains(diagnostics[0].message, "way round"), diagnostics[0].message)
}

// Anything the condition does not use is an error, not ignored: `8..11x` used to read as `8..11`, and a
// missing `and` dropped the rest of the line.
@(test)
test_text_after_the_condition_is_reported :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		line, word: string,
		col:        int,
	} {
		{"  south: hearts >= 5 and hcp in 8..11x", "x", 38},
		{"  north: hcp >= 12 balanced", "balanced", 20},
		{"  north: (hcp >= 12) )", ")", 22},
	}
	for c in cases {
		programs, diagnostics := parse(
			strings.concatenate({"scenario x \"y\"\n", c.line, "\n"}, context.temp_allocator),
			"f.scenario",
			context.temp_allocator,
		)
		testing.expect_value(t, len(programs), 0)
		testing.expectf(t, len(diagnostics) >= 1, "%q: no diagnostic", c.line)
		if len(diagnostics) == 0 {continue}
		testing.expectf(t, strings.contains(diagnostics[0].message, c.word), "%q: %s", c.line, diagnostics[0].message)
		testing.expect_value(t, diagnostics[0].pos.col, c.col)
	}
}

// ---- the parity oracle ---------------------------------------------------------------------------

// The compiled form of the scenario written as text below. Deliberately hand-written, in Odin, the way
// every entry in `bidding/scenarios.odin` is.
@(private = "file")
compiled :: proc(summary: norn.Deal_Summary) -> bool {
	north := summary[.North]
	south := summary[.South]
	return(
		norn.hcp(north) >= 16 &&
		norn.suit_length(south, .Hearts) >= 5 &&
		norn.hcp(south) >= 8 &&
		norn.hcp(south) <= 11 \
	)
}

/*
★ AN INTERPRETED SCENARIO ACCEPTS EXACTLY WHAT THE COMPILED ONE ACCEPTS.

The point of the whole package, and the only test here that could catch the language MEANING something
other than it reads. Both conditions see the same deals — one seeded stream, replayed — and every single
verdict has to match, not merely the totals: two conditions can accept the same NUMBER of deals while
disagreeing about which.
*/
@(test)
test_a_parsed_condition_agrees_with_the_compiled_one :: proc(t: ^testing.T) {
	program, ok := parse_one(
		t,
		`scenario parity "strong North, South 5+ hearts and 8-11"
  north: hcp >= 16
  south: hearts >= 5 and hcp in 8..11
`,
	)
	if !ok {return}

	// The same deals for both, by summarising each one once and asking both conditions about it.
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20260902)
	interpreted_accepts := 0
	compiled_accepts := 0
	for _ in 0 ..< 20_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		from_text := evaluate(summary, {}, &program)
		from_code := compiled(summary)
		testing.expectf(
			t,
			from_text == from_code,
			"the two disagreed: text said %v, code said %v",
			from_text,
			from_code,
		)
		if from_text {interpreted_accepts += 1}
		if from_code {compiled_accepts += 1}
	}
	testing.expect_value(t, interpreted_accepts, compiled_accepts)
	// And it is not vacuously equal because neither ever fires.
	testing.expect(t, compiled_accepts > 0, "the condition never accepted anything — the oracle proves nothing")
}

// ---- loading from a directory --------------------------------------------------------------------

/*
A DIRECTORY OF FILES, END TO END: parse, own, and hand back `cli.Scenario` values.

It also frees what it loaded, and that half is not ceremony — it is the regression test for a real crash.
The diagnostics' file names were BORROWED from the loader's temp-allocated directory entries while
`destroy_loaded` freed them, so the first run that produced a diagnostic at all exited with heap
corruption (0xC0000374). A happy path never finds that; a test that loads a BROKEN file and then destroys
the result does.
*/
@(test)
test_a_directory_of_scenario_files_loads_and_frees :: proc(t: ^testing.T) {
	install_test_vocabulary()

	temp, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {return}
	folder, join_err := filepath.join({temp, "scenario-dsl-load-test"}, context.temp_allocator)
	if join_err != nil {return}
	_ = os.make_directory(folder)
	defer os.remove_all(folder)

	good, _ := filepath.join({folder, "good.scenario"}, context.temp_allocator)
	bad, _ := filepath.join({folder, "bad.scenario"}, context.temp_allocator)
	if os.write_entire_file(
		   good,
		   transmute([]u8)string("scenario mine \"my own\"\n  tags: mine\n  north: is_big\n"),
	   ) !=
	   nil {
		return
	}
	if os.write_entire_file(bad, transmute([]u8)string("scenario broken \"no\"\n  north: hcp >= nonsense\n")) != nil {
		return
	}

	loaded := load_directories({folder})
	// FREED HERE, deliberately inside the test rather than left to the process: the free is what crashed.
	defer destroy_loaded(&loaded)

	testing.expect_value(t, len(loaded.scenarios), 1)
	if len(loaded.scenarios) == 1 {
		testing.expect_value(t, loaded.scenarios[0].name, "mine")
		testing.expect_value(t, loaded.scenarios[0].description, "my own")
		// It is INTERPRETED, which is what makes it usable beside the compiled registry.
		testing.expect(t, cli.is_interpreted(loaded.scenarios[0]), "a loaded scenario must carry a program")
		testing.expect_value(t, len(loaded.tags[0]), 1)
		testing.expect_value(t, loaded.tags[0][0], "mine")
	}
	// The broken file is reported, with the file it came from, and does not stop the good one loading.
	testing.expect(t, len(loaded.diagnostics) > 0, "the broken file should be reported")
	if len(loaded.diagnostics) > 0 {
		testing.expect(
			t,
			strings.contains(diagnostic_text(loaded.diagnostics[0], context.temp_allocator), "bad.scenario"),
			"a diagnostic should name the file it came from",
		)
	}
}

// A directory that is not there is a normal state for a list of places to look, not an error.
@(test)
test_a_missing_directory_is_not_an_error :: proc(t: ^testing.T) {
	install_test_vocabulary()
	loaded := load_directories({"C:/no/such/place/at/all", ""})
	defer destroy_loaded(&loaded)
	testing.expect_value(t, len(loaded.scenarios), 0)
	testing.expect_value(t, len(loaded.diagnostics), 0)
}

// ---- the round trip ------------------------------------------------------------------------------

/*
`parse -> write -> parse` reaches the same tree, over expressions that exercise every printing decision:
the precedence both ways round, `not` over a compound, a range, `holds`, `balanced` and a name.

WHY THE SECOND PARSE rather than a string comparison against the source. The unparser prints what the
tree MEANS, one way — a range where the file wrote two comparisons, brackets where the shape needs them
rather than where they were typed — so the text is deliberately not the input. What must survive is the
MEANING, and the only honest way to ask that is to read the printed text back and compare the trees.

The comparison is over the printed form of BOTH, which is a canonical form: two trees that print the
same accept the same hands, and a printer bug that lost a node would have to lose it identically on the
second pass to hide here.
*/
@(test)
test_a_program_survives_being_written_out_and_read_back :: proc(t: ^testing.T) {
	install_test_vocabulary()
	expressions := []string {
		"hcp >= 15",
		"hcp in 15..17",
		"balanced and hcp in 15..17",
		"is_big or is_five_spades",
		"is_big and (is_five_spades or hearts >= 5)",
		"(is_big or is_five_spades) and hcp <= 20",
		"not (is_big and balanced)",
		"not is_big or hearts != 4",
		"holds(spades, ace) and holds(clubs, king)",
		"longest >= 6 and controls in 2..4 and not balanced",
		"seat = 3 and (favourable or not vulnerable)",
		"seat in 1..2 and unfavourable",
	}
	for expression in expressions {
		source := strings.concatenate(
			{"scenario round-trip \"a description\"\n  tags: mine, slam\n  north: ", expression, "\n"},
			context.temp_allocator,
		)
		first, ok := parse_one(t, source)
		if !ok {continue}
		defer destroy_program(&first)

		printed := write_program(&first, context.temp_allocator)
		second_programs, diagnostics := parse(printed, "printed.scenario", context.temp_allocator)
		for diagnostic in diagnostics {
			testing.expectf(
				t,
				false,
				"the printed form of %q did not parse: %s",
				expression,
				diagnostic_text(diagnostic, context.temp_allocator),
			)
		}
		if len(second_programs) != 1 {
			testing.expectf(t, false, "the printed form of %q gave %d scenarios", expression, len(second_programs))
			continue
		}
		second := second_programs[0]
		defer destroy_program(&second)

		testing.expect_value(t, second.name, first.name)
		testing.expect_value(t, second.description, first.description)
		testing.expect_value(t, len(second.tags), len(first.tags))
		testing.expectf(
			t,
			write_program(&second, context.temp_allocator) == printed,
			"%q did not survive the round trip: %q",
			expression,
			printed,
		)
	}
}

// The printer's own output, for the two decisions a round trip cannot see because both sides make them:
// that a range prints as a range, and that the brackets are the ones the SHAPE needs rather than the ones
// that were typed. A test that only round-tripped would pass on a printer that bracketed everything.
@(test)
test_the_printer_spells_the_tree_the_short_way :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		written:  string,
		expected: string,
	} {


		// Redundant brackets go: `and` binds tighter than `or` already.
		{"(is_big and balanced) or is_five_spades", "is_big and balanced or is_five_spades"},
		// And they appear where the shape needs them, whether or not the author typed them.
		{"is_big and (balanced or is_five_spades)", "is_big and (balanced or is_five_spades)"},
		{"not (is_big or balanced)", "not (is_big or balanced)"},
		{"hcp in 8..11", "hcp in 8..11"},
		{"hcp != 10", "hcp != 10"},
	}
	for c in cases {
		source := strings.concatenate({"scenario p\n  north: ", c.written, "\n"}, context.temp_allocator)
		program, ok := parse_one(t, source)
		if !ok {continue}
		defer destroy_program(&program)
		printed := write_program(&program, context.temp_allocator)
		testing.expect_value(
			t,
			printed,
			strings.concatenate({"scenario p\n  north: ", c.expected, "\n"}, context.temp_allocator),
		)
	}
}

// ---- partnership lines ---------------------------------------------------------------------------

// Cards placed by hand rather than dealt, so every combined number below can be checked on paper. Short
// "hands" are fine: nothing a partnership line reads needs thirteen cards.
@(private = "file")
two_sides :: proc() -> (summary: norn.Deal_Summary) {
	// North: S AK2, H A - 11 hcp, 5 controls.  South: S QJ543, C AK - 10 hcp, 3 controls.
	summary[.North].suits[.Spades] = {.Ace, .King, .Two}
	summary[.North].suits[.Hearts] = {.Ace}
	summary[.South].suits[.Spades] = {.Queen, .Jack, .Five, .Four, .Three}
	summary[.South].suits[.Clubs] = {.Ace, .King}
	// East: H KQJ - 6 hcp. West: nothing. So north-south must not see these, and east-west must.
	summary[.East].suits[.Hearts] = {.King, .Queen, .Jack}
	return
}

/*
A PARTNERSHIP LINE READS THE SIDE'S TWO HANDS AS ONE.

Every case mixes the two hands on purpose: 21 hcp is neither hand's count, eight spades is neither hand's
length, and the two aces in the `holds` case sit in different hands — so a line that read only its first
seat would fail them all.
*/
@(test)
test_a_partnership_line_reads_both_hands_as_one :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		line:     string,
		expected: bool,
	} {
		{"north-south: hcp = 21", true},
		{"north-south: hcp >= 22", false},
		{"north-south: spades >= 8", true}, // 3 opposite 5: the fit
		{"north-south: spades >= 9", false},
		{"north-south: longest = 8", true}, // the longest COMBINED suit
		{"north-south: controls = 8", true},
		{"north-south: holds(hearts, ace) and holds(clubs, ace)", true}, // one ace in each hand
		{"north-south: holds(hearts, king)", false}, // East's card, not this side's
		{"east-west: hcp = 6", true},
		{"east-west: hearts = 3 and spades = 0", true},
		// Lines AND, partnership and seat alike.
		{"north: hcp = 11\n  north-south: hcp = 21", true},
		{"south: hcp = 11\n  north-south: hcp = 21", false},
	}
	summary := two_sides()
	for c in cases {
		source := strings.concatenate({"scenario x \"y\"\n  ", c.line, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		if len(diagnostics) != 0 || len(programs) != 1 {
			testing.expectf(t, false, "%q did not parse", c.line)
			continue
		}
		program := programs[0]
		got := evaluate(summary, {}, &program)
		testing.expectf(t, got == c.expected, "%q gave %v", c.line, got)
	}
}

// A ONE-HAND WORD ON A PARTNERSHIP LINE IS A DIAGNOSTIC, at the word, never a quiet evaluation: a side's
// 26 cards are never "balanced", and a named helper asked about them would answer with something that
// reads like a verdict.
@(test)
test_one_hand_words_are_refused_on_a_partnership_line :: proc(t: ^testing.T) {
	install_test_vocabulary()
	lines := []string{"north-south: balanced", "east-west: is_big", "north-south: hcp >= 20 and not balanced"}
	for line in lines {
		source := strings.concatenate({"scenario x \"y\"\n  ", line, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "f.scenario", context.temp_allocator)
		testing.expectf(t, len(programs) == 0, "%q should not have produced a scenario", line)
		// The word, and then "a scenario needs at least one seat condition".
		testing.expectf(t, len(diagnostics) == 2, "%q: expected 2 diagnostics, got %d", line, len(diagnostics))
		if len(diagnostics) == 0 {continue}
		testing.expectf(
			t,
			strings.contains(diagnostics[0].message, "one hand"),
			"%q: %s",
			line,
			diagnostics[0].message,
		)
		// The column is the word's, not the line's: two spaces of indent, 1-based, after the last space.
		word_col := strings.last_index(line, " ") + 4
		testing.expectf(
			t,
			diagnostics[0].pos.col == word_col,
			"%q: column %d, expected %d",
			line,
			diagnostics[0].pos.col,
			word_col,
		)
	}
	// And the same words stay legal on a seat line beside a partnership line.
	_, ok := parse_one(t, "scenario x \"y\"\n  north: balanced and is_big\n  north-south: hcp >= 25\n")
	testing.expect(t, ok, "one-hand words on a seat line must still parse")
}

@(test)
test_a_side_that_is_not_a_partnership_is_an_unknown_key :: proc(t: ^testing.T) {
	install_test_vocabulary()
	_, diagnostics := parse(
		"scenario x \"y\"\n  north-east: hcp >= 20\n  north: hcp >= 12\n",
		"f.scenario",
		context.temp_allocator,
	)
	testing.expect_value(t, len(diagnostics), 1)
	if len(diagnostics) == 1 {
		testing.expect(t, strings.contains(diagnostics[0].message, "north-south"), diagnostics[0].message)
	}
}

// The compiled forms, written the way `bidding/scenarios.odin` writes them — the first is
// `slam-hands-32-plus-hcp` verbatim.
@(private = "file")
compiled_32_plus :: proc(b: norn.Deal_Summary) -> bool {
	return norn.hcp(b[.North]) + norn.hcp(b[.South]) >= 32
}

@(private = "file")
compiled_fit_and_stopper :: proc(b: norn.Deal_Summary) -> bool {
	ns_spades := norn.suit_length(b[.North], .Spades) + norn.suit_length(b[.South], .Spades)
	ns_hearts := norn.suit_length(b[.North], .Hearts) + norn.suit_length(b[.South], .Hearts)
	ew_controls := norn.controls(b[.East]) + norn.controls(b[.West])
	ew_spade_ace := norn.holds(b[.East], .Spades, .Ace) || norn.holds(b[.West], .Spades, .Ace)
	return(
		norn.hcp(b[.North]) >= 12 &&
		norn.hcp(b[.North]) + norn.hcp(b[.South]) >= 24 &&
		(ns_spades >= 8 || ns_hearts >= 8) &&
		(ew_spade_ace || ew_controls >= 5) \
	)
}

/*
★ THE PARITY ORACLE, FOR PARTNERSHIP LINES. Same shape as the seat-line oracle above — one seeded stream,
every verdict compared — over the scenario that motivated the feature (`slam-hands-32-plus-hcp`, which
had no text form) and over one that mixes a seat line, a fit and the defending side's holdings.
*/
@(test)
test_a_partnership_condition_agrees_with_the_compiled_one :: proc(t: ^testing.T) {
	cases := []struct {
		source:   string,
		compiled: proc(b: norn.Deal_Summary) -> bool,
	} {
		{"scenario slam-hands \"N-S 32+\"\n  north-south: hcp >= 32\n", compiled_32_plus},
		{
			"scenario fit \"x\"\n  north: hcp >= 12\n  north-south: hcp >= 24 and (spades >= 8 or hearts >= 8)\n  east-west: holds(spades, ace) or controls >= 5\n",
			compiled_fit_and_stopper,
		},
	}
	for c in cases {
		program, ok := parse_one(t, c.source)
		if !ok {continue}

		state: rand.Xoshiro256_Random_State
		context.random_generator = norn.seeded_xoshiro(&state, 20261003)
		accepted := 0
		disagreements := 0
		for _ in 0 ..< 20_000 {
			summary := norn.summarize_deal(norn.deal_hands())
			from_text := evaluate(summary, {}, &program)
			if from_text != c.compiled(summary) {
				disagreements += 1
			}
			if from_text {accepted += 1}
		}
		testing.expectf(
			t,
			disagreements == 0,
			"%q: %d deals where text and code disagreed",
			program.name,
			disagreements,
		)
		testing.expectf(t, accepted > 0, "%q never accepted anything — the oracle proves nothing", program.name)
	}
}

// The printer names a side the way the parser reads it, and keeps it apart from the seat lines.
@(test)
test_a_partnership_line_prints_and_reads_back :: proc(t: ^testing.T) {
	source := "scenario p\n  north: is_big\n  north-south: hcp >= 32 and (spades >= 8 or hearts >= 8)\n  east-west: holds(spades, ace)\n"
	program, ok := parse_one(t, source)
	if !ok {return}
	defer destroy_program(&program)
	printed := write_program(&program, context.temp_allocator)
	testing.expect_value(t, printed, source)

	again, again_ok := parse_one(t, printed)
	if !again_ok {return}
	defer destroy_program(&again)
	testing.expect_value(t, len(again.rules), 3)
	testing.expect(
		t,
		!again.rules[0].pair && again.rules[1].pair && again.rules[2].pair,
		"the pair flags did not survive",
	)
	testing.expect_value(t, again.rules[2].seat, norn.Seat.East)
}

// ---- the double-dummy line -------------------------------------------------------------------------

// `double-dummy: <side> make <goal>` is recorded on the program (the consumer links the solver), prints
// back as it was meant, and a bad or second one is a diagnostic rather than silently ignored.
@(test)
test_a_double_dummy_line_is_recorded_and_printed :: proc(t: ^testing.T) {
	cases := []struct {
		line:  string,
		want:  Double_Dummy,
		print: string,
	} {
		{"north-south make slam", {.North_South, .Slam}, "north-south make slam"},
		{"East-West makes game", {.East_West, .Game}, "east-west make game"},
		{"north-south make grand slam", {.North_South, .Grand}, "north-south make grand"},
		{"north-south make small slam", {.North_South, .Slam}, "north-south make slam"},
	}
	for c in cases {
		source := strings.concatenate(
			{"scenario dd \"x\"\n  north: hcp >= 15\n  double-dummy: ", c.line, "\n"},
			context.temp_allocator,
		)
		program, ok := parse_one(t, source)
		if !ok {continue}
		defer destroy_program(&program)
		got, has := program.double_dummy.?
		testing.expectf(t, has && got == c.want, "%q read as %v", c.line, program.double_dummy)
		printed := write_program(&program, context.temp_allocator)
		testing.expectf(
			t,
			strings.contains(
				printed,
				strings.concatenate({"  double-dummy: ", c.print, "\n"}, context.temp_allocator),
			),
			"%q printed as %q",
			c.line,
			printed,
		)
		// And the printed form reads back the same.
		again, _ := parse(printed, "printed.scenario", context.temp_allocator)
		if len(again) == 1 {
			back, back_has := again[0].double_dummy.?
			testing.expectf(t, back_has && back == c.want, "%q did not survive the round trip", c.line)
			destroy_program(&again[0])
		}
	}

	none, ok := parse_one(t, "scenario plain \"x\"\n  north: hcp >= 15\n")
	if ok {
		_, has := none.double_dummy.?
		testing.expect(t, !has, "no line, no double-dummy requirement")
		destroy_program(&none)
	}

	install_test_vocabulary()
	for bad in ([]string {
			"  double-dummy: north make slam\n", // a seat is not a side
			"  double-dummy: north-south slam\n", // no `make`
			"  double-dummy: north-south make partscore\n", // no such goal
			"  double-dummy: north-south make slam\n  double-dummy: east-west make game\n", // two
		}) {
		source := strings.concatenate({"scenario dd \"x\"\n  north: hcp >= 15\n", bad}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		testing.expectf(t, len(diagnostics) == 1, "%q gave %d diagnostics", bad, len(diagnostics))
		for &program in programs {
			destroy_program(&program)
		}
	}
}

// ---- the table: seat and vulnerability -------------------------------------------------------------

// `seat` counts from the dealer, clockwise; the vulnerability words are the hand's own side's view.
@(test)
test_seat_and_vulnerability_read_the_table :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		expression: string,
		dealer:     norn.Seat,
		vul:        norn.Vulnerability,
		expected:   bool,
	} {
		{"seat = 1", .North, .None, true}, // North dealt
		{"seat = 3", .South, .None, true}, // South, West, North
		{"seat = 2", .West, .None, true},
		{"seat = 4", .East, .None, true},
		{"seat = 3", .East, .None, false},
		{"seat in 3..4", .East, .None, true},
		{"vulnerable", .North, .North_South, true},
		{"vulnerable", .North, .East_West, false},
		{"favourable", .North, .East_West, true},
		{"favorable", .North, .Both, false}, // both spellings
		{"unfavourable", .North, .North_South, true},
		{"unfavourable", .North, .Both, false},
		{"not vulnerable and not favourable", .North, .None, true}, // love all
	}
	for c in cases {
		source := strings.concatenate({"scenario x \"y\"\n  north: ", c.expression, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "test.scenario", context.temp_allocator)
		if len(diagnostics) != 0 || len(programs) != 1 {
			testing.expectf(t, false, "%q did not parse", c.expression)
			continue
		}
		program := programs[0]
		testing.expectf(t, program.reads_table, "%q reads the table", c.expression)
		got := evaluate({}, norn.Table{vulnerability = c.vul, dealer = c.dealer}, &program)
		testing.expectf(t, got == c.expected, "%q, %v dealing at %v: %v", c.expression, c.dealer, c.vul, got)
	}

	// A partnership line reads its side's vulnerability, but has no one seat.
	side, ok := parse_one(t, "scenario x\n  east-west: favourable\n")
	if ok {
		testing.expect(t, evaluate({}, norn.Table{vulnerability = .North_South, dealer = .North}, &side), "E-W at favourable")
		testing.expect(t, !evaluate({}, norn.Table{vulnerability = .East_West, dealer = .North}, &side), "E-W at unfavourable")
	}
	_, diagnostics := parse("scenario x\n  north-south: seat = 1\n", "f.scenario", context.temp_allocator)
	testing.expect(t, len(diagnostics) > 0 && strings.contains(diagnostics[0].message, "one hand"), "`seat` on a partnership line is refused")

	// A scenario without a table word does not ask for a table, so its runs keep their random stream.
	plain, plain_ok := parse_one(t, "scenario x\n  north: hcp >= 10\n")
	if plain_ok {
		testing.expect(t, !plain.reads_table, "no table word, no table")
		_, asks := norn.condition_table(condition(&plain))
		testing.expect(t, !asks, "and the condition does not ask for one")
	}
}

// `dealer:` and `vulnerability:` FIX the table: recorded, printed back, handed to the draw - and a bad or a
// second one is a diagnostic.
@(test)
test_dealer_and_vulnerability_lines_fix_the_table :: proc(t: ^testing.T) {
	source := "scenario w2 \"weak two, third seat\"\n  dealer: south\n  vulnerability: east-west\n  north: longest = 6 and hcp in 3..10\n"
	program, ok := parse_one(t, source)
	if !ok {return}
	defer destroy_program(&program)
	testing.expect_value(t, program.dealer.? or_else .North, norn.Seat.South)
	testing.expect_value(t, program.vulnerability.? or_else .None, norn.Vulnerability.East_West)
	testing.expect(t, program.reads_table, "a fixed table is a table")
	testing.expect_value(t, write_program(&program, context.temp_allocator), source)

	draw, asks := norn.condition_table(condition(&program))
	testing.expect(t, asks, "the condition asks for a table")
	testing.expect_value(t, draw.dealer.? or_else .North, norn.Seat.South)
	testing.expect_value(t, draw.vulnerability.? or_else .None, norn.Vulnerability.East_West)

	install_test_vocabulary()
	for bad in ([]string {
			"  dealer: northeast\n",
			"  dealer: south\n  dealer: north\n",
			"  vulnerability: ns\n",
			"  vul: both\n  vulnerability: none\n",
		}) {
		text := strings.concatenate({"scenario x\n  north: hcp >= 10\n", bad}, context.temp_allocator)
		programs, diagnostics := parse(text, "f.scenario", context.temp_allocator)
		testing.expectf(t, len(diagnostics) == 1, "%q gave %d diagnostics", bad, len(diagnostics))
		for &p in programs {
			destroy_program(&p)
		}
	}
}

// ★ THE PARITY ORACLE FOR THE TABLE: a third-seat, not-unfavourable weak two as text against the same thing
// in Odin, over a seeded stream of deals EACH AT A DRAWN TABLE, every verdict compared.
@(private = "file")
compiled_third_seat_weak_two :: proc(b: norn.Deal_Summary, table: norn.Table) -> bool {
	dealer := table.dealer.? or_else .North
	third := (int(norn.Seat.North) - int(dealer) + 4) %% 4 == 2
	ours := norn.vulnerable(table.vulnerability, .North)
	theirs := norn.vulnerable(table.vulnerability, .East)
	longest := 0
	for suit in norn.Suit {
		longest = max(longest, norn.suit_length(b[.North], suit))
	}
	return third && !(ours && !theirs) && longest == 6 && norn.hcp(b[.North]) >= 3 && norn.hcp(b[.North]) <= 10
}

@(test)
test_a_table_condition_agrees_with_the_compiled_one :: proc(t: ^testing.T) {
	program, ok := parse_one(t, "scenario w2\n  north: seat = 3 and not unfavourable\n  north: longest = 6 and hcp in 3..10\n")
	if !ok {return}
	defer destroy_program(&program)
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20261104)
	accepted, disagreements := 0, 0
	for _ in 0 ..< 40_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		table := norn.draw_condition_table({})
		from_text := evaluate(summary, table, &program)
		if from_text != compiled_third_seat_weak_two(summary, table) {
			disagreements += 1
		}
		if from_text {accepted += 1}
	}
	testing.expectf(t, disagreements == 0, "%d deals where text and code disagreed", disagreements)
	testing.expectf(t, accepted > 0, "never accepted anything - the oracle proves nothing")
}

// ---- alternatives: what a scenario lets in beyond its definition, and why ---------------------------

@(private = "file")
ALTERNATIVES_SOURCE :: `scenario 1nt "1NT 15-17, and the hands some would open 1NT anyway"
  north: hcp in 15..17 and balanced
  south: hcp >= 8
  also "14, five-card suit" north: hcp = 14 and balanced and longest = 5
  also "a weak responder" south: hcp in 6..7
  also "a weak responder" north: hcp = 17 and balanced
`

// The same scenario in Odin: which way each deal is kept, the core first.
@(private = "file")
compiled_1nt_why :: proc(b: norn.Deal_Summary) -> (kept: bool, why: string) {
	north, south := b[.North], b[.South]
	n_hcp, s_hcp := norn.hcp(north), norn.hcp(south)
	flat := norn.is_balanced(north)
	longest := 0
	for suit in norn.Suit {
		longest = max(longest, norn.suit_length(north, suit))
	}
	switch {
	case n_hcp >= 15 && n_hcp <= 17 && flat && s_hcp >= 8:
		return true, ""
	case n_hcp == 14 && flat && longest == 5 && s_hcp >= 8:
		return true, "14, five-card suit"
	case n_hcp == 17 && flat && s_hcp >= 6 && s_hcp <= 7:
		return true, "a weak responder"
	}
	return false, ""
}

/*
★ AN ALTERNATIVE REPLACES ITS SEAT'S LINES AND KEEPS THE REST, and the deal says which way it got in: every verdict
and every reason compared with the Odin above, over a seeded stream. The second alternative has two lines, so it
replaces BOTH seats' lines.
*/
@(test)
test_an_alternative_loosens_its_seat_and_names_the_deal :: proc(t: ^testing.T) {
	program, ok := parse_one(t, ALTERNATIVES_SOURCE)
	if !ok {return}
	defer destroy_program(&program)
	testing.expect_value(t, len(program.alternatives), 2)
	testing.expect_value(t, write_program(&program, context.temp_allocator), ALTERNATIVES_SOURCE)

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20261105)
	disagreements := 0
	by_why: map[string]int
	defer delete(by_why)
	for _ in 0 ..< 60_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		want, want_why := compiled_1nt_why(summary)
		got := evaluate(summary, {}, &program)
		got_why := explain(summary, {}, &program) if got else ""
		if got != want || got_why != want_why {
			disagreements += 1
		}
		if got {
			by_why[got_why] += 1
		}
	}
	testing.expectf(t, disagreements == 0, "%d deals where text and code disagreed", disagreements)
	for why in ([]string{"", "14, five-card suit", "a weak responder"}) {
		testing.expectf(t, by_why[why] > 0, "%q never kept a deal - the oracle proves nothing about it", why)
	}

	// norn asks the same question through the condition, and counts by it.
	labels := make(map[string]int, context.temp_allocator)
	kept := norn.count_accepted_seeded(20_000, condition(&program), 3, labels = &labels)
	testing.expect_value(t, labels[""] + labels["14, five-card suit"] + labels["a weak responder"], kept)

	// A scenario without alternatives has nothing to explain, so norn never asks.
	plain, plain_ok := parse_one(t, "scenario x\n  north: hcp >= 10\n")
	if plain_ok {
		predicate := condition(&plain).(norn.Interpreted_Predicate)
		testing.expect(t, predicate.explain == nil, "no alternatives, no explain")
		destroy_program(&plain)
	}
}

// A malformed `also` line is one diagnostic, at the part that is wrong, and the rest of the scenario stands.
@(test)
test_a_bad_alternative_is_one_diagnostic :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		line: string,
		says: string,
	} {
		{`  also north: hcp = 14`, "in quotes"},
		{`  also "" north: hcp = 14`, "needs a name"},
		{`  also "open" north: hcp = 14`, ""}, // fine: the control
		{`  also "14 north: hcp = 14`, "closing quote"},
		{`  also "a name far too long to sit on the board beside the hands" north: hcp = 14`, "40 characters"},
		{`  also "upgrade" east: hcp = 14`, "none above it"},
		{`  also "upgrade" tags: x`, "seat, partnership or deal"},
		{`  also "upgrade" north hcp = 14`, "in quotes"},
		{`  also "upgrade" north: hcp = 14 balanced`, "unexpected"},
		{`  also "upgrade" north-south: hcp >= 25`, "none above it"},
	}
	for c in cases {
		source := strings.concatenate({"scenario x\n  north: hcp in 15..17\n", c.line, "\n"}, context.temp_allocator)
		programs, diagnostics := parse(source, "f.scenario", context.temp_allocator)
		testing.expectf(t, len(programs) == 1, "%q lost the scenario", c.line)
		if c.says == "" {
			testing.expectf(t, len(diagnostics) == 0, "%q: unexpected %v", c.line, diagnostics)
		} else {
			testing.expectf(
				t,
				len(diagnostics) == 1 && strings.contains(diagnostics[0].message, c.says),
				"%q: %v",
				c.line,
				diagnostics,
			)
		}
		for &program in programs {
			destroy_program(&program)
		}
	}
}

// `system:` names whose meanings a scenario uses: one word, one line, printed back where it was read.
@(test)
test_a_scenario_names_its_system :: proc(t: ^testing.T) {
	install_test_vocabulary()
	source := "scenario 1m-1n \"1M - 1NT, semi-forcing\"\n  system: 2over1\n  tags: mine\n  north: hcp in 11..21\n"
	program, ok := parse_one(t, source)
	if !ok {return}
	defer destroy_program(&program)
	testing.expect_value(t, program.system, "2over1")
	testing.expect_value(t, write_program(&program, context.temp_allocator), source)

	cases := []struct {
		line: string,
		says: string,
	} {
		{`  system: swedish-club`, ""},
		{`  system: 2/1 GF`, "one word"},
		{`  system:`, "one word"},
		{`  system: -x`, "one word"},
	}
	for c in cases {
		text := strings.concatenate({"scenario x\n", c.line, "\n  north: hcp in 15..17\n"}, context.temp_allocator)
		programs, diagnostics := parse(text, "f.scenario", context.temp_allocator)
		testing.expectf(t, len(programs) == 1, "%q lost the scenario", c.line)
		if c.says == "" {
			testing.expectf(t, len(diagnostics) == 0, "%q: unexpected %v", c.line, diagnostics)
		} else {
			testing.expectf(
				t,
				len(diagnostics) == 1 && strings.contains(diagnostics[0].message, c.says),
				"%q: %v",
				c.line,
				diagnostics,
			)
		}
		for &parsed in programs {
			destroy_program(&parsed)
		}
	}
	// Two lines are one too many.
	twice := "scenario x\n  system: a\n  system: b\n  north: hcp >= 1\n"
	programs, diagnostics := parse(twice, "f.scenario", context.temp_allocator)
	testing.expect(t, len(diagnostics) == 1 && strings.contains(diagnostics[0].message, "one `system:`"))
	for &parsed in programs {
		destroy_program(&parsed)
	}
}

// A scenario's LABEL (the auction as a player writes it, colons and all) and FORMER NAME are carried to the
// loaded `cli.Scenario`, so the list shows the label and a lookup by the old name still finds it.
@(test)
test_a_scenario_has_a_label_and_a_former_name :: proc(t: ^testing.T) {
	install_test_vocabulary()
	source := "scenario 1hs_slam-try \"slam try\"\n  label: 1♥/♠ – ? : slam try\n  formerly: 1major-slam-try\n  system: swedish-club\n  north: hcp in 11..15\n"
	program, ok := parse_one(t, source)
	if !ok {return}
	defer destroy_program(&program)
	testing.expect_value(t, program.label, "1♥/♠ – ? : slam try")
	testing.expect_value(t, program.formerly, "1major-slam-try")
	testing.expect_value(t, write_program(&program, context.temp_allocator), source)

	quoted, quoted_ok := parse_one(t, "scenario x\n  label: \"1NT\"\n  north: hcp >= 1\n")
	if quoted_ok {
		testing.expect_value(t, quoted.label, "1NT")
		destroy_program(&quoted)
	}

	cases := []struct {
		text: string,
		says: string,
	} {
		{"scenario x\n  label:\n  north: hcp >= 1\n", "expected `label:"},
		{"scenario x\n  formerly: two words\n  north: hcp >= 1\n", "one word"},
		{"scenario x\n  label: a\n  label: b\n  north: hcp >= 1\n", "one `label:`"},
		{"scenario x\n  formerly: a\n  formerly: b\n  north: hcp >= 1\n", "one `formerly:`"},
	}
	for c in cases {
		programs, diagnostics := parse(c.text, "f.scenario", context.temp_allocator)
		testing.expectf(t, len(programs) == 1, "%q lost the scenario", c.text)
		testing.expectf(
			t,
			len(diagnostics) == 1 && strings.contains(diagnostics[0].message, c.says),
			"%q: %v",
			c.text,
			diagnostics,
		)
		for &parsed in programs {
			destroy_program(&parsed)
		}
	}

	// Loaded, the scenario carries both, and `cli.lookup` answers the old name.
	temp, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {return}
	folder, _ := filepath.join({temp, "dsl-label-test"}, context.temp_allocator)
	_ = os.make_directory(folder)
	defer os.remove_all(folder)
	path, _ := filepath.join({folder, "a.scenario"}, context.temp_allocator)
	if os.write_entire_file(path, transmute([]u8)source) != nil {return}
	loaded := load_directories({folder}, context.allocator)
	defer destroy_loaded(&loaded)
	found, found_ok := cli.lookup(loaded.scenarios, "1major-slam-try")
	testing.expect(t, found_ok, "the former name finds the scenario")
	testing.expect_value(t, found.name, "1hs_slam-try")
	testing.expect_value(t, found.label, "1♥/♠ – ? : slam try")
}

// A deal only an alternative kept carries the alternative's name on its card; a deal the scenario's own lines
// kept carries none.
@(test)
test_an_alternative_is_named_on_the_card :: proc(t: ^testing.T) {
	program, ok := parse_one(t, "scenario x\n  north: hcp >= 18\n  also \"17 & up\" north: hcp = 17\n")
	if !ok {return}
	defer destroy_program(&program)
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 9)
	page := strings.builder_make(context.temp_allocator)
	norn.generate_accepted(&page, 30, .Html_Cards, condition(&program), 2_000_000)
	text := strings.to_string(page)
	marked := strings.count(text, `<div class="why"`)
	testing.expectf(t, marked > 0 && marked < 30, "%d of 30 boards marked", marked)
	testing.expect(t, strings.contains(text, ">17 &amp; up</div>"), "the name is on the card, escaped")
}

// And through generation: every kept deal is at a table the condition accepts, and a fixed dealer deals them
// all. Counted with norn's own generator, so the table the deal is SHOWN at is the one that was checked.
@(test)
test_a_table_scenario_generates_at_its_table :: proc(t: ^testing.T) {
	program, ok := parse_one(t, "scenario w2\n  dealer: south\n  north: seat = 3 and favourable and longest = 6\n")
	if !ok {return}
	defer destroy_program(&program)
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 7)
	deals: [dynamic]norn.Deal
	tables: [dynamic]norn.Table
	defer delete(deals)
	defer delete(tables)
	accepted, _ := norn.collect_accepted(&deals, &tables, 10, .Html_Cards, condition(&program), 2_000_000)
	testing.expect_value(t, accepted, 10)
	for table, i in tables {
		testing.expect_value(t, table.dealer.? or_else .North, norn.Seat.South)
		testing.expect_value(t, table.vulnerability, norn.Vulnerability.East_West) // N-S at favourable
		testing.expect(t, evaluate(norn.summarize_deal(deals[i]), table, &program), "a kept deal fails its own condition")
	}
}
// ---- systems and named meanings -------------------------------------------------------------------

MEANINGS_SOURCE :: `system 2over1 "2/1 game forcing"
  meaning nt-opening: hcp in 15..17 and balanced
  meaning major-opening: (spades >= 5 or hearts >= 5) and hcp in 12..21
  meaning strong: hcp >= 15

system ours extends 2over1 "2/1 as we play it"
  meaning nt-opening: hcp in 14..16 and balanced

scenario 1nt-major "1NT, responder has a four-card major"
  system: 2over1
  north: nt-opening
  south: hcp >= 8 and (spades = 4 or hearts = 4)

scenario strong-major "a strong major opening"
  north: major-opening and strong
  system: 2over1
`

// A meaning is its condition: the same verdict on every deal as the condition written out, and the scenario
// prints back with the meaning's name rather than what it expands to.
@(test)
test_a_meaning_is_its_condition :: proc(t: ^testing.T) {
	install_test_vocabulary()
	programs, diagnostics := parse(MEANINGS_SOURCE, "m.scenario", context.temp_allocator)
	defer for &program in programs {
		destroy_program(&program)
	}
	testing.expectf(t, len(diagnostics) == 0, "unexpected %v", diagnostics)
	if len(programs) != 2 {
		testing.expectf(t, false, "parsed %d scenarios", len(programs))
		return
	}
	written := write_program(&programs[1], context.temp_allocator)
	testing.expect(t, strings.contains(written, "north: major-opening and strong"), written)

	inline, ok := parse_one(t, "scenario x\n  north: hcp in 15..17 and balanced\n  south: hcp >= 8 and (spades = 4 or hearts = 4)\n")
	if !ok {return}
	defer destroy_program(&inline)
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20261106)
	disagreements, kept := 0, 0
	for _ in 0 ..< 40_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		got := evaluate(summary, {}, &programs[0])
		if got != evaluate(summary, {}, &inline) {
			disagreements += 1
		}
		if got {
			kept += 1
		}
	}
	testing.expectf(t, disagreements == 0, "%d deals where the meaning and its text disagreed", disagreements)
	testing.expect(t, kept > 0, "the oracle proves nothing if nothing was kept")
}

// The meaning of a node: which system's definition it is, and what it overrides.
@(private = "file")
first_meaning :: proc(program: ^Program, name: string) -> (Meaning_Node, bool) {
	for node in program.nodes {
		if m, is := node.(Meaning_Node); is && m.name == name {
			return m, true
		}
	}
	return {}, false
}

// A SYSTEM THAT EXTENDS ANOTHER changes the other's scenarios when it is the one chosen: with `ours` active,
// the 2over1 scenario reads ours' 14-16 notrump, and says it overrides 2over1's; with nothing (or 2over1)
// active it reads 2over1's own. A meaning ours does not override is still 2over1's.
@(test)
test_an_extending_system_overrides_a_meaning :: proc(t: ^testing.T) {
	install_test_vocabulary()
	for active in ([]string{"", "2over1", "ours"}) {
		programs, diagnostics := parse(MEANINGS_SOURCE, "m.scenario", context.temp_allocator, active = active)
		defer for &program in programs {
			destroy_program(&program)
		}
		testing.expectf(t, len(diagnostics) == 0 && len(programs) == 2, "%q: %v", active, diagnostics)
		if len(programs) != 2 {
			continue
		}
		nt, found := first_meaning(&programs[0], "nt-opening")
		testing.expectf(t, found, "%q: no nt-opening node", active)
		if active == "ours" {
			testing.expect_value(t, nt.system, "ours")
			testing.expect_value(t, nt.overrides, "2over1")
		} else {
			testing.expect_value(t, nt.system, "2over1")
			testing.expect_value(t, nt.overrides, "")
		}
		major, _ := first_meaning(&programs[1], "major-opening")
		testing.expect_value(t, major.system, "2over1")

		// 14 balanced: a notrump only in ours.
		fourteen := 0
		state: rand.Xoshiro256_Random_State
		context.random_generator = norn.seeded_xoshiro(&state, 7)
		for _ in 0 ..< 20_000 {
			summary := norn.summarize_deal(norn.deal_hands())
			if evaluate(summary, {}, &programs[0]) && norn.hcp(summary[.North]) == 14 {
				fourteen += 1
			}
		}
		testing.expectf(t, (fourteen > 0) == (active == "ours"), "%q: %d fourteen-point notrumps", active, fourteen)
	}
}

// What can go wrong with a system or a meaning: one diagnostic each, at the line that is wrong.
@(test)
test_a_bad_system_or_meaning_is_one_diagnostic :: proc(t: ^testing.T) {
	install_test_vocabulary()
	cases := []struct {
		source: string,
		says:   string,
		line:   int,
	} {
		{"system a extends nowhere\n  meaning m: hcp >= 1\n", "no system called `nowhere`", 1},
		{"system a\n  meaning m: hcp >= 1\nsystem a\n  meaning n: hcp >= 2\n", "defined already", 3},
		{"system a\n  meaning m: hcp >= 1 and m\n", "uses itself", 2},
		{"system a\n  meaning m: n\n  meaning n: m\n", "uses itself", 2},
		{"system a\n  meaning m: hcp >== 1\n", "", 2},
		{"system a\n  meaning hcp: hcp >= 1\n", "already a word", 2},
		{"system a\n  meaning is_big: hcp >= 1\n", "already a word", 2},
		{"system a\n  meaning m: hcp >= 1\n  meaning m: hcp >= 2\n", "already a meaning", 3},
		{"system a\n  hcp >= 1\n", "`meaning <name>: <condition>`", 2},
		{"system a b c d\n", "expected `system <name>`", 1},
		{"system a\n  meaning flat: balanced\nscenario x\n  system: a\n  north-south: flat\n", "does not fit here", 5},
		{"system a\n  meaning m: hcp >= 1\nscenario x\n  north: m\n", "unknown condition `m`", 4},
	}
	for c in cases {
		programs, diagnostics := parse(c.source, "f.scenario", context.temp_allocator)
		for &program in programs {
			destroy_program(&program)
		}
		if !testing.expectf(t, len(diagnostics) >= 1, "%q: no diagnostic", c.source) {
			continue
		}
		testing.expectf(
			t,
			strings.contains(diagnostics[0].message, c.says) && diagnostics[0].pos.line == c.line,
			"%q: %v",
			c.source,
			diagnostics,
		)
	}
}

// SYSTEMS ACROSS FILES: a meaning defined in one file is used by a scenario in another, and the loader keeps
// the systems for the picker.
@(test)
test_a_meaning_from_another_file :: proc(t: ^testing.T) {
	install_test_vocabulary()
	temp, temp_err := os.temp_directory(context.temp_allocator)
	if temp_err != nil {return}
	folder, _ := filepath.join({temp, "scenario-dsl-meanings"}, context.temp_allocator)
	_ = os.make_directory(folder)
	defer os.remove_all(folder)
	a, _ := filepath.join({folder, "a-scenarios.scenario"}, context.temp_allocator)
	b, _ := filepath.join({folder, "b-system.scenario"}, context.temp_allocator)
	_ = os.write_entire_file(a, transmute([]u8)string("scenario uses-it\n  system: 2over1\n  north: nt-opening\n"))
	_ = os.write_entire_file(b, transmute([]u8)string("system 2over1 \"2/1\"\n  meaning nt-opening: hcp in 15..17 and balanced\n"))

	loaded := load_directories({folder})
	defer destroy_loaded(&loaded)
	testing.expectf(t, len(loaded.diagnostics) == 0, "%v", loaded.diagnostics)
	testing.expect_value(t, len(loaded.scenarios), 1)
	testing.expect_value(t, len(loaded.systems.defs), 1)
	if len(loaded.systems.defs) == 1 {
		testing.expect_value(t, loaded.systems.defs[0].description, "2/1")
	}
}

// A `deal:` line names a hand for each part of its condition, which is what lets one condition OR across seats:
// held to the same thing written in Odin over random deals, printed back as written, with a meaning made of
// groups and a side's `opc`.
@(test)
test_a_deal_line_names_its_hands :: proc(t: ^testing.T) {
	install_test_vocabulary()
	source := `system s
  meaning major-fit: north(spades >= 5) and south(spades >= 4) or north(hearts >= 5) and south(hearts >= 4)

scenario fit "a major fit, or a big side"
  system: s
  north: hcp >= 11
  deal: major-fit or north-south(opc >= 30 and hcp >= 26)
`
	programs, diagnostics := parse(source, "d.scenario", context.temp_allocator)
	defer for &program in programs {
		destroy_program(&program)
	}
	testing.expectf(t, len(diagnostics) == 0, "unexpected %v", diagnostics)
	if !testing.expect_value(t, len(programs), 1) {return}
	written := write_program(&programs[0], context.temp_allocator)
	testing.expect(t, strings.contains(written, "  deal: major-fit or north-south(opc >= 30 and hcp >= 26)\n"), written)

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20261107)
	wrong, kept := 0, 0
	for _ in 0 ..< 40_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		n, s := summary[.North], summary[.South]
		fit :=
			norn.spade_length(n) >= 5 && norn.spade_length(s) >= 4 ||
			norn.heart_length(n) >= 5 && norn.heart_length(s) >= 4
		big := norn.combined_opc(n, s, nil) >= 30 && norn.hcp(n) + norn.hcp(s) >= 26
		want := norn.hcp(n) >= 11 && (fit || big)
		got := evaluate(summary, {}, &programs[0])
		if got != want {
			wrong += 1
		}
		kept += int(got)
	}
	testing.expectf(t, wrong == 0, "%d deals where the deal line and its Odin disagree", wrong)
	testing.expect(t, kept > 0, "nothing kept")

	cases := []struct {
		line: string,
		says: string,
	} {
		{"  deal: hcp >= 12", "names its hand"},
		{"  deal: north(hcp >= 12) and spades >= 4", "names its hand"},
		{"  north: south(hcp >= 12)", "belongs on a `deal:` line"},
		{"  deal: north(south(hcp >= 12))", "cannot hold another"},
		{"  deal: north(hcp >= 12", "expected `)`"},
		{"  deal: north-south(balanced)", "one hand"},
		{"  north: opc >= 30", "`opc` is a side's"},
		{"  deal: north(opc >= 30)", "`opc` is a side's"},
		{"  north-south: opc >= 30", ""},
		{"  deal: east-west(hcp < 15) and (west(spades >= 7) or east(spades >= 7))", ""},
	}
	for c in cases {
		text := strings.concatenate({"scenario x\n", c.line, "\n"}, context.temp_allocator)
		parsed, problems := parse(text, "f.scenario", context.temp_allocator)
		if c.says == "" {
			testing.expectf(t, len(problems) == 0 && len(parsed) == 1, "%q: unexpected %v", c.line, problems)
		} else {
			testing.expectf(
				t,
				len(problems) >= 1 && strings.contains(problems[0].message, c.says),
				"%q: %v",
				c.line,
				problems,
			)
		}
		for &program in parsed {
			destroy_program(&program)
		}
	}
}

// A MEANING INSIDE A MEANING, and a vocabulary name inside one, own their strings like any other node: the
// program frees them, so they must be the program's. They were cloned into scratch while the outer meaning
// expanded, and `destroy_program` then freed memory it never owned (a heap-corruption exit from `sim` once the
// built-in file nested its meanings). Parsed with the context's own allocator, which the test runner tracks.
@(test)
test_a_nested_meaning_belongs_to_its_program :: proc(t: ^testing.T) {
	install_test_vocabulary()
	source := `system s
  meaning strong: is_big
  meaning strong-spades: strong and is_five_spades
scenario x
  system: s
  north: strong-spades or strong
`
	// The runner's own tracking only LISTS a bad free; this one is asserted.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	programs, diagnostics := parse(source, "n.scenario")
	testing.expectf(t, len(diagnostics) == 0, "unexpected %v", diagnostics)
	delete(diagnostics)
	for &program in programs {
		destroy_program(&program)
	}
	delete(programs)
	testing.expectf(t, len(track.bad_free_array) == 0, "%d frees of memory the program did not own", len(track.bad_free_array))
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations not freed", len(track.allocation_map))
}

// A HAND'S NUMBERS AGAINST EACH OTHER: a suit against a suit, and a sum against a number or a sum. Held to the same
// conditions in Odin over random deals, printed back as written, and the mistakes one diagnostic each.
@(test)
test_a_hands_numbers_compare_with_each_other :: proc(t: ^testing.T) {
	source := "scenario x\n  north: spades > hearts and spades + hearts >= 9 and clubs + diamonds in 3..5\n  south: hearts >= spades + diamonds or longest = hcp\n"
	program, ok := parse_one(t, source)
	if !ok {return}
	defer destroy_program(&program)
	testing.expect_value(t, write_program(&program, context.temp_allocator), source)

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 20261108)
	wrong, kept := 0, 0
	for _ in 0 ..< 40_000 {
		summary := norn.summarize_deal(norn.deal_hands())
		n, s := summary[.North], summary[.South]
		ns, nh := norn.spade_length(n), norn.heart_length(n)
		minors := norn.club_length(n) + norn.diamond_length(n)
		longest := max(norn.spade_length(s), norn.heart_length(s), norn.diamond_length(s), norn.club_length(s))
		want :=
			ns > nh && ns + nh >= 9 && minors >= 3 && minors <= 5 &&
			(norn.heart_length(s) >= norn.spade_length(s) + norn.diamond_length(s) || longest == norn.hcp(s))
		got := evaluate(summary, {}, &program)
		wrong += int(got != want)
		kept += int(got)
	}
	testing.expectf(t, wrong == 0, "%d deals where the comparison and its Odin disagree", wrong)
	testing.expect(t, kept > 0, "nothing kept")

	cases := []struct {
		line: string,
		says: string,
	} {
		{"  north: spades + 3 >= 9", "after `+`"},
		{"  north: spades + seat >= 9", "`seat` and `opc`"},
		{"  north: seat > hearts", "`seat` and `opc`"},
		{"  north: spades > is_big", "a number of the hand"},
		{"  north: spades + hearts", "expected a comparison"},
		{"  north: spades + hearts in 9..", "high end"},
		{"  north: spades + hearts + diamonds + clubs + hcp >= 9", "at most four"},
		{"  north: spades + hearts in 11..9", "wrong way round"},
	}
	for c in cases {
		text := strings.concatenate({"scenario x\n", c.line, "\n"}, context.temp_allocator)
		parsed, problems := parse(text, "f.scenario", context.temp_allocator)
		testing.expectf(
			t,
			len(problems) >= 1 && strings.contains(problems[0].message, c.says),
			"%q: %v",
			c.line,
			problems,
		)
		for &each in parsed {
			destroy_program(&each)
		}
	}
}

MEANING_ALTERNATIVES_SOURCE :: `system 2over1
  meaning nt-opening: hcp in 15..17 and balanced
    also "14, five-card minor": hcp = 14 and balanced and longest = 5
    also "4441": hcp in 15..17 and longest = 4 and (spades = 1 or hearts = 1 or diamonds = 1 or clubs = 1)

system ours extends 2over1
  meaning nt-opening
    without "14, five-card minor"
    also "a six-card minor": hcp in 15..17 and longest = 6 and spades <= 3 and hearts <= 3

scenario nt "1NT"
  system: 2over1
  north: nt-opening
`

// A MEANING'S NAMED ALTERNATIVES: the meaning holds through its core or any alternative in force; a deal kept
// only through one is labelled with its name; and a system that extends another switches inherited ones off
// (`without`) and adds its own (`also`) without restating the core. Held to the same thing in Odin, read in each
// system.
@(test)
test_a_meanings_alternatives_widen_it_and_name_themselves :: proc(t: ^testing.T) {
	install_test_vocabulary()
	Hand :: norn.Hand_Summary
	core := proc(h: Hand) -> bool {return norn.hcp(h) >= 15 && norn.hcp(h) <= 17 && norn.is_balanced(h)}
	longest := proc(h: Hand) -> int {
		return max(norn.spade_length(h), norn.heart_length(h), norn.diamond_length(h), norn.club_length(h))
	}
	five_minor := proc(h: Hand) -> bool {
		longest := max(norn.spade_length(h), norn.heart_length(h), norn.diamond_length(h), norn.club_length(h))
		return norn.hcp(h) == 14 && norn.is_balanced(h) && longest == 5
	}
	shortest := proc(h: Hand) -> int {
		return min(norn.spade_length(h), norn.heart_length(h), norn.diamond_length(h), norn.club_length(h))
	}
	for active in ([]string{"", "ours"}) {
		programs, diagnostics := parse(MEANING_ALTERNATIVES_SOURCE, "m.scenario", context.temp_allocator, active = active)
		defer for &program in programs {
			destroy_program(&program)
		}
		testing.expectf(t, len(diagnostics) == 0, "%q: unexpected %v", active, diagnostics)
		if len(programs) != 1 {
			testing.expectf(t, false, "%q: parsed %d scenarios", active, len(programs))
			continue
		}
		program := &programs[0]
		if active == "" {
			testing.expect_value(t, len(program.meaning_alternatives), 2)
		} else {
			testing.expect_value(t, len(program.meaning_alternatives), 2)
			testing.expect_value(t, program.meaning_alternatives[0], "4441")
			testing.expect_value(t, program.meaning_alternatives[1], "a six-card minor")
		}
		testing.expect(t, strings.contains(write_program(program, context.temp_allocator), "north: nt-opening\n"))

		state: rand.Xoshiro256_Random_State
		context.random_generator = norn.seeded_xoshiro(&state, 20261109)
		wrong, labelled, kept := 0, 0, 0
		for _ in 0 ..< 60_000 {
			summary := norn.summarize_deal(norn.deal_hands())
			n := summary[.North]
			hcp := norn.hcp(n)
			four441 := hcp >= 15 && hcp <= 17 && longest(n) == 4 && shortest(n) == 1
			six := hcp >= 15 && hcp <= 17 && longest(n) == 6 && norn.spade_length(n) <= 3 && norn.heart_length(n) <= 3
			want := core(n) || four441 || (five_minor(n) if active == "" else six)
			label := ""
			switch {
			case core(n):
			case active == "" && five_minor(n):
				label = "14, five-card minor"
			case four441:
				label = "4441"
			case active == "ours" && six:
				label = "a six-card minor"
			}
			got := evaluate(summary, {}, program)
			wrong += int(got != want)
			if got {
				kept += 1
				if explain(summary, {}, program) != label {
					labelled += 1
				}
			}
		}
		testing.expectf(t, wrong == 0, "%q: %d deals where the meaning and its Odin disagree", active, wrong)
		testing.expectf(t, labelled == 0, "%q: %d kept deals labelled wrongly", active, labelled)
		testing.expect(t, kept > 0, "nothing kept")
	}

	cases := []struct {
		text: string,
		says: string,
	} {
		{"system s\n  also \"x\": hcp >= 1\n", "belongs under a `meaning` line"},
		{"system s\n  meaning m: hcp >= 1\n    without \"x\"\n", "inherited alternative"},
		{"system s\n  meaning m: hcp >= 1\n    also x: hcp >= 2\n", "expected `also"},
		{"system s\n  meaning m: hcp >= 1\n    also \"x\": hcp >= 2\n    also \"x\": hcp >= 3\n", "already has an alternative"},
		{"system s\n  meaning m: hcp >= 1\n    also \"x\": hcp >=\n", "expected a number"},
		{"system s\nsystem t extends s\n  meaning m\n", "nothing `t` extends defines it"},
		{"system s\n  meaning m: hcp >= 1\nsystem t extends s\n  meaning m\n    without \"nope\"\n", "no alternative \"nope\""},
	}
	for c in cases {
		parsed, problems := parse(c.text, "f.scenario", context.temp_allocator)
		testing.expectf(
			t,
			len(problems) == 1 && strings.contains(problems[0].message, c.says),
			"%q: %v",
			c.text,
			problems,
		)
		for &each in parsed {
			destroy_program(&each)
		}
	}
}
