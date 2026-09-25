[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('ETB-HostKit-smoke-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temp)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Import-Function([string]$File, [string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "解析失败：$File" }
    $functions = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    if ($functions.Count -ne 1) { throw "未找到唯一函数：$Name ($File)" }
    return [scriptblock]::Create($functions[0].Extent.Text)
}

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "断言失败：$Message" }
}

try {
    foreach ($name in @('install.ps1', 'check.ps1', 'uninstall.ps1', 'HostPanel.ps1')) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name), [ref]$tokens, [ref]$errors) | Out-Null
        Assert (@($errors).Count -eq 0) "$name 语法"
    }

    foreach ($name in @('install.ps1', 'check.ps1', 'uninstall.ps1', 'HostPanel.ps1')) {
        . (Import-Function (Join-Path $root $name) 'Resolve-GameDir')
        Assert (-not (Resolve-GameDir (Join-Path $temp 'not-a-game'))) "$name 必须拒绝无效 -GameDir"
    }

    $installer = Join-Path $root 'install.ps1'
    . (Import-Function $installer 'Read-TextLines')
    . (Import-Function $installer 'Write-TextLines')
    . (Import-Function $installer 'Set-IniValues')
    $settings = Join-Path $temp 'UE4SS-settings.ini'
    [System.IO.File]::WriteAllText($settings, "[Hooks]`nHookProcessInternal = 0`nHookProcessInternal = 0`n", $Utf8NoBom)
    Set-IniValues $settings 'Hooks' ([ordered]@{HookProcessInternal='1'; HookBeginPlay='0'})
    Set-IniValues $settings 'EngineVersionOverride' ([ordered]@{MajorVersion='4'; MinorVersion='27'})
    $result = [System.IO.File]::ReadAllText($settings)
    Assert ([regex]::Matches($result, '(?m)^HookProcessInternal\s*=').Count -eq 1) '重复 hook 应去重'
    Assert ($result -match '(?m)^HookBeginPlay\s*=\s*0\r?$') '缺失 hook 应补齐'
    Assert ($result -match '(?m)^\[EngineVersionOverride\]\r?$') '缺失配置节应创建'
    Assert ($result -match '(?m)^MinorVersion\s*=\s*27\r?$') '引擎版本应写入'

    $uninstaller = Join-Path $root 'uninstall.ps1'
    . (Import-Function $uninstaller 'Get-InstalledMaxPlayers')
    . (Import-Function $uninstaller 'Fix-IniFile')
    function Write-Note([string]$Text) { }
    $mods = Join-Path $temp 'Mods'
    $luaDir = Join-Path $mods 'ETB_HostKit\Scripts'
    [void][System.IO.Directory]::CreateDirectory($luaDir)
    [System.IO.File]::WriteAllText((Join-Path $luaDir 'main.lua'), '    max_players = 16,', $Utf8NoBom)
    $script:InstalledMaxPlayers = Get-InstalledMaxPlayers @($mods)
    Assert ($script:InstalledMaxPlayers -eq 16) '应读取自定义人数'
    $gameIni = Join-Path $temp 'Game.ini'
    [System.IO.File]::WriteAllText($gameIni, "[/Script/Engine.GameSession]`nMaxPlayers=16`nMaxPlayers=16`n[/Script/Engine.GameNetworkManager]`nClientNetSendMoveThrottleOverPlayerCount=16`n[/Unrelated]`nMaxPlayers=12`nMaxClientRate=250000`n", $Utf8NoBom)
    Fix-IniFile $gameIni
    $result = [System.IO.File]::ReadAllText($gameIni)
    Assert ($result -notmatch 'MaxPlayers\s*=\s*16') '无备份时应清理自定义人数和重复项'
    Assert ($result -notmatch 'ClientNetSendMoveThrottleOverPlayerCount\s*=') '无备份时应清理网络参数'
    Assert ($result -match '(?m)^MaxPlayers=12\r?$') '应保留其他配置节中的同名键'
    Assert ($result -match '(?m)^MaxClientRate=250000\r?$') '应保留其他配置节中的网络键'
    $engineIni = Join-Path $temp 'Engine.ini'
    [System.IO.File]::WriteAllText($engineIni, "[/Script/Engine.GameSession]`nMaxPlayers=16`n", $Utf8NoBom)
    Fix-IniFile $engineIni
    Assert ([System.IO.File]::ReadAllText($engineIni) -match 'MaxPlayers=16') '无备份的 Engine.ini 不应被修改'

    Write-Host 'smoke tests: PASS'
} catch {
    Write-Host $_.ScriptStackTrace
    throw
} finally {
    $resolved = [System.IO.Path]::GetFullPath($temp)
    if ($resolved.StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolved).StartsWith('ETB-HostKit-smoke-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
