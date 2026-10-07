// Run with: node tools/test_wire_repair.cjs
const assert = require('node:assert/strict');
const W = require('./wire_repair_core.js');
let checked = 0;

for (let mask = 0; mask < 16; mask++) {
  let rotated = mask;
  for (let i = 0; i < 4; i++) rotated = W.rotateMask(rotated);
  assert.equal(rotated, mask, 'Four turns must preserve port geometry');
  assert.equal(W.rotateMask(W.rotateMask(mask), -1), mask, 'Reverse must invert a turn');
}

for (const board of W.boards) {
  assert.ok(board.cols >= 7 && board.rows >= 6, 'Every expanded layout has a larger grid');
  assert.equal(new Set(board.route.map(p=>p.join(','))).size,board.route.length);
  for (const [x,y] of board.route) {
    assert.ok(x>=0 && y>=0 && x<board.cols && y<board.rows, 'Authored route stays within the grid');
    assert.ok(!board.blanks.some(p=>p[0]===x && p[1]===y),'Blank plates cannot obstruct the route');
  }
  for (const [x,y] of board.locked) assert.ok(board.route.some(p=>p[0]===x && p[1]===y),'Fixed wires anchor the valid route');
  for (let seed = 1; seed <= 100; seed++) {
    const model = W.createBoard(board.id, seed);
    assert.equal(W.trace(model).solved, false, `${board.id}/${seed} must start unsolved`);
    assert.deepEqual(W.trace(model).path, [], 'Unsolved circuits have no completion animation route');
    const firstMask = model.cells.map(c => c.mask);
    const index = model.cells.findIndex(c => c.mask && !c.locked);
    assert.equal(W.turn(model, index), true);
    assert.equal(W.undo(model), true);
    assert.deepEqual(model.cells.map(c => c.mask), firstMask);
    assert.equal(model.turns, 0);
    const historyLength = model.history.length;
    for (const fixed of model.cells.filter(c=>c.locked)) {
      const fixedIndex = fixed.y * board.cols + fixed.x;
      assert.equal(fixed.mask,fixed.solution, 'Fixed wires begin in their authored orientation');
      assert.equal(W.turn(model,fixedIndex),false,'Fixed wires reject clockwise turns');
      assert.equal(W.turn(model,fixedIndex,-1),false,'Fixed wires reject reverse turns');
      assert.equal(fixed.mask,fixed.solution);
      assert.equal(model.history.length,historyLength,'A fixed-wire attempt must not affect undo');
    }
    assert.equal(model.turns,0);
    const hinted = W.hint(model);
    assert.ok(hinted && !hinted.locked,'Hints target a movable wire');
    for (const cell of model.cells) {
      const ports = W.directions.filter(d => cell.mask & d.bit);
      assert.ok(ports.length === 0 || ports.length === 2, 'Only blank and two-port modules');
      if (cell.solution === null) continue;
      let turns = 0;
      const index = cell.y * board.cols + cell.x;
      while (cell.mask !== cell.solution && turns < 4) {
        assert.equal(W.turn(model, index), true); turns++;
        if (W.trace(model).solved) break;
      }
      if (W.trace(model).solved) break;
    }
    const completed = W.trace(model);
    assert.equal(completed.solved, true, `${board.id}/${seed} must be solvable`);
    assert.equal(completed.path[0], board.startRow * board.cols);
    assert.equal(completed.path.at(-1), board.endRow * board.cols + board.cols - 1);
    assert.equal(new Set(completed.path).size, completed.path.length, 'Completion path cannot loop');
    for (let step = 1; step < completed.path.length; step++) {
      const previous = model.cells[completed.path[step-1]], current = model.cells[completed.path[step]];
      const direction = W.directions.find(d => previous.x + d.dx === current.x && previous.y + d.dy === current.y);
      assert.ok(direction && (previous.mask & direction.bit) && (current.mask & direction.opposite), 'Animation must stay on reciprocal wire ports');
    }
    assert.equal(W.turn(model, index), false, 'Completed boards must lock');
    assert.equal(W.undo(model), false, 'Completion must remain stable');
    assert.equal(W.hint(model), null);
    W.reset(model);
    assert.deepEqual(model.cells.map(c => c.mask), firstMask);
    assert.equal(W.trace(model).solved, false);
    model.cells.filter(c=>c.locked).forEach(c=>assert.equal(c.mask,c.solution,'Reset preserves fixed wires'));
    checked++;
  }
}

// Merely touching the output is insufficient without matching reciprocal ports.
const pair = { definition: {cols:2,rows:1,startRow:0,endRow:0}, cells:[{x:0,y:0,mask:10},{x:1,y:0,mask:3}] };
assert.equal(W.trace(pair).solved, false);
assert.deepEqual([...W.trace(pair).powered], [0]);
pair.cells[1].mask = 10;
assert.equal(W.trace(pair).solved, true);
pair.cells[0].mask = 5;
assert.equal(W.trace(pair).solved, false, 'Output alignment alone cannot complete a circuit');

// A disconnected closed loop does not conduct and cannot trap traversal.
const loop = { definition: {cols:2,rows:2,startRow:0,endRow:1}, cells:[
  {x:0,y:0,mask:6}, {x:1,y:0,mask:12}, {x:0,y:1,mask:3}, {x:1,y:1,mask:9}
] };
assert.equal(W.trace(loop).powered.size, 0);
assert.equal(W.trace(loop).solved, false);
// A fixed section carries current exactly like a movable two-port section.
pair.cells[0].mask = 10; pair.cells[1].mask = 10; pair.cells[1].locked = true;
assert.equal(W.trace(pair).solved,true,'Fixed wire sections conduct power');
const alternate = { definition: {cols:3,rows:2,startRow:0,endRow:0}, cells:[12,5,6,3,10,9].map((mask,i)=>({x:i%3,y:Math.floor(i/3),mask})) };
assert.deepEqual(W.trace(alternate).path, [0,3,4,5,2], 'Pulse must follow the actual lower detour, not an authored top-row route');
alternate.cells[2].mask = 5;
assert.deepEqual(W.trace(alternate).path, [], 'Breaking the route clears its animation path');
console.log(`PASS: ${checked} expanded-board shuffles, fixed wires, rotations, completion, actual power-flow routes, alternate paths, and disconnected loops.`);
