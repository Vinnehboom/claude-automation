// Unit tests for capture.mjs's pure logic: the step dispatch, the
// attach-worthiness rule, and the sign-in-bounce check. Anything that
// drives a real browser (captureStill, captureVideo, buildContactSheet)
// has no automated test here -- run.sh's own test suite in this same
// directory covers the boot/run half instead.
//
// Run directly: node --test scripts/ui_capture/test/capture_logic_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { runStep, computeAttach, redirectedToSignIn, skippedEntry } from '../capture.mjs';

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

test('skippedEntry always reports kind "still", even given a video target', () => {
  const entry = skippedEntry({ name: 'demo', kind: 'video' }, 'desktop', 'sign-in failed');
  assert.equal(entry.kind, 'still');
  assert.equal(entry.error, 'sign-in failed');
  // No file was ever produced, so this is never worth its own upload --
  // matches computeAttach's "no file, no attach" rule.
  assert.equal(entry.attach, false);
});
