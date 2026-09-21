// The naming lifecycle — maintenance, recovery, retirement, the consumer
// binding and the wire datum — replayed from the Lean corpus.
//
// It does not re-implement the lifecycle. The previous simulator did, in about
// nine hundred lines of JavaScript, and when the Lean moved to registry mode
// every one of those lines went on describing a model that no longer existed
// while still reporting green. What is transcribed here is the *replay*: each
// row is a verdict the Lean computed, and the page's job is to show it and to
// fail loudly when the corpus it was given is not the corpus it expects.
export const LIFECYCLE_SECTIONS = ['initializations', 'steps', 'recovery', 'retirement', 'wire'];

// What each section is about, in the reader's words rather than the field name.
export const LIFECYCLE_TITLES = {
  initializations: 'Seeding the consumer: every pinned policy is checked',
  steps: 'Maintenance: the payment destination moves, the registry does not',
  recovery: 'Recovery: the committed key is revealed, and the old one is dead',
  retirement: 'Retirement: the recovery key or a quorum, never the control key alone',
  wire: 'The datum on the wire, byte for byte',
};

/** Inspect the lifecycle corpus. Every row is an expectation the Lean model
 * computed and every row must still say what it said; an empty section, a
 * duplicate id or a row without a verdict is a failure, not a smaller pass.
 *
 * The receipt reports INSPECTION, never execution: these rows are verdicts
 * the Lean computed, replayed by nothing here, so `executed` is zero by
 * construction and the page labels say "inspected". */
export function checkLifecycleCorpus(corpus) {
  if (!corpus || typeof corpus !== 'object') throw Error('no lifecycle corpus');
  let discovered = 0, executed = 0;
  const ids = new Set(), rows = [];
  for (const section of LIFECYCLE_SECTIONS) {
    const found = corpus[section];
    if (!Array.isArray(found) || found.length === 0)
      throw Error(`empty lifecycle corpus section: ${section}`);
    for (const row of found) {
      discovered++;
      if (typeof row.id !== 'string' || !row.id) throw Error(`lifecycle row without an id in ${section}`);
      if (ids.has(row.id)) throw Error(`duplicate lifecycle row: ${row.id}`);
      ids.add(row.id);
      if (typeof row.ok !== 'boolean') throw Error(`lifecycle row has no verdict: ${row.id}`);
      // Every row states something that HELD in the Lean. A false one is the
      // model contradicting its own corpus, not a row the page may display.
      if (row.ok !== true) throw Error(`lifecycle row did not hold in the model: ${row.id}`);
      rows.push({ section, id: row.id, detail: row.detail });
      executed++;
    }
  }
  if (discovered !== executed) throw Error('lifecycle denominator');
  return { discovered, inspected: executed, executed: 0,
    sections: LIFECYCLE_SECTIONS.length, rows, boundary: 'evidence' };
}

/** The reason a row records, when it records one rather than a plain `true`. */
export function lifecycleReason(row) {
  return typeof row.detail === 'string' ? row.detail : '— held —';
}
