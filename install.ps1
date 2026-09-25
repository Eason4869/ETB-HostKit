<#
    ETB-HostKit 安装脚本（仅需在房主所在机器上执行）

    本脚本依次完成三项操作：
      1. 将 UE4SS 运行时部署到 游戏目录\EscapeTheBackrooms\Binaries\Win64
         运行时版本：UE4SS v3.0.1 Beta #0 experimental（Git SHA #f58e8f84），
         MIT 许可，许可证原文见 runtime\ue4ss\LICENSE。
         本作的可执行文件中不包含引擎版本字符串，因此 UE4SS-settings.ini 中的
         [EngineVersionOverride] 必须固定为 4/27（本包已预先写入，脚本仍会复核）。
         该版本 UE4SS 通过内置特征码即可定位本作的 StaticConstructObject_Internal
         （日志记录为 "Found StaticConstructObject_Internal: 0x..."，而非 "<- Lua Script"），
         无需手工提供 UE4SS_Signatures 签名文件。
      2. 部署 ETB_HostKit（Lua mod），并登记到 Mods\mods.txt
      3. 将联机所需的网络参数写入 存档目录\Saved\Config\...\Game.ini
         （默认 12 人，可用 -MaxPlayers 参数调整）

    本脚本可重复执行；不修改 .pak 文件，不改动存档；卸载使用 卸载.bat（或 uninstall.bat），
    可完整还原。执行前请先完全退出游戏；若游戏安装在 Program Files 目录下，
    需以管理员身份运行。
#>
[CmdletBinding()]
param(
    [string]$GameDir = "",
    [switch]$SkipIni,
    [int]$MaxPlayers = 12
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 游戏本体默认为 4 人；1 人无实际意义，32 为实测仍可正常开房的上限
if ($MaxPlayers -lt 2 -or $MaxPlayers -gt 32) {
    throw "-MaxPlayers 只支持 2 到 32（默认 12）。用法：install.bat -MaxPlayers 8"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtimeDir = Join-Path $scriptRoot "runtime"
$modSource  = Join-Path $scriptRoot "mods"
$iniSnippet = Join-Path $scriptRoot "config\Game.ini.snippet"
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    $Text" -ForegroundColor DarkGray }
function Write-Warn2([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

function Read-TextLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrEmpty($text)) { return @() }
    return @($text -split "`r?`n")
}

function Write-TextLines([string]$Path, [string[]]$Lines) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), $Utf8NoBom)
}

function Resolve-GameDir([string]$Hint) {
    $expectedExe = "EscapeTheBackrooms\Binaries\Win64\Backrooms-Win64-Shipping.exe"
    if ($Hint) {
        if (Test-Path -LiteralPath (Join-Path $Hint $expectedExe)) { return $Hint }
        return $null
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add("D:\steam\steamapps\common\EscapeTheBackrooms")
    $candidates.Add("C:\Program Files (x86)\Steam\steamapps\common\EscapeTheBackrooms")
    $candidates.Add("C:\Program Files\Steam\steamapps\common\EscapeTheBackrooms")
    $steamRoots = New-Object System.Collections.Generic.List[string]
    try {
        $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name SteamPath -ErrorAction Stop).SteamPath
        if ($steamPath) { $steamRoots.Add($steamPath) }
    } catch { }
    if (Test-Path -LiteralPath "D:\steam") { $steamRoots.Add("D:\steam") }
    foreach ($root in $steamRoots) {
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        $text = [System.IO.File]::ReadAllText($vdf)
        foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $libPath = $match.Groups[1].Value -replace '\\\\', '\'
            $candidates.Add((Join-Path $libPath "steamapps\common\EscapeTheBackrooms"))
        }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $exe = Join-Path $candidate $expectedExe
        if (Test-Path -LiteralPath $exe) { return $candidate }
    }
    return $null
}

$GameDir = Resolve-GameDir $GameDir
if (-not $GameDir) { throw "未找到游戏目录，请用 -GameDir ""X:\steam\steamapps\common\EscapeTheBackrooms"" 指定" }
Write-Ok "游戏目录: $GameDir"

$binDir  = Join-Path $GameDir "EscapeTheBackrooms\Binaries\Win64"
$modsDir = Join-Path $binDir "ue4ss\Mods"
$ue4ssDir = Join-Path $binDir "ue4ss"

$hasRuntime = Test-Path -LiteralPath (Join-Path $runtimeDir "ue4ss\UE4SS.dll")
if (-not $hasRuntime) {
    Write-Warn2 "本包不含 UE4SS 运行时（Lite 包）：仅更新 mod 本体，请确认此前已安装过完整包。"
}

# 游戏运行时 dwmapi.dll / UE4SS.dll 处于占用状态，写入会失败，
# 并留下「mod 已更新、运行时未更新」的不完整安装状态，因此此处直接中止安装，而非仅作提示。
$running = @(Get-Process -Name "Backrooms-Win64-Shipping" -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    throw "游戏正在运行：请完全退出游戏（含启动器）后再执行安装。"
}

# 权限探测：游戏安装在 Program Files 目录下时，若在复制过程中报错，用户难以判断原因，故此处提前拦截
function Test-DirWritable([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    $probe = Join-Path $Dir (".etb-write-test-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [System.IO.File]::WriteAllText($probe, "ok")
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}
if (-not (Test-DirWritable $binDir)) {
    throw "无权限写入 $binDir`n请右键 一键安装.bat（或 install.bat），选择「以管理员身份运行」。"
}

# ---------------------------------------------------------- 1. UE4SS 运行时
if ($hasRuntime) {
Write-Step "部署 UE4SS 运行时 -> $binDir"
$proxySource = Join-Path $runtimeDir "dwmapi.dll"
$proxyTarget = Join-Path $binDir "dwmapi.dll"
if (Test-Path -LiteralPath $proxyTarget) {
    $same = (Get-FileHash -LiteralPath $proxyTarget).Hash -eq (Get-FileHash -LiteralPath $proxySource).Hash
    if (-not $same -and -not (Test-Path -LiteralPath "$proxyTarget.etb-mod.bak")) {
        Copy-Item -LiteralPath $proxyTarget -Destination "$proxyTarget.etb-mod.bak"
    }
}
Copy-Item -LiteralPath $proxySource -Destination $proxyTarget -Force
Write-Ok "写入 dwmapi.dll（负责加载 ue4ss\UE4SS.dll）"

New-Item -ItemType Directory -Force -Path $ue4ssDir | Out-Null
Copy-Item -Path (Join-Path $runtimeDir "ue4ss\*") -Destination $ue4ssDir -Recurse -Force
Write-Ok "写入 ue4ss\（UE4SS.dll + UE4SS-settings.ini + Mods）"

# 旧版 v2.5.2 使用根目录布局，会覆盖注入目标且运行不稳定，故改名停用
foreach ($stale in @("UE4SS.dll", "UE4SS-settings.ini")) {
    $stalePath = Join-Path $binDir $stale
    if (Test-Path -LiteralPath $stalePath) {
        Move-Item -LiteralPath $stalePath -Destination "$stalePath.old-layout-disabled" -Force
        Write-Warn2 "已停用旧的 $stale（重命名为 $stale.old-layout-disabled）"
    }
}
$staleMods = Join-Path $binDir "Mods"
if (Test-Path -LiteralPath $staleMods) {
    Move-Item -LiteralPath $staleMods -Destination "$staleMods.old-layout-disabled" -Force
    Write-Warn2 "已停用旧的 Mods 目录（改名为 Mods.old-layout-disabled）"
}

# 将指定 section 下的若干键改写为指定值（section 不存在则补充；同名键重复出现时仅保留最后一条）
function Set-IniValues([string]$IniPath, [string]$Section, $Want) {
    if (-not (Test-Path -LiteralPath $IniPath)) { return }
    $lines = @(Read-TextLines $IniPath)
    $out = [System.Collections.Generic.List[string]]::new()
    $inSection = $false
    $foundSection = $false
    $seen = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') {
            if ($inSection) {
                foreach ($key in $Want.Keys) { if (-not $seen[$key]) { $out.Add("$key = $($Want[$key])") } }
            }
            $inSection = ($line -match ('^\s*\[' + [regex]::Escape($Section) + '\]'))
            if ($inSection) { $foundSection = $true }
            $seen = @{}
            $out.Add($line)
            continue
        }
        if ($inSection) {
            $m = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=')
            if ($m.Success -and $Want.Contains($m.Groups[1].Value)) {
                $key = $m.Groups[1].Value
                if (-not $seen[$key]) { $out.Add("$key = $($Want[$key])") }
                $seen[$key] = $true
                continue
            }
        }
        $out.Add($line)
    }
    if ($inSection) {
        foreach ($key in $Want.Keys) { if (-not $seen[$key]) { $out.Add("$key = $($Want[$key])") } }
    }
    if (-not $foundSection) {
        $out.Add('')
        $out.Add("[$Section]")
        foreach ($key in $Want.Keys) { $out.Add("$key = $($Want[$key])") }
    }
    Write-TextLines $IniPath $out
}

$settingsIni = Join-Path $ue4ssDir "UE4SS-settings.ini"
# 本作的可执行文件中不包含引擎版本字符串，UE4SS 无法自动判定版本，将按默认版本扫描并导致游戏崩溃。
# 该项是整套方案可运行的前提（并非可选优化），因此每次安装均强制写入 4/27。
Set-IniValues $settingsIni "EngineVersionOverride" ([ordered]@{
    MajorVersion = '4'
    MinorVersion = '27'
})
# 同属必需项：本作为定制版 UE4.27，UE4SS 默认开启的若干 hook 会破坏堆内存，
# 表现为游戏在 30 秒至数分钟内无提示退出；实测仅保留以下两项即可稳定运行。
Set-IniValues $settingsIni "Hooks" ([ordered]@{
    HookProcessInternal                 = '1'
    HookProcessLocalScriptFunction      = '0'
    HookInitGameState                   = '0'
    HookCallFunctionByNameWithArguments = '1'
    HookBeginPlay                       = '0'
    HookLocalPlayerExec                 = '0'
})
Write-Ok "已确认 UE4SS 配置（EngineVersionOverride = 4.27 + 稳定 hook 组合）"

} # end hasRuntime

Write-Step "写入 UE4SS 内置 mod 清单（含蓝图 mod 加载器）"
$modsTxt = Join-Path $ue4ssDir "Mods\mods.txt"
New-Item -ItemType Directory -Force -Path (Join-Path $ue4ssDir "Mods") | Out-Null
if (-not (Test-Path -LiteralPath $modsTxt)) {
    # 仅登记本包 runtime 中实际存在的 mod：登记未随包提供的名称会导致 UE4SS 报「mod not found」
    $lines = @(
        "CheatManagerEnablerMod : 1",
        "ConsoleCommandsMod : 1",
        "ConsoleEnablerMod : 1",
        "BPModLoaderMod : 1",
        "",
        "; Built-in keybinds, do not move up!",
        "Keybinds : 1"
    )
    Write-TextLines $modsTxt $lines
    Write-Ok "已生成 mods.txt"
}
Write-Ok "已启用：控制台 / 作弊管理器 / BPModLoaderMod（第三方 pak 蓝图 mod 依赖后者加载）"

# 第三方 pak mod（例如 LevelSelector.pak 及其前置包）自动装入 LogicMods
$paksSource = Join-Path $scriptRoot "paks"
if (Test-Path -LiteralPath $paksSource) {
    $pakFiles = @(Get-ChildItem -LiteralPath $paksSource -Filter "*.pak" -File -ErrorAction SilentlyContinue)
    if ($pakFiles.Count -gt 0) {
        Write-Step "安装第三方 pak mod（$($pakFiles.Count) 个）"
        $logicMods = Join-Path $GameDir "EscapeTheBackrooms\Content\Paks\LogicMods"
        New-Item -ItemType Directory -Force -Path $logicMods | Out-Null
        foreach ($pak in $pakFiles) {
            Copy-Item -LiteralPath $pak.FullName -Destination (Join-Path $logicMods $pak.Name) -Force
            Write-Ok $pak.Name
        }
        Write-Ok "已装入 $logicMods（BPModLoaderMod 会加载它们）"
    }
}

# --------------------------------------------------------- 2. ETB_HostKit
Write-Step "部署 ETB_HostKit"
$target = Join-Path $modsDir "ETB_HostKit"
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -LiteralPath (Join-Path $modSource "ETB_HostKit\Scripts") -Destination $target -Recurse -Force
Copy-Item -LiteralPath (Join-Path $modSource "ETB_HostKit\enabled.txt") -Destination $target -Force

# 此处必须使用字符串插值。若写成 "..." + $GameDir + "..." 再放入 @()，
# PowerShell 中逗号的优先级高于加号，会将一个元素拆成三个（落盘为 [[ / 路径 / ]], 三行）。
# lua 侧的 clean_path 虽能容错，但属巧合，不应依赖。
$pathsLua = @(
    "return {",
    "    game_dir = [[$GameDir]],",
    "    bin_dir  = [[$binDir]],",
    "    mods_dir = [[$modsDir]],",
    "}"
)
Write-TextLines (Join-Path $target "Scripts\GamePaths.lua") $pathsLua
Write-Ok $target

# -MaxPlayers 需同步写入 main.lua：mod 内部另有一份 CONFIG.max_players（默认 12）。
# 仅修改 Game.ini 会导致大厅滑块显示 12、实际建房按 8 人开启的前后不一致。
$luaMain = Join-Path $target "Scripts\main.lua"
if (Test-Path -LiteralPath $luaMain) {
    $luaText = [System.IO.File]::ReadAllText($luaMain)
    $luaNew = ([regex]'(?m)^(\s*max_players\s*=\s*)\d+').Replace($luaText, ('${1}' + $MaxPlayers), 1)
    if ($luaNew -ne $luaText) {
        [System.IO.File]::WriteAllText($luaMain, $luaNew, $Utf8NoBom)
        Write-Ok "main.lua 中的目标人数已同步为 $MaxPlayers"
    } else {
        Write-Warn2 "未能在 main.lua 中定位 max_players，人数以 config\Game.ini 为准"
    }
}

$modsTxt = Join-Path $modsDir "mods.txt"
if (-not (Test-Path -LiteralPath $modsTxt)) { throw "缺少 $modsTxt" }
$lines = [System.Collections.Generic.List[string]]::new()
foreach ($line in (Read-TextLines $modsTxt)) { $lines.Add($line) }
$already = $false
foreach ($line in $lines) { if ($line -match "^\s*ETB_HostKit\s*:") { $already = $true; break } }
if ($already) {
    Write-Ok "mods.txt 已包含 ETB_HostKit"
} else {
    $index = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*Keybinds\s*:") { $index = $i; break } }
    if ($index -ge 0) { $lines.Insert($index, "ETB_HostKit : 1") } else { $lines.Add("ETB_HostKit : 1") }
    Write-TextLines $modsTxt $lines
    Write-Ok "mods.txt 增加 ETB_HostKit : 1"
}

# ------------------------------------------------------------ 3. 网络参数
function Write-IniBlock([string]$IniPath, [string]$SnippetPath) {
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $IniPath))) {
        Write-Warn2 "未找到配置目录，跳过 $([System.IO.Path]::GetFileName($IniPath))"
        return
    }
    if ((Test-Path -LiteralPath $IniPath) -and -not (Test-Path -LiteralPath "$IniPath.etb-mod.bak")) {
        Copy-Item -LiteralPath $IniPath -Destination "$IniPath.etb-mod.bak"
    }
    $begin = "; ETB-MOD BEGIN"
    $end = "; ETB-MOD END"
    # 以下键仅由本安装脚本写入，重复安装时先移除旧值，避免不断累积
    $managedKeys = @(
        'MaxPlayers',
        'ClientNetSendMoveThrottleOverPlayerCount',
        'ClientNetSendMoveThrottleAtNetSpeed',
        'MaxClientRate',
        'MaxInternetClientRate',
        'NetServerMaxTickRate'
    )
    $kept = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in (Read-TextLines $IniPath)) {
        if ($line.Trim() -eq $begin) { $inside = $true; continue }
        if ($line.Trim() -eq $end) { $inside = $false; continue }
        if ($inside) { continue }
        $m = [regex]::Match($line.Trim(), '^([A-Za-z_][A-Za-z0-9_]*)\s*=')
        if ($m.Success -and ($managedKeys -contains $m.Groups[1].Value)) { continue }
        $kept.Add($line)
    }
    # 同时移除内容为空的 section
    $trimmed = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $kept.Count; $i++) {
        $line = $kept[$i]
        if ($line.Trim() -match '^\[.*\]$') {
            $hasBody = $false
            for ($j = $i + 1; $j -lt $kept.Count; $j++) {
                $next = $kept[$j].Trim()
                if ($next -match '^\[.*\]$') { break }
                if ($next -ne '' -and -not $next.StartsWith(';')) { $hasBody = $true; break }
            }
            if (-not $hasBody) { continue }
        }
        $trimmed.Add($line)
    }
    $kept = $trimmed
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
    $kept.Add("")
    $kept.Add($begin)
    foreach ($line in (Read-TextLines $SnippetPath)) {
        if ($line -match "^\s*MaxPlayers\s*=") { $kept.Add("MaxPlayers=$MaxPlayers"); continue }
        $kept.Add($line)
    }
    $kept.Add($end)
    Write-TextLines $IniPath $kept
    Write-Ok "已写入 $IniPath"
}

if (-not $SkipIni) {
    $configDir = Join-Path $env:LOCALAPPDATA "EscapeTheBackrooms\Saved\Config\WindowsNoEditor"
    Write-Step "写入网络参数（GameSession.MaxPlayers=$MaxPlayers 等）"
    Write-IniBlock (Join-Path $configDir "Game.ini") $iniSnippet
}

Write-Host ""
Write-Host "安装完成。重启游戏后生效（UE4SS 仅在游戏启动时注入）。" -ForegroundColor Green

# 桌面快捷方式：一键打开可视化控制台
try {
    $panelVbs = Join-Path $scriptRoot "HostPanel.vbs"
    $panelBat = Join-Path $scriptRoot "HostPanel.bat"
    if ((Test-Path -LiteralPath $panelVbs) -or (Test-Path -LiteralPath $panelBat)) {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktop "ETB 控制台.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        if (Test-Path -LiteralPath $panelVbs) {
            # 通过 wscript 执行 .vbs，可完全不出现命令行窗口
            $shortcut.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
            $shortcut.Arguments = '"' + $panelVbs + '"'
        } else {
            $shortcut.TargetPath = $panelBat
        }
        $shortcut.WorkingDirectory = $scriptRoot
        $shortcut.WindowStyle = 7
        $shortcut.Description = "Escape The Backrooms 房主控制台（无窗口启动，游戏内按 F6 显示/隐藏）"

        # 图标优先使用游戏自身的图标（与游戏快捷方式一致），否则使用包内附带的二创图标
        $iconCandidates = @(
            (Join-Path $GameDir "Backrooms.exe"),
            (Join-Path $GameDir "EscapeTheBackrooms\Binaries\Win64\Backrooms-Win64-Shipping.exe"),
            (Join-Path $scriptRoot "logo.ico")
        )
        foreach ($iconSource in $iconCandidates) {
            if (Test-Path -LiteralPath $iconSource) {
                $shortcut.IconLocation = "$iconSource,0"
                break
            }
        }
        $shortcut.Save()
        Write-Ok "已创建桌面快捷方式：ETB 控制台"
    }
} catch {
    Write-Warn2 "创建快捷方式失败（不影响使用，可直接双击 HostPanel.bat）：$($_.Exception.Message)"
}
Write-Host ""
Write-Host "房主操作：" -ForegroundColor Green
Write-Host "  F6                 显示 / 收起桌面控制台（桌面上的 ETB 控制台窗口）"
Write-Host "  F10                游戏内控制台 -> etb_hub 查看状态；etb_help 查看全部命令"
Write-Host "  Ctrl+F9            全员集合到房主"
Write-Host "  Ctrl+Shift+F9      全员传送进出口区域（触发同时过关）"
Write-Host "  Ctrl+Shift+F10     跳过当前关卡"
Write-Host "  Ctrl+Shift+F11     列出关卡"
Write-Host "  Ctrl+Shift+F12     状态"
Write-Host ""
Write-Host "自检: check.bat    卸载: 卸载.bat（或 uninstall.bat）" -ForegroundColor DarkGray
Write-Host "游戏更新后建议重新执行一次 check.bat。" -ForegroundColor DarkGray
