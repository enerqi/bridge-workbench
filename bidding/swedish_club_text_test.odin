package bidding

/*
	swedish_club_text_test.odin — the Swedish Club as TEXT (`swedish-club.scenario`) held to the compiled
	scenarios of the same names, deal for deal.

	The guard for shipping the built-in set as scenario files: a text scenario costs the same per deal as a
	compiled one (measured, `TODO-scenario-create-select-filter.md`), so the question is whether the text says
	what the compiled predicate says. A disagreement here is the language falling short (or the text being
	wrong), and the deal it disagreed on is printed so the boundary can be found.
*/

import "core:fmt"
import "core:math/rand"
import "core:testing"
import "core:thread"
import "norn:cli"
import "norn:norn"
import "../scenario_dsl"


// Deals per scenario. The rarest (`4n`, `1d-unbal_two-suiter-slam-try`, `2d-precision_18plus`) are kept 17-31
// times in these; every deal any scenario REJECTS is compared as well.
@(private = "file")
PARITY_DEALS :: 300_000

@(test)
test_the_text_swedish_club_is_the_compiled_one :: proc(t: ^testing.T) {
	scenario_dsl.set_vocabulary(vocabulary)
	programs, diagnostics := scenario_dsl.parse(SWEDISH_CLUB_TEXT, "swedish-club.scenario", context.temp_allocator)
	defer for &program in programs {
		scenario_dsl.destroy_program(&program)
	}
	testing.expectf(t, len(diagnostics) == 0, "the file should parse clean: %v", diagnostics)
	if !testing.expect(t, len(programs) > 0, "the file holds no scenarios") {
		return
	}

	// Every compiled scenario has its text, so the file can take the registry's place.
	for scenario in registry {
		found := false
		for program in programs {
			found ||= program.name == scenario.name
		}
		testing.expectf(t, found, "%s has no text copy in swedish-club.scenario", scenario.name)
	}

	compiled := make([]norn.Predicate, len(programs), context.temp_allocator)
	for &program, i in programs {
		scenario, found := cli.lookup(registry, program.name)
		if !testing.expectf(t, found, "%s: no compiled scenario of that name", program.name) {
			return
		}
		predicate, is := scenario.predicate.(norn.Predicate)
		if !testing.expectf(t, is, "%s: the compiled scenario is not a predicate", program.name) {
			return
		}
		compiled[i] = predicate
		// What the list shows and finds it by is the same too: its label, its old name, its description, and
		// the system and groups `taggings` gives the compiled one.
		testing.expect_value(t, program.label, scenario.label)
		testing.expect_value(t, program.formerly, scenario.formerly)
		testing.expect_value(t, program.description, scenario.description)
		testing.expect_value(t, program.system, system_for(program.name))
		for tagging in taggings {
			if tagging.scenario != program.name {
				continue
			}
			testing.expectf(
				t,
				len(program.tags) == len(tagging.tags),
				"%s: tags %v, compiled %v",
				program.name,
				program.tags,
				tagging.tags,
			)
			for tag, j in tagging.tags {
				if j < len(program.tags) {
					testing.expect_value(t, program.tags[j], tag)
				}
			}
		}
	}

	// THE DEALS ARE SHARED OUT over a few threads, each with its own seeded stream and its own counts: the programs,
	// the vocabulary and the compiled predicates are only read. One thread took 26s in a debug build.
	Part :: struct {
		programs: []scenario_dsl.Program,
		compiled: []norn.Predicate,
		seed:     u64,
		deals:    int,
		kept:     []int,
		wrong:    []int,
	}
	work :: proc(part: ^Part) {
		state: rand.Xoshiro256_Random_State
		context.random_generator = norn.seeded_xoshiro(&state, part.seed)
		for _ in 0 ..< part.deals {
			summary := norn.summarize_deal(norn.deal_hands())
			for &program, i in part.programs {
				text := scenario_dsl.evaluate(summary, {}, &program)
				if text == part.compiled[i](summary) {
					part.kept[i] += int(text)
					continue
				}
				part.wrong[i] += 1
				if part.wrong[i] == 1 {
					north := summary[.North]
					fmt.eprintfln(
						"%s: text %v, compiled %v - North %v hcp %d",
						program.name,
						text,
						!text,
						norn.shape(north),
						norn.hcp(north),
					)
				}
			}
		}
	}
	THREADS :: 8
	parts: [THREADS]Part
	threads: [THREADS]^thread.Thread
	for &part, k in parts {
		part = Part {
			programs = programs[:],
			compiled = compiled,
			seed     = 20261106 + u64(k),
			deals    = PARITY_DEALS / THREADS,
			kept     = make([]int, len(programs), context.temp_allocator),
			wrong    = make([]int, len(programs), context.temp_allocator),
		}
		threads[k] = thread.create_and_start_with_poly_data(&part, work)
	}
	thread.join_multiple(..threads[:])
	for th in threads {
		thread.destroy(th)
	}
	kept := make([]int, len(programs), context.temp_allocator)
	wrong := make([]int, len(programs), context.temp_allocator)
	for part in parts {
		for i in 0 ..< len(programs) {
			kept[i] += part.kept[i]
			wrong[i] += part.wrong[i]
		}
	}
	for program, i in programs {
		testing.expectf(t, wrong[i] == 0, "%s: %d of %d deals disagree", program.name, wrong[i], PARITY_DEALS)
		testing.expectf(t, kept[i] > 0, "%s: nothing kept, so the comparison proves nothing", program.name)
	}
}
