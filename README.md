# ETB-HostKit

**Escape the Backrooms（逃离后室）房主工具包** — 仅需安装在开房电脑上，其他玩家无需安装任何内容。

[中文文档](#中文) · [English](#english)

---

## 中文

安装后可实现：

- **12 人（最多 32 人）联机** — 扩展本作默认的 4 人上限
- **全队同时过关** — 集合 / 全员进出口 / 掉队自动拉人
- **直接切换至指定关卡** — 也可跳过当前关卡（走正常出口结算）

### 安装

1. **先完全退出游戏**（安装需向游戏目录写入文件）
2. 双击 **`一键安装.bat`**，脚本会自动定位游戏安装位置
3. 安装完成后桌面会新增「ETB 控制台」快捷方式，此后请用它启动游戏
4. 进入游戏后按 **F6**，控制台窗口将显示在游戏画面之上

> 游戏安装在 `C:\Program Files` 时，请右键 `一键安装.bat` →「以管理员身份运行」。  
> 杀毒软件可能误报 `dwmapi.dll` / `UE4SS.dll`，请先将本文件夹加入白名单。  
> 游戏更新后建议重新执行一次 `一键安装.bat`，并用 `check.bat` 确认。

### 功能速览

| 操作目标 | 对应按钮 |
| --- | --- |
| 设置房间人数上限 | 最大人数一行（8 / 12 / 16 / 24 / 32），**需在建房前点击** |
| 更换关卡 | 先用 ◀ ▶ 或下拉框选择，再点击「前往选中关卡」 |
| 跳过当前关卡 | 「跳过当前关」 |
| 玩家走散 | 「全员集合到房主」 |
| 全队同时过关 | 走到出口附近，点击「全员进出口」 |
| 自动收拢掉队玩家 | 开启「掉队自动拉人」 |

快捷键、控制台指令、安装其他 pak mod、常见问题 → 详见 **[`详细说明.md`](详细说明.md)**

### 卸载

双击 `卸载.bat` 即可。加 `-RemoveUE4SS` 可连同 UE4SS 运行时一并清除；被移除内容会先进入  
`%LOCALAPPDATA%\EscapeTheBackrooms\ETB-uninstall-backup` 备份。

### 系统要求

- Windows 10 / 11
- Steam 版 *Escape the Backrooms*
- 仅需在**房主**机器上安装

### 注意事项

- 游戏本体原本仅支持 4 人，人数上限为额外扩展。**请勿用于公开房间**，建议与熟人一同游玩。
- 首次使用建议先以 2 人小规模测试「切关」「全员进出口」，再进行十余人游玩。
- 人数与切关依赖修改网络参数与蓝图函数实现，重大游戏更新后可能需要适配。

---

## English

**Host-side toolkit** for *Escape the Backrooms*. Install **only on the host machine** — other players need nothing.

### Features

- **Up to 12 (or 32) players** — raises the default 4-player cap
- **Clear levels together** — gather to host / send everyone to exit / auto-pull stragglers
- **Level select & skip** — jump to any campaign level, or skip via the normal exit flow

### Install

1. Fully quit the game
2. Double-click **`一键安装.bat`** (one-click install) — it locates your Steam install automatically
3. Launch the game via the new **「ETB 控制台」** desktop shortcut
4. Press **F6** in-game to show the host panel

> Run as Administrator if the game is under `C:\Program Files`.  
> Add this folder to your antivirus whitelist if `dwmapi.dll` / `UE4SS.dll` is quarantined.  
> After a game update, re-run the installer and verify with `check.bat`.

### Uninstall

Run `卸载.bat` (or `uninstall.bat`). Use `-RemoveUE4SS` to also remove the UE4SS runtime.  
Removed files are backed up to `%LOCALAPPDATA%\EscapeTheBackrooms\ETB-uninstall-backup`.

Full Chinese documentation (hotkeys, console commands, FAQ): [`详细说明.md`](详细说明.md)

---

## Repository layout

```
├── 一键安装.bat / install.bat    # Installer entry
├── 卸载.bat / uninstall.bat      # Uninstaller
├── HostPanel.*                  # Desktop host console
├── check.bat                    # Post-install verification
├── mods/ETB_HostKit/            # UE4SS Lua mod (core logic)
├── runtime/                     # UE4SS runtime + loader
├── config/Game.ini.snippet      # Multiplayer network parameters
├── 详细说明.md                   # Full manual (Chinese)
└── logo.png / logo.ico          # Icons
```

## Third-party components

- **UE4SS (RE-UE4SS)** `v3.0.1 Beta #0` (Git SHA `#f58e8f84`, experimental) by Narknon et al. — **MIT**  
  License text: [`runtime/ue4ss/LICENSE`](runtime/ue4ss/LICENSE) · <https://github.com/UE-RE-UE4SS/RE-UE4SS>  
  Packaged nearly as-is; `UE4SS-settings.ini` is adjusted for this game (custom UE 4.27).

Game-related content (`ETB_HostKit` Lua mod, host panel, install scripts, icons) is original work of this repository and is not affiliated with the game developers or UE4SS.

## License

This project’s original content is released under the [MIT License](LICENSE).  
UE4SS remains under its own MIT license (see above).

## Author

**彧晟Eason**
