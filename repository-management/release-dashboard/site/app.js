'use strict';

const STATE_LABEL = {
  'unreleased-work': 'Unreleased work',
  'never-released': 'No version tag',
  'automation-only': 'Bot commits only',
  'current': 'Fully released',
  'compare-failed': 'Lookup failed',
  'unknown': 'Unknown'
};

// Most actionable first. Drives the default table order.
const STATE_RANK = {
  'unreleased-work': 0,
  'never-released': 1,
  'compare-failed': 2,
  'automation-only': 3,
  'current': 4,
  'unknown': 5
};

const AGED_DAYS = 90;
const THEME_LABEL = { system: 'System', light: 'Light', dark: 'Dark' };

// What a field-level change means for someone already using the module.
const VERDICT_LABEL = {
  breaking: 'breaks callers',
  behaviour: 'changes behaviour',
  relaxed: 'accepts more',
  unclear: 'needs reading'
};

// One series counts repositories and one counts issues, so each label names its
// unit. They share an axis, which would otherwise read as though 38 repos and 5
// issues were the same kind of quantity.
const SERIES = [
  {
    key: 'unreleasedWork',
    label: 'Repos with unreleased work',
    note: 'changes merged but not tagged yet',
    color: 'var(--amber)'
  },
  {
    key: 'awaitingIssues',
    label: 'Issues awaiting release',
    note: 'labelled Awaiting Release To Be Cut',
    color: 'var(--accent)'
  }
];

let MODULES = [];
let HISTORY = [];
const EXPANDED = new Set();
let sortKey = 'state';
let sortAsc = true;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function cell(label, className, text) {
  const td = el('td', className, text);
  td.dataset.label = label;
  return td;
}

function shortDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return '—';
  return d.toISOString().slice(0, 10);
}

/* theme ------------------------------------------------------------------ */

function applyTheme(choice) {
  document.documentElement.setAttribute('data-theme', choice);
  try { localStorage.setItem('avm-theme', choice); } catch (e) { /* private mode */ }

  document.getElementById('themeTriggerIcon').setAttribute('href', '#i-' + choice);
  document.getElementById('themeTriggerLabel').textContent = THEME_LABEL[choice] || choice;

  document.querySelectorAll('[data-theme-choice]').forEach(b => {
    b.setAttribute('aria-selected', String(b.dataset.themeChoice === choice));
  });
}

function closeThemeMenu() {
  document.getElementById('themeList').hidden = true;
  document.getElementById('themeTrigger').setAttribute('aria-expanded', 'false');
}

function wireTheme() {
  const trigger = document.getElementById('themeTrigger');
  const list = document.getElementById('themeList');

  let current = 'system';
  try { current = localStorage.getItem('avm-theme') || 'system'; } catch (e) { /* private mode */ }
  // An earlier build stored "auto" for this option.
  if (current === 'auto') current = 'system';
  applyTheme(current);

  trigger.addEventListener('click', e => {
    e.stopPropagation();
    const open = list.hidden;
    list.hidden = !open;
    trigger.setAttribute('aria-expanded', String(open));
  });

  list.querySelectorAll('[data-theme-choice]').forEach(b => {
    b.addEventListener('click', () => {
      applyTheme(b.dataset.themeChoice);
      closeThemeMenu();
      trigger.focus();
    });
  });

  document.addEventListener('click', e => {
    if (!document.getElementById('themeMenu').contains(e.target)) closeThemeMenu();
  });

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !list.hidden) { closeThemeMenu(); trigger.focus(); }
  });
}

/* trend chart ------------------------------------------------------------ */

const SVG_NS = 'http://www.w3.org/2000/svg';

function svg(tag, attrs) {
  const node = document.createElementNS(SVG_NS, tag);
  Object.entries(attrs || {}).forEach(([k, v]) => node.setAttribute(k, String(v)));
  return node;
}

// A viewBox lets the chart scale with the panel without recomputing on resize.
const CHART = { w: 900, h: 220, left: 40, right: 16, top: 16, bottom: 28 };

function renderTrend() {
  const panel = document.getElementById('trendPanel');
  const host = document.getElementById('trend');
  host.textContent = '';

  if (HISTORY.length === 0) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;

  const note = document.getElementById('trendNote');
  if (HISTORY.length === 1) {
    note.textContent = 'One day recorded so far. The shape appears once a few more runs land.';
  } else {
    note.textContent = HISTORY.length + ' days recorded, ' + HISTORY[0].date + ' to ' + HISTORY[HISTORY.length - 1].date + '.';
  }

  const plotW = CHART.w - CHART.left - CHART.right;
  const plotH = CHART.h - CHART.top - CHART.bottom;

  const values = HISTORY.flatMap(row => SERIES.map(s => row[s.key] || 0));
  // Round the ceiling up to a multiple of five so the gridline labels stay whole.
  const peak = Math.max(5, Math.ceil(Math.max(...values) / 5) * 5);

  const x = i => CHART.left + (HISTORY.length === 1 ? plotW / 2 : (i / (HISTORY.length - 1)) * plotW);
  const y = v => CHART.top + plotH - (v / peak) * plotH;

  const chart = svg('svg', {
    viewBox: `0 0 ${CHART.w} ${CHART.h}`,
    class: 'chart',
    role: 'img',
    'aria-label': 'Counts over time. Latest: ' +
      SERIES.map(s => s.label + ' ' + (HISTORY[HISTORY.length - 1][s.key] || 0)).join(', ') + '.'
  });

  [0, 0.5, 1].forEach(fraction => {
    const value = Math.round(peak * fraction);
    const yy = y(value);
    chart.appendChild(svg('line', { x1: CHART.left, y1: yy, x2: CHART.w - CHART.right, y2: yy, class: 'grid' }));
    const label = svg('text', { x: CHART.left - 8, y: yy + 4, class: 'axis', 'text-anchor': 'end' });
    label.textContent = String(value);
    chart.appendChild(label);
  });

  // Drawn before the dots so it sits behind them.
  const guide = svg('line', { y1: CHART.top, y2: CHART.top + plotH, class: 'guide', opacity: 0 });
  chart.appendChild(guide);

  const dotsByColumn = HISTORY.map(() => []);

  SERIES.forEach(series => {
    if (HISTORY.length > 1) {
      const points = HISTORY.map((row, i) => `${x(i)},${y(row[series.key] || 0)}`).join(' ');
      chart.appendChild(svg('polyline', { points, class: 'line', stroke: series.color }));
    }
    HISTORY.forEach((row, i) => {
      const dot = svg('circle', { cx: x(i), cy: y(row[series.key] || 0), r: 3, class: 'dot', fill: series.color });
      chart.appendChild(dot);
      dotsByColumn[i].push(dot);
    });
  });

  const first = svg('text', { x: CHART.left, y: CHART.h - 8, class: 'axis' });
  first.textContent = HISTORY[0].date;
  chart.appendChild(first);

  if (HISTORY.length > 1) {
    const last = svg('text', { x: CHART.w - CHART.right, y: CHART.h - 8, class: 'axis', 'text-anchor': 'end' });
    last.textContent = HISTORY[HISTORY.length - 1].date;
    chart.appendChild(last);
  }

  host.appendChild(chart);

  // One transparent band per day, full plot height. A 3px dot is far too small to
  // aim at, and hovering the band shows every series for that date at once rather
  // than one value at a time.
  const tooltip = el('div', 'chart-tip');
  tooltip.hidden = true;
  host.appendChild(tooltip);

  const span = HISTORY.length > 1 ? plotW / (HISTORY.length - 1) : plotW;

  const clearHover = () => {
    tooltip.hidden = true;
    guide.setAttribute('opacity', '0');
    dotsByColumn.flat().forEach(dot => dot.setAttribute('r', '3'));
  };

  HISTORY.forEach((row, i) => {
    const band = svg('rect', {
      x: Math.max(0, x(i) - span / 2),
      y: CHART.top,
      width: HISTORY.length > 1 ? span : plotW,
      height: plotH,
      class: 'band'
    });

    band.addEventListener('mouseenter', () => {
      guide.setAttribute('x1', String(x(i)));
      guide.setAttribute('x2', String(x(i)));
      guide.setAttribute('opacity', '1');

      dotsByColumn.flat().forEach(dot => dot.setAttribute('r', '3'));
      dotsByColumn[i].forEach(dot => dot.setAttribute('r', '5'));

      tooltip.textContent = '';
      tooltip.appendChild(el('div', 'tip-date', row.date));
      SERIES.forEach(series => {
        const line = el('div', 'tip-row');
        const swatch = el('span', 'swatch');
        swatch.style.background = series.color;
        line.appendChild(swatch);
        line.appendChild(el('span', 'tip-label', series.label));
        line.appendChild(el('span', 'tip-value', String(row[series.key] ?? 0)));
        tooltip.appendChild(line);
      });

      // The chart scales to the panel, so the anchor is a percentage of the
      // viewBox rather than a pixel offset.
      tooltip.style.left = (x(i) / CHART.w * 100) + '%';
      // Flip the tooltip to the left of the guide once the point is past the middle,
      // so it cannot overflow the panel on the right.
      tooltip.classList.toggle('flip', x(i) > CHART.w * 0.6);
      tooltip.hidden = false;
    });

    chart.appendChild(band);
  });

  chart.addEventListener('mouseleave', clearHover);
  clearHover();

  const legend = document.getElementById('trendLegend');
  legend.textContent = '';
  SERIES.forEach(series => {
    const item = el('span', 'legend-item');
    const swatch = el('span', 'swatch');
    swatch.style.background = series.color;
    item.appendChild(swatch);
    const text = el('span', 'legend-text');
    text.appendChild(el('span', 'legend-label', series.label));
    if (series.note) text.appendChild(el('span', 'legend-note', series.note));
    item.appendChild(text);
    legend.appendChild(item);
  });
}

/* rendering -------------------------------------------------------------- */

function median(numbers) {
  if (numbers.length === 0) return null;
  const sorted = [...numbers].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

// Every figure here describes the same population: modules whose default branch
// carries human commits past the newest tag. Each carries a note, because a bare
// label states a consequence without saying what was counted.
function renderCards() {
  const waiting = MODULES.filter(m => m.state === 'unreleased-work');
  const prs = waiting.reduce((total, m) => total + (m.unreleasedPrs || []).length, 0);
  const ages = waiting.map(m => m.oldestHumanDays).filter(d => d !== null && d !== undefined);
  const middle = median(ages);

  const cards = [
    {
      n: waiting.length,
      label: 'modules waiting on a release',
      note: 'someone merged work past the newest version tag',
      tone: 'warn'
    },
    {
      n: prs,
      label: 'merged pull requests, still unreleased',
      note: 'no published version includes them yet',
      tone: ''
    },
    {
      n: middle === null ? '—' : middle,
      label: 'days the typical module has waited',
      note: 'half have waited longer than this',
      tone: middle > AGED_DAYS ? 'alert' : ''
    }
  ];

  const host = document.getElementById('cards');
  host.textContent = '';

  cards.forEach(c => {
    const card = el('div', 'card' + (c.tone ? ' ' + c.tone : ''));
    card.appendChild(el('div', 'n', String(c.n)));
    card.appendChild(el('div', 'k', c.label));
    if (c.note) card.appendChild(el('div', 'k-note', c.note));
    host.appendChild(card);
  });
}

function compare(a, b) {
  let x, y;
  if (sortKey === 'state') {
    x = STATE_RANK[a.state] ?? 9;
    y = STATE_RANK[b.state] ?? 9;
  } else {
    x = a[sortKey];
    y = b[sortKey];
  }

  if (x === null || x === undefined) x = sortAsc ? Infinity : -Infinity;
  if (y === null || y === undefined) y = sortAsc ? Infinity : -Infinity;

  let result;
  if (typeof x === 'number' && typeof y === 'number') {
    result = x - y;
  } else {
    result = String(x).localeCompare(String(y));
  }
  if (result === 0) result = a.module.localeCompare(b.module);
  return sortAsc ? result : -result;
}

function linkItem(number, title, url, meta) {
  const li = el('li');
  const link = el('a', 'ref', '#' + number);
  link.href = url;
  link.target = '_blank';
  link.rel = 'noopener';
  li.appendChild(link);
  li.appendChild(el('span', 'ref-title', title));
  if (meta) li.appendChild(el('span', 'ref-meta', meta));
  return li;
}

function detailBlock(heading, items) {
  const block = el('div', 'detail-block');
  block.appendChild(el('h3', null, heading));
  const list = el('ul');
  items.forEach(node => list.appendChild(node));
  block.appendChild(list);
  return block;
}

// The suggestion always ships with the evidence that produced it. A bare verdict
// cannot be checked, and a maintainer who cannot check it will either follow a
// wrong answer or ignore a right one.
function suggestionBlock(m, delta) {
  const block = el('div', 'suggestion' + (delta.breaking ? ' is-breaking' : ''));

  const head = el('div', 'suggestion-head');
  head.appendChild(el('span', 'from', delta.comparedAgainst));
  head.appendChild(el('span', 'arrow', '→'));
  head.appendChild(el('span', 'to', delta.suggestedVersion));
  head.appendChild(el('span', 'bump ' + delta.suggestedBump, delta.suggestedBump));
  if (delta.breaking) head.appendChild(el('span', 'bump breaking', 'breaking'));
  block.appendChild(head);

  const reasons = delta.reasons || [];
  const fieldChanges = delta.fieldChanges || [];

  if (reasons.length) {
    const list = el('ul', 'suggestion-reasons');
    reasons.forEach(r => list.appendChild(el('li', null, r)));
    block.appendChild(list);
  }

  if (fieldChanges.length) {
    const list = el('ul', 'field-changes');
    fieldChanges.forEach(fc => {
      const li = el('li');
      li.appendChild(el('span', 'verdict ' + fc.verdict, VERDICT_LABEL[fc.verdict] || fc.verdict));
      li.appendChild(el('code', 'decl', fc.declaration));
      li.appendChild(el('span', 'detail', fc.detail));
      list.appendChild(li);
    });
    block.appendChild(list);
  }

  if (!reasons.length && !fieldChanges.length) {
    block.appendChild(el('p', 'fine', 'No variable or output changed, so the interface is unchanged.'));
  }

  const why = el('p', 'fine method-note');
  const unclear = delta.unclearCount || 0;
  if (unclear) {
    why.textContent = unclear + (unclear === 1 ? ' change is' : ' changes are') +
      ' marked needs reading: the declaration moved in a way a comparison cannot rank. ';
  }
  why.textContent += 'Compares every variable and output at the tag against the default branch, field by field. It cannot see behaviour that changed without the interface changing, so read the pull requests below before tagging.';
  block.appendChild(why);

  return block;
}

function detailRow(m, prs, issues) {
  const row = el('tr', 'detail');
  const holder = el('td');
  holder.colSpan = 8;

  const box = el('div', 'detail-box');

  const delta = m.interfaceDelta;
  if (delta && delta.suggestedVersion) {
    box.appendChild(suggestionBlock(m, delta));
  }

  if (prs.length) {
    box.appendChild(detailBlock(
      prs.length + (prs.length === 1 ? ' pull request merged since ' : ' pull requests merged since ') + m.latestTag,
      prs.map(pr => linkItem(pr.number, pr.title, pr.url, pr.author ? '@' + pr.author : ''))
    ));
  }

  if (issues.length) {
    box.appendChild(detailBlock(
      issues.length + (issues.length === 1 ? ' issue awaiting a release' : ' issues awaiting a release'),
      issues.map(issue => linkItem(issue.number, issue.title, issue.url, ''))
    ));
  }

  if (prs.length) {
    // No tag is prefilled. The suggestion above is evidence for a maintainer to
    // weigh, not a decision to hand to GitHub.
    const actions = el('div', 'detail-actions');
    const draft = el('a', 'button', 'Draft a release');
    draft.href = m.url + '/releases/new';
    draft.target = '_blank';
    draft.rel = 'noopener';
    actions.appendChild(draft);
    actions.appendChild(el('span', 'fine', 'Opens GitHub with the tag blank. Generate release notes there.'));
    box.appendChild(actions);
  }

  holder.appendChild(box);
  row.appendChild(holder);
  return row;
}

function buildRow(m, body) {
  const tr = el('tr');

  const nameCell = cell('Module', 'cell-module');
  const link = el('a', null, m.module);
  link.href = m.url;
  link.target = '_blank';
  link.rel = 'noopener';
  nameCell.appendChild(link);
  tr.appendChild(nameCell);

  const stateCell = cell('State');
  stateCell.appendChild(el('span', 'pill ' + m.state, STATE_LABEL[m.state] || m.state));
  tr.appendChild(stateCell);

  tr.appendChild(cell('Version', m.latestTag ? null : 'dim', m.latestTag || 'none'));
  tr.appendChild(cell('Published', m.latestPublished ? null : 'dim', shortDate(m.latestPublished)));
  tr.appendChild(cell('Unreleased commits', 'num' + (m.humanAhead ? '' : ' dim'), String(m.humanAhead ?? 0)));

  const days = m.oldestHumanDays;
  tr.appendChild(cell('Oldest, days',
    'num' + (days ? (days > AGED_DAYS ? ' aged' : '') : ' dim'),
    days === null || days === undefined ? '—' : String(days)));

  tr.appendChild(cell('Managed files', m.pinnedVersion ? null : 'dim', m.pinnedVersion || 'none'));

  const suggestCell = cell('Suggested');
  const delta = m.interfaceDelta;
  if (delta && delta.suggestedVersion) {
    suggestCell.appendChild(el('span', 'sugg', delta.suggestedVersion));
    suggestCell.appendChild(el('span', 'bump ' + delta.suggestedBump, delta.suggestedBump));
  } else {
    suggestCell.className = 'dim';
    suggestCell.textContent = '—';
  }
  tr.appendChild(suggestCell);

  const prs = m.unreleasedPrs || [];
  const issues = m.awaitingReleaseIssues || [];
  const hasDetail = prs.length > 0 || issues.length > 0;

  if (hasDetail) {
    tr.classList.add('expandable');
    tr.tabIndex = 0;
    tr.setAttribute('role', 'button');
    tr.setAttribute('aria-expanded', String(EXPANDED.has(m.repo)));
    nameCell.insertBefore(el('span', 'caret', '▸'), nameCell.firstChild);

    const toggle = () => {
      if (EXPANDED.has(m.repo)) { EXPANDED.delete(m.repo); } else { EXPANDED.add(m.repo); }
      render();
    };
    // The module name is a link out to GitHub, so clicking it must not also expand.
    tr.addEventListener('click', e => { if (!e.target.closest('a')) toggle(); });
    tr.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); }
    });
  }

  body.appendChild(tr);

  if (hasDetail && EXPANDED.has(m.repo)) {
    tr.classList.add('is-open');
    body.appendChild(detailRow(m, prs, issues));
  }
}

function render() {
  const term = document.getElementById('search').value.trim().toLowerCase();
  const matches = m => !term || m.module.toLowerCase().includes(term);

  // The page is about modules waiting on a release. Everything else stays reachable
  // but collapsed, so 150 rows that need no action do not bury the 38 that do.
  const waiting = MODULES.filter(m => m.state === 'unreleased-work' && matches(m)).sort(compare);
  const rest = MODULES.filter(m => m.state !== 'unreleased-work' && matches(m)).sort(compare);

  const body = document.getElementById('rows');
  body.textContent = '';
  waiting.forEach(m => buildRow(m, body));

  const restBody = document.getElementById('restRows');
  restBody.textContent = '';
  rest.forEach(m => buildRow(m, restBody));

  const counts = {};
  rest.forEach(m => { counts[m.state] = (counts[m.state] || 0) + 1; });
  const parts = [];
  if (counts['automation-only'] || counts['current']) {
    parts.push(((counts['automation-only'] || 0) + (counts['current'] || 0)) + ' with nothing to release');
  }
  if (counts['never-released']) parts.push(counts['never-released'] + ' with no version tag');

  document.getElementById('restCount').textContent = rest.length + ' other modules';
  document.getElementById('restNote').textContent = parts.length ? parts.join(', ') : '';
  document.getElementById('restPanel').hidden = rest.length === 0;

  document.getElementById('empty').hidden = waiting.length > 0;

  document.querySelectorAll('th[data-sort]').forEach(th => {
    th.classList.toggle('sorted', th.dataset.sort === sortKey);
    th.classList.toggle('asc', th.dataset.sort === sortKey && sortAsc);
  });
}

function wire() {
  document.getElementById('search').addEventListener('input', render);
  document.querySelectorAll('th[data-sort]').forEach(th => {
    th.addEventListener('click', () => {
      const key = th.dataset.sort;
      if (key === sortKey) { sortAsc = !sortAsc; } else { sortKey = key; sortAsc = true; }
      render();
    });
  });
}

wireTheme();

// History is optional. A repository publishing for the first time has no rows yet,
// and the page must still render everything else.
Promise.all([
  fetch('data/release-status.json').then(r => r.json()),
  fetch('data/history.json').then(r => (r.ok ? r.json() : [])).catch(() => [])
])
  .then(([doc, history]) => {
    MODULES = doc.modules || [];
    HISTORY = Array.isArray(history) ? history : [];
    document.getElementById('stamp').textContent = doc.generatedAt || 'unknown';
    document.getElementById('count').textContent = doc.repoCount ?? MODULES.length;
    renderCards();
    renderTrend();
    wire();
    render();
  })
  .catch(err => {
    document.getElementById('rows').innerHTML =
      '<tr><td colspan="8" class="dim">Could not load data/release-status.json — ' + err.message + '</td></tr>';
  });
