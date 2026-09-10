import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

async function checkPage(page, evidence) { const errors=[]; page.on('pageerror',e=>errors.push(e.message)); const checks=[]; const assert=(v,m)=>{if(!v)throw Error(m);checks.push(m)};
  await page.selectOption('#story-picker','register');
  await page.click('#hist-last');
  assert((await page.locator('#where').innerText()).includes('address 100'),'register outcome');
  await page.selectOption('#story-picker','compete');
  await page.click('#hist-next');
  await page.click('#hist-next');
  await page.locator('#branches button').filter({hasText:'Try folding both'}).click();
  assert((await page.locator('#narration').innerText()).includes('occupied-key'),'batch refusal');
  await page.click('#hist-prev');
  await page.locator('#branches button').filter({hasText:'Fold the first request'}).click();
  await page.click('#hist-last');
  assert((await page.locator('#where').innerText()).includes('0 pending'),'withdraw story');
  await page.click('#btn-reset');
  await page.click('#create-insert');
  await page.fill('#datum-input','200');
  await page.click('#create-insert');
  assert(await page.locator('[data-batch]').count()===2,'competing inserts');
  await page.locator('[data-batch="1"]').check();
  await page.click('#fold-batch');
  assert((await page.locator('#where').innerText()).includes('address 100'),'fold first manual');
  await page.click('#withdraw');
  assert((await page.locator('#narration').innerText()).includes('withdraw-binding'),'withdraw separate auth refusal');
  await page.click('#mint-withdraw');
  await page.click('#withdraw');
  assert((await page.locator('#where').innerText()).includes('0 pending'),'manual withdrawal');
  await page.locator('#spend-approved').uncheck();
  await page.click('#evolve');
  assert((await page.locator('#narration').innerText()).includes('application-evolution-authorization'),'unauthorized change');
  await page.locator('#spend-approved').check();
  await page.click('#evolve');
  assert((await page.locator('#where').innerText()).includes('address 200'),'manual address B');
  await page.click('#release-update');
  await page.click('#resolve');
  assert(await page.locator('#resolve-output').innerText()==='pending','pending resolution');
  await page.locator('[data-batch]').check();
  await page.click('#fold-batch');
  await page.click('#resolve');
  assert(await page.locator('#resolve-output').innerText()==='retired','retired resolution');
  await page.locator('#authenticated-view').uncheck();
  await page.click('#resolve');
  assert(await page.locator('#resolve-output').innerText()==='unauthenticated','forged view');
  await page.click('#btn-theme');
  await page.selectOption('#naming-profile','m1-naming');
  assert((await page.locator('#naming-verdict').innerText()).includes('unaccepted'),'naming profile selected');
  const namingTheoremNames=await page.evaluate(()=>NAMINGTHEOREMS.map(row=>row.name).sort());
  const namingLampNames=(await page.locator('[data-naming-theorem]').evaluateAll(nodes=>nodes.map(node=>node.getAttribute('data-naming-theorem')).sort()));
  assert(namingTheoremNames.length>0&&JSON.stringify(namingLampNames)===JSON.stringify(namingTheoremNames),'naming exact theorem lamps');
  await page.click('#naming-claim');
  assert((await page.locator('#naming-verdict').innerText()).includes('queued'),'naming first claim');
  await page.click('#naming-claim-competing');
  assert((await page.locator('#naming-verdict').innerText()).includes('Competing'),'naming competing claim');
  await page.click('#naming-fold-first');
  assert((await page.locator('#naming-verdict').innerText()).includes('Active'),'naming first fold active');
  await page.click('#naming-fold-second');
  assert((await page.locator('#naming-verdict').innerText()).includes('occupied-key'),'naming duplicate refused');
  await page.click('#naming-crafted-delete');
  assert((await page.locator('#naming-verdict').innerText()).includes('naming-no-delete'),'naming crafted delete refused');
  await page.click('#naming-resolve');
  assert((await page.locator('#naming-verdict').innerText()).includes('paymentDestination'),'naming resolve carries fixture');
  await page.selectOption('#naming-profile','generic');
  assert((await page.locator('#naming-verdict').innerText()).includes('No implicit fallback'),'naming explicit fallback guard');
  await page.screenshot({path:join(evidence,'browser-dark.png'),fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await page.click('#btn-theme');
  await page.selectOption('#story-picker','batch');
  await page.click('#hist-last');
  assert((await page.locator('#where').innerText()).includes('address 200'),'delete reinsert story');
  await page.screenshot({path:join(evidence,'browser-mobile.png'),fullPage:true});
  await page.goto(new URL('/lifecycle-view.html', page.url()).href, {waitUntil:'networkidle'});
  await page.click('#hash');
  assert((await page.locator('#result').innerText()).includes('digest'),'lifecycle browser non-fixture hash');
  await page.click('#forge');
  assert((await page.locator('#result').innerText()).includes('lifecycle-action'),'lifecycle browser forged digest refused');
  await page.click('#retire');
  const retirement=await page.locator('#result').innerText();
  assert(retirement.includes('pending')&&retirement.includes('retired'),'lifecycle browser pending retired distinction');
  assert(errors.length===0,'page errors '+errors.join(';'));
  return {status:'PASS',checks:checks.length,assertions:checks,errors,url:page.url(),title:await page.title(),browser:page.context().browser().version(),manual:['competing Inserts','fold first','withdraw refused without separate approval','mint withdrawal approval','withdraw second','unauthorized evolution refused','evolve address B','queue Update','resolve pending','fold terminal','resolve retired','unauthenticated view','naming claim and fold','naming occupied-key','naming crafted delete','naming resolve fixture'],stories:['register','compete refusal fork and trunk','batch','naming journey'],screenshots:['browser-dark.png','browser-mobile.png']}; }

const root = resolve(process.argv[2] ?? '.');
const evidence = await mkdtemp(join(tmpdir(), 'singular-browser-'));
const html = await readFile(join(root, 'simulator/index.html'));
const server = createServer((request, response) => {
  if (request.url === '/' || request.url === '/index.html') {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end(html);
  } else if (['/lifecycle-view.html','/lifecycle-view.mjs','/lifecycle.mjs','/naming.mjs','/core.mjs'].includes(request.url)) {
    const file = request.url.slice(1);
    readFile(join(root, 'simulator', file)).then(bytes => {
      response.writeHead(200, {'Content-Type': file.endsWith('.html') ? 'text/html; charset=utf-8' : 'text/javascript; charset=utf-8'});
      response.end(bytes);
    }, error => { response.writeHead(500); response.end(error.message); });
  } else {
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
  await writeFile(join(evidence, 'result.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({ ...result, evidence }));
  passed = true;
} finally {
  await browser?.close();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  if (passed && process.env.KEEP_BROWSER_EVIDENCE !== '1') await rm(evidence, { recursive: true });
  else console.error(`Browser evidence retained: ${evidence}`);
}
