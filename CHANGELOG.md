# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed (2026-09-24)

- **人数滑块只能拉到 4**：游戏在建房界面里自己存了一份上限
  （`W_CreateServer.MaximumPlayers`，默认 4）。之前只把滑块的 `MaxValue` 抬高，
  所以滑块会变成「长一截、后半段灰色、拉不过 4」，游戏最终也还是按 4 个人建房。
  现在连同这份上限一起抬到目标人数，游戏自己的 `MaxPlayer` 会跟着变成目标值。
- **PublicConnections 参数位置改为运行时自动识别**：从 `CreateAdvancedSession`
  的 UFunction 里读参数名定位（当前是第 4 个），游戏更新后参数顺序变了也不会改错地方。
- **客户端不要再写服务器状态**：`enforce_max_players` 现在只在房主端生效。
  如果一台没开房的机器也装了本 mod，原来它会在本地写 `GameState.MaxPlayers`
  这类同步属性，容易让状态错乱。
- **滑块值不再每帧被抢回去**：改为「每个控件实例 / 每次改目标人数」同步一次，
  之后手动拖动不会被覆盖。

### Added

- 建房时会在日志里记录 `PublicConnections` / `PrivateConnections` 的实际取值，
  方便排查「房间没满却进不来」。

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
