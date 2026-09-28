// biome-ignore-all lint/correctness/noUnusedVariables: these helpers are used by page.mjs,
// which simulator/build.mjs concatenates into the same page script.
// Small DOM helpers shared by the page. Kept separate so the page module reads
// as behaviour rather than as string building.
const $ = (id) => document.getElementById(id);
const esc = (s) =>
  String(s).replace(
    /[&<>"]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c],
  );
const rows = (tbody, data, cells) => {
  tbody.innerHTML = data
    .map(
      (d) =>
        '<tr>' +
        cells(d)
          .map((c) => `<td>${esc(c)}</td>`)
          .join('') +
        '</tr>',
    )
    .join('');
};
const button = (label, attrs = '') => `<button type="button" ${attrs}>${esc(label)}</button>`;
const leafName = (l) => (l === null ? 'Unknown' : `Known ${l}`);
