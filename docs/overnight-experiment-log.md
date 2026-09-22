# Northern Lands overnight experiment log

This log records only observations from the connected level-201 client
`VanguardAttacker` (UserId `11044000891`). No level-1 client was used, and no
rewrite-repository bundle was loaded.

| Run | Revision | Dungeon / difficulty | Result / furthest point | Evidence and change |
| --- | --- | --- | --- | --- |
| 1 | `fc256b9` + local melee-lease patch | Northern Lands / Insane | Not clear; reached room 2 and engaged Midgardian Champion, then Bob The Frost Giant | Client saw line and radial zones, but entered `safety-hold`/overlapping-line escapes and recorded repeated damage/deaths. Added committed melee escape lease, bounded melee blink eligibility, and same-threat dodge bookkeeping. |
| 2 | working tree after radial-exit patch | Northern Lands / Insane (teleport data) | In progress at observation cutoff; waiting for next wave with no damage after reload | Added cylinder-aware radial exits that rank overlap clearance before target distance. Rebuilt both bundles and loaded the local absolute-path dungeon bundle. Full-clear status not yet verified. |
| 3 | working tree after transparent-marker detection | Northern Lands / Nightmare | Not clear; reached room 2 / Midgardian Champion and later Bob The Frost Giant, with repeated deaths | Transparent `northernMageShot`, `northernWarriorLineStrike`, and related markers became detectable, but persistent templates were counted as active; the scan inflated to 103–111 hazards and produced repeated `safety-hold` decisions. |
| 4 | working tree after activity-window cleanup | Northern Lands / Nightmare | Not clear; reached Midgardian Champion again, then died during first-boss beam/slam overlap | Stale-marker cleanup reduced fresh-run scans to roughly 12–30 hazards. The remaining failure was genuine active geometry: `firstBossPassiveBeam` and `firstBossJumpSlam` were observed near the player while the escape remained inside the overlap. |

Rules for entries: record the actual teleport-data dungeon and difficulty, do not
count a run as clear until the game reports completion, and keep failed changes
in the history rather than silently treating a regression as success.
