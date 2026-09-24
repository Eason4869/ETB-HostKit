# ETB-HostKit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue.svg)](#系统要求)
[![Game](https://img.shields.io/badge/game-Escape%20the%20Backrooms-green.svg)](https://store.steampowered.com/)
[![UE4SS](https://img.shields.io/badge/UE4SS-v3.0.1%20Beta-lightgrey.svg)](https://github.com/UE-RE-UE4SS/RE-UE4SS)

**Escape the Backrooms（逃离后室）房主工具包** — 仅需安装在开房电脑上，其他玩家无需安装任何内容。

把原版 4 人联机扩到 **12 人（最多 32 人）**，并提供全队过关、选关 / 跳关等房主向工具。

**下载：** [Code → Download ZIP](https://github.com/Eason4869/ETB-HostKit/archive/refs/heads/main.zip) · **更新记录：** [CHANGELOG.md](CHANGELOG.md) · **完整手册：** [`详细说明.md`](详细说明.md)

[中文](#中文) · [English](#english)

---

## 中文

### 功能一览

| 分类 | 能力 |
| --- | --- |
| 联机人数 | 8 / 12 / 16 / 24 / 32 人（默认 12），放宽大厅人数滑块与会话槽位 |
| 全队过关 | 全员集合到房主 · 全员进出口 · 掉队自动拉人 |
| 关卡控制 | 浏览全部战役关卡 · 一键跳转 · 跳过当前关（优先走出口正常结算） |
| 桌面控制台 | 点按钮即可操作，顶部持续显示关卡与人数，底部显示执行结果 |
| 游戏内指令 | `F10` 控制台输入 `etb_*` 指令，与按钮 / 快捷键等价 |
| 安装维护 | 一键安装 / 校验 / 卸载 · 支持额外 `.pak` mod · 卸载可回滚备份 |

### 快速开始

1. **先完全退出游戏**（安装需向游戏目录写入文件）
2. 解压后双击 **`一键安装.bat`**，脚本会自动定位 Steam 游戏目录
3. 用桌面新增的 **「ETB 控制台」** 启动游戏（此后请一直用它启动）
4. 进入游戏后按 **`F6`**，控制台窗口显示在游戏画面之上
5. **建房前**点选人数；进关后用按钮或快捷键切关 / 过关

> **权限：** 游戏装在 `C:\Program Files` 时，右键 `一键安装.bat` →「以管理员身份运行」。  
> **杀软：** 可能误报 `dwmapi.dll` / `UE4SS.dll`，请先把本文件夹加入白名单再安装。  
> **游戏更新后：** 重新执行 `一键安装.bat`，再用 `check.bat` 确认（存档与配置不受影响）。

### 控制台按钮

| 操作目标 | 对应按钮 |
| --- | --- |
| 设置房间人数上限 | 最大人数一行（8 / 12 / 16 / 24 / 32），**需在建房前点击** |
| 更换关卡 | 先用 ◀ ▶ 或下拉框选择，再点「前往选中关卡」 |
| 跳过当前关卡 | 「跳过当前关」 |
| 玩家走散 | 「全员集合到房主」 |
| 全队同时过关 | 走到出口附近，点「全员进出口」 |
| 自动收拢掉队玩家 | 开启「掉队自动拉人」 |
| 查看关卡与人数 | 窗口顶部状态区域持续显示 |
| 排查问题 | 「打开日志」 |

「掉队自动拉人」默认关闭，每次启动游戏后需手动开启，退出游戏后自动复位。  
人数设置与切关均要求**当前玩家为房主**；人数还需在**建房前**设置才生效。

### 快捷键

| 按键 | 作用 |
| --- | --- |
| `F6` | 显示 / 收起控制台 |
| `F10` | 打开游戏内控制台 |
| `Ctrl+F9` | 全员集合到房主 |
| `Ctrl+Shift+F9` | 全员进出口 |
| `Ctrl+Shift+F10` | 跳过当前关 |
| `Ctrl+Shift+F4` | 掉队自动拉人 开 / 关 |
| `Ctrl+Shift+F6` / `F7` | 上一个 / 下一个关卡（仅选择） |
| `Ctrl+Shift+F8` | 切换至选中的关卡 |
| `Ctrl+Shift+F11` | 关卡列表 |
| `Ctrl+Shift+F12` | 状态 |

`F6` 被截图 / 录屏 / 输入法占用时，改用标题栏提示的 `Ctrl+Alt+F6`，或重新双击 `HostPanel.bat`。

### 控制台指令（`F10`）

```
etb_hub                  查看状态
etb_players 16           修改人数（2-32，下次建房生效）
etb_levels               关卡列表
etb_level 8              切换至第 8 关（也可写关卡名）
etb_skip                 跳过当前关
etb_gather               全员集合到房主
etb_exit                 全员进出口
etb_assist on|off        掉队自动拉人
etb_help                 全部指令
```

### 卸载

双击 `卸载.bat`（即 `uninstall.bat`）：移除 mod、面板文件、写入配置的联机参数与桌面快捷方式。

| 参数 | 作用 |
| --- | --- |
| `-RemoveUE4SS` | 连同 UE4SS 运行时（`dwmapi.dll`、`ue4ss\`）一并清除 |
| `-Purge` | 不备份，直接删除被移除内容 |

默认备份目录：`%LOCALAPPDATA%\EscapeTheBackrooms\ETB-uninstall-backup`。  
默认保留 UE4SS，以免其他 pak mod 仍依赖它。

### 系统要求

- Windows 10 / 11
- Steam 版 [*Escape the Backrooms*](https://store.steampowered.com/)
- 仅需安装在**房主**机器上

### 常见问题（摘录）

| 问题 | 处理 |
| --- | --- |
| 改人数后没生效 | 需**重新建房**，已开房间不会变更 |
| 人数滑块拉不过 4 | 1.0.1 之前的版本只放宽了滑块、没抬游戏自己的上限；升级到 1.0.1 后重装即可 |
| 切关不能连点 | 两次切换需间隔 10 秒（世界重建冷却），按钮会显示「冷却中…」 |
| 「全员进出口」无效 | 本关须有出口区域；大厅等无出口图会明确提示 |
| 后排玩家卡顿 | 将 `Game.ini` 中 `MaxClientRate` 由 `250000` 调小（如 `150000`） |
| 安装后游戏更新失效 | 重新 `一键安装.bat`，再 `check.bat` |
| 高分屏面板偏糊 | 旧框架固定像素布局被系统拉伸，不影响使用 |

更多（含 pak mod 安装、日志路径、稳定性说明）→ [`详细说明.md`](详细说明.md)

### 注意事项

- 本作原版仅支持 4 人，人数上限为额外扩展。**请勿用于公开房间**，建议与熟人游玩。
- 首次使用建议先 2 人测试「切关」「全员进出口」，再扩大人数。
- 人数与切关依赖网络参数与蓝图函数；游戏大版本更新后可能需要适配。

### 目录结构

```
├── 一键安装.bat / install.bat     # 安装入口
├── 卸载.bat / uninstall.bat       # 卸载入口
├── HostPanel.*                    # 桌面房主控制台
├── check.bat                      # 安装 / 更新后校验
├── mods/ETB_HostKit/              # UE4SS Lua mod（核心逻辑）
├── runtime/                       # UE4SS 运行时（含 dwmapi.dll 注入）
├── config/Game.ini.snippet        # 联机网络参数片段
├── 详细说明.md                     # 完整中文手册
├── CHANGELOG.md                   # 版本更新记录
└── logo.png / logo.ico            # 图标
```

### 日志路径

- Mod：`…\Binaries\Win64\ue4ss\UE4SS.log`
- 控制台：`HostPanel` 同目录下的 `HostPanel.log`

---

## English

**Host-side toolkit** for *Escape the Backrooms*. Install **only on the host machine** — other players need nothing.

Raises the co-op cap from 4 to **12 players (up to 32)** and adds team-clear, level select / skip, and a desktop host panel.

### Features

- **Player cap** — 8 / 12 / 16 / 24 / 32 (default 12) for new lobbies
- **Clear together** — gather to host, send party to exit, optional auto-pull stragglers
- **Level control** — browse all maps, jump with the party, or skip (prefers normal exit clear)
- **Host panel** — desktop UI with hotkeys, live status, level list, logs
- **Console** — `F10` + `etb_*` commands
- **Install / uninstall** — one-click, verifiable, reversible with backup; optional `paks/` drop-in for `.pak` mods

### Quick start

1. Fully quit the game
2. Double-click **`一键安装.bat`** (one-click installer) to locate your Steam install and deploy
3. Launch via the new **「ETB 控制台」** desktop shortcut
4. Press **`F6`** in-game for the host panel
5. Pick max players **before** creating a lobby; use buttons / hotkeys in-level

> Run as Administrator if the game lives under `C:\Program Files`.  
> Whitelist this folder if antivirus quarantines `dwmapi.dll` / `UE4SS.dll`.  
> After a game update, re-run the installer and verify with `check.bat`.

### Hotkeys (summary)

| Key | Action |
| --- | --- |
| `F6` | Show / hide host panel |
| `F10` | In-game console |
| `Ctrl+Shift+F10` | Skip level |
| `Ctrl+F9` / `Ctrl+Shift+F9` | Gather to host / send to exit |
| `Ctrl+Shift+F8` | Go to selected level |
| `Ctrl+Shift+F12` | Status |

Full tables, commands, FAQ (Chinese): [`详细说明.md`](详细说明.md)

### Uninstall

Run `卸载.bat` / `uninstall.bat`. Optional: `-RemoveUE4SS`, `-Purge`.  
Backups go to `%LOCALAPPDATA%\EscapeTheBackrooms\ETB-uninstall-backup`.

### Requirements

- Windows 10 / 11 · Steam *Escape the Backrooms* · **host PC only**

---

## Third-party components

- **UE4SS (RE-UE4SS)** `v3.0.1 Beta #0` (Git SHA `#f58e8f84`, experimental) by Narknon et al. — **MIT**  
  License: [`runtime/ue4ss/LICENSE`](runtime/ue4ss/LICENSE) · <https://github.com/UE-RE-UE4SS/RE-UE4SS>  
  Packaged nearly as-is; `UE4SS-settings.ini` adjusted for this title’s custom UE 4.27  
  (engine version override + selected hooks disabled for stability).

Game-related content (`ETB_HostKit` Lua mod, host panel, install scripts, icons) is original work of this repository and is **not** affiliated with the game developers or the UE4SS project.

## Compatibility

| Item | Status |
| --- | --- |
| Steam *Escape the Backrooms* (Windows) | Supported target |
| Host / listen server | Required role for this kit |
| Guest / client machines | No install needed |
| Game updates that overwrite `Binaries\Win64` | Re-run `一键安装.bat` |
| Other `.pak` mods | Via `paks/` + reinstall (see 详细说明) |

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and pull requests are welcome. For bugs, please attach:

1. `UE4SS.log` and `HostPanel.log`
2. Whether the host had just updated the game
3. Player count and the action you tried (button / hotkey / command)

## License

This project’s original content is released under the [MIT License](LICENSE).  
UE4SS remains under its own MIT license (see above).

## Author

**彧晟Eason**
