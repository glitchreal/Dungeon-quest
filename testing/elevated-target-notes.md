# Elevated attack positions

The old target validator accepted living elevated enemies; no Jump Slam activation
gate existed. Attack flow nevertheless coupled combat to ground navigation:
blocked root-to-root sight entered climb/door recovery before normal casting,
and combat floor probes originated at the enemy's elevation. Horizontal combat
spacing also failed to reserve range for the vertical separation. These are
source findings; the reported statue encounter has not been reproduced live.

AttackPolicy now checks living health and explicit boolean damageability or
invulnerability attributes/BoolValues on the model and Humanoid. Missing flags,
anchoring, generic Active values and elevation do not imply immunity. Spell
preparation checks actual 3D range and unobstructed sight even with Smart Farm off.
Positive ability range metadata remains authoritative; unknown ranges use the
existing configured fallback. No claim is made about hidden server-only immunity.

After Northern mechanics and immediate safety have priority, normal combat tries
eligible abilities without waiting for path completion. Elevated enemies can be
engaged from the current floor or a bounded set of nearby reachable firing points.
Floor probes start at player height, walking and hazard checks remain mandatory,
and new firing-point searches are cached for 0.5 seconds. Normal ground combat
spacing accounts for height within 3D range. Existing Protector flank behavior
and Northern mechanic solvers are preserved.

Verification: `lua testing/attack-policy.lua`, `lua build.lua`, and source/bundle
Luau compilation. No repeated dungeon tests; live damage and platform geometry
remain unverified.

## Follow-up: approach and movement stalls

The first version accepted only firing positions already within range, and held
at any in-range position. It now scores progressive ground steps outside range
and closes toward configured combat spacing. If direct movement is blocked, it
can route to a grounded arena-side firing point. Its progress objective remains
the enemy's ground location across short-step replacements. Room travel still
uses the room graph. Walking checks now reject vertically unreachable endpoints
instead of accepting their XZ projection.

Navigation joins only a nearby reachable prefix of a computed path and cannot
skip an intervening jump. Arrival observation no longer creates and cancels a
room edge every local combat tick. Stuck recovery uses the hazard/enemy/visited
cost checks of normal fallback steering. Route hazard checks inspect the next
12 studs of the actual waypoint/fallback route rather than a straight line
through distant rooms. A short dodge walk out of an existing overlap is allowed
when exposure decreases throughout; entry into a separate hazard is rejected.
Existing tactical teleport limits are unchanged.

Read-only MCP inspection found the client already approaching Bob via room4,
not at the reported first-boss platform. A second read encountered a missing
character root, so the first-boss stall was not reproduced. These fixes address
source defects; they are not a claim that live dungeon behavior is now verified.
Focused checks also include `lua testing/movement-policy.lua` and the existing
adaptive-memory checks. No gameplay campaign or runtime injection was performed.
