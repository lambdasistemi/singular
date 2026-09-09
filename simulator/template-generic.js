const SVGNS = 'http://www.w3.org/2000/svg';

// tiny DOM helpers: h(tag, attrs, ...children) and its SVG twin
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'dataset') for (const [dk, dv] of Object.entries(v)) el.dataset[dk] = dv;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'hidden' || k === 'disabled' || k === 'selected' || k === 'open') { if (v) el.setAttribute(k, ''); el[k] = !!v; }
    else el.setAttribute(k, String(v));
  }
  for (const c of kids.flat()) if (c !== null && c !== undefined && c !== false) el.append(typeof c === 'string' || typeof c === 'number' ? String(c) : c);
  return el;
}
function s(tag, attrs, ...kids) {
  const el = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'dataset') for (const [dk, dv] of Object.entries(v)) el.setAttribute('data-' + dk, dv);
    else el.setAttribute(k, String(v));
  }
  for (const c of kids.flat()) if (c !== null && c !== undefined && c !== false) el.append(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
  return el;
}
const $ = id => document.getElementById(id);
const clear = el => { el.replaceChildren(); return el; };
const fmt = n => String(n);
const raf = cb => (typeof requestAnimationFrame === 'function' ? requestAnimationFrame(cb) : setTimeout(() => cb(Date.now()), 16));
const nowMs = () => (typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now());

/* ---- the tree of plays --------------------------------------------------------
   A node is a session (immutable) plus the record that produced it. Children
   are branches; `last` remembers the branch last taken, so › follows it. */
const app = {
  nodes: [],      // [{id, parent, children, last, session, record, who, say, kind, branch}]
  cursor: 0,
  story: null,    // the scenario being played, or null
  actor: 'alice',
  pending: null,  // {offer, action}
  playing: null,  // interval id while ▶ runs
  fx: [],         // running animations (cancelled on the next move)
};
const node = id => app.nodes[id];
const cur = () => node(app.cursor).session;
function newTree(session, say) {
  app.nodes = [{ id: 0, parent: null, children: [], last: null, session, record: null, who: '', say, kind: 'origin', branch: null }];
  app.cursor = 0; app.pending = null; stopPlay();
}
function addChild(parentId, entry) {
  const n = { id: app.nodes.length, parent: parentId, children: [], last: null, branch: null, ...entry };
  app.nodes.push(n);
  const p = node(parentId); p.children.push(n.id); p.last = n.id;
  return n.id;
}
function pathTo(id) { const out = []; for (let n = id; n !== null; n = node(n).parent) out.unshift(n); return out; }
function forwardPath(id) { const out = []; let n = id; for (;;) { const c = nextOf(n); if (c === null) break; out.push(c); n = c; } return out; }
const currentPath = () => [...pathTo(app.cursor), ...forwardPath(app.cursor)];
// the next node along the branch last taken; a trunk's end has no next of its
// own — its forks are entered through their chips, never by › or ⇥
const nextOf = id => { const n = node(id); if (!n.children.length) return null; if (n.last !== null) return n.last; return n.trunkEnd ? null : n.children[0]; };
const leafNodeOf = id => { let n = id; for (;;) { const c = nextOf(n); if (c === null) return n; n = c; } };
function branchLabel(id) {
  const n = node(id);
  if (n.branch) return n.branch.title;
  if (n.record) return describeAction(n.record.action) + (n.record.ok ? '' : ' (refused)');
  return n.say ? n.say.slice(0, 40) : 'step';
}
