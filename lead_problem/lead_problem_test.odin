#+build !js
package lead_problem

import "core:strings"
import "core:testing"
import "norn:norn"
import "../replay"

@(test)
test_a_lead_contract_reads_both_spellings :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		want: Lead_Contract,
	} {
		{"4S:south", {4, .Spades, .South}},
		{"3nt by north", {3, .NoTrumps, .North}},
		{"1N:e", {1, .NoTrumps, .East}},
		{" 6d : W ", {6, .Diamonds, .West}},
	}
	for c in cases {
		got, bad := parse_lead_contract(c.text)
		testing.expectf(t, bad == "" && got == c.want, "%q: %v (%s)", c.text, got, bad)
	}
	for text in ([]string{"", "4S", "8S:south", "4X:south", "4S:nowhere", "S4:south"}) {
		_, bad := parse_lead_contract(text)
		testing.expectf(t, bad != "", "%q is refused", text)
	}
	c, _ := parse_lead_contract("4S:south")
	testing.expect_value(t, leader(c), norn.Seat.West)
	testing.expect_value(t, tricks_to_beat(c), 4)
}

// A hand's leads are its sequences, spades to clubs and high to low; a void gives none.
@(test)
test_a_hands_leads_are_its_sequences :: proc(t: ^testing.T) {
	hand: norn.Hand_Summary
	hand.suits[.Spades] = {.King, .Queen, .Ten}
	hand.suits[.Diamonds] = {.Nine, .Eight, .Seven, .Two}
	hand.suits[.Clubs] = {.Ace, .King, .Queen, .Jack, .Ten, .Three}
	leads := leads_of(hand, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for lead, i in leads {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		write_lead(&b, lead)
	}
	testing.expect_value(t, strings.to_string(b), "♠KQ ♠T ♦987 ♦2 ♣AKQJT ♣3")
	testing.expect_value(t, leads[0].top, norn.Rank.King)
}

// A made-up answer from the solver: `scores` per lead's top card, in DDS's terms.
@(private = "file")
answer :: proc(cards: []struct {
		suit:   norn.Suit,
		rank:   norn.Rank,
		equals: norn.Rank_Set,
		score:  int,
	}) -> (fut: replay.Dds_Future) {
	for c, k in cards {
		fut.suit[k] = i32(3 - int(c.suit))
		fut.rank[k] = i32(c.rank) + 2
		for r in c.equals {
			fut.equals[k] |= u32(1) << (u32(r) + 2)
		}
		fut.score[k] = i32(c.score)
	}
	fut.cards = i32(len(cards))
	return
}

/*
THE TALLY AND THE RANKING over made-up answers: a lead's figures are its own over the layouts; DDS's `equals` give
the lower cards their score; leads of a suit that scored the same on every layout are one row, and two that
differed once are not; a layout whose answer misses a lead is not counted.
*/
@(test)
test_leads_are_tallied_ranked_and_joined :: proc(t: ^testing.T) {
	hand: norn.Hand_Summary
	hand.suits[.Hearts] = {.Ace, .Five}
	hand.suits[.Diamonds] = {.Six, .Two}
	hand.suits[.Clubs] = {.Nine}
	c := Lead_Contract{4, .Spades, .South} // 4 defence tricks beat it
	tally := make_tally(leads_of(hand, context.temp_allocator), context.temp_allocator)

	// Layout 1: ♥A 4, ♥5 3, the diamonds 2 (the ♦2 by `equals` with the ♦6), ♣9 1.
	testing.expect(
		t,
		tally_layout(&tally, c, answer({{.Hearts, .Ace, {}, 4}, {.Hearts, .Five, {}, 3}, {.Diamonds, .Six, {.Two}, 2}, {.Clubs, .Nine, {}, 1}})),
		"",
	)
	// Layout 2: ♥A 3, ♥5 4, the diamonds 2 each, ♣9 4.
	testing.expect(
		t,
		tally_layout(&tally, c, answer({{.Hearts, .Ace, {}, 3}, {.Hearts, .Five, {}, 4}, {.Diamonds, .Six, {}, 2}, {.Diamonds, .Two, {}, 2}, {.Clubs, .Nine, {}, 4}})),
		"",
	)
	// A failed solve: no clubs in the answer.
	testing.expect(t, !tally_layout(&tally, c, answer({{.Hearts, .Ace, {}, 9}})), "an incomplete answer is refused")
	testing.expect_value(t, tally.layouts, 2)

	rows := rank(tally, context.temp_allocator)
	testing.expect_value(t, len(rows), 4) // ♥A, ♥5, ♦62 joined, ♣9
	b := strings.builder_make(context.temp_allocator)
	for row in rows {
		write_lead(&b, row.lead)
		strings.write_byte(&b, ' ')
	}
	// ♥A and ♥5 beat it once each, 3.5 tricks; ♣9 once, 2.5; the diamonds never.
	testing.expect_value(t, strings.to_string(b), "♥A ♥5 ♣9 ♦62 ")
	testing.expect_value(t, rows[0].beats, 0.5)
	testing.expect_value(t, rows[0].tricks, 3.5)
	testing.expect_value(t, rows[0].cost, 0.0)
	testing.expect_value(t, rows[3].beats, 0.0)
	testing.expect_value(t, rows[3].cost, 1.5)

	report := strings.builder_make(context.temp_allocator)
	write_report(&report, c, hand, rows, tally.layouts, 9)
	testing.expectf(
		t,
		strings.has_prefix(strings.to_string(report), "West leads against 4♠ by South: ♠- ♥A5 ♦62 ♣9\nNeither side vulnerable\n2 layouts (9 deals"),
		"%s",
		strings.to_string(report),
	)
}

/*
THE WHY: a row's worst layouts are those where its rival (the top row; the runner-up for the top row) took more
tricks, a gap that changes beating the contract first, then the bigger gap. The page draws them under the row and
links them for the host; the hand marks the best lead and keeps each figure to a hover title.
*/
@(test)
test_a_rows_worst_layouts_are_where_its_rival_did_better :: proc(t: ^testing.T) {
	hand: norn.Hand_Summary
	hand.suits[.Hearts] = {.Ace}
	hand.suits[.Clubs] = {.Nine}
	c := Lead_Contract{4, .Spades, .South} // 4 beat it
	tally := make_tally(leads_of(hand, context.temp_allocator), context.temp_allocator)
	// ♥A / ♣9 per layout: 4/3 (a swing, gap 1), 5/1 (a swing, gap 4), 2/2 (no gap), 3/1 (gap 2, no swing), 1/4
	// (♣9 better).
	scores := [][2]int{{4, 3}, {5, 1}, {2, 2}, {3, 1}, {1, 4}}
	for s in scores {
		testing.expect(t, tally_layout(&tally, c, answer({{.Hearts, .Ace, {}, s[0]}, {.Clubs, .Nine, {}, s[1]}})), "")
	}
	rows := rank(tally, context.temp_allocator)
	testing.expect_value(t, rows[0].lead.suit, norn.Suit.Hearts) // beats it twice against once
	testing.expect_value(t, rival(rows, 0), 1)
	testing.expect_value(t, rival(rows, 1), 0)
	testing.expect_value(t, rival(rows[:1], 0), -1)

	worst := worst_layouts(tally, c, rows, 1, 10, context.temp_allocator)
	testing.expect_value(t, len(worst), 3)
	testing.expect_value(t, worst[0], 1) // swings, gap 4
	testing.expect_value(t, worst[1], 0) // swings, gap 1
	testing.expect_value(t, worst[2], 3) // gap 2, no swing
	testing.expect_value(t, len(worst_layouts(tally, c, rows, 1, 2, context.temp_allocator)), 2)
	best := worst_layouts(tally, c, rows, 0, 10, context.temp_allocator)
	testing.expect(t, len(best) == 1 && best[0] == 4, "the best lead's worst layout is the one the runner-up won")

	deals := make([]norn.Deal, tally.layouts, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	write_page(&b, Page{title = "1♠ – 2♠ & <4♠>", contract = c, hand = hand, rows = rows, tally = tally, deals = deals, dealt = 9})
	page := strings.clone(strings.to_string(b), context.temp_allocator)
	testing.expect(t, strings.has_prefix(page, "<!DOCTYPE html>"), "a document")
	testing.expect(t, strings.contains(page, "1♠ – 2♠ &amp; &lt;4♠&gt;"), "the title is escaped")
	testing.expect(t, strings.contains(page, `<h1>West leads against 4♠ by South</h1>`), "the heading")
	testing.expect(t, strings.contains(page, `<span class="g best" data-row="0" data-fig="beats it 40%" title="beats it 40%">A</span>`), "the hand marks the best lead")
	testing.expect(t, strings.contains(page, "<body>"), "a page that asks nothing")
	testing.expect_value(t, strings.count(page, `<div class="lead" data-row=`), 2)
	testing.expect_value(t, strings.count(page, `<div class="layout">`), 4) // 3 under ♣9, 1 under ♥A
	// The diagrams are script strings, the folds empty until opened: `</` cannot close the script.
	testing.expect_value(t, strings.count(page, `<div class="why"></div>`), 2)
	script := page[strings.index(page, "var WHY"):]
	testing.expect(t, !strings.contains(script[:strings.index(script, "];")], "</"), "every </ in the strings is escaped")
	testing.expect(t, strings.contains(page, `href="#lead-row-1"`) && strings.contains(page, `href="#lead-row-0"`), "the host's links")
	testing.expect(t, strings.contains(page, "5 layouts (9 deals"), "the count")
	// `next problem` is the workbench's: a browser hides its whole row (a `.next a` rule outranked `.host`'s
	// `display: none`, and the browser showed a link nothing answers).
	testing.expect(t, strings.contains(page, ".next { display: none;"), "the next row is hidden by default")
	shown := strings.index(page, ".next { display: block; }")
	testing.expect(t, shown > strings.index(page, "@media sciter"), "and shown in the workbench")

	// PICK FIRST: the body asks, the hand carries no figure until answered, each row has its verdict waiting.
	strings.builder_reset(&b)
	write_page(&b, Page{contract = c, hand = hand, rows = rows, tally = tally, deals = deals, dealt = 9, pick = true})
	asked := strings.to_string(b)
	testing.expect(t, strings.contains(asked, PICK_BODY), "the page asks")
	testing.expect(t, strings.contains(asked, `<span class="g best" data-row="0" data-fig="beats it 40%">A</span>`), "no hover figure yet")
	testing.expect(t, strings.contains(asked, `Which card do you lead?`), "the question")
	testing.expect_value(t, strings.count(asked, `<div class="verdict" data-row=`), 2)
	testing.expect(t, strings.contains(asked, `is <span class="good">the best lead</span>`), "the best's verdict")
	testing.expect(t, strings.contains(asked, `<span class="cost">`), "the other's says what it gave away")
	testing.expect(t, is_best(rows, 0) && !is_best(rows, 1) && !is_best(rows, 2), "only the top row is the best here")
	answered := answered_page(asked, 1, context.temp_allocator)
	testing.expect(t, !strings.contains(answered, PICK_BODY) && strings.contains(answered, `<body data-picked="1">`), "answered")
	testing.expect_value(t, answered_page(page, 1, context.temp_allocator), page) // a page that asked nothing is kept
}

/*
THE SCORING FORMS (scoring.odin): ♥A sets 4♠ on two layouts in six and gives an overtrick on the other four; ♣9
never sets it and never gives one. ♣9 takes more tricks, so it is the field's lead. At IMPs the two sets (10 each,
not vulnerable) outweigh the four overtricks (1 each), so ♥A is best; at matchpoints two tops against four bottoms
lose to the field's steady 50%.
*/
@(test)
test_imps_and_matchpoints_weigh_a_set_against_overtricks :: proc(t: ^testing.T) {
	hand: norn.Hand_Summary
	hand.suits[.Hearts] = {.Ace}
	hand.suits[.Clubs] = {.Nine}
	c := Lead_Contract{4, .Spades, .South}
	tally := make_tally(leads_of(hand, context.temp_allocator), context.temp_allocator)
	for s in ([][2]int{{4, 3}, {4, 3}, {2, 3}, {2, 3}, {2, 3}, {2, 3}}) {
		testing.expect(t, tally_layout(&tally, c, answer({{.Hearts, .Ace, {}, s[0]}, {.Clubs, .Nine, {}, s[1]}})), "")
	}
	testing.expect_value(t, defence_points(c, 4, false), 50)
	testing.expect_value(t, defence_points(c, 2, true), -650)

	rows := rank(tally, context.temp_allocator)
	score_rows(tally, c, false, .Imps, rows)
	testing.expect_value(t, rows[0].lead.suit, norn.Suit.Hearts)
	testing.expectf(t, abs(rows[0].imps - 16.0 / 6) < 1e-9, "♥A: +10 +10 -1 -1 -1 -1 IMPs, %v", rows[0].imps)
	testing.expect(t, rows[1].field && rows[1].imps == 0 && rows[1].mp == 0.5, "♣9 is the field's lead")
	testing.expect(t, rows[1].key_margin > 0 && rows[0].key_margin == 0, "the gap's margin is paired with the top row")
	testing.expect(t, is_best(rows, 0) && !is_best(rows, 1), "")

	score_rows(tally, c, true, .Imps, rows)
	testing.expectf(t, abs(rows[0].imps - 20.0 / 6) < 1e-9, "vulnerable, a set is 12 IMPs: %v", rows[0].imps)

	rows = rank(tally, context.temp_allocator)
	score_rows(tally, c, false, .Matchpoints, rows)
	testing.expect(t, rows[0].field && rows[0].lead.suit == .Clubs, "at matchpoints the field's lead is best")
	testing.expectf(t, abs(rows[1].mp - 1.0 / 3) < 1e-9, "♥A: two tops in six, %v", rows[1].mp)

	report := strings.builder_make(context.temp_allocator)
	write_report(&report, c, hand, rows, tally.layouts, 6, .Matchpoints, .North_South)
	text := strings.to_string(report)
	testing.expectf(t, strings.contains(text, "North-South vulnerable · Scored at matchpoints") && strings.contains(text, "field") && strings.contains(text, "33%"), "%s", text)

	b := strings.builder_make(context.temp_allocator)
	deals := make([]norn.Deal, tally.layouts, context.temp_allocator)
	score_rows(tally, c, false, .Imps, rows)
	write_page(&b, Page{contract = c, hand = hand, rows = rows, tally = tally, deals = deals, dealt = 6, scoring = .Imps, pick = true})
	page := strings.to_string(b)
	testing.expect(t, strings.contains(page, `<span class="c on" data-key="imps"`), "the IMPs column leads, lit")
	testing.expect(t, strings.contains(page, `data-fig="+2.67 IMPs"`), "the hand's figure is the scoring's")
	testing.expect(t, strings.contains(page, `Neither side vulnerable · Scored at IMPs`), "the heading says how it is scored")
	testing.expect(t, strings.contains(page, `, scores +2.67 IMPs a board against the field's lead, ♣9.</div>`) || strings.contains(page, `the best lead</span>, scores +2.67 IMPs`), "the best's verdict names the field")
	testing.expect(t, strings.contains(page, `the field's lead (the one taking the most tricks); the best, `), "the field's own verdict")
}
