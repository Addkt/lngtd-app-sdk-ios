# Floor contract harness

The plan calls a cross-runtime floor contract test "the highest-value single
test" for the SDK: feed the same floors map and context to the Swift resolver and
to `base.js` under node, assert identical output. This directory is the node half.

```bash
node Tools/FloorContract/generate.mjs          # regenerate fixtures
node Tools/FloorContract/generate.mjs --check  # CI: fail if stale
```

Fixtures land in `Tests/LongitudeCoreTests/Fixtures/floor-contract.json` (24
cases). `LNGTD_BASE_JS` overrides the path to the web bundle so the addkt repo's
CI can assert the fixtures still match its own checkout.

## Why it extracts rather than ports

`extract-web-floor.mjs` lifts the actual source text of
`BaseUnit.prototype.getFloorForEnv` out of `base.js` and executes it with its
five module-scope dependencies injected. It does **not** reimplement the ladder.

That distinction is the whole value. A harness containing its own
reimplementation would compare one reimplementation against another and stay
green while both drifted from the web. Extracting the real body means a change to
`base.js` changes the fixtures, and `--check` fails in CI.

Verified: mutating the web ladder (removing `US` from the `ROW` exclusion list)
makes `--check` exit non-zero. Pointing the extractor at a file without the
function makes it throw rather than emit empty fixtures.

`base.js` is an ES module importing six siblings that transitively want browser
globals, so importing the real graph would mean stubbing `window`/`document`/
`googletag`/`pbjs`. The function's dependency surface was checked and is exactly
13 identifiers, so injection is bounded and cheap.

## What reading the real function changed

Phase 2d cites `base.js:446-506` and describes a four-tier ladder plus a gate.
That covers steps 1–3 of an **eight**-step function. The rest matters:

| Step | Behaviour | Port status |
|---|---|---|
| 1, 8 | Per-`auctionId` memo of the resolved floor | Portable — needed, or refresh re-resolves mid-auction |
| 2 | `parseFloat(baseFloor) \|\| 0` | Portable; note non-numeric becomes `0`, not nil |
| 3 | The documented ladder | Portable |
| 4 | `else if geo_floors` — exact country, then `ESC` (CA/GB/AU/NZ/IE), then `ROW` (excludes those **and US**) | **Portable and absent from the plan.** Runs only when `dynamicFloorsEnabled` is false. A port implementing only step 3 returns `baseFloor` for every account configured this way. |
| 5 | `useHardBaseFloor` → `max(resolved, baseFloor)` | **Portable and absent from the plan.** |
| 6 | Raise to highest non-Amazon bid in the zone pool; average against a pool-derived floor once the unit has fill | **No mobile analogue in v1** — there is no zone bid pool. Fixtures pin `includeHighestBid: false` and a null pool so this stays inert. Revisit with refresh in M4. |
| 7 | `floor_override` query param | Inert in an app. If a debug override is wanted, it is a deliberate addition, not a port. |

Three further traps, each pinned by a named fixture case:

- **`if (!unitFloor) unitFloor = baseFloor` is a falsiness test.** A configured
  floor of `0.0` is discarded in favour of `baseFloor`. A Swift port using
  `if resolved == nil` diverges. See `resolved_zero_falls_back_to_base_floor`.
- **Step 3 does no type check, step 4 does.** A floors value of `"1.50"` is
  truthy, so the web ladder **returns the string**. `geo_floors` by contrast
  requires `typeof === "number"` and skips a string. See
  `string_floor_value_returned_as_string` and `geo_floors_non_numeric_ignored`.
- **The 4th key segment is the section *value*.** The plan's shorthand
  `<platform>_<country>_<deviceClass>_section_<A|B|C>` reads as though `section`
  were a literal; a port emitting the literal produces a key that never matches.
  `section_participates_in_key` has both spellings present and asserts the value
  form wins.

## One decision this leaves open

**1. `deviceClass` cannot be byte-identical across runtimes.** `base.js`
hardcodes `pvState.isMobile() ? "mobile" : "desktop"`, so the web function can
never emit `phone`/`tablet`. The plan's "assert identical output" is therefore not
literally achievable on that segment. Fixtures carry a `{DC}` placeholder in
floors keys plus `deviceClass: { web, mobile }`, so each runtime substitutes its
own spelling and the contract is on the resolved **value**, not the key text.

This has a backend consequence worth confirming before M2: whoever authors app
floors must write `phone`/`tablet` keys, so the floors map published for `ct=app`
is **not** interchangeable with the web one for the same account.

## Already settled by the frozen schema

**The string-return case cannot reach an app config.** `schemas/app_config_v1.json`
constrains every `floors.<uid>` value to `{"type": "number"}`, so a string floor
fails validation at publish time. A `Double`-typed Swift resolver is therefore
correct for app, and no coercion decision is needed.

The fixture still records the web truth (`expectedJSType: "string"`) because the
case documents a real divergence between the two runtimes for the same *stored*
data — the app pipeline is simply protected from it upstream. The Swift test
should skip that one case by name, with a comment pointing at the schema, rather
than coercing and pretending the behaviours match.

The same schema requires a `default` key in every floors entry, which means the
ladder always resolves to at least `default` for valid app config. The
`no_tier_matches_falls_to_base_floor` and `missing_uid_in_floors_map` cases are
consequently unreachable via a validly published config — they are kept as
defensive pins, since the SDK also reads a **bundled** `LNGTDConfig.json` that no
server-side validator has necessarily seen.
