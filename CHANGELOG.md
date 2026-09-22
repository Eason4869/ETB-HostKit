# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-22

First public release of **ETB-HostKit** for *Escape the Backrooms*.

### Added

- **Extended multiplayer cap** — host rooms for 8 / 12 / 16 / 24 / 32 players (default 12; game base is 4)
  - Patches session `PublicConnections` at create-time
  - Raises lobby player-count slider and `MaxPlayers` on relevant game states
  - Writes multiplayer network parameters to `Game.ini` (`MaxClientRate`, move throttle, tick rate)
- **Team clear tools**
  - Gather all players to host
  - Send everyone to the level exit zone (normal clear flow)
  - Auto-pull stragglers (optional, default off; resets each game session)
- **Level control**
  - Browse / select any campaign level
  - Jump to selected level with the whole party (`ServerTravel`)
  - Skip current level (prefer exit-zone clear; otherwise next map)
  - 10-second travel cooldown to avoid world-rebuild races
- **Desktop host panel** (`HostPanel`)
  - One-click actions matching in-game hotkeys
  - Live status (level, player count, last result)
  - Level list dialog, open logs, launch game
  - Tray / global hotkey: `F6` (fallback `Ctrl+Alt+F6`)
- **In-game console commands** (`F10`)
  - `etb_hub`, `etb_players`, `etb_levels`, `etb_level`, `etb_skip`, `etb_gather`, `etb_exit`, `etb_assist`, `etb_help`
- **Installer / uninstaller**
  - `一键安装.bat` — auto-locate Steam game dir, deploy UE4SS + mod, write `Game.ini`, create desktop shortcut
  - Optional drop-in `paks/` folder for third-party `.pak` mods
  - `check.bat` — post-install / post-game-update verification
  - `卸载.bat` — full uninstall with backup under `%LOCALAPPDATA%\EscapeTheBackrooms\ETB-uninstall-backup`
  - Flags: `-RemoveUE4SS`, `-Purge`, `-MaxPlayers`
- **Documentation**
  - `README.md` (bilingual)
  - `详细说明.md` (full Chinese manual: buttons, hotkeys, commands, FAQ, troubleshooting)
- **Packaged runtime**
  - UE4SS (RE-UE4SS) `v3.0.1 Beta #0` (`#f58e8f84`), MIT, tuned for this game’s custom UE 4.27

### Notes

- Install **only on the host machine**. Guests need nothing.
- After a game update, re-run `一键安装.bat` (saves and config are preserved).
- Player-count changes apply to **new** lobbies only.

[Unreleased]: https://github.com/Eason4869/ETB-HostKit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Eason4869/ETB-HostKit/releases/tag/v1.0.0
