import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdir, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';

const root = resolve(process.argv[2] ?? '.');
const evidence = await mkdtemp(join(tmpdir(), 'singular-lifecycle-browser-'));
const publicFiles = new Map([
  ['/index.html', ['simulator', 'index.html', 'text/html; charset=utf-8']],
  ['/lifecycle-view.html', ['simulator', 'lifecycle-view.html', 'text/html; charset=utf-8']],
  ['/lifecycle-journeys.mjs', ['simulator', 'lifecycle-journeys.mjs', 'text/javascript; charset=utf-8']],
  ['/lifecycle-view.mjs', ['simulator', 'lifecycle-view.mjs', 'text/javascript; charset=utf-8']],
  ['/lifecycle.mjs', ['simulator', 'lifecycle.mjs', 'text/javascript; charset=utf-8']],
  ['/naming-wire.mjs', ['simulator', 'naming-wire.mjs', 'text/javascript; charset=utf-8']],
  ['/naming.mjs', ['simulator', 'naming.mjs', 'text/javascript; charset=utf-8']],
  ['/core.mjs', ['simulator', 'core.mjs', 'text/javascript; charset=utf-8']],
  ['/lifecycle-corpus.json', ['lean', 'lifecycle-corpus.json', 'application/json']],
]);
const server = createServer((request, response) => {
  const route = request.url === '/' ? '/lifecycle-view.html' : request.url;
  const file = publicFiles.get(route);
  if (file === undefined) {
    response.writeHead(404);
    response.end();
    return;
  }
  readFile(join(root, file[0], file[1])).then(bytes => {
    response.writeHead(200, {'Content-Type': file[2]});
    response.end(bytes);
  }, error => {
    response.writeHead(500);
    response.end(error.message);
  });
});

let browser;
let passed = false;
try {
  assert(process.env.PLAYWRIGHT_MODULE,
    'Run through the pinned Nix browser-check app or development shell');
  const {chromium} = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  await new Promise((accept, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', accept);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browserEnvironment = {...process.env};
  for (const name of ['XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']) {
    const directory = join(evidence, name.toLowerCase());
    await mkdir(directory, {mode: 0o700});
    browserEnvironment[name] = directory;
  }
  browser = await chromium.launch({
    headless: true,
    channel: 'chromium',
    env: browserEnvironment,
    args: ['--no-zygote'],
  });
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
  page.setDefaultTimeout(10_000);
  const external = [];
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  await page.route('**/*', route => {
    if (route.request().url().startsWith(origin)) return route.continue();
    external.push(route.request().url());
    return route.abort();
  });
  await page.goto(`${origin}/lifecycle-view.html`, {waitUntil: 'networkidle'});

  const checks = [];
  const check = (condition, label) => {
    assert(condition, label);
    checks.push(label);
  };
  const result = page.locator('#result');
  const clickResult = async (selector, fragment, label) => {
    await page.click(selector);
    check((await result.innerText()).includes(fragment), label);
  };
  const receipt = await page.evaluate(() => window.lifecycleCorpusReceipt);
  check(receipt.discovered === 44 && receipt.executed === 44,
    'Lean-derived lifecycle replay is 44/44');
  check(await page.locator('#reconciliation tr').count() === 44,
    'all 44 identities have public correspondence rows');

  await clickResult('#destination-clear', 'Clear payment destination', 'destination clear');
  await clickResult('#destination-set', 'Set payment destination', 'destination set');
  await clickResult('#destination-replace', 'Replace payment destination', 'destination replace');
  await clickResult('#destination-missing-signer', 'controller-signature', 'missing controller refused');
  await clickResult('#destination-tamper', 'destination-field-preservation', 'maintenance tamper refused');
  await clickResult('#destination-quorum-tamper', 'destination-field-preservation',
    'maintenance quorum alteration refused');

  await clickResult('#recovery-key-loss', 'marked unavailable', 'key loss is visible');
  check(await page.locator('#retirement-controller').isDisabled(),
    'controller retirement disabled after controller key loss');
  check(await page.locator('#retirement-quorum').isEnabled(),
    'quorum retirement remains enabled after controller key loss');
  await clickResult('#recovery-wrong-reveal', 'recovery-commitment', 'wrong reveal refused');
  await clickResult('#recovery-missing-signer', 'recovery-required-signer', 'missing recovery signer refused');
  await clickResult('#recovery-wrong-signer', 'recovery-required-signer', 'wrong payment-key signer refused');
  await clickResult('#recovery-missing-fresh', 'recovery-fresh-commitment', 'missing fresh commitment refused');
  await clickResult('#recovery-tamper', 'recovery-field-preservation', 'recovery tamper refused');
  await clickResult('#recovery-representative-tamper', 'recovery-representative', 'representative tamper refused');
  await clickResult('#recovery-registry-tamper', 'recovery-registry', 'registry tamper refused');
  await clickResult('#recovery-quorum-tamper', 'recovery-field-preservation', 'recovery quorum tamper refused');
  await clickResult('#recovery-forged-digest', 'lifecycle-action', 'caller digest refused');
  await clickResult('#recovery-accept', 'Recover with committed next controller', 'recovery accepted');
  check((await result.innerText()).includes('executingWitness'), 'recovery execution witness visible');
  await clickResult('#recovery-replay', 'recovery-commitment', 'recovery replay refused');
  await clickResult('#recovery-old-controller', 'controller-signature', 'old controller refused');
  await clickResult('#recovery-new-controller-update', 'Destination update by recovered controller',
    'new controller updates destination');

  await clickResult('#retirement-reset', 'other authorization route', 'retirement reset');
  await clickResult('#retirement-quorum-takeover', 'controller-signature', 'quorum control takeover refused');
  await clickResult('#retirement-quorum-redirect', 'controller-signature', 'quorum payment redirection refused');
  await clickResult('#retirement-wrong-custody', 'retirement-request', 'wrong retirement custody refused');
  await clickResult('#retirement-controller', '"observation": "pending"', 'controller queues pending retirement');
  check((await page.locator('#state-summary').innerText()).includes('pending'), 'pending resolve is visible');
  check(await page.locator('#destination-clear').isDisabled(), 'active-only controls disabled while retirement pending');
  for (const id of ['destination-set', 'recovery-key-loss', 'retirement-controller', 'retirement-quorum']) {
    check(await page.locator(`#${id}`).isDisabled(), `${id} disabled while retirement pending`);
  }
  for (const id of ['retirement-withdraw', 'retirement-replay', 'retirement-fold']) {
    check(await page.locator(`#${id}`).isEnabled(), `${id} enabled while retirement pending`);
  }
  await clickResult('#retirement-withdraw', 'retirement-withdrawal-refused', 'retirement withdrawal refused');
  await clickResult('#retirement-replay', 'naming-record-unavailable', 'retirement replay refused');
  await clickResult('#retirement-fold', 'retired / Over', 'separate permissionless fold completes retirement');
  check((await page.locator('#state-summary').innerText()).includes('retired'), 'retired resolve is visible');
  check(await page.locator('#destination-clear').isDisabled(), 'clear destination disabled after Over');
  for (const id of ['recovery-key-loss', 'retirement-controller', 'retirement-withdraw',
    'retirement-replay', 'retirement-fold']) {
    check(await page.locator(`#${id}`).isDisabled(), `${id} disabled after Over`);
  }
  check(await page.locator('#retirement-reregister').isEnabled(), 'post-Over re-registration refusal enabled');
  check((await page.locator('#state-guidance').innerText()).includes('Reset to active alice'),
    'post-Over reset guidance visible');
  await clickResult('#retirement-reregister', 'occupied-key', 're-registration after Over refused');
  await clickResult('#retirement-reset', 'other authorization route', 'reset for quorum route');
  await clickResult('#retirement-insufficient', 'retirement-authorization', 'insufficient quorum refused');
  await clickResult('#retirement-quorum', '"observation": "pending"', 'quorum-only route queues retirement');
  check(!(await result.innerText()).includes('controllerAddress'), 'quorum route needs no controller signer');
  await clickResult('#retirement-fold', 'retired / Over', 'quorum retirement separately folded');

  await clickResult('#initialization-canonical', 'Canonical consumer initialization', 'canonical initialization');
  await clickResult('#initialization-repeat', 'canonical-seed-consumed', 'repeated seed refused');
  await clickResult('#initialization-alternate', 'canonical-seed', 'alternate seed refused');
  await clickResult('#initialization-rival', 'canonical-seed', 'rival registry seed refused');
  await clickResult('#initialization-registry', 'registry-authenticity', 'substituted registry refused');
  await clickResult('#initialization-policy', 'application-policy', 'substituted policy refused');
  await clickResult('#initialization-representative-policy', 'representative-policy',
    'substituted representative policy refused');
  await clickResult('#initialization-validator', 'validator-script', 'substituted validator script refused');

  await clickResult('#wire-roundtrip', 'byteLength', 'four-field wire bytes round-trip');
  await clickResult('#wire-hash', 'inline-datum-required', 'datum hash refused');
  await clickResult('#wire-two-destinations', 'four-field-datum-shape', 'two destinations refused');

  const observed = await page.evaluate(() => window.lifecycleJourney.observed().sort());
  check(observed.length === 39, 'all 39 non-cancellation lifecycle identities were browser-observed');
  check(await page.getByText('No death oracle.', {exact: false}).isVisible(), 'no-death-oracle boundary visible');
  const rawAddressLimit = await page.locator('.limits p')
    .filter({hasText: 'Raw-address payment limit.'}).innerText();
  check(rawAddressLimit.includes('prevents name-based resolution')
    && rawAddressLimit.includes('cannot prevent someone from sending directly')
    && rawAddressLimit.includes('previously saved raw Cardano address'),
  'retirement raw-address payment limit explained');
  check(await page.getByText('Claim cancellation is separate.', {exact: false}).isVisible(),
    'claim cancellation and retirement withdrawal are distinguished');
  await page.goto(new URL('/index.html', page.url()).href, {waitUntil: 'networkidle'});
  await page.selectOption('#naming-profile', 'm1-naming');
  const namingWithdraw = page.locator('#naming-card').getByRole('button', {name: /withdraw/i});
  check(await namingWithdraw.count() === 1, 'naming /withdraw/i claim-cancellation control present');
  await page.click('#naming-claim');
  const storedRefundAddress = await page.locator('#naming-state')
    .evaluate(node => JSON.parse(node.textContent).registry.requests[0].proposal.refundAddress);
  check(storedRefundAddress === 60, 'pending naming claim stores refund address');
  await page.locator('#naming-cancel-approved').uncheck();
  await namingWithdraw.click();
  check((await page.locator('#naming-verdict').innerText()).includes('LC03-insert-attestation-cancellation-refused'),
    'public cancellation requires separate approval');
  observed.push('LC03-insert-attestation-cancellation-refused');
  await page.locator('#naming-cancel-approved').check();
  await page.locator('#naming-refund-redirect').check();
  await namingWithdraw.click();
  check((await page.locator('#naming-verdict').innerText()).includes('LC02-cancellation-redirect-refused'),
    'public cancellation refuses refund redirection');
  observed.push('LC02-cancellation-redirect-refused');
  await page.locator('#naming-refund-redirect').uncheck();
  await namingWithdraw.click();
  check((await page.locator('#naming-verdict').innerText()).includes(
    `LC01-cancellation-stored-refund-accepts: claim #1 withdrawn; copied stored refund address ${storedRefundAddress}`),
    'public cancellation copies stored refund address');
  const cancelledState = await page.locator('#naming-state').evaluate(node => JSON.parse(node.textContent));
  check(cancelledState.claims.length === 0 && cancelledState.registry.requests.length === 0,
    'public cancellation consumes pending claim');
  await page.click('#naming-resolve');
  check((await page.locator('#naming-verdict').innerText()).includes('absent'),
    'public cancellation leaves name absent');
  observed.push('LC01-cancellation-stored-refund-accepts');
  await namingWithdraw.click();
  check((await page.locator('#naming-verdict').innerText()).includes('LC06-cancellation-replay-refused'),
    'public cancellation replay refused');
  observed.push('LC06-cancellation-replay-refused');
  await page.selectOption('#naming-profile', 'generic');
  await page.selectOption('#naming-profile', 'm1-naming');
  await page.click('#naming-claim');
  await page.click('#naming-fold-first');
  await namingWithdraw.click();
  check((await page.locator('#naming-verdict').innerText()).includes('LC04-folded-claim-cancellation-refused'),
    'public folded-claim cancellation refused');
  observed.push('LC04-folded-claim-cancellation-refused');
  check(JSON.stringify(observed.sort()) === JSON.stringify([...receipt.identities].sort()),
    'all 44 model and corpus identities were browser-observed');
  check(external.length === 0, 'no external runtime requests');
  check(pageErrors.length === 0, `no page errors: ${pageErrors.join('; ')}`);

  await page.screenshot({path: join(evidence, 'lifecycle-public.png'), fullPage: true});
  const report = {
    status: 'PASS', checks: checks.length, assertions: checks, identities: observed,
    pageErrors, external, browser: browser.version(), screenshot: 'lifecycle-public.png', evidence,
  };
  await writeFile(join(evidence, 'result.json'), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report));
  passed = true;
} finally {
  await browser?.close();
  if (server.listening) await new Promise(resolveServer => server.close(resolveServer));
  if (passed && process.env.KEEP_BROWSER_EVIDENCE !== '1') await rm(evidence, {recursive: true});
  else console.error(`Lifecycle browser evidence retained: ${evidence}`);
}
