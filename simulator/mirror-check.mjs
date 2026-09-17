// The shipped Lean mirror must equal the canonical Lean, in both directions.
//
// A one-directional check passes on a mirror that has quietly lost a file, and a
// hash list passes on a mirror nobody regenerated. This compares the two sets and
// then the bytes, so a missing file, an extra file and a stale file are three
// distinct failures.
import { readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const root = new URL('../', import.meta.url);
const mirror = new URL('formal/', import.meta.url);
const digest = url => createHash('sha256').update(readFileSync(url)).digest('hex');

// The canonical extent, read out of the tree rather than listed here: a model
// file added under lean/ and not mirrored must fail this, not be invisible to it.
const canonical = new Map();
for (const f of readdirSync(new URL('lean/Singular/', root))) canonical.set(f, new URL(`lean/Singular/${f}`, root));
// Every top-level Lean source: the library root, which decides what `lake build`
// compiles at all, and each corpus generator. Read off the directory rather than
// named one by one — Main.lean was mirrored and LifecycleMain.lean was not, so
// the generator that emits the wire rows could change with the mirror silent.
for (const f of readdirSync(new URL('lean/', root)))
  if (f.endsWith('.lean')) canonical.set(f, new URL(`lean/${f}`, root));
for (const f of readdirSync(new URL('lean/', root)))
  if (f.endsWith('theorem-debt.json')) canonical.set(f, new URL(`lean/${f}`, root));

// The page also embeds its own copy of the generated corpus. Same drift shape,
// same check: it is a copy of lean/corpus.json or it is a second source of truth.
const problemsCorpus = digest(new URL('corpus.json', import.meta.url)) === digest(new URL('lean/corpus.json', root))
  ? [] : ['stale beside the page: corpus.json'];

const mirrored = new Set(readdirSync(mirror).filter(f => f !== 'README.md'));
const problems = [...problemsCorpus];
for (const [name, source] of canonical) {
  if (!mirrored.has(name)) { problems.push(`missing from the mirror: ${name}`); continue; }
  if (digest(source) !== digest(new URL(name, mirror))) problems.push(`stale in the mirror: ${name}`);
  mirrored.delete(name);
}
for (const name of mirrored) problems.push(`in the mirror but not under lean/: ${name}`);

if (problems.length) { for (const p of problems) console.error(`  ${p}`); console.error(`FAIL mirror: ${problems.length} file(s)`); process.exit(1); }
console.log(`PASS mirror: ${canonical.size} Lean sources and manifests, plus the embedded corpus, ship exactly as they are built`);
