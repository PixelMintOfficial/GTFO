// Browser companion to the native panel. Both read the same authored circuit catalog.
const response = await fetch('../data/repair_circuits.json');
if (!response.ok) throw new Error('Circuit data unavailable');
window.RepairCircuitData = await response.json();
await import('./wire_repair_core.js');

const W = window.WireRepair;
const $ = id => document.getElementById(id);
const machine = new URLSearchParams(location.search).get('machine') === 'oxygen' ? 'oxygen' : 'power';
const sequence = W.machines[machine];
const tiles = [];
let model, index = 0, attempt = 0, remaining = 30, active = true, solved = false;
let noticeUntil = 0, previous = performance.now();
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const flowSvg = $('power-flow');
const flowPaths = [...flowSvg.querySelectorAll('path')];
const flowHead = flowSvg.querySelector('circle');
let flow = null, flowFrame = 0;
flowSvg.setAttribute('hidden', '');

function wireSvg(cell) {
  const base = `<polygon class="housing" points="22,3 78,3 97,22 97,78 78,97 22,97 3,78 3,22"/>
    <polygon class="inset" points="24,8 76,8 92,24 92,76 76,92 24,92 8,76 8,24"/>
    <path class="bevel" d="M22 3h56l19 19 M3 22l19-19"/>`;
  if (!cell.mask) return `<svg viewBox="0 0 100 100" aria-hidden="true">${base}</svg>`;
  const point = {1:'50 0', 2:'100 50', 4:'50 100', 8:'0 50'};
  const ports = W.directions.filter(d => cell.mask & d.bit);
  const path = `M ${point[ports[0].bit]} L 50 50 L ${point[ports[1].bit]}`;
  const bolts = cell.locked ? [ [24,24], [76,24], [24,76], [76,76] ].map(([x,y]) =>
    `<rect class="mount-tab" x="${x-7}" y="${y-7}" width="14" height="14" rx="2"/>
     <circle class="bolt-ring" cx="${x}" cy="${y}" r="5.5"/>
     <circle class="bolt" cx="${x}" cy="${y}" r="3.8"/>
     <path class="bolt-slot" d="M${x-2.5} ${y}h5"/>`).join('') : '';
  const etching = [ [1,1], [-1,1], [1,-1], [-1,-1] ].map(([x,y]) =>
    `<g transform="translate(50 50) scale(${x} ${y})">
      <path class="etch" d="M-37-10v-16l11-11h16 M-29-10v-12l7-7h12"/>
      <circle class="via-ring" cx="-10" cy="-37" r="2.2"/>
      <circle class="via" cx="-10" cy="-37" r=".9"/>
      <rect class="component" x="-23" y="-40" width="7" height="3"/>
    </g>`).join('');
  return `<svg viewBox="0 0 100 100" aria-hidden="true">${base}
    ${etching}<circle class="hub" cx="50" cy="50" r="10"/>
    <g class="rotor"><path class="wire-under" d="${path}"/><path class="wire" d="${path}"/>
    <circle class="contact-ring" cx="50" cy="50" r="5"/>
    <circle class="contact" cx="50" cy="50" r="2.5"/>
    ${ports.map(d => {
      const at = {1:[50,9], 2:[91,50], 4:[50,91], 8:[9,50]}[d.bit];
      return `<circle class="contact" cx="${at[0]}" cy="${at[1]}" r="2.2"/>`;
    }).join('')}</g>${bolts}</svg>`;
}

function loadBoard() {
  clearFlow();
  const restoreFocus = $('grid').contains(document.activeElement);
  model = W.createBoard(sequence[index], 17 + attempt * 7919);
  solved = false;
  remaining = 30;
  $('grid').replaceChildren();
  tiles.length = 0;
  $('board').style.setProperty('--cols', model.definition.cols);
  $('board').style.setProperty('--rows', model.definition.rows);
  $('supply').style.setProperty('--row', model.definition.startRow);
  $('output').style.setProperty('--row', model.definition.endRow);
  model.cells.forEach((cell, i) => {
    const tile = document.createElement(cell.mask && !cell.locked ? 'button' : 'div');
    tile.className = 'tile' + (!cell.mask ? ' blank' : '') + (cell.locked ? ' locked' : '');
    tile.dataset.index = i;
    tile.dataset.baseTurns = cell.turns;
    tile.innerHTML = wireSvg(cell);
    if (tile.tagName === 'BUTTON') {
      tile.type = 'button';
      tile.addEventListener('click', () => turn(i));
      tile.addEventListener('contextmenu', event => { event.preventDefault(); turn(i, -1); });
      tile.addEventListener('keydown', event => navigate(event, i));
    } else tile.setAttribute('role', 'img');
    $('grid').append(tile);
    tiles.push(tile);
  });
  render();
  if (restoreFocus) tiles.find(tile => tile.tagName === 'BUTTON')?.focus();
}

function render() {
  const traced = W.trace(model);
  const completedNow = traced.solved && !solved;
  solved = traced.solved;
  tiles.forEach((tile, i) => {
    const cell = model.cells[i], powered = traced.powered.has(i);
    const coordinate = String.fromCharCode(65 + cell.x) + (cell.y + 1);
    tile.classList.toggle('powered', powered);
    tile.dataset.mask = cell.mask;
    const ports = W.directions.filter(d => cell.mask & d.bit).map(d => d.name).join(' and ');
    const behavior = cell.locked ? 'Fixed in place.' : solved ? 'Circuit connected.' : 'Rotate clockwise.';
    tile.setAttribute('aria-label', !cell.mask ? `Fixed plate ${coordinate}` :
      `${cell.locked ? 'Bolted wire' : 'Wire'} ${coordinate}, ${ports}, ${powered ? 'powered' : 'unpowered'}. ${behavior}`);
    if (tile.tagName === 'BUTTON') tile.disabled = solved;
    const rotor = tile.querySelector('.rotor');
    if (rotor) rotor.style.transform = `rotate(${(cell.turns - Number(tile.dataset.baseTurns)) * 90}deg)`;
  });
  if (completedNow) startFlow(traced.path);
  else if (!solved) receivePower(false);
  $('status').classList.toggle('solved', solved);
  $('return').hidden = !solved;
  if (solved) {
    $('notice').textContent = 'Circuit connected';
    $('return').focus();
  }
}

function receivePower(received) {
  $('output').classList.toggle('live', received);
  $('output').setAttribute('aria-label', `Receiving terminal, ${received ? 'powered' : solved ? 'charging' : 'unpowered'}`);
}

function clearFlow() {
  cancelAnimationFrame(flowFrame);
  flowFrame = 0;
  flow = null;
  flowSvg.setAttribute('hidden', '');
  $('supply').classList.remove('emitting');
  const rim = $('output').querySelector('.arrival-rim');
  rim.style.opacity = 0;
  rim.style.transform = '';
}

function startFlow(route) {
  if (reducedMotion.matches) { receivePower(true); return; }
  flow = {route, elapsed:0, last:performance.now(), received:false};
  updateFlowGeometry();
  flowSvg.removeAttribute('hidden');
  flowSvg.style.opacity = 0;
  $('supply').classList.add('emitting');
  receivePower(false);
  flowFrame = requestAnimationFrame(animateFlow);
}

function updateFlowGeometry() {
  if (!flow) return;
  const bounds = $('board').getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;
  const center = (element, x = .5) => {
    const box = element.getBoundingClientRect();
    return [box.left - bounds.left + box.width * x, box.top - bounds.top + box.height / 2];
  };
  const points = [center($('supply'), .76), ...flow.route.map(i => center(tiles[i])), center($('output'))];
  const d = points.map(([x,y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' ');
  flowSvg.setAttribute('viewBox', `0 0 ${bounds.width} ${bounds.height}`);
  flowPaths.forEach(path => path.setAttribute('d', d));
  flow.length = flowPaths[0].getTotalLength();
  flow.packet = tiles[0].getBoundingClientRect().width * 1.8;
  flowPaths.forEach(path => path.style.strokeDasharray = `${flow.packet} ${flow.length + flow.packet}`);
}

function animateFlow(now) {
  if (!flow) return;
  if (active && !document.hidden) flow.elapsed += Math.max(0, (now - flow.last) / 1000);
  flow.last = now;
  const progress = Math.max(0, Math.min(1, (flow.elapsed - .15) / 1.6));
  const arrival = Math.max(0, Math.min(1, (flow.elapsed - 1.75) / .45));
  const head = progress * flow.length;
  flowSvg.style.opacity = flow.elapsed >= .15 ? 1 - arrival : 0;
  flowPaths.forEach(path => path.style.strokeDashoffset = flow.packet - head);
  const point = flowPaths[0].getPointAtLength(head);
  flowHead.setAttribute('cx', point.x);
  flowHead.setAttribute('cy', point.y);
  if (progress === 1 && !flow.received) { flow.received = true; receivePower(true); }
  const rim = $('output').querySelector('.arrival-rim');
  rim.style.opacity = flow.received ? 1 - arrival : 0;
  rim.style.transform = `scale(${1 + arrival * .1})`;
  $('supply').style.setProperty('--charge', .75 + .25 * Math.sin(Math.min(flow.elapsed / .15, 1) * Math.PI));
  if (arrival >= 1) { clearFlow(); return; }
  flowFrame = requestAnimationFrame(animateFlow);
}

new ResizeObserver(updateFlowGeometry).observe($('board'));
reducedMotion.addEventListener('change', () => {
  if (reducedMotion.matches && flow) { receivePower(true); clearFlow(); }
});

function turn(i, direction = 1) {
  if (active && W.turn(model, i, direction)) render();
}

function navigate(event, i) {
  if (event.key.toLowerCase() === 'q') { event.preventDefault(); turn(i, -1); return; }
  const step = {ArrowLeft:[-1,0], ArrowRight:[1,0], ArrowUp:[0,-1], ArrowDown:[0,1]}[event.key];
  if (!step) return;
  event.preventDefault();
  let {x, y} = model.cells[i];
  const d = model.definition;
  for (let tries = 0; tries < Math.max(d.cols, d.rows); tries++) {
    x = (x + step[0] + d.cols) % d.cols;
    y = (y + step[1] + d.rows) % d.rows;
    const at = y * d.cols + x;
    if (model.cells[at].mask && !model.cells[at].locked) {
      tiles[at].focus();
      tiles[at].scrollIntoView({block:'nearest', inline:'nearest'});
      break;
    }
  }
}

function close() {
  active = false;
  cancelAnimationFrame(flowFrame);
  flowFrame = 0;
  $('cabinet').hidden = true;
  $('closed').hidden = false;
  $('closed-copy').textContent = solved ? 'Circuit connected. Machine repair: 50%.' : 'Circuit repair paused.';
  $('resume').textContent = solved ? 'View circuit' : 'Resume';
  $('resume').focus();
}

function resume() {
  active = true;
  previous = performance.now();
  $('closed').hidden = true;
  $('cabinet').hidden = false;
  if (flow) {
    flow.last = performance.now();
    updateFlowGeometry();
    flowFrame = requestAnimationFrame(animateFlow);
  }
  (tiles.find(tile => tile.tagName === 'BUTTON' && !tile.disabled) || $('close')).focus();
}

function tick() {
  const now = performance.now(), delta = (now - previous) / 1000;
  previous = now;
  if (!active || document.hidden || solved) return;
  remaining = Math.max(0, remaining - delta);
  if (remaining <= 0) {
    index = (index + 1) % 5;
    attempt++;
    loadBoard();
    $('notice').textContent = 'Circuit changed';
    noticeUntil = now + 1300;
  }
  if (noticeUntil && now > noticeUntil) { $('notice').textContent = ''; noticeUntil = 0; }
  $('timer').textContent = Math.ceil(remaining) + ' s';
  $('timer').classList.toggle('urgent', remaining <= 5);
  $('timer-fill').style.transform = `scaleX(${remaining / 30})`;
}

$('close').onclick = close;
$('return').onclick = close;
$('resume').onclick = resume;
document.addEventListener('keydown', event => { if (event.key === 'Escape' && active) close(); });
document.addEventListener('visibilitychange', () => {
  previous = performance.now();
  if (flow) flow.last = previous;
});
loadBoard();
setInterval(tick, 50);
