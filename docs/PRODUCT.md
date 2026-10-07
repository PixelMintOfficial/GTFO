# Circuit repair product context

## Register

product

## Users and purpose

Players repairing the red-planet outpost in GTFO. A short spatial puzzle reconnects a
machine's wiring by rotating its preplaced straight and elbow modules. Power and O2
machines each need one successful circuit for their wiring task.

## Approved direction

Cozy habitat maintenance, with a detailed blue-green circuit board inspired by the supplied
Spider-Man reference. Connected wires glow neon green. Octagonal housings have layered
rims, solder contacts and etched traces; four bolt mounts identify fixed wires. The owner
requested octagons after rejecting the hexagonal draft.

## Interaction principles

- Rotate modules; their positions and terminal positions stay fixed.
- Trace mutually facing ports from the supply after every turn.
- A supply-to-output route is sufficient; unrelated wires can stay disconnected.
- Fixed wires conduct normally and cannot turn.
- Show only the title, one instruction, countdown, close action and brief state feedback.
- Replace an unsolved circuit after 30 active seconds, cycling five layouts per machine.
- Closing pauses the attempt. Scene changes preserve session progress.
- Wiring earns half of the total repair; crack repair and fixed machine art come later.
- A one-time completion pulse demonstrates power travelling from the capacitor bank along
  the player's route into the receiving relay; its status LEDs activate on arrival.

## Scope boundaries

No voltage arithmetic, module inventory, placement/removal, circuit browsing controls,
visible grid statistics, puzzle categories, or extra narrative description. Native keyboard,
pointer and gamepad input are implemented. The browser companion has keyboard/pointer
input, accessible wire labels, visible focus, reduced-motion support and 44 px targets.
Saving to disk, crack repair, restored machine art, audio and machine simulation effects
remain outside this implementation.
