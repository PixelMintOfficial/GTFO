/* Wire repair design prototype. No engine dependencies; ports are N/E/S/W bits. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('../data/repair_circuits.json'));
  else root.WireRepair = factory(root.RepairCircuitData);
})(typeof globalThis !== 'undefined' ? globalThis : this, function (catalog) {
  'use strict';
  const directions = [
    { bit: 1, opposite: 4, dx: 0, dy: -1, name: 'north' },
    { bit: 2, opposite: 8, dx: 1, dy: 0, name: 'east' },
    { bit: 4, opposite: 1, dx: 0, dy: 1, name: 'south' },
    { bit: 8, opposite: 2, dx: -1, dy: 0, name: 'west' }
  ];
  // Waypoints author a continuous two-port route; locked sections are on that
  // route and remain in their solved orientation through every shuffle.
  const layouts = catalog.circuits;
  function expandRoute(waypoints) {
    const route = [waypoints[0].slice()];
    for (let i = 1; i < waypoints.length; i++) {
      const [x,y] = waypoints[i], previous = route[route.length - 1];
      if (previous[0] !== x && previous[1] !== y) throw new Error('Route waypoints must form right-angle paths.');
      const dx = Math.sign(x - previous[0]), dy = Math.sign(y - previous[1]);
      let at = previous.slice();
      while (at[0] !== x || at[1] !== y) { at = [at[0] + dx, at[1] + dy]; route.push(at); }
    }
    if (new Set(route.map(p => p.join(','))).size !== route.length) throw new Error('Two-port routes cannot cross themselves.');
    return route;
  }
  const boards = layouts.map((layout, index) => {
    return { ...layout, route:expandRoute(layout.waypoints) };
  });
  function rotateMask(mask, direction = 1) {
    return direction > 0 ? ((mask << 1) & 15) | (mask >> 3) : (mask >> 1) | ((mask & 1) << 3);
  }
  function portBetween(a, b) {
    const d = directions.find(d => d.dx === b[0] - a[0] && d.dy === b[1] - a[1]);
    if (!d) throw new Error('Route cells must be orthogonally adjacent.');
    return d.bit;
  }
  function createBoard(id = boards[0].id, seed = 17) {
    const definition = boards.find(board => board.id === id);
    if (!definition) throw new Error('Unknown board: ' + id);
    let randomState = (seed >>> 0) || 1;
    function random() {
      randomState = (Math.imul(1664525, randomState) + 1013904223) >>> 0;
      return randomState / 4294967296;
    }
    const cells = Array.from({ length: definition.cols * definition.rows }, (_, index) => {
      const x = index % definition.cols, y = Math.floor(index / definition.cols);
      const blocked = definition.blanks.some(p => p[0] === x && p[1] === y);
      const mask = blocked ? 0 : (random() > .45 ? 3 : 5);
      const locked = definition.locked.some(p => p[0] === x && p[1] === y);
      return { x, y, mask, locked, turns: Math.floor(random() * 4), solution: null, routeIndex: -1 };
    });
    definition.route.forEach((p, i) => {
      const previous = i === 0 ? [-1, definition.startRow] : definition.route[i - 1];
      const next = i === definition.route.length - 1 ? [definition.cols, definition.endRow] : definition.route[i + 1];
      const cell = cells[p[1] * definition.cols + p[0]];
      cell.mask = portBetween(p, previous) | portBetween(p, next);
      cell.solution = cell.mask;
      cell.routeIndex = i;
      // A short live section teaches the supply direction before the first break.
      cell.turns = cell.locked || i < 2 ? 0 : 1 + Math.floor(random() * 3);
      for (let turn = 0; turn < cell.turns; turn++) cell.mask = rotateMask(cell.mask);
    });
    const model = { definition, cells, history: [], turns: 0, initial: cells.map(c => ({ mask: c.mask, turns: c.turns })) };
    if (trace(model).solved) {
      // Every authored supply cell is movable. Disconnect its supply-facing
      // port, guaranteeing an unsolved start even if a shortcut was aligned.
      const cell = cells[definition.startRow * definition.cols];
      if (cell.locked) throw new Error('The supply wire must be movable.');
      while (cell.mask & 8) { cell.mask = rotateMask(cell.mask); cell.turns++; }
      model.initial = cells.map(c => ({ mask: c.mask, turns: c.turns }));
    }
    return model;
  }
  function trace(model) {
    const { definition: d, cells } = model;
    const powered = new Set(), queue = [], order = [], parents = new Map();
    const first = d.startRow * d.cols;
    if (cells[first].mask & 8) { powered.add(first); queue.push(first); }
    for (let cursor = 0; cursor < queue.length; cursor++) {
      const index = queue[cursor], cell = cells[index];
      order.push(index);
      directions.forEach(dir => {
        if (!(cell.mask & dir.bit)) return;
        const x = cell.x + dir.dx, y = cell.y + dir.dy;
        if (x < 0 || x >= d.cols || y < 0 || y >= d.rows) return;
        const neighbor = y * d.cols + x;
        if (!powered.has(neighbor) && (cells[neighbor].mask & dir.opposite)) {
          parents.set(neighbor, index);
          powered.add(neighbor); queue.push(neighbor);
        }
      });
    }
    const last = d.endRow * d.cols + d.cols - 1;
    const solved = powered.has(last) && !!(cells[last].mask & 2);
    const path = [];
    if (solved) {
      for (let at = last; at !== undefined; at = parents.get(at)) path.push(at);
      path.reverse();
    }
    return { powered, order, path, solved };
  }
  function turn(model, index, direction = 1) {
    const cell = model.cells[index];
    if (!cell || cell.mask === 0 || cell.locked || trace(model).solved) return false;
    model.history.push({ index, mask: cell.mask, turns: cell.turns });
    cell.mask = rotateMask(cell.mask, direction);
    cell.turns += direction > 0 ? 1 : -1;
    model.turns++;
    return true;
  }
  function undo(model) {
    if (trace(model).solved) return false;
    const previous = model.history.pop();
    if (!previous) return false;
    Object.assign(model.cells[previous.index], { mask: previous.mask, turns: previous.turns });
    model.turns--;
    return true;
  }
  function reset(model) {
    model.cells.forEach((cell, index) => Object.assign(cell, model.initial[index]));
    model.history.length = 0; model.turns = 0;
  }
  function hint(model) {
    if (trace(model).solved) return null;
    return model.cells.filter(c => c.solution !== null && !c.locked).sort((a,b) => a.routeIndex - b.routeIndex)
      .find(c => c.mask !== c.solution) || null;
  }
  return { machines:catalog.machines, boards, directions, createBoard, rotateMask, trace, turn, undo, reset, hint };
});
