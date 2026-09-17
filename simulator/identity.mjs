// Regenerate simulator/identity.json — the page's statement of what it is built
// from. Run it after the Lean, the corpus or the template moves, then rebuild.
//
// The file list is READ OUT of the shipped mirror rather than enumerated here.
// A hand-written list is a check that stops covering its subject the moment the
// subject grows, silently: that is how simulator/formal/Main.lean sat stale.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const root = new URL('./', import.meta.url);
const hash = p => createHash('sha256').update(readFileSync(new URL(p, root))).digest('hex');
export const bound = () => [
  ...readdirSync(new URL('formal/', root)).filter(f => f !== 'README.md').sort().map(f => `formal/${f}`),
  'corpus.json',
];

if (import.meta.url === `file://${process.argv[1]}`) {
  const json = p => JSON.parse(readFileSync(new URL(p, root), 'utf8'));
  const corpus = json('corpus.json');
  const files = Object.fromEntries(bound().map(p => [p, hash(p)]));
  const identity = {
    status: 'SIMULATOR-CANDIDATE',
    formalStatus: 'PROVED / standard axioms',
    profiles: [
      { id: 'generic', label: 'Generic registry profile', engine: 'simulator/core.mjs' },
      { id: 'naming', label: 'Naming profile — the Over witness', engine: 'simulator/naming.mjs' }],
    files,
    templateSha256: hash('page-template.html'),
    corpusCases: corpus.cases.length,
    corpusFolds: corpus.folds.length,
    corpusCodec: corpus.codec.length,
    corpusAda: corpus.ada.length,
    theorems: json('formal/theorem-debt.json').length,
    namingTheorems: json('../lean/naming-theorem-debt.json').length,
  };
  writeFileSync(new URL('identity.json', root), JSON.stringify(identity, null, 2) + '\n');
  console.log(`identity: ${Object.keys(files).length} bound files, ${identity.corpusCases} cases, ${identity.theorems} statements, ${identity.namingTheorems} naming`);
}
