package deal_solve

/*
	lead_run — one whole lead problem (LEAD_PROBLEM_PLAN.md): deal the problem, the layouts, choose the contract
	when none is given, solve the leads and rank them. `sim --lead` and the workbench's `lead problem` both call
	`lead_problem_run`; the arithmetic is `lead_problem`'s, the dealing norn's, the solves this package's.
*/

import "core:fmt"
import "core:strings"
import dds "dds:."
import "norn:norn"
import "../lead_problem"
import "../par_caption"
import "../replay"
import "../sampled"

// What a run gives back. `problem` is "" when it ran; otherwise it says why not (a scenario nothing fits, a
// solver fault). Everything is in the allocator the run was given.
Lead_Result :: struct {
	contract: lead_problem.Lead_Contract,
	hand:     norn.Hand_Summary, // the leader's
	deal:     norn.Deal, // the deal the hand was dealt from
	rows:     []lead_problem.Row,
	tally:    lead_problem.Tally, // each layout's tricks for every lead: what a row's worst layouts are read from
	deals:    []norn.Deal, // the layouts, in the tally's order
	tables:   []norn.Table, // the table each was dealt at
	solved:   []sampled.Table, // every layout's table, once `lead_problem_par` has run for a chosen contract; else nil
	layouts:  int, // layouts tallied
	dealt:    int, // deals dealt to find them
	short:    bool, // fewer layouts fit than were asked for
	typed:    bool, // the scenario fixes the leader's whole hand (a `holds:` line): the user came for the answer
	chosen:   bool, // the contract was chosen by the rules; `choice` says how
	choice:   lead_problem.Choice,
	scoring:  lead_problem.Scoring, // what the rows are ranked by
	table:    norn.Table, // the problem's table, dealer and vulnerability; every layout is shown at it
	vulnerable: bool, // the declaring side, at that table: what IMPs are scored at
	problem:  string,
}

// The most deals dealt for the problem's own deal, and for each layout asked for.
LEAD_PROBLEM_ATTEMPTS :: 20_000_000
LEAD_LAYOUT_ATTEMPTS :: 50_000

// What a run is doing, for a progress line: dealing the layouts, solving par on them (a chosen contract only),
// solving their leads.
Lead_Stage :: enum {
	Layouts,
	Par,
	Leads,
}

// Told how far a run is, between batches: `done` of `total` in `stage`. On the run's own thread.
Lead_Progress :: struct {
	report: proc(user: rawptr, stage: Lead_Stage, done, total: int),
	user:   rawptr,
}

@(private = "file")
progress_report :: proc(progress: Lead_Progress, stage: Lead_Stage, done, total: int) {
	if progress.report != nil {
		progress.report(progress.user, stage, done, total)
	}
}

/*
Run one problem over `accept` (a scenario's condition) for `request` with `layouts` layouts, dealt from the
context's random generator. The problem's hand is dealt to fit the scenario; with no contract given, the strain
the rules choose on that deal decides which of the side's seats declares (and so which hand leads), and the
contract is then the rules' most common choice over the layouts, par alongside.

IN THREE STEPS, which the workbench shows as they land (`workbench/lead.odin`): `lead_problem_deal` (the problem,
the layouts and the rules' contract: no solver, milliseconds - enough to ASK the question), `lead_problem_leads`
(every lead solved and ranked: the answer) and `lead_problem_par` (the tables of every layout: par for a chosen
contract's comparison, and the card pages' captions - most of a chosen contract's time, and needed by neither the
question nor the answer). The solves draw nothing from the random generator, so their order changes no figure.
*/
lead_problem_run :: proc(
	accept: norn.Condition,
	request: lead_problem.Lead_Request,
	layouts: int,
	allocator := context.allocator,
	progress: Lead_Progress = {},
) -> (
	result: Lead_Result,
) {
	result = lead_problem_deal(accept, request, layouts, allocator, progress)
	if result.problem == "" && lead_problem_leads(&result, allocator, progress) {
		lead_problem_par(&result, allocator, progress)
	}
	return
}

// The first step: the problem's deal, the layouts with its leader's hand fixed, and the contract when the rules
// choose it (par not yet: `lead_problem_par`).
lead_problem_deal :: proc(
	accept: norn.Condition,
	request: lead_problem.Lead_Request,
	layouts: int,
	allocator := context.allocator,
	progress: Lead_Progress = {},
) -> (
	result: Lead_Result,
) {
	context.allocator = allocator
	deals := make([dynamic]norn.Deal, 0, layouts)
	tables := make([dynamic]norn.Table, 0, layouts)

	// THE PROBLEM: one deal that fits.
	norn.collect_accepted(&deals, &tables, 1, .Pretty, accept, max_attempts = LEAD_PROBLEM_ATTEMPTS)
	if len(deals) == 0 {
		result.problem = fmt.aprintf("no deal fits the scenario in %d tries", LEAD_PROBLEM_ATTEMPTS)
		return
	}
	result.deal, result.table = deals[0], tables[0]
	result.scoring = request.scoring
	summary := norn.summarize_deal(result.deal)
	declarer := request.seats[0]
	if c, given := request.contract.?; given {
		result.contract = c
		declarer = c.declarer
	} else {
		result.chosen = true
		if !request.one_seat {
			partner := norn.Seat((int(request.seats[0]) + 2) % norn.SEAT_COUNT)
			strain := lead_problem.choose_strain(summary[request.seats[0]], summary[partner])
			declarer = lead_problem.choose_declarer(summary, {request.seats[0], partner}, strain)
		}
		result.contract.declarer = declarer
	}
	seat := lead_problem.leader(result.contract)
	result.hand = summary[seat]
	result.vulnerable = norn.vulnerable(result.table.vulnerability, declarer)
	if own, fixes := norn.condition_predeal(accept, nil); fixes {
		result.typed = own.counts[seat] == norn.HAND_SIZE
	}
	fixed: norn.Predeal
	for card in result.deal[seat] {
		norn.predeal_add(&fixed, seat, card)
	}

	// THE LAYOUTS: the scenario again, with that hand fixed. In rounds of DDS's batch, for the progress line;
	// the deals are the ones one call would deal, the stream being drawn in the same order.
	clear(&deals)
	clear(&tables)
	for len(deals) < layouts {
		round := min(dds.MAXNOOFBOARDS, layouts - len(deals))
		accepted, attempts := norn.collect_accepted(
			&deals,
			&tables,
			round,
			.Pretty,
			accept,
			max_attempts = round * LEAD_LAYOUT_ATTEMPTS,
			predeal = fixed,
		)
		result.dealt += attempts
		progress_report(progress, .Layouts, len(deals), layouts)
		if accepted < round {
			break
		}
	}
	// Every layout at the problem's table: the leader sees one dealer and one vulnerability, and the layouts' card
	// pages show the board the problem is about.
	for &table in tables {
		table = result.table
	}
	result.deals, result.tables = deals[:], tables[:]
	result.short = len(deals) < layouts
	result.layouts = len(deals)
	if len(deals) == 0 {
		result.problem = fmt.aprintf("no layout fits this hand in %d deals", result.dealt)
		return
	}

	// THE CONTRACT, when it was not given: the rules' most common choice, which needs no solver.
	if result.chosen {
		dummy := norn.Seat((int(declarer) + 2) % norn.SEAT_COUNT)
		for deal in deals {
			s := norn.summarize_deal(deal)
			lead_problem.choice_add(&result.choice, s[declarer], s[dummy])
		}
		bid, _ := lead_problem.most_common(result.choice.counts)
		result.contract.level, result.contract.strain = bid.level, bid.strain
	}
	return
}

// The second step: every lead of the hand solved on every layout, tallied and ranked. False (and `problem` said)
// when the solver refuses.
lead_problem_leads :: proc(result: ^Lead_Result, allocator := context.allocator, progress: Lead_Progress = {}) -> bool {
	context.allocator = allocator
	futures := make([]replay.Dds_Future, len(result.deals), context.temp_allocator)
	if !solve_leads(result.deals, result.contract, futures, progress) {
		result.problem = strings.clone("the double-dummy solver refused the layouts")
		return false
	}
	tally := lead_problem.make_tally(lead_problem.leads_of(result.hand))
	for fut in futures {
		lead_problem.tally_layout(&tally, result.contract, fut)
	}
	result.rows = lead_problem.rank(tally)
	lead_problem.score_rows(tally, result.contract, result.vulnerable, result.scoring, result.rows)
	result.tally = tally
	result.layouts = tally.layouts
	return true
}

/*
The third step, for a CHOSEN contract: every layout's table (`result.solved`) and its par, added to the choice.
A given contract has no par to compare, and its card pages solve only the layouts they show
(`solve_shown_layouts`). False when the solver refuses; the problem stands without par.
*/
lead_problem_par :: proc(result: ^Lead_Result, allocator := context.allocator, progress: Lead_Progress = {}) -> bool {
	if !result.chosen {
		return true
	}
	context.allocator = allocator
	bid := lead_problem.Bid{result.contract.level, result.contract.strain}
	declarer := result.contract.declarer
	pars := make([]par_caption.Par, len(result.deals), context.temp_allocator)
	solved := make([]sampled.Table, len(result.deals))
	progress_report(progress, .Par, 0, len(result.deals))
	if !layout_pars(result.deals, result.tables, declarer, pars, progress, solved) {
		delete(solved)
		return false
	}
	result.solved = solved
	for par in pars {
		lead_problem.choice_add_par(&result.choice, par, bid, declarer)
	}
	return true
}

// The run as text: the contract's choice (when chosen), then `lead_problem.write_report`.
write_lead_result :: proc(b: ^strings.Builder, result: Lead_Result) {
	if result.problem != "" {
		fmt.sbprintf(b, "%s\n", result.problem)
		return
	}
	if result.short {
		fmt.sbprintf(b, "Only %d layouts fit this hand in %d deals.\n", result.layouts, result.dealt)
	}
	if result.chosen {
		lead_problem.write_choice(b, result.choice, result.contract.declarer)
	}
	lead_problem.write_report(b, result.contract, result.hand, result.rows, result.layouts, result.dealt, result.scoring, result.table.vulnerability)
}

// The run as its page (`lead_problem.write_page`). `title` is the scenario's, `note` a line under it. A dealt hand
// is asked first (pick-first); a hand the scenario fixes shows its answer at once.
write_lead_page :: proc(b: ^strings.Builder, result: Lead_Result, title, note: string) {
	lead_problem.write_page(b, lead_page_of(result, title, note))
}

// The question alone, once the problem is dealt and before its leads are solved (`lead_problem.write_question_page`).
write_lead_question :: proc(b: ^strings.Builder, result: Lead_Result, title, note: string) {
	lead_problem.write_question_page(b, lead_page_of(result, title, note))
}

// The choice block as it stands (`lead_problem.write_choices_html`): with par once `lead_problem_par` has run.
write_lead_choices :: proc(b: ^strings.Builder, result: Lead_Result) {
	lead_problem.write_choices_html(b, result.chosen, result.choice, result.contract.declarer, result.chosen && result.solved == nil)
}

@(private = "file")
lead_page_of :: proc(result: Lead_Result, title, note: string) -> lead_problem.Page {
	return lead_problem.Page {
		title = title,
		note = note,
		contract = result.contract,
		hand = result.hand,
		rows = result.rows,
		tally = result.tally,
		deals = result.deals,
		dealt = result.dealt,
		short = result.short,
		chosen = result.chosen,
		choice = result.choice,
		pick = !result.typed,
		scoring = result.scoring,
		vulnerability = result.table.vulnerability,
		par_pending = result.chosen && result.solved == nil,
	}
}

/*
The tables of every layout some row shows (`lead_problem.worst_layouts`), solved in ONE batched call for the card
pages' par captions - a solve a board was most of a problem's time. `solved[i]` is layout i's table where `have[i]`.
ok=false when DDS refuses; the pages are then written without par.
*/
Shown_Tables :: struct {
	solved: []sampled.Table,
	have:   []bool,
}

solve_shown_layouts :: proc(result: Lead_Result, allocator := context.allocator) -> (tables: Shown_Tables, ok: bool) {
	tables.solved = make([]sampled.Table, len(result.deals), allocator)
	tables.have = make([]bool, len(result.deals), allocator)
	// Par has solved them all already (a chosen contract): nothing to solve.
	if len(result.solved) == len(result.deals) {
		copy(tables.solved, result.solved)
		for &have in tables.have {
			have = true
		}
		return tables, true
	}
	wanted := make([dynamic]int, 0, len(result.rows) * lead_problem.WORST_SHOWN, context.temp_allocator)
	for _, r in result.rows {
		for layout in lead_problem.worst_layouts(
			result.tally,
			result.contract,
			result.rows,
			r,
			lead_problem.WORST_SHOWN,
			context.temp_allocator,
		) {
			if !tables.have[layout] {
				tables.have[layout] = true
				append(&wanted, layout)
			}
		}
	}
	deals := make([]norn.Deal, len(wanted), context.temp_allocator)
	for layout, i in wanted {
		deals[i] = result.deals[layout]
	}
	out := make([]sampled.Table, len(wanted), context.temp_allocator)
	if !solve_layouts(deals, out) {
		for &have in tables.have {
			have = false
		}
		return tables, false
	}
	for layout, i in wanted {
		tables.solved[layout] = out[i]
	}
	return tables, true
}

/*
Row `r`'s worst layouts (`lead_problem.worst_layouts`) as a CARD PAGE: each layout a board of the carousel at the
table it was dealt at, its par caption from `tables` (`solve_shown_layouts`; a layout without one has no caption),
and a pill naming the two leads' tricks. "" when the row has none.
*/
lead_layouts_page :: proc(result: Lead_Result, r: int, tables: Shown_Tables, allocator := context.allocator) -> string {
	worst := lead_problem.worst_layouts(
		result.tally,
		result.contract,
		result.rows,
		r,
		lead_problem.WORST_SHOWN,
		context.temp_allocator,
	)
	if len(worst) == 0 {
		return ""
	}
	mine, theirs := result.rows[r], result.rows[lead_problem.rival(result.rows, r)]
	title := strings.builder_make(context.temp_allocator)
	lead_problem.write_lead(&title, mine.lead)
	strings.write_string(&title, " against ")
	lead_problem.write_contract(&title, result.contract)
	strings.write_string(&title, ": where it did worst against ")
	lead_problem.write_lead(&title, theirs.lead)
	b := strings.builder_make(allocator)
	norn.render_page_prologue(&b, .Html_Cards, strings.to_string(title))
	for layout in worst {
		deal, table := result.deals[layout], result.tables[layout]
		norn.render_deal_html_cards_at(&b, deal, table)
		pill := strings.builder_make(context.temp_allocator)
		for row, i in ([2]lead_problem.Row{mine, theirs}) {
			if i > 0 {
				strings.write_string(&pill, " · ")
			}
			lead_problem.write_lead(&pill, row.lead)
			fmt.sbprintf(&pill, " %d", lead_problem.row_tricks(result.tally, row, layout))
		}
		fmt.sbprintf(
			&b,
			`<div class="why" title="The defence's tricks double dummy: this lead, then the one it is measured against">%s</div>`,
			strings.to_string(pill),
		)
		if layout < len(tables.have) && tables.have[layout] {
			res := transmute(dds.Table_Results)tables.solved[layout]
			annotate_solved(&b, deal, .Html_Cards, &res, table.vulnerability)
		}
	}
	norn.render_page_epilogue(&b, .Html_Cards)
	return strings.to_string(b)
}
