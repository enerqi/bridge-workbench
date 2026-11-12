package scenario_dsl

/*
	parse.odin — text to `Program`.

	A HAND-WRITTEN RECURSIVE-DESCENT PARSER over a line-oriented file, which is what the language's shape
	asks for: the outer level is lines (a header, then `key: value` body lines), and only the right-hand
	side of a seat line is an expression. So the outer level is a line loop and the inner one is the
	classic precedence climb — `or` binds loosest, then `and`, then `not`, then atoms and parentheses.

	EVERY FAILURE CARRIES A POSITION and parsing CONTINUES to the next scenario where it can. A file with
	two scenarios and a typo in the first should still give you the second, and should tell you about the
	typo once, with a line and column — the same bargain `bridge-markup` makes for `.bml`.
*/

import "base:runtime"
import "core:strconv"
import "core:strings"
import "norn:norn"

@(private)
Parser :: struct {
	source:      string,
	file:        string,
	line_index:  int, // 0-based index of the line being read
	lines:       []string,
	diagnostics: ^[dynamic]Diagnostic,
	allocator:   runtime.Allocator,
	// The tree under construction for the seat line being parsed.
	nodes:       [dynamic]Node,
	// Where in the current line the cursor is, for column reporting.
	text:        string,
	col:         int,
	// The line being parsed is a PARTNERSHIP line, where the one-hand atoms are refused.
	pair:        bool,
	// A table word (`seat`, `vulnerable`, ...) was read in this scenario.
	reads_table: bool,
	// NAMED MEANINGS (systems.odin): the systems read so far, the list's chosen system, the system this
	// scenario's meanings are read in ("" for none), and the meanings being expanded, innermost last (a
	// meaning that uses itself, even through others, is refused rather than expanded for ever).
	systems:     ^Systems,
	active:      string,
	reading:     string,
	expanding:   [dynamic]string,
	// WHERE A DIAGNOSTIC'S STRINGS GO, when not where the program's do (`allocator`). Two allocators because the
	// two outlive different things: a meaning's quiet diagnostics are scratch while the nodes it adds are the
	// program's, and a meaning checked where it is written keeps its diagnostics while its nodes are scratch. One
	// allocator for both freed nested meanings' names as though the program owned them (a bad free in `sim`).
	// nil: `allocator`.
	diagnostic_allocator: Maybe(runtime.Allocator),
	// HAND GROUPS (`north(...)`): the line is a `deal:` line, where every atom must be inside one; how deep in a
	// group the cursor is; and a meaning being checked where it is written, which is judged where it is used.
	deal_line:   bool,
	group_depth: int,
	defining:    bool,
}

/*
Parse a whole file's worth of text into scenarios.

Returns what it could parse plus every diagnostic it found — never one or the other. A file that is
entirely wrong yields no programs and several diagnostics; a file with one bad scenario yields the rest.
*/
//
// SYSTEMS: with `systems` nil this file's own system blocks are read and checked, and its scenarios may use
// their meanings. A caller reading several files (the loader, the editor's check) passes the systems of all of
// them instead, already read and checked, and this file's blocks are then skipped here. `active` is the system
// the list is set to: a scenario of a system it extends reads its meanings there (`reading_system`).
parse :: proc(
	source: string,
	file: string,
	allocator := context.allocator,
	systems: ^Systems = nil,
	active := "",
) -> (
	programs: []Program,
	diagnostics: []Diagnostic,
) {
	found := make([dynamic]Program, 0, 4, allocator)
	problems := make([dynamic]Diagnostic, 0, 4, allocator)

	own_systems: Systems
	systems := systems
	if systems == nil {
		own_systems = make_systems(allocator)
		read_systems(source, file, &own_systems, &problems)
		check_systems(&own_systems, &problems)
		systems = &own_systems
	}
	defer if systems == &own_systems {
		destroy_systems(&own_systems)
	}

	lines := strings.split_lines(source, context.temp_allocator)
	p := Parser {
		source      = source,
		file        = file,
		lines       = lines,
		diagnostics = &problems,
		allocator   = allocator,
		systems     = systems,
		active      = active,
		expanding   = make([dynamic]string, 0, 4, context.temp_allocator),
	}

	for p.line_index < len(lines) {
		line := strings.trim_space(strip_comment(lines[p.line_index]))
		if line == "" {
			p.line_index += 1
			continue
		}
		if is_system_header(line) {
			// Read before the scenarios (`read_systems`); its lines are not a scenario's.
			p.line_index += 1
			skip_body(&p)
			continue
		}
		if !strings.has_prefix(folded(line), "scenario") {
			report(&p, p.line_index, 1, "expected a `scenario` line to start a scenario, or a `system` line")
			p.line_index += 1
			continue
		}
		if program, ok := parse_scenario(&p); ok {
			append(&found, program)
		}
	}
	return found[:], problems[:]
}

// Everything from an unquoted `#` to the end of the line is a comment. Checked against quotes so a `#`
// inside a description is text, which matters because bridge descriptions contain them rarely but do.
@(private)
strip_comment :: proc(line: string) -> string {
	in_quotes := false
	for i in 0 ..< len(line) {
		switch line[i] {
		case '"':
			in_quotes = !in_quotes
		case '#':
			if !in_quotes {
				return line[:i]
			}
		}
	}
	return line
}

@(private)
diagnostic_allocator :: proc(p: ^Parser) -> runtime.Allocator {
	if allocator, set := p.diagnostic_allocator.?; set {
		return allocator
	}
	return p.allocator
}

report :: proc(p: ^Parser, line_index: int, col: int, message: string) {
	append(
		p.diagnostics,
		Diagnostic {
			// THE FILE NAME IS CLONED, like the message. It was borrowed from the caller's `file` argument,
			// which in the loader is a temp-allocated `fullpath` — so `destroy_loaded` freeing it was a
			// free of memory this package never owned. It showed up as a HEAP CORRUPTION exit
			// (0xC0000374) on the first run that produced a diagnostic at all, which is exactly the sort
			// of bug a happy path never finds.
			pos = {file = strings.clone(p.file, diagnostic_allocator(p)), line = line_index + 1, col = col},
			message = strings.clone(message, diagnostic_allocator(p)),
		},
	)
}

/*
One scenario: the header line, then the indented body until the next `scenario` or the end of the file.

The body is read as `key: value`, and only three kinds of key exist — `tags`, a seat name, and a
partnership (`north-south` / `east-west`). An
unknown key is a diagnostic rather than silently ignored: a misspelled `tag:` that did nothing would be a
scenario quietly missing from a group, which is exactly the class of bug nobody notices.
*/
@(private)
parse_scenario :: proc(p: ^Parser) -> (program: Program, ok: bool) {
	header_index := p.line_index
	header := strings.trim_space(strip_comment(p.lines[header_index]))
	p.line_index += 1

	rest := strings.trim_space(header[len("scenario"):])
	if rest == "" {
		report(p, header_index, 1, "a scenario needs a name: `scenario <name> \"<description>\"`")
		skip_body(p)
		return {}, false
	}

	name, description := split_name_and_description(rest)
	if name == "" {
		report(p, header_index, 1, "a scenario needs a name before its description")
		skip_body(p)
		return {}, false
	}

	nodes := make([dynamic]Node, 0, 16, p.allocator)
	rules := make([dynamic]Seat_Rule, 0, 4, p.allocator)
	tags := make([dynamic]string, 0, 4, p.allocator)
	system := ""
	label := ""
	formerly := ""
	alternatives := make([dynamic]string, 0, 0, p.allocator)
	double_dummy: Maybe(Double_Dummy)
	dealer: Maybe(norn.Seat)
	vulnerability: Maybe(norn.Vulnerability)
	fixed: [norn.Seat]norn.Hand_Summary
	fixes := false
	p.nodes = nodes
	p.reads_table = false
	// THE SYSTEM ITS MEANINGS ARE READ IN, known before the first seat line: the `system:` line may come after
	// the lines that use a meaning.
	p.reading = reading_system(p.systems, own_system_line(p), p.active)

	for p.line_index < len(p.lines) {
		raw := strip_comment(p.lines[p.line_index])
		line := strings.trim_space(raw)
		if line == "" {
			p.line_index += 1
			continue
		}
		if is_block_header(line) {
			break // the next scenario or system; this one is finished
		}
		if is_also_line(line) {
			parse_also_line(p, raw, line, &rules, &alternatives)
			p.line_index += 1
			continue
		}

		colon := strings.index_byte(line, ':')
		if colon < 0 {
			report(p, p.line_index, 1, "expected `key: value` — a seat, a partnership, `deal:`, `dealer:`, `vulnerability:`, `double-dummy:`, `system:`, `label:`, `formerly:` or `tags:`")
			p.line_index += 1
			continue
		}
		key := folded(strings.trim_space(line[:colon]))
		value := strings.trim_space(line[colon + 1:])
		value_col := strings.index(raw, value) + 1 if value != "" else colon + 2

		switch {
		case key == "dealer":
			// FIXES who deals; `seat` on a line TESTS it. Both are the table (`Program.dealer`).
			if _, already := dealer.?; already {
				report(p, p.line_index, 1, "a scenario has one `dealer:` line")
			} else if seat, seat_ok := seat_of(folded(value)); seat_ok {
				dealer = seat
			} else {
				report(p, p.line_index, value_col, "expected `dealer: <north|east|south|west>`")
			}
		case key == "vulnerability" || key == "vul":
			if _, already := vulnerability.?; already {
				report(p, p.line_index, 1, "a scenario has one `vulnerability:` line")
			} else if v, v_ok := board_vulnerability_of(folded(value)); v_ok {
				vulnerability = v
			} else {
				report(
					p,
					p.line_index,
					value_col,
					"expected `vulnerability: <none|north-south|east-west|both>` - or test it on a seat line: `vulnerable`, `favourable`, `unfavourable`",
				)
			}
		case key == "double-dummy":
			if _, already := double_dummy.?; already {
				report(p, p.line_index, 1, "a scenario has one `double-dummy:` line")
			} else if dd, dd_ok := parse_double_dummy(value); dd_ok {
				double_dummy = dd
			} else {
				report(
					p,
					p.line_index,
					value_col,
					"expected `double-dummy: <north-south|east-west> make <game|slam|grand>`",
				)
			}
		case key == "system":
			// ONE WORD, the way a tag is: it is matched exactly against the picker's systems and shown as a
			// badge, so `2/1 GF` and `2over1` would be two systems by accident.
			if system != "" {
				report(p, p.line_index, 1, "a scenario has one `system:` line")
			} else if !is_system_name(value) {
				report(
					p,
					p.line_index,
					value_col,
					"expected `system: <name>` - one word of letters, digits and dashes, like `2over1` or `swedish-club`",
				)
			} else {
				system = value
			}
		case key == "label":
			// THE AUCTION AS A PLAYER WRITES IT (`1♥/♠ – ? : slam try`), shown on the list's row with the name dim
			// after it. Free text, so it may hold colons; quotes round it are dropped.
			unquoted := value
			if len(unquoted) >= 2 && unquoted[0] == '"' && unquoted[len(unquoted) - 1] == '"' {
				unquoted = unquoted[1:len(unquoted) - 1]
			}
			if label != "" {
				report(p, p.line_index, 1, "a scenario has one `label:` line")
			} else if unquoted == "" {
				report(p, p.line_index, value_col, "expected `label: <the auction as you would write it>`")
			} else {
				label = unquoted
			}
		case key == "formerly":
			// THE NAME IT HAD BEFORE A RENAME, which `sim -S` and the list's filter still answer to. One word, as
			// the scenario's own name is.
			if formerly != "" {
				report(p, p.line_index, 1, "a scenario has one `formerly:` line")
			} else if value == "" || strings.index_any(value, " \t") >= 0 {
				report(p, p.line_index, value_col, "expected `formerly: <the scenario's old name>` - one word")
			} else {
				formerly = value
			}
		case key == "deal":
			if root, line_ok := parse_deal_condition(p, value, value_col); line_ok {
				append(&rules, Seat_Rule{deal = true, root = root})
			}
		case key == "tags":
			for tag in strings.split(value, ",", context.temp_allocator) {
				trimmed := strings.trim_space(tag)
				if trimmed != "" {
					append(&tags, strings.clone(trimmed, p.allocator))
				}
			}
		case strings.has_suffix(key, " holds"):
			// CARDS FIXED to a seat, dealt rather than waited for (`Program.fixed`).
			seat, is_seat := seat_of(strings.trim_space(key[:len(key) - len(" holds")]))
			if !is_seat {
				report(p, p.line_index, 1, "expected `<north|east|south|west> holds: <cards>` - one seat's cards")
			} else if read_fixed_cards(p, value, value_col, seat, &fixed) {
				fixes = true
			}
		case:
			seat, is_seat := seat_of(key)
			pair := false
			if !is_seat {
				seat, pair = pair_of(key)
			}
			if !is_seat && !pair {
				report(
					p,
					p.line_index,
					1,
					"unknown key — expected a seat (north/east/south/west), a partnership (north-south/east-west), `deal`, `dealer`, `vulnerability`, `double-dummy`, `system`, `label`, `formerly` or `tags`",
				)
				p.line_index += 1
				continue
			}
			if root, line_ok := parse_seat_condition(p, value, value_col, pair); line_ok {
				append(&rules, Seat_Rule{seat = seat, pair = pair, root = root})
			}
		}
		p.line_index += 1
	}

	if len(rules) == 0 && !fixes {
		report(p, header_index, 1, "a scenario needs at least one seat condition")
		delete(nodes)
		delete(rules)
		for tag in tags {
			delete(tag, p.allocator)
		}
		delete(tags)
		for alternative in alternatives {
			delete(alternative, p.allocator)
		}
		delete(alternatives)
		return {}, false
	}

	// The meanings' alternatives, each name once: what `explain` labels a deal with.
	meaning_alternatives := make([dynamic]string, 0, 0, p.allocator)
	for node in p.nodes {
		meaning, is := node.(Meaning_Node)
		if !is {
			continue
		}
		for alternative in meaning.alternatives {
			seen := false
			for known in meaning_alternatives {
				seen ||= known == alternative.name
			}
			if !seen {
				append(&meaning_alternatives, strings.clone(alternative.name, p.allocator))
			}
		}
	}

	return Program {
			name = strings.clone(name, p.allocator),
			description = strings.clone(description, p.allocator),
			system = strings.clone(system, p.allocator),
			label = strings.clone(label, p.allocator),
			formerly = strings.clone(formerly, p.allocator),
			tags = tags[:],
			rules = rules[:],
			nodes = p.nodes[:],
			double_dummy = double_dummy,
			dealer = dealer,
			vulnerability = vulnerability,
			fixed = fixed,
			fixes = fixes,
			reads_table = p.reads_table || dealer != nil || vulnerability != nil,
			alternatives = alternatives[:],
			meaning_alternatives = meaning_alternatives[:],
			source = strings.clone(p.file, p.allocator),
			allocator = p.allocator,
		},
		true
}

/*
The cards of a `<seat> holds:` line, added to `fixed[seat]`: PBN's dotted form, spades to clubs (`AKQ32.K2.QJ3.432`,
`AKQ...` for the top three spades alone - an empty suit fixes nothing there, it is not a void), or each suit named
(`S:AKQ H:K`, `♠AKQ ♥K`). False, reported, when a card is not one, is named twice, is another seat's already, or
the seat would hold more than 13.
*/
@(private)
read_fixed_cards :: proc(p: ^Parser, value: string, value_col: int, seat: norn.Seat, fixed: ^[norn.Seat]norn.Hand_Summary) -> bool {
	USAGE :: "expected the cards, spades first: `AKQ32.K2.QJ3.432` (PBN's dots), or each suit named: `S:AKQ H:K`"
	cards: norn.Hand_Summary
	add :: proc(cards: ^norn.Hand_Summary, suit: norn.Suit, text: string) -> (bad: string) {
		if text == "" || text == "-" {
			return ""
		}
		ranks, why := ranks_of(text)
		if why != "" {
			return why
		}
		if ranks & cards.suits[suit] != {} {
			return "a card is named twice"
		}
		cards.suits[suit] += ranks
		return ""
	}
	if value == "" {
		report(p, p.line_index, value_col, USAGE)
		return false
	}
	if strings.contains(value, ".") {
		groups := strings.split(strings.trim_space(value), ".", context.temp_allocator)
		if len(groups) != 4 {
			report(p, p.line_index, value_col, "PBN's form has four suits, spades to clubs, between three dots: `AKQ32.K2.QJ3.432`")
			return false
		}
		for group, i in groups {
			if bad := add(&cards, SUITS_SPADES_FIRST[i], strings.trim_space(group)); bad != "" {
				report(p, p.line_index, value_col, strings.concatenate({"`", group, "`: ", bad}, context.temp_allocator))
				return false
			}
		}
	} else {
		for token in strings.fields(strings.trim_space(value), context.temp_allocator) {
			suit, rest, is_suit := suit_prefix(token)
			if !is_suit {
				report(p, p.line_index, value_col, USAGE)
				return false
			}
			if bad := add(&cards, suit, strings.trim_prefix(rest, ":")); bad != "" {
				report(p, p.line_index, value_col, strings.concatenate({"`", token, "`: ", bad}, context.temp_allocator))
				return false
			}
		}
	}
	total := 0
	for suit in norn.Suit {
		total += card(cards.suits[suit] | fixed[seat].suits[suit])
		for other in norn.Seat {
			if other != seat && cards.suits[suit] & fixed[other].suits[suit] != {} {
				report(p, p.line_index, value_col, fmt_message(p, "a card here is %s's already", seat_word(other)))
				return false
			}
			if other == seat && cards.suits[suit] & fixed[seat].suits[suit] != {} {
				report(p, p.line_index, value_col, "a card here is fixed to this seat already")
				return false
			}
		}
	}
	if total > 13 {
		report(p, p.line_index, value_col, "a hand holds 13 cards - this fixes more")
		return false
	}
	for suit in norn.Suit {
		fixed[seat].suits[suit] += cards.suits[suit]
	}
	return true
}

@(private)
SUITS_SPADES_FIRST := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}

// The suit a token of a `holds:` line starts with - a letter (`S`, `h`) or a glyph (`♠`, `♥`) - and the rest.
@(private)
suit_prefix :: proc(token: string) -> (suit: norn.Suit, rest: string, ok: bool) {
	glyphs := [4]string{"♠", "♥", "♦", "♣"}
	for glyph, i in glyphs {
		if strings.has_prefix(token, glyph) {
			return SUITS_SPADES_FIRST[i], token[len(glyph):], true
		}
	}
	if len(token) < 2 {
		return {}, "", false
	}
	switch token[0] {
	case 's', 'S':
		return .Spades, token[1:], true
	case 'h', 'H':
		return .Hearts, token[1:], true
	case 'd', 'D':
		return .Diamonds, token[1:], true
	case 'c', 'C':
		return .Clubs, token[1:], true
	}
	return {}, "", false
}

// The condition of a seat or partnership line, which has to be the WHOLE rest of the line.
@(private)
parse_seat_condition :: proc(p: ^Parser, value: string, value_col: int, pair: bool) -> (root: int, ok: bool) {
	if value == "" {
		report(p, p.line_index, value_col, "this line has no condition")
		return 0, false
	}
	p.text = value
	p.col = value_col
	p.pair = pair
	defer p.pair = false
	return parse_whole_condition(p)
}

// The condition of a `deal:` line: every atom in a hand's group (`north(...)`, `east-west(...)`).
@(private)
parse_deal_condition :: proc(p: ^Parser, value: string, value_col: int) -> (root: int, ok: bool) {
	if value == "" {
		report(p, p.line_index, value_col, "this line has no condition")
		return 0, false
	}
	p.text = value
	p.col = value_col
	p.deal_line = true
	defer p.deal_line = false
	return parse_whole_condition(p)
}

// The condition from `p.text` to the end of it: an expression, and nothing after it.
@(private)
parse_whole_condition :: proc(p: ^Parser) -> (root: int, ok: bool) {
	root = parse_expression(p) or_return
	// The expression stops at the first thing it cannot read, and that was accepted in silence: `hcp in
	// 8..11x` read as `8..11` (reported 2026-10-19), and `hcp >= 12 balanced` as `hcp >= 12`, which is worse -
	// a forgotten `and` that quietly drops half the condition.
	skip_spaces(p)
	if p.text != "" {
		extra := p.text
		if space := strings.index_any(extra, " \t"); space > 0 {
			extra = extra[:space]
		}
		report(
			p,
			p.line_index,
			p.col,
			strings.concatenate({"unexpected `", extra, "` — expected `and`, `or` or the end of the line"}, context.temp_allocator),
		)
		return 0, false
	}
	return root, true
}

// How long an alternative's name may be: it is drawn as a pill on the board, beside the hands.
ALTERNATIVE_NAME_MAX :: 40

// `also "<name>" ...`: the word, then a space or the quote.
@(private)
is_also_line :: proc(line: string) -> bool {
	lowered := folded(line)
	return strings.has_prefix(lowered, "also") && (len(line) == 4 || line[4] == ' ' || line[4] == '\t' || line[4] == '"')
}

/*
`also "<name>" <seat or side>: <condition>` - a line of a named ALTERNATIVE (see the header). The name is quoted
because it is a phrase ("14, five-card suit") and may hold a colon. An alternative loosens a line the scenario
already has, so the seat must have a line of the scenario's own ABOVE it: an `also` for a seat the scenario says
nothing about would only ever narrow it, and its deals would all be the scenario's own.
*/
@(private)
parse_also_line :: proc(p: ^Parser, raw, line: string, rules: ^[dynamic]Seat_Rule, alternatives: ^[dynamic]string) {
	SHAPE :: "expected `also \"<name>\" <seat>: <condition>` - the name, in quotes, is what a deal's card shows"
	column :: proc(raw, part: string) -> int {
		return int(uintptr(raw_data(part)) - uintptr(raw_data(raw))) + 1
	}
	rest := strings.trim_left_space(line[4:])
	if !strings.has_prefix(rest, `"`) {
		report(p, p.line_index, column(raw, rest), SHAPE)
		return
	}
	close := strings.index_byte(rest[1:], '"')
	if close < 0 {
		report(p, p.line_index, column(raw, rest), "this alternative's name has no closing quote")
		return
	}
	name := strings.trim_space(rest[1:close + 1])
	if name == "" {
		report(p, p.line_index, column(raw, rest), "an alternative needs a name - it is what a deal's card shows")
		return
	}
	if len(name) > ALTERNATIVE_NAME_MAX {
		report(p, p.line_index, column(raw, rest), "keep an alternative's name to 40 characters - it is drawn on the board")
		return
	}
	body := strings.trim_space(rest[close + 2:])
	colon := strings.index_byte(body, ':')
	if colon < 0 {
		report(p, p.line_index, column(raw, body) if body != "" else len(raw) + 1, SHAPE)
		return
	}
	key := folded(strings.trim_space(body[:colon]))
	deal := key == "deal"
	seat, is_seat := seat_of(key)
	pair := false
	if !is_seat {
		seat, pair = pair_of(key)
	}
	if !is_seat && !pair && !deal {
		report(
			p,
			p.line_index,
			column(raw, body),
			"an `also` line is a seat, partnership or deal line: north/east/south/west, north-south/east-west or deal",
		)
		return
	}
	has_own := false
	for rule in rules {
		if rule.also == 0 && rule.deal == deal && (deal || rule.seat == seat && rule.pair == pair) {
			has_own = true
		}
	}
	if !has_own {
		report(
			p,
			p.line_index,
			column(raw, body),
			fmt_message(
				p,
				"an alternative replaces the scenario's own `%s:` lines, and there is none above it",
				key,
			),
		)
		return
	}
	value := strings.trim_space(body[colon + 1:])
	value_col := column(raw, value) if value != "" else column(raw, body) + colon + 1
	root: int
	ok: bool
	if deal {
		root, ok = parse_deal_condition(p, value, value_col)
	} else {
		root, ok = parse_seat_condition(p, value, value_col, pair)
	}
	if !ok {
		return
	}
	also := 0
	for existing, i in alternatives {
		if existing == name {
			also = i + 1
		}
	}
	if also == 0 {
		append(alternatives, strings.clone(name, p.allocator))
		also = len(alternatives)
	}
	append(rules, Seat_Rule{seat = seat, pair = pair, deal = deal, root = root, also = also})
}

// `north-south make slam`: a side, `make` (or `makes`), and game / slam / grand. `small slam` and
// `grand slam` are the same goals spelled out, since that is how people say them.
@(private)
parse_double_dummy :: proc(value: string) -> (dd: Double_Dummy, ok: bool) {
	words := strings.fields(folded(value), context.temp_allocator)
	if len(words) < 3 || (words[1] != "make" && words[1] != "makes") {
		return {}, false
	}
	switch words[0] {
	case "north-south":
		dd.side = .North_South
	case "east-west":
		dd.side = .East_West
	case:
		return {}, false
	}
	goal := strings.join(words[2:], " ", context.temp_allocator)
	switch goal {
	case "game":
		dd.goal = .Game
	case "slam", "small slam", "small-slam":
		dd.goal = .Slam
	case "grand", "grand slam", "grand-slam":
		dd.goal = .Grand
	case:
		return {}, false
	}
	return dd, true
}

// Skip to the next scenario after a bad header, so one broken scenario costs one diagnostic rather than
// one per line of its body.
@(private)
skip_body :: proc(p: ^Parser) {
	for p.line_index < len(p.lines) {
		line := strings.trim_space(strip_comment(p.lines[p.line_index]))
		if line != "" && is_block_header(line) {
			return
		}
		p.line_index += 1
	}
}

// A system's name: letters, digits and dashes, starting with a letter or digit.
@(private)
is_system_name :: proc(value: string) -> bool {
	if value == "" || value[0] == '-' {
		return false
	}
	for c in value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// `1c-then-5hearts "strong 1C; South 5+ hearts"` — the name is the first word, the description is the
// quoted remainder. An unquoted remainder is taken whole, because insisting on quotes for a description
// nobody else parses would be ceremony.
@(private)
split_name_and_description :: proc(rest: string) -> (name: string, description: string) {
	space := strings.index_any(rest, " \t")
	if space < 0 {
		return rest, ""
	}
	name = rest[:space]
	description = strings.trim_space(rest[space:])
	if len(description) >= 2 && description[0] == '"' && description[len(description) - 1] == '"' {
		description = description[1:len(description) - 1]
	}
	return
}

// ---------------------------------------------------------------------------------------------------
// The expression grammar
//
//   expression := term   ( "or"  term )*
//   term       := factor ( "and" factor )*
//   factor     := "not" factor | "(" expression ")" | atom
//   atom       := name | "balanced" | "semibalanced" | "holds" "(" suit "," rank ")" | sum cmp sum
//   sum        := term ( "+" term )* [ ("+" | "-") int ];  term := quantity | "cards" "(" suit "," cards ")"
//               | "shape" "(" ["any"] pattern ( "," ["any"] pattern )* ")" | quantity ( cmp int | "in" a ".." b )
//               | "silent" "(" level ( "," suit )+ | "silent" "(" level "," "notrump" ")"

@(private)
add_node :: proc(p: ^Parser, node: Node) -> int {
	append(&p.nodes, node)
	return len(p.nodes) - 1
}

@(private)
parse_expression :: proc(p: ^Parser) -> (root: int, ok: bool) {
	left := parse_term(p) or_return
	for {
		save := p.text
		save_col := p.col
		word, has_word := peek_word(p)
		if !has_word || folded(word) != "or" {
			p.text = save
			p.col = save_col
			break
		}
		take_word(p)
		right := parse_term(p) or_return
		left = add_node(p, Or_Node{left = left, right = right})
	}
	return left, true
}

@(private)
parse_term :: proc(p: ^Parser) -> (root: int, ok: bool) {
	left := parse_factor(p) or_return
	for {
		save := p.text
		save_col := p.col
		word, has_word := peek_word(p)
		if !has_word || folded(word) != "and" {
			p.text = save
			p.col = save_col
			break
		}
		take_word(p)
		right := parse_factor(p) or_return
		left = add_node(p, And_Node{left = left, right = right})
	}
	return left, true
}

@(private)
parse_factor :: proc(p: ^Parser) -> (root: int, ok: bool) {
	skip_spaces(p)
	if word, has_word := peek_word(p); has_word && folded(word) == "not" {
		take_word(p)
		child := parse_factor(p) or_return
		return add_node(p, Not_Node{child = child}), true
	}
	if strings.has_prefix(p.text, "(") {
		advance(p, 1)
		inner := parse_expression(p) or_return
		skip_spaces(p)
		if !strings.has_prefix(p.text, ")") {
			report(p, p.line_index, p.col, "expected `)`")
			return 0, false
		}
		advance(p, 1)
		return inner, true
	}
	return parse_atom(p)
}

@(private)
parse_atom :: proc(p: ^Parser) -> (root: int, ok: bool) {
	skip_spaces(p)
	start_col := p.col
	word, has_word := take_word(p)
	if !has_word {
		report(p, p.line_index, start_col, "expected a condition")
		return 0, false
	}
	lowered := folded(word)

	// A HAND'S GROUP: `north(...)`, `east-west(...)`.
	{
		save, save_col := p.text, p.col
		skip_spaces(p)
		if strings.has_prefix(p.text, "(") {
			if seat, is_seat := seat_of(lowered); is_seat {
				return parse_hand_group(p, seat, false, word, start_col)
			}
			if seat, is_pair := pair_of(lowered); is_pair {
				return parse_hand_group(p, seat, true, word, start_col)
			}
		}
		p.text, p.col = save, save_col
	}

	// ON A `deal:` LINE an atom outside a group would have no hand to read. A meaning may be all groups, so it is
	// let through and its own atoms are judged as it expands.
	if p.deal_line && p.group_depth == 0 && !is_meaning_here(p, word) {
		report(
			p,
			p.line_index,
			start_col,
			fmt_message(p, "on a `deal:` line every condition names its hand: `north(%s ...)`, `east-west(...)`", word),
		)
		return 0, false
	}

	// ONE-HAND WORDS ON A PARTNERSHIP LINE are refused here rather than evaluated: a side's 26 cards are
	// never "balanced", and a named helper asked about them would answer with something that reads like a
	// verdict and means nothing. A seat line is where they belong, and the message says so.
	// `seat` is one hand's place in the auction; a side has two.
	if p.pair && (lowered == "balanced" || lowered == "semibalanced" || lowered == "shape" || lowered == "silent" || lowered == "seat" || is_vocabulary_word(word)) {
		report(
			p,
			p.line_index,
			start_col,
			fmt_message(p, "`%s` describes one hand — put it on a seat line, not a partnership line", word),
		)
		return 0, false
	}

	if lowered == "balanced" {
		return add_node(p, Balanced_Node{}), true
	}
	if lowered == "semibalanced" {
		return add_node(p, Balanced_Node{semi = true}), true
	}
	if lowered == "holds" {
		return parse_holds(p, start_col)
	}
	if lowered == "cards" {
		term := parse_card_pool(p) or_return
		return parse_sum_start(p, term, start_col)
	}
	if lowered == "shape" {
		return parse_shape(p)
	}
	if lowered == "silent" {
		return parse_silent(p, start_col)
	}
	if v, is_vulnerability := vulnerability_word_of(lowered); is_vulnerability {
		p.reads_table = true
		return add_node(p, Vulnerability_Node{word = v}), true
	}
	if quantity, is_quantity := quantity_of(lowered); is_quantity {
		if quantity == .Seat {
			p.reads_table = true
		}
		if quantity == .Opc && !p.pair && !p.defining {
			report(
				p,
				p.line_index,
				start_col,
				"`opc` is a side's - put it on a partnership line or in a side's group: `north-south(opc >= 32)`",
			)
			return 0, false
		}
		return parse_comparison(p, quantity, start_col)
	}

	// A MEANING of the system this scenario is read in, expanded here (systems.odin).
	if p.systems != nil && p.reading != "" {
		if resolved := resolve_meaning(p.systems, p.reading, word); resolved.ok {
			return expand_meaning(p, &resolved, start_col)
		}
	}

	// A NAME FROM THE CONSUMER'S VOCABULARY, resolved now rather than at run time.
	if index, known := find_in_vocabulary(word); known {
		return add_node(p, Named_Node{name = strings.clone(word, p.allocator), index = index}), true
	}
	report(
		p,
		p.line_index,
		start_col,
		fmt_message(p, "unknown condition `%s` — not a quantity, and not in this system's vocabulary", word),
	)
	return 0, false
}

// `north(...)`: the condition inside, read as that hand's (or with `pair` that side's) - see `Hand_Node`.
@(private)
parse_hand_group :: proc(p: ^Parser, seat: norn.Seat, pair: bool, word: string, start_col: int) -> (root: int, ok: bool) {
	if !p.deal_line && !p.defining {
		report(
			p,
			p.line_index,
			start_col,
			fmt_message(p, "`%s(...)` names a hand - it belongs on a `deal:` line; on this line the hand is already named", word),
		)
		return 0, false
	}
	if p.group_depth > 0 {
		report(p, p.line_index, start_col, "a hand's group cannot hold another - close the first one before naming the next hand")
		return 0, false
	}
	advance(p, 1) // the `(`
	saved_pair := p.pair
	p.pair = pair
	p.group_depth += 1
	inner, inner_ok := parse_expression(p)
	p.group_depth -= 1
	p.pair = saved_pair
	if !inner_ok {
		return 0, false
	}
	skip_spaces(p)
	if !strings.has_prefix(p.text, ")") {
		report(p, p.line_index, p.col, "expected `)` to close the hand's group")
		return 0, false
	}
	advance(p, 1)
	return add_node(p, Hand_Node{seat = seat, pair = pair, child = inner}), true
}

// Is `word` a meaning of the system this scenario is read in?
@(private)
is_meaning_here :: proc(p: ^Parser, word: string) -> bool {
	if p.systems == nil || p.reading == "" {
		return false
	}
	_, _, _, found := find_meaning(p.systems, p.reading, word)
	return found
}

/*
Expand a meaning where it is used: its condition parsed into this scenario's tree under a `Meaning_Node` that
keeps the name. Its own mistakes were reported where it is written (`check_systems`), so here they are
collected quietly and the use gets one diagnostic naming the meaning.
*/
@(private)
expand_meaning :: proc(p: ^Parser, resolved: ^Resolved_Meaning, start_col: int) -> (root: int, ok: bool) {
	meaning := resolved.core
	for name in p.expanding {
		if name == meaning.name {
			report(p, p.line_index, start_col, fmt_message(p, "`%s` uses itself, through the meanings it uses", meaning.name))
			return 0, false
		}
	}
	append(&p.expanding, meaning.name)
	defer pop(&p.expanding)

	// The core, then each alternative in force, parsed quietly where each is written.
	inner, why, inner_ok := parse_meaning_text(p, meaning.text, meaning.line, meaning.col)
	alternatives := make([]Meaning_Alternative, len(resolved.alternatives), p.allocator)
	built := 0
	for alternative in resolved.alternatives {
		if !inner_ok {
			break
		}
		alt_root, alt_why, alt_ok := parse_meaning_text(p, alternative.text, alternative.line, alternative.col)
		if !alt_ok {
			inner_ok, why = false, strings.concatenate({"its alternative \"", alternative.name, "\": ", alt_why}, context.temp_allocator)
			break
		}
		alternatives[built] = Meaning_Alternative{name = strings.clone(alternative.name, p.allocator), root = alt_root}
		built += 1
	}
	if !inner_ok {
		for alternative in alternatives[:built] {
			delete(alternative.name, p.allocator)
		}
		delete(alternatives, p.allocator)
		report(
			p,
			p.line_index,
			start_col,
			strings.concatenate({"the meaning `", meaning.name, "` (", resolved.defined_in, ") does not fit here: ", why}, context.temp_allocator),
		)
		return 0, false
	}
	return add_node(
			p,
			Meaning_Node {
				name = strings.clone(meaning.name, p.allocator),
				system = strings.clone(resolved.defined_in, p.allocator),
				overrides = strings.clone(resolved.overrides, p.allocator),
				amended_by = strings.clone(resolved.amended_by, p.allocator),
				root = inner,
				alternatives = alternatives,
			},
		),
		true
}

// One of a meaning's conditions parsed into this scenario's tree, its own diagnostics collected quietly (they
// were reported where it is written) and the first handed back as `why`.
@(private)
parse_meaning_text :: proc(p: ^Parser, text: string, line, col: int) -> (root: int, why: string, ok: bool) {
	saved_text, saved_col, saved_line := p.text, p.col, p.line_index
	saved_diagnostics, saved_allocator := p.diagnostics, p.diagnostic_allocator
	quiet := make([dynamic]Diagnostic, 0, 2, context.temp_allocator)
	p.diagnostics, p.diagnostic_allocator = &quiet, context.temp_allocator
	p.text, p.col, p.line_index = text, col, line
	root, ok = parse_whole_condition(p)
	p.text, p.col, p.line_index = saved_text, saved_col, saved_line
	p.diagnostics, p.diagnostic_allocator = saved_diagnostics, saved_allocator
	if !ok {
		why = quiet[0].message if len(quiet) > 0 else "it does not read"
	}
	return
}

// The value of this scenario's `system:` line, looked ahead for from its header: "" when it has none.
@(private)
own_system_line :: proc(p: ^Parser) -> string {
	for i in p.line_index ..< len(p.lines) {
		line := strings.trim_space(strip_comment(p.lines[i]))
		if line == "" {
			continue
		}
		if is_block_header(line) {
			break
		}
		colon := strings.index_byte(line, ':')
		if colon > 0 && folded(strings.trim_space(line[:colon])) == "system" {
			return strings.trim_space(line[colon + 1:])
		}
	}
	return ""
}

@(private)
is_vocabulary_word :: proc(word: string) -> bool {
	_, known := find_in_vocabulary(word)
	return known
}

@(private)
parse_holds :: proc(p: ^Parser, start_col: int) -> (root: int, ok: bool) {
	skip_spaces(p)
	if !strings.has_prefix(p.text, "(") {
		report(p, p.line_index, p.col, "`holds` takes a suit and a rank: `holds(spades, ace)`")
		return 0, false
	}
	advance(p, 1)
	suit_word, _ := take_word(p)
	suit, is_suit := suit_of(folded(suit_word))
	if !is_suit {
		report(p, p.line_index, p.col, "expected a suit — clubs, diamonds, hearts or spades")
		return 0, false
	}
	skip_spaces(p)
	if strings.has_prefix(p.text, ",") {
		advance(p, 1)
	}
	rank_word, _ := take_word(p)
	rank, is_rank := rank_of(folded(rank_word))
	if !is_rank {
		report(p, p.line_index, p.col, "expected a rank — ace, king, … or 2..10")
		return 0, false
	}
	skip_spaces(p)
	if !strings.has_prefix(p.text, ")") {
		report(p, p.line_index, p.col, "expected `)`")
		return 0, false
	}
	advance(p, 1)
	return add_node(p, Holds_Node{suit = suit, rank = rank}), true
}

// `shape(any 4333, 5xxx, 10-1-1-1)` - see `Shape_Node`.
@(private)
parse_shape :: proc(p: ^Parser) -> (root: int, ok: bool) {
	skip_spaces(p)
	if !strings.has_prefix(p.text, "(") {
		report(p, p.line_index, p.col, "`shape` takes patterns of four lengths, spades first: `shape(any 4333, 5xxx)`")
		return 0, false
	}
	advance(p, 1)
	node: Shape_Node
	for {
		skip_spaces(p)
		col := p.col
		word, has := take_word(p)
		pattern := Shape_Pattern{}
		if has && folded(word) == "any" {
			pattern.any = true
			skip_spaces(p)
			col = p.col
			word, has = take_word(p)
		}
		why: string
		if has {
			pattern, why = read_shape_pattern(word, pattern.any)
		} else {
			why = "expected a pattern of four lengths, spades first: `5332`, `5xxx`, `any 4432`"
		}
		if why != "" {
			report(p, p.line_index, col, why)
			return 0, false
		}
		if node.count == SHAPE_PATTERNS_MAX {
			report(p, p.line_index, col, "too many patterns in one `shape` - at most 12; join two with `or`")
			return 0, false
		}
		node.patterns[node.count] = pattern
		node.count += 1
		skip_spaces(p)
		if strings.has_prefix(p.text, ",") {
			advance(p, 1)
			continue
		}
		if strings.has_prefix(p.text, ")") {
			advance(p, 1)
			return add_node(p, node), true
		}
		report(p, p.line_index, p.col, "expected `,` and another pattern, or `)`")
		return 0, false
	}
}

// One pattern's word: four characters, each a digit or `x` (`5332`, `5xxx`), or four parts joined by hyphens
// (`10-1-1-1`). The lengths must add up to 13, or to less with an `x` to take the rest.
@(private)
read_shape_pattern :: proc(word: string, any: bool) -> (pattern: Shape_Pattern, why: string) {
	pattern.any = any
	parts: [4]string
	count := 0
	if strings.contains_rune(word, '-') {
		rest := word
		for part in strings.split_iterator(&rest, "-") {
			if count == 4 {
				count += 1
				break
			}
			parts[count] = part
			count += 1
		}
	} else if len(word) == 4 {
		for i in 0 ..< 4 {
			parts[i] = word[i:i + 1]
		}
		count = 4
	}
	bad := strings.concatenate(
		{"`", word, "` is not a shape: four lengths, spades first - `5332`, `5xxx`, or `10-1-1-1` past 9"},
		context.temp_allocator,
	)
	if count != 4 {
		return pattern, bad
	}
	total, free := 0, false
	for part, i in parts {
		if part == "x" || part == "X" {
			pattern.lengths[i] = -1
			free = true
			continue
		}
		if part == "" || len(part) > 2 {
			return pattern, bad
		}
		value := 0
		for c in transmute([]u8)part {
			if c < '0' || c > '9' {
				return pattern, bad
			}
			value = value * 10 + int(c - '0')
		}
		if value > 13 {
			return pattern, bad
		}
		pattern.lengths[i] = i8(value)
		total += value
	}
	if total > 13 || (!free && total != 13) {
		return pattern, strings.concatenate(
			{"`", word, "` does not add up to 13 cards", " - use `x` for a length left open" if !free else ""},
			context.temp_allocator,
		)
	}
	return pattern, ""
}

@(private)
parse_comparison :: proc(p: ^Parser, quantity: Quantity, start_col: int) -> (root: int, ok: bool) {
	skip_spaces(p)

	// A SUM on the left (`spades + hearts`, `hcp - 2`), or another number on the right (`spades > hearts`): a
	// `Sum_Compare_Node`. Anything else is the plain `Compare_Node` below, as it always was.
	if strings.has_prefix(p.text, "+") || strings.has_prefix(p.text, "-") || quantity_after_comparison(p) {
		return parse_sum_start(p, Term{quantity = quantity}, start_col)
	}

	// `hcp in 15..17`
	if word, has_word := peek_word(p); has_word && folded(word) == "in" {
		take_word(p)
		low, low_ok := take_int(p)
		if !low_ok {
			report(p, p.line_index, p.col, "expected the low end of the range")
			return 0, false
		}
		skip_spaces(p)
		if !strings.has_prefix(p.text, "..") {
			report(p, p.line_index, p.col, "expected `..` between the ends of the range")
			return 0, false
		}
		advance(p, 2)
		high, high_ok := take_int(p)
		if !high_ok {
			report(p, p.line_index, p.col, "expected the high end of the range")
			return 0, false
		}
		if low > high {
			report(p, p.line_index, start_col, "the range is the wrong way round — the low end must come first")
			return 0, false
		}
		return add_node(p, Compare_Node{quantity = quantity, value = low, is_range = true, high = high}), true
	}

	op, has_op := take_comparison(p)
	if !has_op {
		report(p, p.line_index, p.col, "expected a comparison (`>= 15`) or a range (`in 15..17`)")
		return 0, false
	}
	value, value_ok := take_int(p)
	if !value_ok {
		report(p, p.line_index, p.col, "expected a number after the comparison, or a number of the hand - hcp, controls, a suit or longest")
		return 0, false
	}
	return add_node(p, Compare_Node{quantity = quantity, op = op, value = value}), true
}

// Is what follows a comparison and then a number OF THE HAND (`> hearts`, `> cards(...)`), rather than a plain
// number? The cursor is left where it was.
@(private)
quantity_after_comparison :: proc(p: ^Parser) -> bool {
	save, save_col := p.text, p.col
	defer p.text, p.col = save, save_col
	if _, has_op := take_comparison(p); !has_op {
		return false
	}
	word, has_word := peek_word(p)
	if !has_word || is_number_start(word[0]) {
		return false
	}
	_, is_quantity := quantity_of(folded(word))
	return is_quantity || folded(word) == "cards"
}

// A sum whose first term is read: the rest of it, then its comparison.
@(private)
parse_sum_start :: proc(p: ^Parser, first: Term, start_col: int) -> (root: int, ok: bool) {
	left := Sum{}
	append_term(p, &left, first, start_col) or_return
	read_sum_tail(p, &left) or_return
	return parse_sum_comparison(p, left, start_col)
}

/*
`cards(spades, AKQ)`, the word `cards` already read: a suit and the cards of it, as ranks run together (`AKQJT`,
`AKQJ10`, `AQ9`) or apart (`A K Q`, `ace king`).
*/
@(private)
parse_card_pool :: proc(p: ^Parser) -> (term: Term, ok: bool) {
	USAGE :: "`cards` takes a suit and its cards: `cards(spades, AKQ) >= 2` - two of the top three spades"
	skip_spaces(p)
	if !strings.has_prefix(p.text, "(") {
		report(p, p.line_index, p.col, USAGE)
		return {}, false
	}
	advance(p, 1)
	suit_col := p.col
	suit_word, _ := take_word(p)
	suit, is_suit := suit_of(folded(suit_word))
	if !is_suit {
		report(p, p.line_index, suit_col, "expected a suit — clubs, diamonds, hearts or spades")
		return {}, false
	}
	skip_spaces(p)
	if strings.has_prefix(p.text, ",") {
		advance(p, 1)
	}
	term = Term{is_cards = true, suit = suit}
	for {
		skip_spaces(p)
		if strings.has_prefix(p.text, ")") {
			break
		}
		word_col := p.col
		word, has_word := take_word(p)
		if !has_word {
			report(p, p.line_index, p.col, "expected the cards, then `)`")
			return {}, false
		}
		ranks, bad := ranks_of(word)
		if bad != "" {
			report(p, p.line_index, word_col, strings.concatenate({"`", word, "` is not a list of cards: ", bad}, context.temp_allocator))
			return {}, false
		}
		if ranks & term.cards != {} {
			report(p, p.line_index, word_col, fmt_message(p, "`%s` names a card already named", word))
			return {}, false
		}
		term.cards += ranks
		skip_spaces(p)
		if strings.has_prefix(p.text, ",") {
			advance(p, 1)
		}
	}
	advance(p, 1)
	if term.cards == {} {
		report(p, p.line_index, suit_col, USAGE)
		return {}, false
	}
	return term, true
}

// The ranks in one word of a card pool: a rank's name (`ace`, `10`), or its letters run together (`AKQJT`,
// `KJ10`). `bad` says what is wrong, "" when nothing.
@(private)
ranks_of :: proc(word: string) -> (ranks: norn.Rank_Set, bad: string) {
	lowered := folded(word)
	if rank, is_rank := rank_of(lowered); is_rank {
		return {rank}, ""
	}
	for i := 0; i < len(lowered); i += 1 {
		letter := lowered[i:i + 1]
		if lowered[i] == '1' && i + 1 < len(lowered) && lowered[i + 1] == '0' {
			letter = "10"
			i += 1
		}
		rank, is_rank := rank_of(letter)
		if !is_rank {
			return {}, "a card is A K Q J T (or 10), or 9 down to 2"
		}
		if rank in ranks {
			return {}, "a card is named twice"
		}
		ranks += {rank}
	}
	return ranks, ""
}

@(private)
is_number_start :: proc(c: byte) -> bool {
	return (c >= '0' && c <= '9') || c == '-' || c == '+'
}

// The rest of a sum after its first term: `+ hearts + diamonds`, `+ cards(hearts, AK)`, and a constant at the
// end, `+ 2` or `- 1`. Each term a hand's number, and not `seat` or `opc` (see `Sum_Compare_Node`).
@(private)
read_sum_tail :: proc(p: ^Parser, sum: ^Sum) -> (ok: bool) {
	for {
		skip_spaces(p)
		minus := strings.has_prefix(p.text, "-")
		if !minus && !strings.has_prefix(p.text, "+") {
			return true
		}
		sign_col := p.col
		advance(p, 1)
		skip_spaces(p)
		term_col := p.col
		if len(p.text) > 0 && p.text[0] >= '0' && p.text[0] <= '9' {
			value, _ := take_int(p)
			sum.constant += -value if minus else value
			skip_spaces(p)
			if strings.has_prefix(p.text, "+") || strings.has_prefix(p.text, "-") {
				report(p, p.line_index, p.col, "a number added to a sum comes last: `hearts + diamonds + 2`")
				return false
			}
			return true
		}
		if minus {
			report(p, p.line_index, sign_col, "only a number is taken away (`hcp - 2`); the hand's numbers are added up")
			return false
		}
		word, has_word := take_word(p)
		term: Term
		is_term := false
		if has_word && folded(word) == "cards" {
			term = parse_card_pool(p) or_return
			is_term = true
		} else if has_word {
			term.quantity, is_term = quantity_of(folded(word))
		}
		if !is_term {
			report(p, p.line_index, term_col, "expected a number of the hand after `+` - hcp, controls, a suit, longest or cards(...) - or a number")
			return false
		}
		append_term(p, sum, term, term_col) or_return
	}
}

@(private)
is_place_or_judgement :: proc(term: Term) -> bool {
	return !term.is_cards && (term.quantity == .Seat || term.quantity == .Opc)
}

// One term of a sum, refused when it is not a number a hand can add up.
@(private)
append_term :: proc(p: ^Parser, sum: ^Sum, term: Term, col: int) -> (ok: bool) {
	if is_place_or_judgement(term) || (sum.count > 0 && is_place_or_judgement(sum.terms[0])) {
		report(p, p.line_index, col, "`seat` and `opc` are not added to or compared with the hand's other numbers")
		return false
	}
	if sum.count >= SUM_TERMS_MAX {
		report(p, p.line_index, col, "a sum adds up at most four numbers")
		return false
	}
	sum.terms[sum.count] = term
	sum.count += 1
	return true
}

// `<sum> <op> <number or sum>`, or `<sum> in <low>..<high>`, the left already read.
@(private)
parse_sum_comparison :: proc(p: ^Parser, left: Sum, start_col: int) -> (root: int, ok: bool) {
	skip_spaces(p)
	if word, has_word := peek_word(p); has_word && folded(word) == "in" {
		take_word(p)
		low, low_ok := take_int(p)
		skip_spaces(p)
		if !low_ok || !strings.has_prefix(p.text, "..") {
			report(p, p.line_index, p.col, "expected a range: `in <low>..<high>`")
			return 0, false
		}
		advance(p, 2)
		high, high_ok := take_int(p)
		if !high_ok {
			report(p, p.line_index, p.col, "expected the high end of the range")
			return 0, false
		}
		if low > high {
			report(p, p.line_index, start_col, "the range is the wrong way round — the low end must come first")
			return 0, false
		}
		return add_node(p, Sum_Compare_Node{left = left, is_range = true, value = low, high = high}), true
	}
	op, has_op := take_comparison(p)
	if !has_op {
		report(p, p.line_index, p.col, "expected a comparison (`>= 9`, `> hearts`) or a range (`in 9..11`)")
		return 0, false
	}
	skip_spaces(p)
	right_col := p.col
	// A WORD here is a number of the hand; digits are word characters too, so a plain number is told apart first.
	if word, has_word := peek_word(p); has_word && !is_number_start(word[0]) {
		term: Term
		is_term := false
		if folded(word) == "cards" {
			take_word(p)
			term = parse_card_pool(p) or_return
			is_term = true
		} else {
			term.quantity, is_term = quantity_of(folded(word))
			if is_term {
				take_word(p)
			}
		}
		if !is_term {
			report(p, p.line_index, right_col, "expected a number, or a number of the hand - hcp, controls, a suit, longest or cards(...)")
			return 0, false
		}
		right := Sum{}
		append_term(p, &right, term, right_col) or_return
		read_sum_tail(p, &right) or_return
		return add_node(p, Sum_Compare_Node{left = left, op = op, right = right}), true
	}
	value, value_ok := take_int(p)
	if !value_ok {
		report(p, p.line_index, p.col, "expected a number after the comparison")
		return 0, false
	}
	return add_node(p, Sum_Compare_Node{left = left, op = op, value = value}), true
}

// ---------------------------------------------------------------------------------------------------
// The cursor
//
// `p.text` is what is LEFT of the line and `p.col` is where that starts, so every diagnostic can name a
// column without the scanner carrying an index as well.

@(private)
advance :: proc(p: ^Parser, n: int) {
	count := min(n, len(p.text))
	p.text = p.text[count:]
	p.col += count
}

@(private)
skip_spaces :: proc(p: ^Parser) {
	for len(p.text) > 0 && (p.text[0] == ' ' || p.text[0] == '\t') {
		advance(p, 1)
	}
}

@(private)
is_word_byte :: proc(c: byte) -> bool {
	return c == '_' || c == '-' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
peek_word :: proc(p: ^Parser) -> (word: string, ok: bool) {
	save := p.text
	save_col := p.col
	word, ok = take_word(p)
	p.text = save
	p.col = save_col
	return
}

@(private)
take_word :: proc(p: ^Parser) -> (word: string, ok: bool) {
	skip_spaces(p)
	end := 0
	for end < len(p.text) && is_word_byte(p.text[end]) {
		end += 1
	}
	if end == 0 {
		return "", false
	}
	word = p.text[:end]
	advance(p, end)
	return word, true
}

@(private)
take_int :: proc(p: ^Parser) -> (value: int, ok: bool) {
	skip_spaces(p)
	end := 0
	if end < len(p.text) && (p.text[end] == '-' || p.text[end] == '+') {
		end += 1
	}
	digits := end
	for end < len(p.text) && p.text[end] >= '0' && p.text[end] <= '9' {
		end += 1
	}
	if end == digits {
		return 0, false
	}
	value, ok = strconv.parse_int(p.text[:end])
	advance(p, end)
	return
}

// Longest first, so `>=` is not read as `>` followed by a stray `=`.
@(private)
take_comparison :: proc(p: ^Parser) -> (op: Comparison, ok: bool) {
	skip_spaces(p)
	pairs := []struct {
		text: string,
		op:   Comparison,
	} {
		{">=", .Greater_Equal},
		{"<=", .Less_Equal},
		{"!=", .Not_Equal},
		{"==", .Equal},
		{">", .Greater},
		{"<", .Less},
		{"=", .Equal},
	}
	for pair in pairs {
		if strings.has_prefix(p.text, pair.text) {
			advance(p, len(pair.text))
			return pair.op, true
		}
	}
	return {}, false
}

// A message with one substitution, in the parser's own allocator (diagnostics outlive the parse).
@(private)
fmt_message :: proc(p: ^Parser, format: string, argument: string) -> string {
	parts := strings.split(format, "%s", context.temp_allocator)
	if len(parts) != 2 {
		return format
	}
	return strings.concatenate({parts[0], argument, parts[1]}, context.temp_allocator)
}
