package deal_solve

import "core:math/rand"
import "core:strings"
import "core:testing"
import "norn:norn"
import "../lead_problem"
import "../replay"

/*
West holds five top spades against 3NT by South, and North-South every other high card. A spade lead cashes five
and beats it; on any other lead declarer runs nine tricks first. The solved ranking must say exactly that.
*/
@(test)
test_the_lead_that_cashes_the_setting_tricks_ranks_first :: proc(t: ^testing.T) {
	init()
	defer shutdown()
	board, err := norn.parse_pbn_deal(`[Deal "N:43.AKQ.AKQJT.AKQ 98765.765.654.65 2.JT98.987.JT987 AKQJT.432.32.432"]`)
	if !testing.expect_value(t, err, norn.Pbn_Parse_Error.None) {return}
	contract := lead_problem.Lead_Contract{level = 3, strain = .NoTrumps, declarer = .South}

	futures: [1]replay.Dds_Future
	if !testing.expect(t, solve_leads({board.deal}, contract, futures[:]), "the solve succeeds") {return}
	hand := norn.summarize_deal(board.deal)[.West]
	tally := lead_problem.make_tally(lead_problem.leads_of(hand, context.temp_allocator), context.temp_allocator)
	testing.expect(t, lead_problem.tally_layout(&tally, contract, futures[0]), "every lead is answered")
	rows := lead_problem.rank(tally, context.temp_allocator)

	testing.expect_value(t, rows[0].lead.suit, norn.Suit.Spades)
	testing.expect_value(t, rows[0].lead.cards, norn.Rank_Set{.Ace, .King, .Queen, .Jack, .Ten})
	testing.expect_value(t, rows[0].beats, 1.0)
	testing.expect_value(t, rows[0].tricks, 5.0)
	for row in rows[1:] {
		testing.expectf(t, row.beats == 0 && row.tricks < 5 && row.cost > 0, "%v lets the contract make", row)
	}
	// Each other suit's small cards are one lead: nothing on the layout tells them apart.
	testing.expect_value(t, len(rows), 4)
}

/*
A WHOLE RUN with the contract left to the rules: North-South hold 26+ hcp, so the problem is dealt, the declarer
and contract chosen, par compared on every layout and the leads ranked over all of them.
*/
@(test)
test_a_lead_problem_with_the_contract_chosen_runs_end_to_end :: proc(t: ^testing.T) {
	init()
	defer shutdown()
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 11)
	strong := norn.Predicate(proc(s: norn.Deal_Summary) -> bool {return norn.hcp(s[.North]) + norn.hcp(s[.South]) >= 26})
	request, bad := lead_problem.parse_lead_request("north-south")
	if !testing.expect_value(t, bad, "") {return}
	result := lead_problem_run(strong, request, 40, context.temp_allocator)
	testing.expect_value(t, result.problem, "")
	testing.expect(t, result.chosen, "the contract was chosen")
	testing.expect_value(t, result.layouts, 40)
	testing.expect_value(t, result.choice.layouts, 40)
	testing.expect_value(t, result.choice.pars, 40)
	testing.expect(t, result.contract.declarer == .North || result.contract.declarer == .South, "North-South declare")
	testing.expect(t, result.contract.level >= 3, "26 hcp bid game or more")
	_, count := lead_problem.most_common(result.choice.counts)
	testing.expect(t, count > 0 && len(result.rows) > 0, "a contract and a ranking")
	testing.expect_value(t, len(result.deals), 40)
	testing.expect_value(t, len(result.tally.each), 40 * len(result.tally.leads))

	// THE PAGES: the problem, and a row's worst layouts as a card page, a board each with its pill and par.
	b := strings.builder_make(context.temp_allocator)
	write_lead_page(&b, result, "strong", "seed 11")
	testing.expect(t, !result.typed && strings.contains(strings.to_string(b), lead_problem.PICK_BODY), "a dealt hand asks first")
	testing.expectf(t, strings.count(strings.to_string(b), `<div class="lead" data-row=`) == len(result.rows), "a line a row")
	tables, solved := solve_shown_layouts(result, context.temp_allocator)
	testing.expect(t, solved, "the shown layouts' tables are solved")
	shown := 0
	for _, r in result.rows {
		worst := lead_problem.worst_layouts(result.tally, result.contract, result.rows, r, lead_problem.WORST_SHOWN, context.temp_allocator)
		page := lead_layouts_page(result, r, tables, context.temp_allocator)
		if len(worst) == 0 {
			testing.expect_value(t, page, "")
			continue
		}
		shown += 1
		testing.expectf(t, strings.count(page, `<div class="compass"`) == len(worst), "row %d: a board a layout", r)
		testing.expectf(t, strings.count(page, `<div class="why"`) == len(worst), "row %d: a pill a board", r)
		testing.expectf(t, strings.count(page, `class="par"`) >= len(worst), "row %d: par on each board", r)
	}
	testing.expect(t, shown > 0, "some row has layouts it did worse on")
}

/*
A hand the scenario FIXES (a `west holds:` line) was typed by someone who came for the answer: the run says so and
the page does not ask for the lead first.
*/
@(test)
test_a_typed_hand_is_answered_at_once :: proc(t: ^testing.T) {
	init()
	defer shutdown()
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 3)
	board, err := norn.parse_pbn_deal(`[Deal "N:43.AKQ.AKQJT.AKQ 98765.765.654.65 2.JT98.987.JT987 AKQJT.432.32.432"]`)
	if !testing.expect_value(t, err, norn.Pbn_Parse_Error.None) {return}
	fixed: norn.Predeal
	for card in board.deal[.West] {
		norn.predeal_add(&fixed, .West, card)
	}
	typed := norn.Condition(
		norn.Interpreted_Predicate {
			call = proc(_: norn.Deal_Summary, _: norn.Table, _: rawptr) -> bool {return true},
			predeal = fixed,
		},
	)
	request, bad := lead_problem.parse_lead_request("4S:south")
	if !testing.expect_value(t, bad, "") {return}
	result := lead_problem_run(typed, request, 20, context.temp_allocator)
	testing.expect_value(t, result.problem, "")
	testing.expect(t, result.typed, "the leader's hand is the scenario's")
	b := strings.builder_make(context.temp_allocator)
	write_lead_page(&b, result, "typed", "")
	testing.expect(t, !strings.contains(strings.to_string(b), lead_problem.PICK_BODY), "answered at once")
}
