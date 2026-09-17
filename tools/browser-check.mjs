import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

async function checkPage(page, evidence) {
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  const checks = []; const assert = (v, m) => { if (!v) throw Error(m); checks.push(m); };
  const text = sel => page.locator(sel).innerText();

  // The page must run the engine in the browser and reproduce every Lean row.
  const status = await text('#corpus-status');
  assert(/^(\d+)\/\1 Lean corpus rows reproduced/.test(status),
    `every corpus row reproduced in the browser (${status})`);

  // The seven edges are exposed, and the read among them.
  for (const edge of ['insertAbsent','insertActive','updateActive','updateTerminal',
                      'deleteAbsent','deleteActive','witnessTerminal'])
    assert(await page.locator(`#edge-${edge}`).count() === 1, `edge exposed: ${edge}`);

  // Every illegal combination is refused BY NAME, not as a generic failure.
  const refusals = await page.locator('#refusals tr').allInnerTexts();
  assert(refusals.length === 28, 'the complement of the edge table is shown in full');
  const reasons = refusals.map(r => r.split('\t').pop().trim());
  const admitted = reasons.filter(r => r === '\u2014 admitted \u2014');
  assert(admitted.length === 7, `exactly seven admitted rows (saw ${admitted.length})`);
  const refused = reasons.filter(r => r !== '\u2014 admitted \u2014');
  assert(refused.length === 21, `21 refused rows (saw ${refused.length})`);
  // Every refusal is a NAME a reader can look up, and the whole vocabulary is
  // exercised: a page that collapsed two causes onto one name fails here.
  // The table supplies the custody entry and the active token for every row, so
  // custody-missing and token-missing cannot appear here; the Lean corpus rows
  // replayed above (GC01-GC06) are what exercise those two.
  const vocabulary = ['already-booked','key-exists','key-unknown','not-absent',
    'not-active','not-booked','read-absent','read-active','read-unknown',
    'terminal-immutable'];
  const seen = [...new Set(refused)].sort().join(',');
  assert(seen === vocabulary.join(','),
    `every refusal is named, and all ten names are exercised (saw ${seen})`);

  // A journey a reader can play: witness an absence, then book it.
  await page.selectOption('#story-picker', 'witness');
  await page.click('#hist-last');
  let where = await text('#where');
  assert(/leaf Known active/.test(where), `booking a witnessed absence lands active (${where})`);
  assert(/absent 0/.test(where), 'the absent token was consumed');

  // Retirement, and the attestation that is a read.
  await page.selectOption('#story-picker', 'retire');
  await page.click('#hist-last');
  where = await text('#where');
  assert(/leaf Known terminal/.test(where), `retirement leaves the leaf terminal (${where})`);
  assert(/terminal 2/.test(where), 'the terminal witness is plural');
  await page.click('#hist-prev');
  await page.click('#hist-prev');
  assert(/terminal 0/.test(await text('#where')), 'stepping back unwinds the attestations');

  // A refusal a reader can watch, named.
  await page.selectOption('#story-picker', 'refused');
  await page.click('#hist-next');
  await page.click('#hist-next');
  await page.click('#hist-next');
  assert(/read-active/.test(await text('#narration')),
    'attesting an active key is refused by name');

  // Free play: right policy, wrong tuple is not sufficient (D-APPROVAL).
  await page.click('#btn-reset');
  await page.selectOption('#approval-picker', 'mismatched');
  await page.click('#edge-insertActive');
  assert(/approval-mismatch/.test(await text('#edge-result')),
    'an approval under the right policy with the wrong tuple is refused');
  await page.selectOption('#approval-picker', 'none');
  await page.click('#edge-insertActive');
  assert(/no-approval/.test(await text('#edge-result')), 'no approval at all is refused');
  await page.selectOption('#approval-picker', 'matching');
  await page.click('#edge-insertActive');
  assert(/admitted/.test(await text('#edge-result')), 'a matching approval is admitted');

  // The naming profile: the Over witness, minted by a folded read and burned.
  await page.selectOption('#profile-picker', 'naming');
  const journey = await page.locator('#naming-journey tr').allInnerTexts();
  assert(journey.length === 5, 'the Over witness journey has five steps');
  assert(/witnessTerminal/.test(journey[2]), 'the witness is minted by a folded read');
  assert(/burn/.test(journey[4]) && /Known terminal/.test(journey[4]),
    'the witnesses burn and the leaf stays terminal');
  assert(/\d+\/\d+ naming corpus rows/.test(await text('#naming-status')),
    'the naming corpus is replayed');

  await page.click('#btn-theme');
  await writeFile(join(evidence, 'checks.json'), JSON.stringify(checks, null, 2) + '\n');
  return { status: errors.length ? 'FAIL' : 'PASS', checks: checks.length, errors };
}

const root = resolve(process.argv[2] ?? '.');
const evidence = await mkdtemp(join(tmpdir(), 'singular-browser-'));
const html = await readFile(join(root, 'simulator/index.html'));
// The page is one self-contained file: everything else 404s, so a page that
// quietly grew a subresource cannot pass by fetching it out of the tree.
const served = [];
const server = createServer((request, response) => {
  if (request.url === '/' || request.url === '/index.html') {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end(html);
  } else {
    served.push(request.url);
    response.writeHead(404);
    response.end();
  }
});
let browser;
let passed = false;
try {
  assert(process.env.PLAYWRIGHT_MODULE, 'Run through the pinned Nix browser-check app or development shell');
  const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  await new Promise((accept, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', accept);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const browserEnvironment = { ...process.env };
  for (const name of ['XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']) {
    const directory = join(evidence, name.toLowerCase());
    await mkdir(directory, { mode: 0o700 });
    browserEnvironment[name] = directory;
  }
  // CI forbids the zygote's capset syscall. Fork/exec children directly while
  // preserving the outer runner restrictions and Playwright's existing flags.
  browser = await chromium.launch({ headless: true, channel: 'chromium', env: browserEnvironment, args: ['--no-zygote'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  page.setDefaultTimeout(10000);
  const external = [];
  await page.route('**/*', route => {
    if (route.request().url().startsWith(url)) return route.continue();
    external.push(route.request().url());
    return route.abort();
  });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(url, { waitUntil: 'networkidle' });
  const result = await checkPage(page, evidence);
  assert.equal(result.status, 'PASS');
  assert(result.checks > 0, 'browser assertion set is empty');
  assert.deepEqual(errors, [], 'browser page errors');
  assert.deepEqual(external, [], 'external runtime network requests');
  assert.deepEqual(served, [], 'the page is self-contained: no subresource requests');
  await writeFile(join(evidence, 'result.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({ ...result, evidence }));
  passed = true;
} finally {
  await browser?.close();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  if (passed && process.env.KEEP_BROWSER_EVIDENCE !== '1') await rm(evidence, { recursive: true });
  else console.error(`Browser evidence retained: ${evidence}`);
}
