<#
    卸载 ETB-HostKit（Escape The Backrooms 房主 mod）

    默认依次完成四项操作：
      1. 删除 ue4ss\Mods\ETB_HostKit（旧版布局的 Mods\ETB_HostKit 一并清理）
      2. 从 mods.txt 中移除登记项，并清理面板文件、UE4SS.log、cache 等附带产物
      3. 将 Game.ini / Engine.ini 还原为安装前的状态
      4. 删除桌面上的 ETB 控制台快捷方式

    默认保留 UE4SS 运行时（第三方 pak mod 可能仍在使用）。
    加 -RemoveUE4SS 可一并清除运行时（dwmapi.dll + ue4ss 目录，游戏本体不包含这些文件）。
    默认将被删除的内容移动到备份目录而非直接删除，加 -Purge 才真正删除。
    备份目录：%LOCALAPPDATA%\EscapeTheBackrooms\ETB-uninstall-backup
#>
[CmdletBinding()]
param(
    [string]$GameDir = "",
    [switch]$RemoveUE4SS,
    [switch]$Purge
)

$ErrorActionPreference = "Stop"
$scriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$stashRoot   = Join-Path $env:LOCALAPPDATA "EscapeTheBackrooms\ETB-uninstall-backup"
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host "    $Text" -ForegroundColor DarkGray }
function Write-Warn2([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

$script:StashIndex = 0

# 将文件或目录移入备份或直接删除（目录连同内容一并处理）
function Remove-Target([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($Purge) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Note "已删除 $Label"
        return $true
    }
    New-Item -ItemType Directory -Force -Path $stashRoot | Out-Null
    $script:StashIndex = $script:StashIndex + 1
    $safe = ($Label -replace '[\\/:*?"<>|]', '_')
    $dest = Join-Path $stashRoot ("{0:00}_{1}" -f $script:StashIndex, $safe)
    Move-Item -LiteralPath $Path -Destination $dest -Force
    Write-Note "已移除 $Label（备份在 $dest）"
    return $true
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
    foreach ($root in @("D:\steam", "C:\Program Files (x86)\Steam", "C:\Program Files\Steam")) {
        if (Test-Path -LiteralPath $root) { $steamRoots.Add($root) }
    }
    foreach ($root in $steamRoots) {
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $libPath = $match.Groups[1].Value -replace '\\\\', '\'
            $candidates.Add((Join-Path $libPath "steamapps\common\EscapeTheBackrooms"))
        }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        # 游戏目录内还嵌套一层同名目录，可执行文件位于第二层的 Binaries\Win64 下
        if (Test-Path -LiteralPath (Join-Path $candidate $expectedExe)) { return $candidate }
    }
    return $null
}

# 移除 mods.txt 中的登记行
function Remove-ModsTxtEntry([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @([System.IO.File]::ReadAllLines($Path) | Where-Object { $_ -notmatch '^\s*ETB_HostKit\s*:' })
    [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), $Utf8NoBom)
    Write-Note "mods.txt 已清理：$Path"
}

# Game.ini / Engine.ini：优先还原安装前备份；备份缺失时仅清理本工具写入的节和值。

# 在移除 mod 之前读取安装时写入 Lua 的人数。Game.ini 的备份可能被游戏更新或清理工具删除，
# 此时需要依据实际安装值清理，而不能仅假定默认的 12 人。
function Get-InstalledMaxPlayers($Dirs) {
    foreach ($dir in $Dirs) {
        $lua = Join-Path $dir 'ETB_HostKit\Scripts\main.lua'
        if (-not (Test-Path -LiteralPath $lua)) { continue }
        $content = [System.IO.File]::ReadAllText($lua)
        $match = [regex]::Match($content, '(?m)^\s*max_players\s*=\s*(\d+)')
        if ($match.Success) {
            $value = [int]$match.Groups[1].Value
            if ($value -ge 2 -and $value -le 32) { return $value }
        }
    }
    return 12
}

function Fix-IniFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $bak = "$Path.etb-mod.bak"
    if (Test-Path -LiteralPath $bak) {
        Copy-Item -LiteralPath $bak -Destination $Path -Force
        Remove-Target $bak ((Split-Path -Leaf $Path) + ".etb-mod.bak") | Out-Null
        Write-Note "已还原 $(Split-Path -Leaf $Path)（安装前备份）"
        return
    }
    # 当前安装器只写 Game.ini；没有备份的 Engine.ini 不应被猜测性清理。
    if ((Split-Path -Leaf $Path) -ne 'Game.ini') { return }
    $managedValues = @{
        '[/Script/Engine.GameSession]' = @{ MaxPlayers = "$script:InstalledMaxPlayers" }
        '[/Script/Engine.GameNetworkManager]' = @{
            ClientNetSendMoveThrottleOverPlayerCount = '16'
            ClientNetSendMoveThrottleAtNetSpeed = '20000'
        }
        '[/Script/OnlineSubsystemUtils.IpNetDriver]' = @{
            MaxClientRate = '250000'
            MaxInternetClientRate = '250000'
            NetServerMaxTickRate = '30'
        }
    }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    $changed = $false
    $out = New-Object System.Collections.Generic.List[string]
    $section = ''
    $insideBlock = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '; ETB-MOD BEGIN') { $insideBlock = $true; $changed = $true; continue }
        if ($trimmed -eq '; ETB-MOD END') { $insideBlock = $false; $changed = $true; continue }
        if ($insideBlock) { $changed = $true; continue }
        if ($trimmed -match '^\[.*\]$') { $section = $trimmed }
        $m = [regex]::Match($trimmed, '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$')
        if ($m.Success -and $managedValues.ContainsKey($section)) {
            $key = $m.Groups[1].Value
            if ($managedValues[$section].ContainsKey($key) -and
                $m.Groups[2].Value -eq $managedValues[$section][$key]) {
                $changed = $true
                continue
            }
        }
        $out.Add($line)
    }
    if (-not $changed) { Write-Note "$(Split-Path -Leaf $Path) 中未发现本工具写入的内容"; return }
    # 移除内容为空的 section
    $final = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $out.Count; $i++) {
        $line = $out[$i]
        if ($line.Trim() -match '^\[.*\]$') {
            $hasBody = $false
            for ($j = $i + 1; $j -lt $out.Count; $j++) {
                $next = $out[$j].Trim()
                if ($next -match '^\[.*\]$') { break }
                if ($next -ne '' -and -not $next.StartsWith(';')) { $hasBody = $true; break }
            }
            if (-not $hasBody) { continue }
        }
        $final.Add($line)
    }
    while ($final.Count -gt 0 -and [string]::IsNullOrWhiteSpace($final[$final.Count - 1])) { $final.RemoveAt($final.Count - 1) }
    [System.IO.File]::WriteAllText($Path, (($final -join "`r`n") + "`r`n"), $Utf8NoBom)
    Write-Note "已清除 $(Split-Path -Leaf $Path) 中本工具写入的网络参数"
}

# ------------------------------------------------------------------ 执行
$GameDir = Resolve-GameDir $GameDir
if (-not $GameDir) { throw "未找到游戏目录，请用 -GameDir ""X:\steam\steamapps\common\EscapeTheBackrooms"" 指定" }
Write-Host "游戏目录: $GameDir" -ForegroundColor DarkGray

if (@(Get-Process -Name "Backrooms-Win64-Shipping" -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "游戏正在运行，请完全退出游戏后再执行卸载。"
}

$binDir  = Join-Path $GameDir "EscapeTheBackrooms\Binaries\Win64"
$ue4ssDir = Join-Path $binDir "ue4ss"
$modsDirs = @((Join-Path $ue4ssDir "Mods"), (Join-Path $binDir "Mods"))
$script:InstalledMaxPlayers = Get-InstalledMaxPlayers $modsDirs

Write-Step "移除 ETB_HostKit 本体"
foreach ($modsDir in $modsDirs) {
    Remove-Target (Join-Path $modsDir "ETB_HostKit") "ETB_HostKit（$modsDir）" | Out-Null
    Remove-ModsTxtEntry (Join-Path $modsDir "mods.txt")
}

Write-Step "清理附带的日志 / 缓存 / 面板文件"
foreach ($item in @(
    (Join-Path $binDir "UE4SS.log"),
    (Join-Path $ue4ssDir "UE4SS.log"),
    (Join-Path $binDir "cache"),
    (Join-Path $ue4ssDir "cache")
)) { Remove-Target $item (Split-Path -Leaf $item) | Out-Null }

Write-Step "还原配置文件"
$configDir = Join-Path $env:LOCALAPPDATA "EscapeTheBackrooms\Saved\Config\WindowsNoEditor"
Fix-IniFile (Join-Path $configDir "Game.ini")
Fix-IniFile (Join-Path $configDir "Engine.ini")

Write-Step "移除桌面快捷方式"
foreach ($desktop in @([Environment]::GetFolderPath("Desktop"), (Join-Path $env:PUBLIC "Desktop"))) {
    if (-not $desktop) { continue }
    foreach ($name in @("ETB 控制台.lnk", "ETB控制台.lnk")) {
        Remove-Target (Join-Path $desktop $name) $name | Out-Null
    }
}

if ($RemoveUE4SS) {
    Write-Step "移除 UE4SS 运行时"
    foreach ($name in @("dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini")) {
        $file = Join-Path $binDir $name
        if (Test-Path -LiteralPath "$file.etb-mod.bak") {
            Copy-Item -LiteralPath "$file.etb-mod.bak" -Destination $file -Force
            Remove-Target "$file.etb-mod.bak" ("$name.etb-mod.bak") | Out-Null
            Write-Note "已还原游戏原本的 $name"
        } else {
            Remove-Target $file $name | Out-Null
        }
    }
    foreach ($item in @(
        $ue4ssDir,
        # 旧版（v2.5.x）布局遗留的签名目录：当前运行时既不使用也不读取，
        # 但旧安装可能残留，一并清理
        (Join-Path $binDir "UE4SS_Signatures"),
        (Join-Path $binDir "Mods.old-layout-disabled")
    )) { Remove-Target $item (Split-Path -Leaf $item) | Out-Null }
    # 清理旧安装遗留的各类备份文件
    foreach ($file in @(Get-ChildItem -LiteralPath $binDir -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^UE4SS.*\.(bak|ini|dll)$' -or $_.Name -like '*.old-layout-disabled' -or $_.Name -like 'UE4SS-settings.*' })) {
        Remove-Target $file.FullName $file.Name | Out-Null
    }
    # pak mod 的加载目录（安装时创建）；为空时一并清除
    $logicMods = Join-Path $GameDir "EscapeTheBackrooms\Content\Paks\LogicMods"
    if ((Test-Path -LiteralPath $logicMods) -and (@(Get-ChildItem -LiteralPath $logicMods -Force).Count -eq 0)) {
        Remove-Target $logicMods "LogicMods（空目录）" | Out-Null
    }
}

Write-Host ""
Write-Host "卸载完成。" -ForegroundColor Green
if (-not $RemoveUE4SS) {
    $left = @()
    if (Test-Path -LiteralPath (Join-Path $binDir "dwmapi.dll")) { $left += "dwmapi.dll" }
    if (Test-Path -LiteralPath $ue4ssDir) { $left += "ue4ss 目录" }
    if ($left.Count -gt 0) {
        Write-Host ("UE4SS 运行时仍保留（" + ($left -join "、") + "）。") -ForegroundColor DarkGray
        Write-Host "如需恢复纯净的游戏目录，请再次执行：卸载.bat -RemoveUE4SS（或 uninstall.bat -RemoveUE4SS）" -ForegroundColor DarkGray
    }
}
if (-not $Purge -and (Test-Path -LiteralPath $stashRoot)) {
    Write-Host "被移除的内容已备份至：$stashRoot" -ForegroundColor DarkGray
    Write-Host "确认游戏运行正常后，该文件夹可直接删除。" -ForegroundColor DarkGray
}
