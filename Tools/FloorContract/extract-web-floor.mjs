// Extracts the REAL getFloorForEnv from the web bundle and makes it callable
// under node, so the Swift FloorResolver can be tested against the actual web
// behaviour rather than against a second implementation of it.
//
// Why extraction and not a port: the whole point of the contract test is to
// catch divergence between Swift and the web ladder. If this harness contained
// its own reimplementation, the test would compare a reimplementation to a
// reimplementation and pass while both drifted from base.js. So we execute the
// function's actual source text. When base.js changes, the fixtures change, and
// CI on both repos notices.
//
// base.js is an ES module importing six siblings that transitively want browser
// globals (window, document, googletag, pbjs). Rather than stub that whole
// graph, we lift out just getFloorForEnv and _arrayContains — verified to be
// the function's entire dependency surface beyond the injected five.

import { readFileSync } from 'node:fs';

/**
 * Scan forward from the opening brace of a function body and return the index
 * just past its matching close brace. Skips string literals, template literals,
 * regex-free comment forms — enough for this file, and it throws rather than
 * guessing if it runs off the end.
 */
function matchBraces(src, openIdx) {
  let depth = 0;
  let i = openIdx;
  while (i < src.length) {
    const c = src[i];
    const next = src[i + 1];

    if (c === '/' && next === '/') {
      i = src.indexOf('\n', i);
      if (i === -1) break;
      continue;
    }
    if (c === '/' && next === '*') {
      i = src.indexOf('*/', i + 2);
      if (i === -1) break;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      const quote = c;
      i++;
      while (i < src.length) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === '{') depth++;
    if (c === '}') {
      depth--;
      if (depth === 0) return i + 1;
    }
    i++;
  }
  throw new Error('unbalanced braces while extracting function body');
}

/** Pull `<needle> ... { body }` out of src and return the body text. */
function extractFunctionBody(src, needle, label) {
  const start = src.indexOf(needle);
  if (start === -1) {
    throw new Error(
      `could not find ${label} (looked for ${JSON.stringify(needle)}). ` +
      `base.js has probably been refactored — fix this extractor rather than ` +
      `letting the contract test silently pass against stale fixtures.`
    );
  }
  const open = src.indexOf('{', start);
  if (open === -1) throw new Error(`no opening brace after ${label}`);
  const end = matchBraces(src, open);
  return src.slice(open + 1, end - 1);
}

/**
 * Build a callable getFloorForEnv from base.js on disk.
 *
 * @param {string} baseJsPath
 * @returns {{ call: Function, source: string, arrayContainsSource: string }}
 */
export function loadWebFloorResolver(baseJsPath) {
  const src = readFileSync(baseJsPath, 'utf8');

  const floorBody = extractFunctionBody(
    src,
    'BaseUnit.prototype.getFloorForEnv = function',
    'getFloorForEnv'
  );
  const arrayContainsBody = extractFunctionBody(
    src,
    'function _arrayContains',
    '_arrayContains'
  );

  // Sanity-check that we lifted the function we think we did. If base.js is
  // restructured these markers go missing, and a fixture regenerated from a
  // half-matched body would be worse than useless.
  for (const marker of ['useHardBaseFloor', 'floor_override', 'getHighestNonAmazonBid', '"ESC"', '"ROW"']) {
    if (!floorBody.includes(marker)) {
      throw new Error(
        `extracted getFloorForEnv body is missing ${marker} — extraction is ` +
        `probably truncated. Refusing to generate fixtures from it.`
      );
    }
  }

  // The function's signature is (auctionId, includeHighestBid) and it reads the
  // five module-scope identifiers below plus `this`. Everything it touches is
  // supplied by the caller, so nothing here silently defaults.
  const factory = new Function(
    'config', 'pvState', 'sessionState', 'findGetParameter', '_arrayContains',
    `return function getFloorForEnv(auctionId, includeHighestBid) {\n${floorBody}\n};`
  );

  const arrayContains = new Function(
    'arr', 'value', arrayContainsBody
  );

  /**
   * @param {object} env  - { config, pvState, sessionState, findGetParameter }
   * @param {object} unit - the `this` receiver: unitConfig, config.uid,
   *                        _auctionFloors, _bidPool, filledImpressionCount
   * @param {string=} auctionId
   * @param {boolean=} includeHighestBid
   */
  function call(env, unit, auctionId, includeHighestBid) {
    const fn = factory(
      env.config,
      env.pvState,
      env.sessionState,
      env.findGetParameter,
      arrayContains
    );
    return fn.call(unit, auctionId, includeHighestBid);
  }

  return { call, source: floorBody, arrayContainsSource: arrayContainsBody };
}
