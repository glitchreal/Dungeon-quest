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

## Confirmed passive-beam ownership stall

A later read-only MCP snapshot captured Midgardian Champion at 41.18 studs,
`BEAM_AVOIDANCE`, `mechanic-hold`, and the status "Holding a local lane between
passive beams". The mechanic owner cleared the path before normal pursuit could
run. This was a separate cause from generic elevated navigation. A later damage
record showed a 388,728,800 HP hit during "Escaping committed slam and beam
geometry"; that record does not identify which visual attack the user calls a
tornado.

Passive beam control now releases pursuit when the current position and next
approach segment are clear of those beams. When a beam blocks the approach,
grounded local forward/lateral candidates allow progress toward attack range;
an out-of-range stationary candidate is excluded. A player currently safe never
trades that safety for range. In-range holding still permits attacks.

Leased mechanic movement rechecks the crossing as well as its destination,
rejecting new hazards even when the old endpoint remains safe. Unsafe mechanic
holds request the existing safety controller before executing. The focused
movement check covers clear-lane release, safe movement around a blocking beam,
and interruption of an unsafe leased crossing. Live client controls were not
replaced, and no repeated dungeon tests were run.

## Slam shape, escape distance, and attack suppression

Another read-only inspection confirmed the current Geyser forward-burst profile
was loaded and cast counters increased. Its most recent damage record was a
747,451,392 HP hit during "Escaping committed slam and beam geometry".
The replicated `enemyProjectiles.firstBossJumpSlam` template has a cylindrical
4×67×67 warning marker rotated -90 degrees and a spherical 67×67×67 hitbox with
zero rotation. The scanner used the hitbox frame but inherited Cylinder from
the marker. Collision shape now comes exclusively from the actual geometry part;
spheres have orientation-independent clearance.

The old escape candidates stopped at 21 studs, which cannot exit this slam from
near its center. New candidates lie beyond the actual radial boundary at the
player's height, with wall/hazard checks retained. The controller starts leaving
an overlapping visible slam without consuming a bait delay. These are walking
goals; blink distance and rolling budgets are unchanged. Destination forecasting
uses actual walking travel time rather than capping it at 1.5 seconds.

Slam bait/escape and projectile escape now permit independent validated casting
after their movement decision. Emergency movement can also cast after facing;
damageability, spell geometry, actual facing and cooldown checks remain active.
The existing FarmAim label now reports cast status, including cooldown, busy
casting, reach rejection, alignment, or a cast request. Requests still count as
confirmed casts only when the game exposes their cooldown transition.

The offline movement check covers spherical symmetry, radius at player height,
immediate escape, destinations outside the 67-stud slam, and attack permission
during slam/projectile movement. This confirms policy behavior, not live survival
or statue-phase damage after the patch. No runtime replacement or dungeon loop
was performed.
