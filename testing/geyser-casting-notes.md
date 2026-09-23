# Geyser cast eligibility

Read-only client inspection found Geyser equipped in both slots. Neither tool
exposed cast range or explosion radius; their child `name` value was `Fireball`,
while the actual Tool.Name was `Geyser`. The former policy consequently used the
26-stud fallback and a direct root-to-root visibility check. Its splash radius
only affected clustering, not whether the spell could reach an elevated target.

`StarterGui.abilityLocal.abilityLocal2`, lines 1344–1357 in the inspected client,
places Geyser at the caster's CFrame plus LookVector times 40, then expands the
ring to 92 by 2 by 92. The accessible description says it damages nearby enemies.
No server damage radius or vertical hitbox was available.

FarmPlanner now identifies Geyser by the actual tool name and supplies a forward
burst profile. AttackPolicy uses the observed 40-stud placement and a 46-stud
spherical envelope as a cast-attempt heuristic, with explicit radius metadata
taking precedence. The visual ring is not treated as a verified server hitbox.
It checks the target's full 3D displacement from the burst center, not only
distance from the player. A blocked direct ray to the enemy root does not reject
this directly spawned effect. Before activation the actual horizontal facing
must place the burst over the target. Health and invulnerability gates remain.

The same eligibility is used during normal casting, allowed mechanic casting,
and elevated firing-position planning, including when Smart Farm is disabled.
Other spells keep their own range fallback and visibility checks; the large
Geyser envelope does not expand an unknown spell's range. No abilities were fired
through MCP and no dungeon test loop was run.

`lua testing/attack-policy.lua` covers elevated overlap, vertical/horizontal
exclusion, wrong facing, explicit radius override, and direct-spell isolation.
Build and compile the source and generated bundles normally. Live server damage
at the boundary of this client-derived envelope remains unverified.
