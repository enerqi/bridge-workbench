package bidding

/*
	builtin.odin — the scenarios this program ships, as TEXT: `swedish-club.scenario`, compiled into the exe and
	read by `scenario_dsl.load_directories` before any folder of the user's.

	They were the compiled `registry` (scenarios.odin), and that is still here for one job: the parity test
	(`swedish_club_text_test.odin`) holds every text scenario to the compiled predicate of its name, deal for deal.
	Shipping them as text means a user's system can `extend swedish-club` and override a meaning, and the editor
	can show what each built-in scenario says.
*/

import "../scenario_dsl"

SWEDISH_CLUB_TEXT :: #load("swedish-club.scenario", string)

// What `sim` and the workbench pass to `scenario_dsl.load_directories` as `builtins`.
builtin_files := []scenario_dsl.Builtin_File{{name = "swedish-club.scenario", text = SWEDISH_CLUB_TEXT}}
