[CmdletBinding()]
param([string]$Revision = '')

# Exercise the real panel timer callback with a dialog probe that pumps the
# WinForms message loop. This reproduces modal reentry without showing windows.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
using System.Windows.Forms;

public static class ETBUpdateDialogProbe
{
    public static int Count;
    public static DialogResult Show(params object[] arguments)
    {
        Count++;
        if (Count > 1) return DialogResult.No;
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < 1200)
        {
            Application.DoEvents();
            Thread.Sleep(10);
        }
        return DialogResult.No;
    }
}
'@

if ($Revision) {
    $source = (git -C $root show "${Revision}:HostPanel.ps1") -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read baseline revision.' }
} else {
    $source = [System.IO.File]::ReadAllText((Join-Path $root 'HostPanel.ps1'))
}
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw 'Panel syntax error.' }
$timerCalls = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -eq '$refreshTimer' -and $node.Member.Value -eq 'Add_Tick'
}, $true))
if ($timerCalls.Count -ne 1) { throw 'Expected one refresh timer callback.' }
$body = $timerCalls[0].Arguments[0].ScriptBlock.Extent.Text
$body = $body.Substring(1, $body.Length - 2).Replace(
    '[System.Windows.Forms.MessageBox]::Show', '[ETBUpdateDialogProbe]::Show')
$callback = [scriptblock]::Create($body)

function Read-State { return @{} }
$versionMatch = [regex]::Match($source, '\$script:PanelVersion\s*=\s*"(\d+\.\d+\.\d+)"')
if (-not $versionMatch.Success) { throw 'Panel version missing.' }
$script:PanelVersion = $versionMatch.Groups[1].Value
$script:ActiveModVersion = $null
$ThemeWarn = [System.Drawing.Color]::Gold
$form = New-Object System.Windows.Forms.Form
$script:UpdateButton = New-Object System.Windows.Forms.Button
$script:VersionLabel = New-Object System.Windows.Forms.Label
$script:HookDot = New-Object System.Windows.Forms.Label
$script:Footer = New-Object System.Windows.Forms.Label
$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 100
$refreshTimer.Add_Tick({
    $script:TickCount++
    try { & $callback } catch { $script:TickErrors.Add($_.Exception.Message) }
})

try {
    # A second same-version request also verifies that checking again is possible.
    foreach ($scenario in @('current', 'newer', 'failed', 'current')) {
        [ETBUpdateDialogProbe]::Count = 0
        $script:TickCount = 0
        $script:TickErrors = New-Object System.Collections.Generic.List[string]
        $script:UpdateButton.Enabled = $false
        $script:UpdateButton.Text = 'checking'
        $script:UpdateJob = Start-Job -ArgumentList $scenario, $script:PanelVersion -ScriptBlock {
            param($Scenario, $Current)
            if ($Scenario -eq 'failed') { throw 'Simulated network failure' }
            $version = if ($Scenario -eq 'newer') { '99.0.0' } else { $Current }
            [pscustomobject]@{
                Version = $version
                Tag = 'v' + $version
                Url = 'https://github.com/Eason4869/ETB-HostKit/releases/tag/v' + $version
            }
        }
        $jobId = $script:UpdateJob.Id
        if (-not (Wait-Job -Job $script:UpdateJob -Timeout 20)) { throw 'Test job timed out.' }
        $refreshTimer.Start()
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt 4000 -and
            ($script:UpdateJob -or -not $script:UpdateButton.Enabled)) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }
        $refreshTimer.Stop()
        if ([ETBUpdateDialogProbe]::Count -ne 1) {
            throw "$scenario displayed $([ETBUpdateDialogProbe]::Count) dialogs; expected exactly one."
        }
        if ($script:TickCount -lt 2) { throw 'The test did not exercise timer reentry.' }
        if ($script:TickErrors.Count) { throw ($script:TickErrors -join '; ') }
        if ($script:UpdateJob -or -not $script:UpdateButton.Enabled) { throw 'Update controls did not reset.' }
        if (Get-Job -Id $jobId -ErrorAction SilentlyContinue) { throw 'Completed job was not removed.' }
        Write-Host "$scenario : PASS (one dialog, $($script:TickCount) timer ticks)"
    }
} finally {
    $refreshTimer.Stop()
    $refreshTimer.Dispose()
    if ($script:UpdateJob) { Remove-Job -Job $script:UpdateJob -Force }
    foreach ($control in @($script:UpdateButton, $script:VersionLabel, $script:HookDot, $script:Footer, $form)) {
        $control.Dispose()
    }
}
