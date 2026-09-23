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
