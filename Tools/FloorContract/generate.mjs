// Generates the floor-contract golden fixtures by running the real web
// getFloorForEnv (see extract-web-floor.mjs) over a case matrix.
//
//   node Tools/FloorContract/generate.mjs            # write fixtures
//   node Tools/FloorContract/generate.mjs --check    # fail if stale (CI)
//
// ── The deviceClass wrinkle ───────────────────────────────────────────────────
// The plan describes this test as "feed the same floors map and context to the
// Swift resolver and to base.js, assert identical output". That is not literally
// possible for one segment of the key. base.js hardcodes
//
//     floorKeyPieces.push(pvState.isMobile() ? "mobile" : "desktop")
//
// so the web function can only ever emit "mobile"/"desktop", while the mobile
// SDK must emit "phone"/"tablet" (Phase 2d). The two runtimes therefore cannot
// produce byte-identical *keys*.
//
// What is contractible is the ladder *logic*: tier precedence, the falsy-zero
// fallback, gating, and the resolved *value*. So each case carries the floors
// map with a {DC} placeholder, substituted with the web spelling for the node
// run and the mobile spelling for the Swift run. Identical resolved values then
// mean identical ladder behaviour, which is the property we actually care about.
//
// Likewise `platform` stands in for pvState.getBrowser() — that substitution IS
// clean, since getBrowser() returns an opaque token the ladder only concatenates.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadWebFloorResolver } from './extract-web-floor.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');
const FIXTURE = resolve(REPO, 'Tests/LongitudeCoreTests/Fixtures/floor-contract.json');

// Where the web bundle lives. Overridable so CI in the addkt repo can point at
// its own checkout and assert the fixtures still match.
const BASE_JS = process.env.LNGTD_BASE_JS ?? resolve(
  REPO, '../addkt/addkt/static/header/v4-zone/src/units/base.js'
);

const UID = 'home_top_uid';

/** Substitute the {DC} placeholder in floors-map keys. */
function spell(floors, deviceClass) {
  if (floors === null || typeof floors !== 'object') return floors;
  return Object.fromEntries(
    Object.entries(floors).map(([k, v]) => [k.replaceAll('{DC}', deviceClass), v])
  );
}

// A sentinel meaning "store a string that is not valid JSON", to exercise the
// silent try/catch parse paths.
const UNPARSEABLE = '<<unparseable>>';

/**
 * Case matrix. `floors` keys may use {DC}. `dynamicFloorParameters` may be an
 * object, null, or UNPARSEABLE.
 */
const CASES = [
  {
    name: 'full_key_wins',
    why: 'The 5-part key <platform>_<country>_<deviceClass>_<section>_<bucket> takes precedence over every shorter tier.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 2.5, 'ios_US': 1.0, US: 0.5, default: 0.25 },
  },
  {
    name: 'platform_country_tier',
    why: 'Falls to <platform>_<country> when the full key is absent.',
    tier: 'platform_country',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US': 1.0, US: 0.5, default: 0.25 },
  },
  {
    name: 'country_tier',
    why: 'Falls to bare <country>.',
    tier: 'country',
    ctx: { platform: 'ios', country: 'GB', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 1 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { GB: 0.75, default: 0.25 },
  },
  {
    name: 'default_tier',
    why: 'Falls to the "default" key.',
    tier: 'default',
    ctx: { platform: 'android', country: 'DE', dcWeb: 'desktop', dcMobile: 'tablet', section: 'app', sessionDepth: 5 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { default: 0.25 },
  },
  {
    name: 'no_tier_matches_falls_to_base_floor',
    why: 'With no matching key and no default, unitFloor stays at baseFloor.',
    tier: 'baseFloor',
    ctx: { platform: 'ios', country: 'FR', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.42,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_JP': 9.99 },
  },
  {
    name: 'resolved_zero_falls_back_to_base_floor',
    why: 'THE TRAP: `if (!unitFloor) unitFloor = baseFloor` is a falsy test, so a legitimately configured 0.0 floor is discarded and baseFloor is used. A port using `== nil` instead of falsiness diverges here.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.33,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 0 },
  },
  {
    name: 'zero_at_top_tier_does_not_fall_through',
    why: 'PRESENCE, NOT TRUTHINESS: the ladder tests hasOwnProperty, so a 0 on the most specific key IS a match. It is assigned, then the falsy check replaces it with baseFloor — it does NOT fall through to a lower tier. A port that gates each tier on JS truthiness returns 1.0 here instead of 0.33. Verified directly against the web function.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.33,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 0, 'ios_US': 1.0, US: 0.5, default: 0.25 },
  },
  {
    name: 'empty_string_at_top_tier_does_not_fall_through',
    why: 'Same presence rule for another falsy value: an empty string on the most specific key matches, then falls back to baseFloor rather than to the ios_US tier.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.33,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': '', 'ios_US': 1.0 },
  },
  {
    name: 'null_at_top_tier_does_not_fall_through',
    why: 'And for null. A Swift port must therefore distinguish "key absent" from "key present holding a falsy value" — dropping null keys while parsing silently converts this case into a fall-through.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.33,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': null, 'ios_US': 1.0 },
  },
  {
    name: 'string_floor_value_returned_as_string',
    why: 'THE OTHER TRAP: tier 3 does no type check (unlike geo_floors, which requires typeof === "number"). A string "1.50" is truthy, so it is returned as a STRING. A Swift Double-typed port cannot reproduce this and must decide deliberately — see the fixture note.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': '1.50' },
  },
  {
    name: 'bucket_A_depth_0',
    why: 'sessionDepth 0 -> bucket A.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1, dynamicFloorsEnabled: true, dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 1.11, 'ios_US_{DC}_app_B': 2.22, 'ios_US_{DC}_app_C': 3.33 },
  },
  {
    name: 'bucket_B_depth_1',
    why: 'sessionDepth 1 -> bucket B (lower boundary).',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 1 },
    baseFloor: 0.1, dynamicFloorsEnabled: true, dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 1.11, 'ios_US_{DC}_app_B': 2.22, 'ios_US_{DC}_app_C': 3.33 },
  },
  {
    name: 'bucket_B_depth_2',
    why: 'sessionDepth 2 -> still bucket B (upper boundary; > 2 is required for C).',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 2 },
    baseFloor: 0.1, dynamicFloorsEnabled: true, dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 1.11, 'ios_US_{DC}_app_B': 2.22, 'ios_US_{DC}_app_C': 3.33 },
  },
  {
    name: 'bucket_C_depth_3',
    why: 'sessionDepth 3 -> bucket C.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 3 },
    baseFloor: 0.1, dynamicFloorsEnabled: true, dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_app_A': 1.11, 'ios_US_{DC}_app_B': 2.22, 'ios_US_{DC}_app_C': 3.33 },
  },
  {
    name: 'use_static_floor_skips_ladder',
    why: 'useStaticFloor disables tier 3 entirely; note it also skips the geo_floors else-if, so the result is baseFloor.',
    tier: 'gated',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.77,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: { useStaticFloor: true },
    floors: { 'ios_US_{DC}_app_A': 5.0, default: 4.0 },
  },
  {
    name: 'dynamic_floors_disabled_uses_geo_floors_country',
    why: 'With dynamicFloorsEnabled false, the else-if geo_floors branch runs and an exact country match wins. The plan omits this branch; a port implementing only tier 3 returns baseFloor here instead.',
    tier: 'geo_floors',
    ctx: { platform: 'ios', country: 'CA', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: false,
    dynamicFloorParameters: { geo_floors: { CA: 1.8, ESC: 1.2, ROW: 0.4 } },
    floors: { 'ios_CA_{DC}_app_A': 9.99 },
  },
  {
    name: 'geo_floors_ESC_group',
    why: 'ESC covers CA/GB/AU/NZ/IE when no exact country entry exists.',
    tier: 'geo_floors',
    ctx: { platform: 'ios', country: 'AU', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: false,
    dynamicFloorParameters: { geo_floors: { ESC: 1.2, ROW: 0.4 } },
    floors: {},
  },
  {
    name: 'geo_floors_ROW_excludes_US',
    why: 'ROW explicitly excludes CA/GB/AU/NZ/IE *and US*, so a US request matches neither ESC nor ROW and keeps baseFloor.',
    tier: 'geo_floors',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.15,
    dynamicFloorsEnabled: false,
    dynamicFloorParameters: { geo_floors: { ESC: 1.2, ROW: 0.4 } },
    floors: {},
  },
  {
    name: 'geo_floors_ROW_applies_to_other_country',
    why: 'A country outside both lists takes ROW.',
    tier: 'geo_floors',
    ctx: { platform: 'ios', country: 'BR', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: false,
    dynamicFloorParameters: { geo_floors: { ESC: 1.2, ROW: 0.4 } },
    floors: {},
  },
  {
    name: 'geo_floors_non_numeric_ignored',
    why: 'geo_floors requires typeof === "number", so a string is skipped and baseFloor survives — the opposite of tier 3 behaviour above.',
    tier: 'geo_floors',
    ctx: { platform: 'ios', country: 'CA', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.19,
    dynamicFloorsEnabled: false,
    dynamicFloorParameters: { geo_floors: { CA: '1.80' } },
    floors: {},
  },
  {
    name: 'hard_base_floor_raises',
    why: 'useHardBaseFloor clamps the resolved floor up to baseFloor.',
    tier: 'hard_base',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 3.0,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: { useHardBaseFloor: true },
    floors: { 'ios_US_{DC}_app_A': 1.0 },
  },
  {
    name: 'hard_base_floor_does_not_lower',
    why: 'useHardBaseFloor is a max, never a min — a higher resolved floor is kept.',
    tier: 'hard_base',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.5,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: { useHardBaseFloor: true },
    floors: { 'ios_US_{DC}_app_A': 2.0 },
  },
  {
    name: 'unparseable_floors_string_yields_no_match',
    why: 'pvState.floors[uid] is a JSON *string*; a parse failure is swallowed and itFloors becomes {}.',
    tier: 'baseFloor',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.66,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: UNPARSEABLE,
  },
  {
    name: 'unparseable_dynamic_floor_parameters',
    why: 'dynamicFloorParameters is also a JSON string; a parse failure leaves it null, so useStaticFloor is false and the ladder still runs.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: UNPARSEABLE,
    floors: { 'ios_US_{DC}_app_A': 1.23 },
  },
  {
    name: 'missing_uid_in_floors_map',
    why: 'No entry for this unit uid at all.',
    tier: 'baseFloor',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 0.88,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: null,
  },
  {
    name: 'base_floor_non_numeric_becomes_zero',
    why: 'parseFloat(baseFloor) || 0 — a non-numeric baseFloor is 0, and with no tier match the result is 0.',
    tier: 'baseFloor',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'app', sessionDepth: 0 },
    baseFloor: 'not-a-number',
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: {},
  },
  {
    name: 'section_participates_in_key',
    why: 'The 4th segment is the account section VALUE, not the literal string "section" — the plan\'s shorthand <platform>_<country>_<deviceClass>_section_<bucket> reads as a literal and would produce a key that never matches.',
    tier: 'full',
    ctx: { platform: 'ios', country: 'US', dcWeb: 'mobile', dcMobile: 'phone', section: 'sports', sessionDepth: 0 },
    baseFloor: 0.1,
    dynamicFloorsEnabled: true,
    dynamicFloorParameters: {},
    floors: { 'ios_US_{DC}_sports_A': 4.44, 'ios_US_{DC}_section_A': 9.99 },
  },
];

/** Build the (config, pvState, sessionState, findGetParameter) env for a case. */
function buildEnv(c, deviceClass) {
  const floors = c.floors === UNPARSEABLE
    ? { [UID]: '{not json' }
    : c.floors === null
      ? {}
      : { [UID]: JSON.stringify(spell(c.floors, deviceClass)) };

  return {
    config: {
      getConfig: (key) => {
        if (key === 'account.dynamicFloorsEnabled') return c.dynamicFloorsEnabled;
        if (key === 'account.section') return c.ctx.section;
        throw new Error(`unexpected config key: ${key}`);
      },
    },
    pvState: {
      getBrowser: () => c.ctx.platform,
      country: c.ctx.country,
      isMobile: () => deviceClass === 'mobile' || deviceClass === 'phone',
      floors,
    },
    sessionState: { sessionDepth: c.ctx.sessionDepth },
    // No URL in an app; the override path must be inert.
    findGetParameter: () => null,
  };
}

function buildUnit(c) {
  return {
    unitConfig: {
      baseFloor: c.baseFloor,
      dynamicFloorParameters: c.dynamicFloorParameters === UNPARSEABLE
        ? '{not json'
        : c.dynamicFloorParameters === null
          ? null
          : JSON.stringify(c.dynamicFloorParameters),
    },
    config: { uid: UID },
    _auctionFloors: {},
    // Mobile v1 has no zone-level bid pool, so step 6 must be inert. Passing
    // includeHighestBid=false below AND leaving _bidPool null pins that.
    _bidPool: null,
    filledImpressionCount: 0,
    currentAuctionId: undefined,
  };
}

function main() {
  const check = process.argv.includes('--check');
  const { call, source } = loadWebFloorResolver(BASE_JS);

  const sha = createHash('sha256').update(readFileSync(BASE_JS)).digest('hex');
  const bodySha = createHash('sha256').update(source).digest('hex');

  const cases = CASES.map((c) => {
    // The web run uses the web deviceClass spelling; the Swift run will use the
    // mobile spelling against the same values.
    const value = call(buildEnv(c, c.ctx.dcWeb), buildUnit(c), 'auction-1', false);
    return {
      name: c.name,
      why: c.why,
      ladderTier: c.tier,
      input: {
        platform: c.ctx.platform,
        country: c.ctx.country,
        deviceClass: { web: c.ctx.dcWeb, mobile: c.ctx.dcMobile },
        section: c.ctx.section,
        sessionDepth: c.ctx.sessionDepth,
        uid: UID,
        baseFloor: c.baseFloor,
        dynamicFloorsEnabled: c.dynamicFloorsEnabled,
        dynamicFloorParameters: c.dynamicFloorParameters === UNPARSEABLE
          ? { $unparseable: true } : c.dynamicFloorParameters,
        floors: c.floors === UNPARSEABLE ? { $unparseable: true } : c.floors,
        includeHighestBid: false,
      },
      expected: value,
      expectedJSType: typeof value,
    };
  });

  const doc = {
    $comment: [
      'Golden fixtures for the Swift FloorResolver, generated by running the',
      'REAL getFloorForEnv from the web bundle. Do not hand-edit: regenerate with',
      '`node Tools/FloorContract/generate.mjs`. CI runs --check.',
      '',
      'floors keys contain a {DC} placeholder: substitute input.deviceClass.mobile',
      'in Swift and input.deviceClass.web on the web side. base.js hardcodes',
      '"mobile"/"desktop" so the two runtimes cannot emit identical keys; the',
      'contract is on the resolved VALUE, not the key text.',
      '',
      'expectedJSType "string" marks cases where the web ladder returns a string',
      'because tier 3 does no type check. A Double-typed Swift port cannot',
      'reproduce that; see README for the decision required.',
    ].join('\n'),
    source: {
      baseJs: 'addkt/static/header/v4-zone/src/units/base.js',
      function: 'BaseUnit.prototype.getFloorForEnv',
      fileSha256: sha,
      functionBodySha256: bodySha,
    },
    cases,
  };

  const json = JSON.stringify(doc, null, 2) + '\n';

  if (check) {
    let existing = null;
    try { existing = readFileSync(FIXTURE, 'utf8'); } catch { /* missing */ }
    if (existing !== json) {
      console.error(
        'floor-contract.json is stale.\n' +
        'The web floor ladder changed (or the fixtures were hand-edited).\n' +
        'Regenerate with: node Tools/FloorContract/generate.mjs\n' +
        'and re-run the Swift contract test — a diff here means the SDK floor\n' +
        'logic has drifted from the web implementation.'
      );
      process.exit(1);
    }
    console.log(`floor-contract.json up to date (${cases.length} cases)`);
    return;
  }

  writeFileSync(FIXTURE, json);
  console.log(`wrote ${cases.length} cases to Tests/LongitudeCoreTests/Fixtures/floor-contract.json`);
  const byTier = cases.reduce((a, c) => (a[c.ladderTier] = (a[c.ladderTier] || 0) + 1, a), {});
  console.log('tiers covered:', byTier);
  const strings = cases.filter((c) => c.expectedJSType !== 'number');
  if (strings.length) {
    console.log(`\nnote: ${strings.length} case(s) return a non-number from the web ladder:`);
    for (const c of strings) console.log(`  - ${c.name} -> ${JSON.stringify(c.expected)} (${c.expectedJSType})`);
  }
}

main();
