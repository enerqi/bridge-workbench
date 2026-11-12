package deal_solve

/*
	leads — every opening lead of a set of layouts, double dummy (LEAD_PROBLEM_PLAN.md).

	One position per layout, the opening lead (`lead_problem.opening_position`), asked for every card with its
	score (`solutions` 3) - so one solve answers the whole hand's leads. Batched `MAXNOOFBOARDS` at a time through
	`SolveAllBoardsBin`, which spreads them over DDS's threads, as `play_cost` solves a recorded play.
*/

import dds "dds:."
import "norn:norn"
import "../lead_problem"
import "../par_caption"
import "../replay"
import "../sampled"

// DDS's largest batch, and it matters: 1000 layouts took 6.6s in batches of 200, 8.0s of 100 and 12s of 40
// (measured 2026-11-11) - a batch's last boards leave threads idle. So progress steps a batch, not finer.
LEAD_BATCH :: dds.MAXNOOFBOARDS

/*
Solve the opening lead on each of `layouts`, into `futures` (one per layout, in order). ok=false when DDS refuses a
batch; the futures before it are filled.
*/
solve_leads :: proc(
	layouts: []norn.Deal,
	contract: lead_problem.Lead_Contract,
	futures: []replay.Dds_Future,
	progress: Lead_Progress = {},
) -> (
	ok: bool,
) {
	assert(len(futures) >= len(layouts))
	boards := new(dds.Boards)
	defer free(boards)
	solved := new(dds.Solved_Boards)
	defer free(solved)
	#assert(size_of(dds.Deal) == size_of(replay.Dds_Deal))
	#assert(size_of(dds.Future_Tricks) == size_of(replay.Dds_Future))
	for start := 0; start < len(layouts); start += LEAD_BATCH {
		count := min(LEAD_BATCH, len(layouts) - start)
		for i in 0 ..< count {
			boards.deals[i] = transmute(dds.Deal)lead_problem.opening_position(layouts[start + i], contract)
			boards.target[i] = replay.DDS_TARGET
			boards.solutions[i] = dds.Solutions(replay.DDS_SOLUTIONS)
			boards.mode[i] = dds.Solve_Mode(replay.DDS_MODE)
		}
		boards.noOfBoards = i32(count)
		if dds.SolveAllBoardsBin(boards, solved) != .NO_FAULT {
			return false
		}
		answers := ([^]replay.Dds_Future)(&solved.solvedBoard[0])[:count]
		copy(futures[start:start + count], answers)
		if progress.report != nil {
			progress.report(progress.user, .Leads, start + count, len(layouts))
		}
	}
	return true
}

/*
Par on each of `layouts` (vulnerability `tables[i]`), with `declaring` the side that bids first, into `pars`: the
chosen contract's comparison (`lead_problem.choice_add_par`). The tables are solved 40 layouts a call, as the
sampling's are. ok=false when DDS refuses a batch or a par.
*/
layout_pars :: proc(
	layouts: []norn.Deal,
	tables: []norn.Table,
	declaring: norn.Seat,
	pars: []par_caption.Par,
	progress: Lead_Progress = {},
	out: []sampled.Table = nil, // the tables too, when given (one per layout)
) -> (
	ok: bool,
) {
	assert(len(pars) >= len(layouts) && len(tables) >= len(layouts))
	solved := out
	if solved == nil {
		solved = make([]sampled.Table, len(layouts))
	}
	defer if out == nil {delete(solved)}
	// A batch a call, for the progress line: par is most of a chosen contract's time.
	for start := 0; start < len(layouts); start += SOLVE_BATCH {
		end := min(start + SOLVE_BATCH, len(layouts))
		if !solve_layouts(layouts[start:end], solved[start:end]) {
			return false
		}
		if progress.report != nil {
			progress.report(progress.user, .Par, end, len(layouts))
		}
	}
	side := dds.Side.NS if declaring == .North || declaring == .South else dds.Side.EW
	dds_vulnerability := DDS_VULNERABILITY
	for &table, i in solved {
		sides: [2]dds.Par_Results_Master
		res := transmute(dds.Table_Results)table
		if dds.SidesParBin(&res, &sides, dds_vulnerability[tables[i].vulnerability]) != .NO_FAULT {
			return false
		}
		pars[i] = caption_par(&sides[side])
	}
	return true
}
