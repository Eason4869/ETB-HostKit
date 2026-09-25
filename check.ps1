<#
    检查 ETB-HostKit 的安装状态，以及上次启动游戏时 mod 是否加载成功。
    只需关注最终结论：全部正常，或需要重新执行一键安装。
#>
[CmdletBinding()]
param([string]$GameDir = "")

$ErrorActionPreference = "Stop"

function Check([string]$Label, [bool]$Ok, [string]$Detail = "") {
    if ($Ok) { Write-Host ("[ OK ] " + $Label + " " + $Detail) -ForegroundColor Green }
    else {
        $script:problems++
        Write-Host ("[ 缺 ] " + $Label + " " + $Detail) -ForegroundColor Red
    }
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
    foreach ($root in @("D:\steam", "C:\Program Files (x86)\Steam", "C:\Program Files\Steam")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $libPath = $match.Groups[1].Value -replace '\\\\', '\'
            $candidates.Add((Join-Path $libPath "steamapps\common\EscapeTheBackrooms"))
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate $expectedExe))) { return $candidate }
    }
    return $null
}

$GameDir = Resolve-GameDir $GameDir
if (-not $GameDir) { throw "未找到游戏目录，请用 -GameDir ""X:\steam\steamapps\common\EscapeTheBackrooms"" 指定" }
$binDir  = Join-Path $GameDir "EscapeTheBackrooms\Binaries\Win64"
$ue4ssDir = Join-Path $binDir "ue4ss"
Write-Host "游戏目录: $GameDir`n" -ForegroundColor DarkGray

$problems = 0
function Note([string]$Text) { Write-Host "        $Text" -ForegroundColor DarkGray }

Check "游戏本体 Backrooms-Win64-Shipping.exe" (Test-Path -LiteralPath (Join-Path $binDir "Backrooms-Win64-Shipping.exe"))

$ue4ssDll = Join-Path $ue4ssDir "UE4SS.dll"
Check "ue4ss\UE4SS.dll" (Test-Path -LiteralPath $ue4ssDll)
if (Test-Path -LiteralPath $ue4ssDll) {
    $size = (Get-Item -LiteralPath $ue4ssDll).Length
    if ($size -eq 20572160) { Note "版本：UE4SS v3.0.1 Beta #0 experimental（本包附带，本作实测可用）" }
    elseif ($size -eq 7635456) { Note "版本：UE4SS v2.5.2，本作会在特征码扫描阶段卡住，请重新执行一键安装"; $problems++ }
    else { Note "版本：大小为 $size，并非本包附带的版本，请重新执行一键安装"; $problems++ }
}

Check "dwmapi.dll（负责将 UE4SS 注入游戏）" (Test-Path -LiteralPath (Join-Path $binDir "dwmapi.dll"))
$modMain = Join-Path $ue4ssDir "Mods\ETB_HostKit\Scripts\main.lua"
Check "Mods\ETB_HostKit\Scripts\main.lua" (Test-Path -LiteralPath $modMain)
$gamePaths = Join-Path $ue4ssDir "Mods\ETB_HostKit\Scripts\GamePaths.lua"
Check "mod 可自行定位游戏路径（GamePaths.lua）" (Test-Path -LiteralPath $gamePaths)

$modsTxt = Join-Path $ue4ssDir "Mods\mods.txt"
if (Test-Path -LiteralPath $modsTxt) {
    $text = [System.IO.File]::ReadAllText($modsTxt)
    $registered = $text -match "(?m)^\s*ETB_HostKit\s*:"
    Check "mods.txt 中已登记 ETB_HostKit" $registered
} else {
    Check "mods.txt" $false "文件不存在"
}

$settings = Join-Path $ue4ssDir "UE4SS-settings.ini"
if (Test-Path -LiteralPath $settings) {
    $ini = [System.IO.File]::ReadAllText($settings)
    $safeHooks = ($ini -match 'HookProcessInternal\s*=\s*1') -and ($ini -match 'HookProcessLocalScriptFunction\s*=\s*0')
    Check "hook 配置为稳定组合（其余 hook 开启会导致闪退）" $safeHooks
} else {
    Check "UE4SS-settings.ini" $false "文件不存在"
}

# 游戏会重写 Game.ini，写入的注释（; ETB-MOD BEGIN/END）会被引擎清除，
# 因此不能依据注释判断是否安装过，只能按键名检查。
$ETB_INI_KEYS = @(
    'MaxPlayers',
    'ClientNetSendMoveThrottleOverPlayerCount',
    'ClientNetSendMoveThrottleAtNetSpeed',
    'MaxClientRate',
    'MaxInternetClientRate',
    'NetServerMaxTickRate'
)
$gameIni = Join-Path $env:LOCALAPPDATA "EscapeTheBackrooms\Saved\Config\WindowsNoEditor\Game.ini"
if (-not (Test-Path -LiteralPath $gameIni)) {
    Check "Game.ini（联机参数写在这里）" $false
    Note "该文件尚不存在：请先启动一次游戏，再重新执行一次一键安装.bat"
} else {
    $ini = [System.IO.File]::ReadAllText($gameIni)
    $missing = @()
    foreach ($key in $ETB_INI_KEYS) {
        if ($ini -notmatch ("(?m)^\s*" + $key + "\s*=")) { $missing += $key }
    }
    if ($missing.Count -eq 0) {
        Check "Game.ini 中的联机参数" $true "（6 项均已写入）"
    } else {
        Check "Game.ini 中的联机参数" $false ("缺失: " + ($missing -join " "))
        Note "重新执行一次一键安装.bat 即可补齐"
    }
    # 重复的键以最后一条生效（游戏重写 ini 时不会合并重复项，多次安装会不断累积）
    $m = [regex]::Matches($ini, "(?m)^\s*MaxPlayers\s*=\s*(\d+)")
    if ($m.Count -gt 0) {
        Note "当前人数上限: $($m[$m.Count - 1].Groups[1].Value)"
        if ($m.Count -gt 1) { Note "（文件中共有 $($m.Count) 条 MaxPlayers，以最后一条为准）" }
    } else {
        Note "未找到 MaxPlayers：建房上限将回退为游戏默认的 4 人"
    }
}

$log = Join-Path $ue4ssDir "UE4SS.log"
Write-Host ""
if (-not (Test-Path -LiteralPath $log)) {
    Write-Host "尚未生成 UE4SS.log：安装完成后需先启动一次游戏，再回到此处查看。" -ForegroundColor Yellow
} else {
    $content = [System.IO.File]::ReadAllText($log)
    $loaded = $content -match "Starting Lua mod 'ETB_HostKit'"
    Check "上次启动时 mod 已成功加载" $loaded
    Check "面板驱动正常（已收到帧回调）" ($content -match "panel driver: first frame tick received")
    if ($content -match "Found StaticConstructObject_Internal") {
        Note "签名：UE4SS 内置特征码扫描已定位 StaticConstructObject_Internal（正常，无需签名文件）"
    } elseif ($content -match "AOB scans could not be completed|StaticConstructObject_Internal") {
        Note "签名：内置特征码扫描未命中；若游戏刚更新过，请重新执行一键安装.bat。仍无法解决请提供 UE4SS.log"
        Check "UE4SS 内置特征码扫描" $false
    }
    if ($content -match "error in |panel command failed") {
        Write-Host "        日志中存在报错行，可搜索 'error in' 查看：" -ForegroundColor Yellow
        foreach ($line in (($content -split "`r?`n") | Where-Object { $_ -match "error in " } | Select-Object -Last 3)) { Write-Host "          $line" -ForegroundColor DarkYellow }
    }
    Note "最后 5 行:"
    foreach ($line in (($content -split "`r?`n") | Select-Object -Last 5)) { Note $line }
}

Write-Host ""
if ($problems -eq 0) { Write-Host "检查结果：未发现问题。" -ForegroundColor Green }
else { Write-Host "检查结果：有 $problems 项不符合预期，通常重新执行一次一键安装.bat 即可解决。" -ForegroundColor Yellow }
