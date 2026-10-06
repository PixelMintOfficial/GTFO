extends Node
## What carries over between the overworld and the inside of the base (autoload: GameState).

## The crash scene has been seen (or skipped): it only plays once.
var intro_done := false
## Where the astronaut should appear in the next scene: "" (its default spawn), "interior"
## (coming in through the airlock), "door" (stepping back out of the airlock door_id).
var arrive := ""
var door_id := -1
## Whether the multitool was out, so it stays out across the airlock.
var tool_out := false
