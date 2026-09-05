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
`src/HubLogic.luau`.

After changing source, rebuild and commit the generated scripts with it:

```sh
lua build.lua
```

The build writes `dist/lobby.luau` and `dist/dungeon.luau`. Runtime bundles include
their dependencies together, so each load uses one consistent bundle. The
external [Obsidian library](https://docs.mspaint.cc/obsidian) is pinned to a revision.
