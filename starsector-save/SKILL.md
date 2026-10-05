---
name: starsector-save
description: Inspect and reason about the user's Starsector campaign from its save files and game data — where the saves live on the desktop, the Steam Deck (Bottles) and the seldon share, how the two installs are kept as one save through Ludusavi, how to decode the abbreviated campaign.xml, and the traps that produced wrong answers before. Use whenever the user asks about their Starsector game, saves, fleet, story progress, mods, markets, or moving the save between machines.
---

# Starsector save inspection

One campaign, two installs, one Ludusavi backup named **Starsector**. The desktop path is canonical; the Deck translates through a bidirectional redirect. Everything below was verified 2026-09-09/10 on Starsector 0.98a-RC8.

## Where things are

| What | Path |
|---|---|
| Desktop game (Linux, native) | `~/.local/share/starsector/` — saves in `saves/`, mods in `mods/`, game data in `data/`, API sources in `starfarer.api.zip` |
| Deck game (Windows build in Bottles, host `egret`) | `/home/deck/.var/app/com.usebottles.bottles/data/bottles/bottles/Starsector/drive_c/Program Files (x86)/Fractal Softworks/Starsector/` — `saves/`, `mods/`, game data under `starsector-core/data/` |
| Deck stale copy, ignore | `/home/deck/Downloads/Starsector` (June 2025) |
| Ludusavi backup folder, each machine | `~/ludusavi-backup/Starsector/drive-0/home/acoddington/.local/share/starsector/{saves,mods}` (Deck paths are rewritten to this form by the redirect) |
| Shared store (Samba, host `seldon`) | `/media/golem/saves/Starsector/...` same layout; share is `//10.224.224.2/saves`, guest access |
| Ludusavi config | `~/.var/app/com.github.mtkennerly.ludusavi/config/ludusavi/config.yaml` on both machines |
| Side copies of overwritten backups | `~/ludusavi-backup-overlap-2026-09-09/` on both machines (six games that both play; not Starsector) |

Both installs are the same campaign: captain **Adamr**, level 5 as of 2026-09-10, story at Galatia Academy missions *Kallichore Archive* (hack installed at the Aztlan relay is the next step) and *Finding Coureuse* (probe branch), plus Sebestyen errands. Re-derive the current state with the script rather than trusting this line.

## Inspect first, with the script

`inspect_save.py` beside this file reads saves with plain regexes; no game launch, no XML parser (files are 14–30 MB with unbalanced-looking abbreviated tags).

```
inspect_save.py slots                    # every slot by save date; newest last
inspect_save.py summary [slot]           # captain, credits, story points, skills, fleet, cargo
inspect_save.py flags [slot] ['$gaKA']   # REAL memory flags (see trap 1)
inspect_save.py missions [slot]          # mission objects: current stage, stage order, in intel list?
inspect_save.py markets [slot] [commodity...]   # stock / available / demand per known market
inspect_save.py --saves /path summary    # same against a copy from the Deck or the share
```

Ask the game what it thinks before answering about story position: the Intel screen is authoritative; the script is for reading it without the user.

## Decoding campaign.xml

XStream with aliases. What the useful tags are:

- **Slot metadata** is in `descriptor.xml`: `saveDate` (real time, UTC), `characterLevel`, `locDesc`, `autosave`, `gameDate/timestamp` (ms; ≈ year = 1970 + ts/31.5e9 → cycle 209 in 2026-09).
- **Player**: `<playerFleet ref="N">` → `<Flt z="N" n="Player Fleet">`. Its `<fD … nSf="player">` holds `<m>` with inline `<FMmbr sN="ship name">` members, each with `<savedVariant hId="hull_id">` and an optional captain `<c … pst="fleetCommander|officer"><n f="Name">`. The fleet's `<cargo z=…>` follows the member list: stacks `<CIStack s="qty"><d cl="st">commodity</d>`, credits `<c z=…><value>N</value>`.
- **Captain stats**: `<c … fid="player"><stats x2 xp l="level" pt="unspent skill pts" sp="story points"><a>{aptitudes}</a><s>{skills}</s>`.
- **Memory flags**: real state is `<e><st>$key</st><bp|st|fp|ip>value</…></e>` inside a `<memory cl="Memory">`/`<d>` block. Personal flags sit under `<characterData><memory>`; mission flags are in global memory, which is huge and contains whole mission objects, so search the whole file for the `<st>$key</st>` form.
- **Mission objects**: `com.fs.starfarer.api.impl.campaign.missions.academy.GA*` (Kallichore, FindingCoureuse, ProbePackage, DerelictArtifact, ProjectZiggurat…). `<currentStage>` is the live stage; the `_-Stage` tags list the stage order; a `ref` inside `<intelManager>` means it is an active intel entry. Objects may be serialized either as `<full.class.Name z=…>` or as `<sometag cl="full.class.Name" z=…>`; search both.
- **Markets**: `<market cl="Market"><id><name>` then `<COMkt c="commodity" sto="stock" mD="demand units">` with `<available m="supply units">`. Prices are not stored; `available > mD` is a glut (cheap), `<` a deficit (dear). Base prices in `data/campaign/commodities.csv` (supplies 100, fuel 25); open-market tariff ≈30%.
- **Systems/coordinates**: `<X cl="Sstm" z="N" dN="Name Star System">`; hyperspace position is the `<loc>` of the LocationToken that references it (inline `z` or later `ref`). 2000 units = 1 ly. A planet's/station's system is the `<cL cl="Sstm" ref=…>` inside that entity, **not** the nearest preceding one.
- **Terrain**: `<CampaignTerrain>` with `<plugin cl="AsteroidBeltTerrainPlugin|RingSystemTerrainPlugin|MagneticFieldTerrainPlugin|…">`.

Game data worth grepping: `data/campaign/rules.csv` (all dialogue and mission gating, columns id/trigger/conditions/script/text/options), `data/hulls/ship_data.csv` (upkeep, burn, fuel/ly, tags such as `no_auto_penalty`, `no_dealer`), `data/hullmods/hull_mods.csv`, `data/world/factions/*.faction`, and the API sources in `starfarer.api.zip` (`unzip -p … path.java`) for rule commands like `IsSeenByAnyFleet` and submarket legality.

## Traps that produced wrong answers

1. **`<key>$flag</key>` is not state.** Those are `SetMemoryValueAction`s scripted inside mission objects. Reading them as progress made both Academy missions look finished when both were mid-way. Only the `<st>$flag</st><bp>true</bp>` form counts.
2. **Market → system by "nearest preceding Sstm" is wrong**; a market first serialized inside a passing trade fleet lands in that fleet's system. Use the owning planet's `<cL>`.
3. **Storage legality is code, not faction files.** `BaseSubmarketPlugin.isIllegalOnSubmarket` refuses any automated ship (the Onslaught Mk.I) at every non-black-market submarket unless the market is player-owned or its faction is neutral. Only the player's colonies and unowned derelict stations (Abandoned Terraforming Platform in Corvus, Siphon Station in Yma, etc.) will store it.
4. **The Aztlan relay check is `IsSeenByAnyFleet`**: blocks only if a fleet within 1000 units can see the player, or has the saw-transponder-off / pursue-player memory. Distance and marks matter, not stealth in general.
5. **The game rotates autosaves**; slot directories appear and vanish. Never hard-code a slot name; use `slots`/`newest`. The user's manual saves may reuse a slot name (e.g. `save_Adamr_2725421144625641907` was re-saved on 2026-09-10).

## Ludusavi rules for this save

- Config on both machines: custom game **Starsector**, `integration: override`, files = `saves` + `mods` only. Deck adds `redirects: [{kind: bidirectional, source: <Bottles Starsector dir>, target: /home/acoddington/.local/share/starsector}]`.
- **Never press Upload in the GUI** on either machine; it is a full mirror with deletions across all 97 games. Download-then-Backup is the safe order. CLI `ludusavi cloud upload/download` (via `flatpak run com.github.mtkennerly.ludusavi`) is scoped to games the local layout knows and is safe; pass a game name to scope further.
- After a backup the automatic upload sometimes does not run; check `cloud upload --preview Starsector` and push with `cloud upload --force Starsector`.
- Moving the save: back up on the machine you leave; on the other, cloud Download then Restore Starsector. Restore adds/overwrites, never deletes. The Deck's Decky Ludusavi plugin backs up on game close if enabled for the Steam shortcut named "Starsector".
- The Ludusavi GUI rewrites config.yaml from memory on any settings change: close it before editing the file by hand.

## Mods

20 enabled (list in `mods/enabled_mods.json`, identical on both machines); see `mod_info.json` per folder for descriptions. Combat Chatter, LazyLib, MagicLib, LunaLib, GraphicsLib 1.10.2, Ship/Weapon Pack, Industrial.Evolution, Unknown Skies, Illustrated Entities, Dynamic Tariffs, Demand Indicators, Stellar Networks (trade boards live inside the Intel tab under the `stelnet` filter: "Commodity Market", "Trade Opportunities"), Hostile Intercept, Leading Pip, Larger Zoom Out, Planet Search, QoL Pack, SpeedUp, Autosave Extended, Audio Plus. Lightshow installed but off; `zz GraphicsLib-1.9.0` is a dead leftover folder.
