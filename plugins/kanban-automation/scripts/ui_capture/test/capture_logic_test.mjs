// Unit tests for capture.mjs's pure logic: the step dispatch, the
// attach-worthiness rule, the sign-in-bounce check, and the full-page
// decision. captureStill's own wiring of that decision into a screenshot
// call is exercised below too, against a fake page -- no real browser.
// captureVideo and buildContactSheet still have no automated test here;
// run.sh's own test suite in this same directory covers the boot/run half
// instead.
//
// Run directly: node --test scripts/ui_capture/test/capture_logic_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  runStep, computeAttach, redirectedToSignIn, skippedEntry, pageNeedsFullCapture, captureStill,
} from '../capture.mjs';

function fakePage() {
  const calls = [];
  return {
    calls,
    click(selector) { calls.push(['click', selector]); },
    fill(selector, value) { calls.push(['fill', selector, value]); },
    waitForSelector(selector) { calls.push(['wait_for', selector]); },
    press(selector, value) { calls.push(['press', selector, value]); },
  };
}

test('runStep dispatches click to page.click', async () => {
  const page = fakePage();
  await runStep(page, { action: 'click', selector: '#go' });
  assert.deepEqual(page.calls, [['click', '#go']]);
});

test('runStep dispatches fill with its value', async () => {
  const page = fakePage();
  await runStep(page, { action: 'fill', selector: '#name', value: 'Playoff bonus' });
  assert.deepEqual(page.calls, [['fill', '#name', 'Playoff bonus']]);
});

test('runStep dispatches wait_for to page.waitForSelector', async () => {
  const page = fakePage();
  await runStep(page, { action: 'wait_for', selector: '.ready' });
  assert.deepEqual(page.calls, [['wait_for', '.ready']]);
});

test('runStep dispatches press with its value', async () => {
  const page = fakePage();
  await runStep(page, { action: 'press', selector: '#name', value: 'Enter' });
  assert.deepEqual(page.calls, [['press', '#name', 'Enter']]);
});

test('runStep rejects an action outside the four-key vocabulary', async () => {
  const page = fakePage();
  await assert.rejects(
    () => runStep(page, { action: 'evaluate', selector: 'body' }),
    /unknown step action/,
  );
  assert.deepEqual(page.calls, []);
});

test('computeAttach is false with no file', () => {
  assert.equal(computeAttach({ file: null, kind: 'still', source: 'core', status: 200 }), false);
});

test('computeAttach is true for any ticket-sourced target, still or video', () => {
  assert.equal(computeAttach({ file: 'x.png', kind: 'still', source: 'ticket', status: 200 }), true);
  assert.equal(computeAttach({ file: 'x.webm', kind: 'video', source: 'ticket', status: 200 }), true);
});

test('computeAttach is true for a core page that did not answer 200', () => {
  assert.equal(computeAttach({ file: 'x.png', kind: 'still', source: 'core', status: 500 }), true);
});

test('computeAttach is false for a core still folded into its contact sheet', () => {
  assert.equal(computeAttach({ file: 'x.png', kind: 'still', source: 'core', status: 200 }), false);
});

test('computeAttach is true for any entry that carries an error', () => {
  assert.equal(computeAttach({ file: 'x.png', kind: 'still', source: 'core', status: 200, error: 'boom' }), true);
});

test('redirectedToSignIn is false when the target IS the sign-in page', () => {
  const page = { url: () => 'http://127.0.0.1:1/users/sign_in' };
  assert.equal(redirectedToSignIn(page, { path: '/users/sign_in' }, '/users/sign_in'), false);
});

test('redirectedToSignIn is true when a different target bounced there', () => {
  const page = { url: () => 'http://127.0.0.1:1/users/sign_in' };
  assert.equal(redirectedToSignIn(page, { path: '/admin/players' }, '/users/sign_in'), true);
});

test('redirectedToSignIn is false when the page landed where it was sent', () => {
  const page = { url: () => 'http://127.0.0.1:1/admin/players' };
  assert.equal(redirectedToSignIn(page, { path: '/admin/players' }, '/users/sign_in'), false);
});

test('pageNeedsFullCapture is false when the page is shorter than its viewport', () => {
  assert.equal(pageNeedsFullCapture(600, 900), false);
});

test('pageNeedsFullCapture is false when the page exactly fills its viewport', () => {
  assert.equal(pageNeedsFullCapture(900, 900), false);
});

test('pageNeedsFullCapture is true when the page is taller than its viewport', () => {
  assert.equal(pageNeedsFullCapture(2400, 900), true);
});

// A page object standing in for Playwright's, so captureStill's own wiring
// (does it read the page height, does it pass fullPage through) is under
// test, not just pageNeedsFullCapture in isolation -- deleting either call
// would still leave pageNeedsFullCapture itself passing.
function fakeStillPage(pageHeight, viewportHeight) {
  const calls = { goto: [], evaluate: 0, screenshot: [] };
  let lastUrl = '';
  return {
    calls,
    viewportSize: () => ({ width: 999, height: viewportHeight }),
    async goto(url, options) {
      calls.goto.push([url, options]);
      lastUrl = url;
      return { status: () => 200 };
    },
    async evaluate() {
      calls.evaluate += 1;
      return pageHeight;
    },
    async screenshot(options) {
      calls.screenshot.push(options);
      fs.writeFileSync(options.path, Buffer.from('fake-png'));
    },
    url: () => lastUrl,
  };
}

async function withTempOutDir(viewportName, run) {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'capture-still-test-'));
  fs.mkdirSync(path.join(outDir, viewportName), { recursive: true });
  try {
    return await run(outDir);
  } finally {
    fs.rmSync(outDir, { recursive: true, force: true });
  }
}

test('captureStill takes a full-page shot when the page is taller than its viewport', async () => {
  await withTempOutDir('desktop', async (outDir) => {
    const page = fakeStillPage(2000, 900);
    const target = { name: 'admin-players', path: '/admin/players' };
    const entry = await captureStill(page, target, 'http://127.0.0.1:1', outDir, 'desktop', '/users/sign_in');
    assert.equal(page.calls.evaluate, 1);
    assert.equal(page.calls.screenshot[0].fullPage, true);
    assert.equal(entry.full_page, true);
  });
});

test('captureStill takes a viewport-cropped shot when the page fits', async () => {
  await withTempOutDir('desktop', async (outDir) => {
    const page = fakeStillPage(600, 900);
    const target = { name: 'admin-players', path: '/admin/players' };
    const entry = await captureStill(page, target, 'http://127.0.0.1:1', outDir, 'desktop', '/users/sign_in');
    assert.equal(page.calls.screenshot[0].fullPage, false);
    assert.equal(entry.full_page, false);
  });
});

test('skippedEntry always reports kind "still", even given a video target', () => {
  const entry = skippedEntry({ name: 'demo', kind: 'video' }, 'desktop', 'sign-in failed');
  assert.equal(entry.kind, 'still');
  assert.equal(entry.error, 'sign-in failed');
  // No file was ever produced, so this is never worth its own upload --
  // matches computeAttach's "no file, no attach" rule.
  assert.equal(entry.attach, false);
});
