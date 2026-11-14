# Low Ready Project

**Version:** 1.0.0  
**Author:** gabrielfluorite (Nexus Mods)  
**Platform:** PAYDAY 2 for Windows (Steam), non-VR  
**Required:** SuperBLT, installed separately  
**Supported use:** Local single-player/offline play

## Overview

Low Ready Project makes PAYDAY 2 movement feel more deliberate by letting you configure walking, sprinting and crouching speeds, reduce sprint camera bobbing, and lean the camera left or right. It is designed as a focused set of movement/camera adjustments, not a total gameplay overhaul.

This mod does **not** include SuperBLT, game files, other mods or preconfigured save data.

## Features and default settings

| Setting | Default | What it does |
| --- | --- | --- |
| Walk Speed | 60% | Scales walking speed. Also applies to unmasked/casing walking when eligible. |
| Sprint Speed | 60% | Scales sprinting speed in supported player states. |
| Crouch Speed | 60% | Scales crouching speed in supported player states. |
| Sprinting Head Bob | 50% | Reduces eligible camera bobbing during sprinting. |
| Enable Lean | Enabled | Enables or disables camera leaning. |
| Lean Left Key | Q | Key for leaning left. |
| Lean Right Key | E | Key for leaning right. |
| Lean Mode | Toggle | Toggle: press to lean, press again to return. Hold: lean while pressed. |

All four percentage sliders range from 10% to 100%. A speed setting of 100% removes this mod's speed scaling in the corresponding supported contexts; it does not remove other gameplay modifiers.

The Lean effect combines camera tilt and a small horizontal camera displacement. It has smooth transitions and cancels/returns in supported movement transitions such as sprinting and jumping. Its availability depends on the current player/camera state. Lean is supported in standard and carry states, but not in casing mode.

**Important:** Q and E may overlap with PAYDAY 2's existing controls. The mod does not unbind or override the game's key assignments; choose non-conflicting keys or adjust the game's bindings yourself.

## Manual installation

1. Close PAYDAY 2 before installing.
2. Install **SuperBLT** separately, following the instructions from its official project. The mod requires a working SuperBLT installation.
3. Open the PAYDAY 2 installation folder (in Steam, use **Manage > Browse local files**), then open `mods`.
4. Extract the included `LowReadyProject` folder directly into `PAYDAY 2/mods/`.
5. Check that the result is `PAYDAY 2/mods/LowReadyProject/mod.txt`. Do not leave an extra nested folder.
6. Start PAYDAY 2 in local single-player and find **LOW READY PROJECT** in the SuperBLT mod options menu.

**Do not enable older standalone Low Ready/Lean prototypes alongside this unified package.** In particular, avoid simultaneously loading mods named `low_ready` or `low_ready_lean_combined_proof`. Remove or disable older copies before starting the game; make a backup first if they contain custom changes.

**Upgrading from an earlier Low Ready Project installation:** If your previous installation folder is named `low_ready_project_unified` or `Low_Ready_Project`, move that entire folder **outside `PAYDAY 2/mods/`** as a backup before extracting `LowReadyProject`. Do not load both folders at once. To preserve existing settings, close the game, back up your save files and rename `mods/saves/low_ready_project_preferences_v1.json` to `mods/saves/lowreadyproject.json` before launching this version. If both files already exist, do not overwrite either; back them up and choose the preferences you wish to keep. This release does not automatically migrate the previous file name.

No executables or external installers are supplied with this mod.

## Configuring and saving settings

Changes made in the menu are saved by the mod to:

`PAYDAY 2/mods/saves/lowreadyproject.json`

Movement/head-bob changes may require restarting the current mission to become effective. Lean enable/keys/mode are designed to apply during the session when the current state permits it. If a key capture is cancelled with Escape or rejected, the previous setting is retained.

The defaults shown in the menu are **informational**. There is no Reset to Default button, and the mod does not reset PAYDAY 2's own control settings.

## Updating and uninstalling

**Updating:** Close the game, back up your current `LowReadyProject` folder, then replace that folder with the new release. Keep the separate `mods/saves/lowreadyproject.json` if you want to preserve your settings. Do not keep two active versions of the mod.

**Uninstalling:** Close the game and remove only `PAYDAY 2/mods/LowReadyProject`. Your preferences file can remain; the mod does not remove it or change the game's bindings when uninstalled.

## Compatibility and limitations

- Developed for **Windows, non-VR, local single-player**. Multiplayer and VR are not supported or validated.
- Tested in a limited set of real missions and offline simulations. Compatibility with every map, weapon, animation, camera state and third-party mod is **not guaranteed**.
- The camera displacement used for Lean has not been comprehensively validated for collision, cover, clipping, hit registration or projectile/reticle alignment. Consider it experimental in those contexts.
- Speed changes scale eligible game values; native abilities, carry penalties and modifiers from other installed mods can still affect the final result.
- Some interactions or transitions deliberately suspend Lean to avoid interfering with the game's camera handling.
- Because this is an unofficial game mod, account or anti-cheat safety cannot be guaranteed. This project is intended only for the supported offline/single-player context. Use at your own discretion.

## Support

For reports, include the game build, SuperBLT version, any other installed mods, the relevant option values, and reproducible steps. Avoid posting account identifiers, save files, private file paths or other personal information publicly.

## Credits and distribution

Project: **Low Ready Project**. Author: **gabrielfluorite**. Requires the third-party SuperBLT mod loader, which is **not included**. This package contains only the Low Ready Project files.

Development involved AI-assisted coding tools (including Codex) and manual in-game testing. SuperBLT and other third-party mods are separate projects and are not distributed with this package.
