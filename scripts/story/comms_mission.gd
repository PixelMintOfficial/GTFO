class_name CommsMission
extends RefCounted
## One SOS per session. The signal travels on the game clock, even after the player
## leaves the dish. The repaired, powered receiver logs the reply once it can hear it.

enum Stage { READY, OUTBOUND, INBOUND, RECEIVER_OFFLINE, RECEIVED }

## Scenario light time in each direction, within NASA's Earth–Mars range.
const LEG_MINUTES := 20
const LEG_HOURS := LEG_MINUTES / 60.0

var _sent_at := -1.0
var reply_received := false


func transmit(clock_hours: float, link_online: bool) -> bool:
	if has_transmitted() or not link_online:
		return false
	_sent_at = clock_hours
	return true


func has_transmitted() -> bool:
	return _sent_at >= 0.0


func advance(clock_hours: float, link_online: Callable) -> void:
	if stage(clock_hours) == Stage.RECEIVER_OFFLINE and link_online.call():
		reply_received = true


func stage(clock_hours: float) -> Stage:
	if reply_received:
		return Stage.RECEIVED
	if not has_transmitted():
		return Stage.READY
	if clock_hours < _sent_at + LEG_HOURS:
		return Stage.OUTBOUND
	if clock_hours < _sent_at + 2.0 * LEG_HOURS:
		return Stage.INBOUND
	return Stage.RECEIVER_OFFLINE


func minutes_left(clock_hours: float, leg: Stage) -> int:
	var arrival := _sent_at + LEG_HOURS * (1.0 if leg == Stage.OUTBOUND else 2.0)
	return clampi(ceili((arrival - clock_hours) * 60.0), 0, LEG_MINUTES)
