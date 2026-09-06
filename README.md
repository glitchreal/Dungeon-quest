# Dungeon Quest Obsidian

One loader selects the Obsidian script for the current Dungeon Quest Reborn place:

```lua
getgenv().autoexecute = true
getgenv().autoloadconfig = true

loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/Dungeon-quest/main/main.luau"))()
```

`autoexecute` reruns the loader after teleports. `autoloadconfig` restores your
saved settings when loading. Set either to `false` to disable that behavior.
These two options live above the loadstring, not in the UI. The same snippet is
in `launch.luau`.

All toggles, sliders, inputs, selections, and the menu key save automatically
after changes, with a final save on unload or teleport. There is no config panel
or manual save button. Settings are stored in `DungeonQuestObsidian-config.json`
in the executor's workspace, including any configured webhook URL. Saving and
restoring require the executor's `writefile` and `readfile` APIs.

| Place | Place ID | Script |
| --- | --- | --- |
| Main lobby | `77649408247578` | `dist/lobby.luau` |
| Level 100+ lobby | `115445507767090` | `dist/lobby.luau` |
| Dungeon, raid, wave defense | `85776757589518` | `dist/dungeon.luau` |

The lobby script opens the Lobby tab and handles queue creation, starting runs,
gear, stats, and player settings. It does not load the combat controller or scan
for enemies. Dungeon settings remain available to configure before entering a run.

The dungeon script opens the Dungeon tab and loads combat, enemy-facing,
bounded teleport dodges, replay, and run tracking. Both use the same Obsidian UI.
Unsupported places exit with a message instead of loading the wrong script.

With `autoexecute = true`, settings and session totals are carried forward and the **main loader
runs again**, selecting the destination's script. This requires the executor's
`queue_on_teleport` API or supported alias. Without it, rerun the same loader after
teleporting. Right Shift toggles the menu.

## Features

- Player: optional speed/jump overrides, cosmetic name/level displays, eligible
  warrior/mage gear selection, and skill-point allocation.
- Dungeon: position/distance controls, abilities, optional hover, auto dodge,
  replay, join allowlist, and session statistics.
- Lobby: live difficulty requirements, automatic creation/start, private lobbies,
  hardcore, and wave defense.
- Farm Visuals: target line, waypoints, FPS cap, rendering/effect switches, and
  reversible lighting/shadow reductions.
- Raids: owned-key tier selection, creation/start, replay, and next-tier eligibility.
- Webhooks: selected run fields, drop images, and manual test/log sends.
- Settings: unload, menu key, and teleport-continuation status. Config saving is automatic.

Eligibility uses the real game level and owned keys, including higher-level
content. Cosmetic spoofing does not change eligibility. Teleport dodges are capped
at 3 studs, one second apart, and two dodges/six studs per rolling three seconds.
Those same shared limits also apply to emergency dodges from incoming regular
enemies; a visible attack marker is no longer required for close melee danger.
Retreat stays active until predicted separation clears an additional five-stud
margin, and escape steps are renewed before the character reaches their endpoint.

Dodges use announced boss telegraphs and observed active attack geometry. Escape
goals account for nearby enemies in every direction, and movement checks prevent
re-entering an active hitbox after a teleport. When a short teleport cannot clear
a large attack, the controller continues walking outward while attacking when
the target remains in range and visible. Static safe-zone/spawn markers are
excluded; no movement-speed increase is required.
Approach steps also check enemies' predicted positions half a second ahead.
This lets the controller brake or retreat before a closing enemy reaches it,
including enemies arriving from behind and larger enemy bodies.
Target selection refreshes every 0.15 seconds, preferring the closest nearby
enemy in clear sight over one behind a wall. Switching to a different area
invalidates the old route; switches within a close group preserve smooth walking.

Abilities use the equipped tools' real cooldowns and the game's normal
`localEvent` / `abilityUsed` activation path. The scheduler skips unavailable
slots, respects `busyCasting`, and avoids casting while you type. Cast totals
advance when the cooldown activates, rather than on attempted key presses.
The Combat Status group shows equipped ability cooldowns, target health, active
hazards, path calculations, and the most recent damage event.

Short clear routes use direct walking after body-width and ground-support checks.
Escape and recovery steps check the whole route for gaps, not just the landing
point. Enemy avoidance checks the full predicted crossing path for each nearby
enemy, so moving away from one cannot mask entering another's danger radius.
Adaptive Safety Spacing adds three studs briefly after a hit and up to eight
studs at low health; the larger buffer applies, rather than stacking both. It is
enabled by default and can be disabled to keep exactly the configured spacing.
Dynamic distance reads the currently equipped weapon, including mid-run changes.
Recognized ranged ability descriptions override a physical weapon's melee
distance: physical scaling does not imply a close-range spell. Adaptive spacing
also adds up to eight studs for faster pursuers and nearby crowd pressure.
Faster pursuers trigger melee-dodge consideration earlier, under the same limits.

Smart Farming is enabled by default and profiles equipped moves from tool
attributes, value fields, ability types, and inventory descriptions. It handles
heals, shields, buffs, self-area attacks, splash attacks, and ordinary targeted
spells without a spell-name whitelist. Equipped tools are rediscovered as they
change; inventory descriptions refresh every 30 seconds.

Positive range and radius metadata take priority when supplied by the game.
Splash attacks score compact visible groups while movement retains its nearest
enemy. Self-area attacks wait for close enemies; heals wait for health below 85%,
shields for danger, and buffs for nearby combat. Healing can run outside attack
range. Unknown moves retain normal targeting and configured range estimates.
The client does not expose exact ranges for every spell: the status readout marks
missing ranges as estimated, and grouping/close-AoE sliders supply fallbacks.

During cooldowns, the bot holds a safe useful range instead of needlessly closing
the gap; threat avoidance still takes priority. Grouping Radius and Close AoE
Distance are adjustable estimates, not verified server damage radii. The group
count in Combat Status estimates potential coverage and is not a confirmed hit
counter. Smart Farming can be disabled to restore ordinary targeting.

Automation, movement overrides, hover, and logging are off by default. Auto
Dungeon enables combat; Auto Create Lobby and Auto Start Dungeon enable queueing.
With `autoloadconfig = true`, existing settings are retained when reloading or
changing places. Turning autoload off starts with default controls; subsequent
changes still save automatically.

This is an executor script, not a standard Studio LocalScript. It requires
`loadstring` and `game:HttpGet`; file saving, FPS controls, HTTP requests, and teleport
continuation depend on the corresponding executor APIs.

## Source

This repository contains only the Obsidian project. `main.luau` is the public
entry point; `src/Lobby.luau` and `src/Dungeon.luau` contain place-specific logic.
`src/CombatController.luau` has no separate legacy UI. Shared controls and game
interfaces are in `src/ObsidianHub.luau`, `src/GameAdapter.luau`, and
`src/HubLogic.luau`. Ready-slot casting is in `src/AbilityController.luau`, and
collision/trajectory calculations are in `src/ThreatGeometry.luau`.
`src/FarmPlanner.luau` contains group scoring and cooldown-farming policy.

After changing source, rebuild and commit the generated scripts with it:

```sh
lua build.lua
```

The build writes `dist/lobby.luau` and `dist/dungeon.luau`. Runtime bundles include
their dependencies together, so each load uses one consistent bundle. The
external [Obsidian library](https://docs.mspaint.cc/obsidian) is pinned to a revision.
