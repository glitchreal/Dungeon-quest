# Adaptive memory and navigation

## Audit of 5800a7b

* Short-term: mechanic state, orb samples, chosen escape/sector side, waypoint
  leases, target locks, route progress, and recent failure cooldowns.
* Session history: hazard observations, escape results, damage records, the
  160-entry threat log, visited fallback cells, and failed path cache.
* Persisted: `DodgeMemory` in `DungeonQuestObsidian-config.json`, capped at 24
  hazard signatures, with hit margin, side success estimates, and aim-follow
  observations. This already adapts hazard clearance and escape preferences.
* Fixed heuristics: Northern boss candidate scores, orb stand-off choices,
  arena sectors, checkpoint order, path configuration choice. No boss outcome
  policy or persistent navigation-edge outcomes existed.

## Added evidence and limits

`AdaptiveMemory` shares that config file; lobby saves preserve it. It is versioned
independently and rejects invalid versions, nonfinite numbers, malformed rows,
negative counters, and future timestamps. File-saving support remains optional.
Caps: 32 boss/mechanic/color records (the four recognized bosses), 96 route/local
edge records, 48 feature bins per record, six recent choices per live mechanic.
Graph planning caps at 96 checkpoints, eight alternatives per room, and a
four-room lookahead. No remote calls or gameplay loops are involved.

Counters are effective evidence weights, not lifetime statistics. Damage within
one second of a known mechanic choice and with overlapping visible geometry
records one failure for that episode. Features include direction, boss distance,
arena sector, destination and segment cells; orb policies include color,
approach-angle and stand-off bins. Damage records the observed sector/distance.
The old hazard learner remains independent: it models attacks, while this one
models mechanic choices. There is no second hazard-margin learner.

Success requires reaching an escape destination and observing removal/expiry of
its threat, holding a matching zone through its deadline plus a short damage
settlement interval, or an observed matching-color orb explosion near both the
matching crystal and the recently tracked orb. Removal alone is not orb success;
aborted objectives and switching targets/colors earn no reward. These are
client-visible proxies, not claims about server-only success state. Final approach
features receive the reward. Wrong-crystal pursuit near misses and excessive
guidance corrections contribute one quarter-weight efficiency penalty per orb.

Costs are capped at ±24 and shrink toward neutral with low confidence. They
rank only candidates with equal current destination exposure and route-safety
status; current geometry and walking checks still win. Stand-off and spacing
candidate sets provide alternatives for the policy to favor without locking
positions across encounters. Seven-day wall-clock half-life plus 4% fading per
full-weight observation lets fresh successes reverse old failures.

## Navigation

Authored ordered rooms are directed graph layers. Multiple checkpoints in a room
are alternative entrances. The graph is cached and invalidated by checkpoint
addition/removal; it does not invent connections through walls. Target ancestry
or bounded spatial association determines the target room. Long approaches use
the graph before local navmesh paths. When no checkpoints exist, the existing
local navigator remains the fallback. Live targets in passed rooms are explicit
return objectives; nearest-checkpoint distance alone never lowers route progress.

Arrival rewards an edge; failed local path computation and objective stalls
penalize it. A short failure cooldown encourages alternate entrances when the
map supplies them. Later success lowers the learned cost. Single-entrance rooms
retain their authored route instead of inventing an unsafe shortcut. Local
recovery segments separately learn arrival, timeout and supported hazard damage.
Interrupted or replaced fallback objectives are discarded without an outcome;
reaching another entrance cannot reward the edge that was originally selected.

Two existing navmesh configurations are scored by exposure first, then travel,
enemy collisions and learned segment costs. Recovery candidates additionally
require current walking, hazard and enemy clearance and penalize recently visited
cells. This is bounded candidate scoring, not a modified Roblox navmesh or a
global voxel map. Path/route leases, meaningful score-improvement thresholds, and
an epoch check reject obsolete asynchronous path results.

Objective progress uses best distance and best remaining path length across
waypoint replacements. Eight seconds without improvement triggers a replan;
moving sideways or circling alone is not progress. A gap in navigation monitoring
suspends the timer for mechanic/hazard ownership. Existing debug fields expose
policy, confidence, side, destination penalty, edge cost, stall score and reason.

## Verification

`lua testing/adaptive-memory.lua` checks bounded storage, malformed input,
persistence round-trip, confidence, decay, reversal with new success, failed-edge
alternatives, arrival rewards, circling detection, suspended timers, and geometry
precedence over historical preference. Compile source and generated bundles with
`luau-compile`; rebuild using `lua build.lua`. Gameplay outcomes remain unverified.
