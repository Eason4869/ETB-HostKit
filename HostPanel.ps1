<#
    Escape The Backrooms - 房主可视化控制台

    * 全局热键 F6：显示 / 隐藏本窗口
    * 通过文件与 mod 通信：面板写入 panel_command.txt，mod 每秒读取并执行；
      mod 将实时状态写回 panel_state.txt，面板每秒刷新。

    本文件必须保存为 UTF-8（含 BOM），否则 Windows PowerShell 5.1 无法正确解析中文。
#>
[CmdletBinding()]
param([string]$GameDir = "")

$ErrorActionPreference = "Stop"
$script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath = Join-Path $script:BaseDir "HostPanel.log"
$script:PosPath = Join-Path $script:BaseDir "HostPanel.pos"

function Write-PanelLog([string]$Text) {
    try { Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text) -Encoding UTF8 } catch { }
}

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 单实例保护：避免同时打开多个面板（会导致 F6 注册失败、命令重复发送）
$script:SingleInstance = New-Object System.Threading.Mutex($false, "Global\ETB_HostPanel_SingleInstance")
if (-not $script:SingleInstance.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show("控制台已在运行。`n`n按 F6 可显示 / 隐藏它。", "ETB 控制台") | Out-Null
    exit
}

Add-Type -Namespace ETB -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@

Add-Type -Namespace ETBWin -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
'@

# 使用原生 RegisterHotKey 注册全局热键（轮询方式会漏掉快速按键）
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ETBHotkeyForm : Form
{
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public event EventHandler HotkeyPressed;
    private bool registered = false;
    private int hotkeyId = 0xE7B;

    public bool RegisterHotkey(int virtualKey)
    {
        return RegisterHotkey(virtualKey, 0);
    }

    // modifiers: 0 = 无修饰键 / 0x1 = Alt / 0x2 = Ctrl / 0x3 = Ctrl+Alt
    public bool RegisterHotkey(int virtualKey, int modifiers)
    {
        registered = RegisterHotKey(this.Handle, hotkeyId, modifiers, virtualKey);
        return registered;
    }

    protected override void OnHandleDestroyed(EventArgs e)
    {
        if (registered) { UnregisterHotKey(this.Handle, hotkeyId); registered = false; }
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312)
        {
            var handler = HotkeyPressed;
            if (handler != null) { handler(this, EventArgs.Empty); }
        }
        base.WndProc(ref m);
    }
}
'@

$VK_F6 = 0x75

# ---------------------------------------------------------------- 路径探测
function Resolve-GameDir([string]$Hint) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Hint) { $candidates.Add($Hint) }
    $candidates.Add("D:\steam\steamapps\common\EscapeTheBackrooms")
    $candidates.Add("C:\Program Files (x86)\Steam\steamapps\common\EscapeTheBackrooms")
    $candidates.Add("C:\Program Files\Steam\steamapps\common\EscapeTheBackrooms")
    $steamRoots = New-Object System.Collections.Generic.List[string]
    try {
        $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name SteamPath -ErrorAction Stop).SteamPath
        if ($steamPath) { $steamRoots.Add($steamPath) }
    } catch { }
    if (Test-Path -LiteralPath "D:\steam") { $steamRoots.Add("D:\steam") }
    if (Test-Path -LiteralPath "C:\Program Files (x86)\Steam") { $steamRoots.Add("C:\Program Files (x86)\Steam") }
    foreach ($root in $steamRoots) {
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $libPath = $match.Groups[1].Value -replace '\\\\', '\'
            $candidates.Add((Join-Path $libPath "steamapps\common\EscapeTheBackrooms"))
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate "EscapeTheBackrooms\Binaries\Win64\Backrooms-Win64-Shipping.exe"))) {
            return $candidate
        }
    }
    return $null
}

$script:GameDir = Resolve-GameDir $GameDir
$script:Candidates = @()
if ($script:GameDir) {
    $bin = Join-Path $script:GameDir "EscapeTheBackrooms\Binaries\Win64"
    $script:Candidates += (Join-Path $bin "ue4ss\Mods\ETB_HostKit")
    $script:Candidates += (Join-Path $bin "Mods\ETB_HostKit")
}
$script:ModDir = $null
$script:StateFile = $null
$script:AliveFile = $null
$script:CmdFile = $null
$script:StateCache = $null      # 状态文件缓存（按修改时间判失效）
$script:StateStamp = $null

function Update-PanelPaths {
    # 已定位到目录后不再重复探测（每次 Test-Path 都会访问磁盘，游戏运行时开销明显）
    if ($script:StateFile -and (Test-Path -LiteralPath $script:StateFile)) { return }
    foreach ($dir in $script:Candidates) {
        $stateFile = Join-Path $dir "panel_state.txt"
        if (Test-Path -LiteralPath $stateFile) {
            $script:ModDir = $dir
            $script:StateFile = $stateFile
            $script:AliveFile = Join-Path $dir "panel_alive.txt"
            $script:CmdFile = Join-Path $dir "panel_command.txt"
            return
        }
    }
    if (-not $script:ModDir -and $script:Candidates.Count -gt 0) {
        $script:ModDir = $script:Candidates[0]
        $script:StateFile = Join-Path $script:ModDir "panel_state.txt"
        $script:AliveFile = Join-Path $script:ModDir "panel_alive.txt"
        $script:CmdFile = Join-Path $script:ModDir "panel_command.txt"
    }
}
Update-PanelPaths

# 启动时清空上次残留的指令，否则在游戏未运行时误点，会在下次进入游戏时被意外执行
if ($script:CmdFile -and (Test-Path -LiteralPath $script:CmdFile)) {
    try { [System.IO.File]::WriteAllText($script:CmdFile, "", (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function Send-PanelCommand([string]$Command) {
    Update-PanelPaths
    if (-not $script:CmdFile -or -not (Test-Path -LiteralPath $script:ModDir)) {
        $script:Footer.Text = "未找到 mod 目录，请先运行 一键安装.bat"
        return
    }
    # 必须使用不含 BOM 的 UTF-8 追加：PowerShell 的 Add-Content -Encoding UTF8 会写入 BOM，
    # 使清空后的第一条命令带 BOM 前缀而被 mod 忽略。
    [System.IO.File]::AppendAllText($script:CmdFile, $Command + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-PanelLog "send: $Command"
    $script:Footer.Text = "已发送：$Command"
    # 记录发送前的命令序号：mod 执行后会加 1，面板据此确认命令确实已执行
    $seqBefore = 0
    $stateNow = Read-State
    [void][int]::TryParse("$($stateNow['seq'])", [ref]$seqBefore)
    $script:Pending = @{ Command = $Command; Sent = (Get-Date); Seq = $seqBefore; Acked = $false }
}

function Test-ModAlive {
    # mod 每秒写入一次心跳文件；该操作仅访问文件、不涉及游戏对象，因此游戏卡顿或未正确安装时不会更新
    if (-not $script:AliveFile) { Update-PanelPaths }
    if (-not $script:AliveFile) { return $false }
    try {
        $stamp = [System.IO.File]::GetLastWriteTimeUtc($script:AliveFile)
        return (((Get-Date).ToUniversalTime()) - $stamp).TotalSeconds -lt 6
    } catch { return $false }
}

function Focus-Game {
    $proc = Get-Process -Name "Backrooms-Win64-Shipping" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $false }
    $handle = $proc.MainWindowHandle
    if ($handle -eq [IntPtr]::Zero) { return $false }
    if ([ETBWin.Native]::IsIconic($handle)) { [ETBWin.Native]::ShowWindow($handle, 9) | Out-Null }
    [ETBWin.Native]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 120
    return $true
}

# 文件通道无响应时，退回到「聚焦游戏窗口 + 发送快捷键」这条通道。
# 仅收录重复执行不会改变结果的命令：
#   prev / next_select 用于移动选择项、assist 为开关切换，重复发送会得到错误结果，故不收录；
#   切关命令为 "level N"（N 为选中序号），没有对应快捷键，无法映射。
#   skip 带 10 秒冷却，重复发送会被 mod 丢弃，可以收录。
$KEY_FALLBACK = @{
    "gather"       = "^({F9})"
    "exit"         = "^+({F9})"
    "skip"         = "^+({F10})"
    "status"       = "^+({F12})"
    "levels"       = "^+({F11})"
}

function Invoke-CommandFallback([string]$Command) {
    $keys = $KEY_FALLBACK[$Command]
    if (-not $keys) { return $false }
    if (-not (Focus-Game)) { return $false }
    try {
        [System.Windows.Forms.SendKeys]::SendWait($keys)
        Write-PanelLog "fallback key: $Command -> $keys"
        return $true
    } catch {
        Write-PanelLog "fallback failed: $($_.Exception.Message)"
        return $false
    }
}

function Read-State {
    # 仅在文件修改时间变化时重新解析；此前每次刷新都读取磁盘，游戏运行时会拖慢界面
    if (-not $script:StateFile) { Update-PanelPaths }
    if (-not $script:StateFile) { return @{} }
    try {
        $stamp = [System.IO.File]::GetLastWriteTimeUtc($script:StateFile)
    } catch {
        return @{}
    }
    if (($null -ne $script:StateCache) -and ($script:StateStamp -eq $stamp)) { return $script:StateCache }
    $state = @{}
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($script:StateFile)) {
            $key, $value = $line -split "=", 2
            if ($key) { $state[$key.Trim()] = "$value".Trim() }
        }
    } catch { return @{} }
    $script:StateStamp = $stamp
    $script:StateCache = $state
    return $state
}

# ---------------------------------------------------------------- 主题
$ThemeBg        = [System.Drawing.Color]::FromArgb(22, 24, 28)
$ThemeCard      = [System.Drawing.Color]::FromArgb(33, 37, 43)
$ThemeBtn       = [System.Drawing.Color]::FromArgb(45, 50, 58)
$ThemeBtnHover = [System.Drawing.Color]::FromArgb(60, 68, 80)
$ThemeAccent    = [System.Drawing.Color]::FromArgb(86, 182, 255)
$ThemeAccentDark  = [System.Drawing.Color]::FromArgb(40, 110, 170)
$ThemeOk        = [System.Drawing.Color]::FromArgb(120, 220, 150)
$ThemeWarn      = [System.Drawing.Color]::FromArgb(240, 200, 120)
$ThemeText      = [System.Drawing.Color]::FromArgb(236, 240, 245)
$ThemeMuted     = [System.Drawing.Color]::FromArgb(150, 158, 170)
$FONT_NAME = "Microsoft YaHei UI"

$LEVELS = @(
    "Level 0",
    "Habitable Zone",
    "Pipe Dreams",
    "Electrical Station",
    "Abandoned Office",
    "Terror Hotel",
    "Level Fun",
    "Poolrooms",
    "Level Run",
    "The End",
    "Level 94",
    "Lights Out",
    "Ocean Map",
    "Cave Level",
    "Level 05",
    "Level 9",
    "Level 10",
    "Level 3999",
    "Level 07",
    "Snackrooms",
    "Level Dash",
    "Level 188",
    "Poolrooms Expanded",
    "Level Fun Expanded",
    "Level 52",
    "Tunnel",
    "Bunker",
    "Level 922",
    "Level 974",
    "Graffiti Level",
    "Grassrooms",
    "Plastic Mariana",
    "Animated Kingdom",
    "The Hub",
    "Abandoned Base"
)

function New-FlatButton([string]$Text, [int]$Width, [int]$Height, [scriptblock]$OnClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = $Width
    $b.Height = $Height
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(62, 70, 82)
    $b.FlatAppearance.MouseOverBackColor = $ThemeBtnHover
    $b.FlatAppearance.MouseDownBackColor = $ThemeAccentDark
    $b.BackColor = $ThemeBtn
    $b.ForeColor = $ThemeText
    $b.Font = New-Object System.Drawing.Font($FONT_NAME, 9.5)
    $b.Cursor = "Hand"
    $b.Add_Click($OnClick)
    return $b
}

function New-Card([int]$X, [int]$Y, [int]$W, [int]$H) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($W, $H)
    $panel.BackColor = $ThemeCard
    return $panel
}

function New-Caption([string]$Text, [int]$X, [int]$Y, [int]$W) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, 20)
    $label.ForeColor = $ThemeAccent
    $label.Font = New-Object System.Drawing.Font($FONT_NAME, 9, [System.Drawing.FontStyle]::Bold)
    return $label
}

# ---------------------------------------------------------------- 窗体
$form = New-Object ETBHotkeyForm
$form.Text = "ETB 房主控制台   (F6 显示/隐藏)"
$form.ClientSize = New-Object System.Drawing.Size(430, 664)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "Manual"
$form.TopMost = $true
$form.BackColor = $ThemeBg
$form.ForeColor = $ThemeText
$form.Font = New-Object System.Drawing.Font($FONT_NAME, 9.5)

if (Test-Path -LiteralPath $script:PosPath) {
    try {
        $pos = [int[]]((Get-Content -LiteralPath $script:PosPath) -split ",")
        if ($pos.Count -eq 2) { $form.Location = New-Object System.Drawing.Point($pos[0], $pos[1]) }
    } catch { $form.Location = New-Object System.Drawing.Point(70, 60) }
} else {
    $form.Location = New-Object System.Drawing.Point(70, 60)
}

# 标题区域使用二创图标（logo.png，缺失时回退为文字）
$logoPath = Join-Path $script:BaseDir "logo.png"
if (Test-Path -LiteralPath $logoPath) {
    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Location = New-Object System.Drawing.Point(16, 6)
    $logoBox.Size = New-Object System.Drawing.Size(300, 52)
    $logoBox.SizeMode = "StretchImage"
    try { $logoBox.Image = [System.Drawing.Image]::FromFile($logoPath) } catch { }
    $form.Controls.Add($logoBox)
} else {
    $title = New-Object System.Windows.Forms.Label
    $title.Text = "房 主 控 制 台"
    $title.Location = New-Object System.Drawing.Point(16, 10)
    $title.Size = New-Object System.Drawing.Size(250, 30)
    $title.Font = New-Object System.Drawing.Font($FONT_NAME, 14, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $ThemeText
    $form.Controls.Add($title)
}

$iconPath = Join-Path $script:BaseDir "logo.ico"
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
}

$script:HookDot = New-Object System.Windows.Forms.Label
$script:HookDot.Text = "● 未连接"
$script:HookDot.Location = New-Object System.Drawing.Point(322, 10)
$script:HookDot.Size = New-Object System.Drawing.Size(92, 20)
$script:HookDot.TextAlign = "MiddleRight"
$script:HookDot.ForeColor = $ThemeWarn
$script:HookDot.Font = New-Object System.Drawing.Font($FONT_NAME, 8.5)
$form.Controls.Add($script:HookDot)

$line = New-Object System.Windows.Forms.Panel
$line.Location = New-Object System.Drawing.Point(16, 60)
$line.Size = New-Object System.Drawing.Size(398, 1)
$line.BackColor = [System.Drawing.Color]::FromArgb(52, 58, 68)
$form.Controls.Add($line)

# 状态卡
$stateCard = New-Card 16 72 398 76
$form.Controls.Add($stateCard)
$script:LevelText = New-Object System.Windows.Forms.Label
$script:LevelText.Text = "关卡：-"
$script:LevelText.Location = New-Object System.Drawing.Point(12, 8)
$script:LevelText.Size = New-Object System.Drawing.Size(374, 22)
$script:LevelText.Font = New-Object System.Drawing.Font($FONT_NAME, 10)
$script:LevelText.ForeColor = $ThemeText
$stateCard.Controls.Add($script:LevelText)
$script:MembersText = New-Object System.Windows.Forms.Label
$script:MembersText.Text = "人数：- / 上限 -"
$script:MembersText.Location = New-Object System.Drawing.Point(12, 30)
$script:MembersText.Size = New-Object System.Drawing.Size(200, 20)
$script:MembersText.ForeColor = $ThemeMuted
$stateCard.Controls.Add($script:MembersText)
$script:RoleText = New-Object System.Windows.Forms.Label
$script:RoleText.Text = "房主：-    自动护送：-"
$script:RoleText.Location = New-Object System.Drawing.Point(12, 50)
$script:RoleText.Size = New-Object System.Drawing.Size(374, 20)
$script:RoleText.ForeColor = $ThemeMuted
$stateCard.Controls.Add($script:RoleText)

# 最大人数
$form.Controls.Add((New-Caption "最大人数（建房前设置，含房主）" 18 158 300))
$playerCard = New-Card 16 180 398 46
$form.Controls.Add($playerCard)
$script:PlayerButtons = @{}
$x = 8
foreach ($n in 8, 12, 16, 24, 32) {
    $btn = New-FlatButton "$n" 68 30 { Send-PanelCommand ("set_max " + $this.Tag) }
    $btn.Tag = $n
    $btn.Location = New-Object System.Drawing.Point($x, 8)
    $playerCard.Controls.Add($btn)
    $script:PlayerButtons[$n] = $btn
    $x += 76
}

# 关卡
$form.Controls.Add((New-Caption "关卡选择与跳转" 18 236 300))
$levelCard = New-Card 16 258 398 116
$form.Controls.Add($levelCard)

$levelCombo = New-Object System.Windows.Forms.ComboBox
$levelCombo.Location = New-Object System.Drawing.Point(10, 10)
$levelCombo.Size = New-Object System.Drawing.Size(374, 26)
$levelCombo.DropDownStyle = "DropDownList"
$levelCombo.FlatStyle = "Flat"
$levelCombo.BackColor = $ThemeBtn
$levelCombo.ForeColor = $ThemeText
$levelCombo.Font = New-Object System.Drawing.Font($FONT_NAME, 10)
# 下拉列表最多展开 14 行、超出部分滚动显示（35 行全部展开时每次都需重算布局，响应明显变慢）
$levelCombo.IntegralHeight = $false
$levelCombo.MaxDropDownItems = 14
$levelCombo.DropDownHeight = 320
$levelNumber = 1
foreach ($name in $LEVELS) {
    [void]$levelCombo.Items.Add(("[{0}] {1}" -f $levelNumber, $name))
    $levelNumber++
}
$levelCombo.SelectedIndex = 0
$levelCard.Controls.Add($levelCombo)

$prevBtn = New-FlatButton "◀" 52 30 { Send-PanelCommand "prev" }
$prevBtn.Location = New-Object System.Drawing.Point(10, 44)
$levelCard.Controls.Add($prevBtn)
$nextBtn = New-FlatButton "▶" 52 30 { Send-PanelCommand "next_select" }
$nextBtn.Location = New-Object System.Drawing.Point(66, 44)
$levelCard.Controls.Add($nextBtn)
$goBtn = New-FlatButton "前往选中关卡" 132 30 {
    # 防连点：切图期间禁用按钮（连续切图会导致游戏崩溃）
    if ($script:TravelLocked) { return }
    $script:TravelLocked = $true
    $script:GoBtn.Text = "切图中…"
    $script:GoBtn.Enabled = $false
    $script:GoBtn.BackColor = $ThemeBtn
    $script:Footer.Text = "已发送：前往 " + $LEVELS[$levelCombo.SelectedIndex] + "（10 秒内不可再切）"
    Send-PanelCommand ("level " + ($levelCombo.SelectedIndex + 1))
    $script:TravelTimer = New-Object System.Windows.Forms.Timer
    $script:TravelTimer.Interval = 10000
    $script:TravelTimer.Add_Tick({
        $script:TravelTimer.Stop()
        $script:TravelLocked = $false
        $script:GoBtn.Text = "前往选中关卡"
        $script:GoBtn.Enabled = $true
        $script:GoBtn.BackColor = $ThemeAccentDark
    })
    $script:TravelTimer.Start()
}
$script:GoBtn = $goBtn
$script:TravelLocked = $false
$goBtn.Location = New-Object System.Drawing.Point(122, 44)
$goBtn.BackColor = $ThemeAccentDark
$levelCard.Controls.Add($goBtn)
$skipBtn = New-FlatButton "跳过当前关" 122 30 {
    # 与「前往选中关卡」共用冷却：连续切图或结算会导致引擎崩溃
    if ($script:TravelLocked) { return }
    $script:TravelLocked = $true
    $skipBtn.Enabled = $false
    $goBtn.Enabled = $false
    $goBtn.Text = "冷却中…"
    $script:Footer.Text = "已发送：跳过当前关（10 秒内不可再切图）"
    Send-PanelCommand "skip"
    $script:TravelTimer = New-Object System.Windows.Forms.Timer
    $script:TravelTimer.Interval = 10000
    $script:TravelTimer.Add_Tick({
        $script:TravelTimer.Stop()
        $script:TravelLocked = $false
        $skipBtn.Enabled = $true
        $goBtn.Enabled = $true
        $goBtn.Text = "前往选中关卡"
        $goBtn.BackColor = $ThemeAccentDark
    })
    $script:TravelTimer.Start()
}
$skipBtn.Location = New-Object System.Drawing.Point(258, 44)
$levelCard.Controls.Add($skipBtn)

$script:SelectedText = New-Object System.Windows.Forms.Label
$script:SelectedText.Text = "选中：-"
$script:SelectedText.Location = New-Object System.Drawing.Point(10, 80)
$script:SelectedText.Size = New-Object System.Drawing.Size(374, 22)
$script:SelectedText.ForeColor = $ThemeMuted
$levelCard.Controls.Add($script:SelectedText)

# 队伍
$form.Controls.Add((New-Caption "队伍" 18 382 300))
$teamCard = New-Card 16 404 398 46
$form.Controls.Add($teamCard)
$gatherBtn = New-FlatButton "全员集合到房主" 130 30 { Send-PanelCommand "gather" }
$gatherBtn.Location = New-Object System.Drawing.Point(8, 8)
$teamCard.Controls.Add($gatherBtn)
$exitBtn = New-FlatButton "全员进出口" 118 30 { Send-PanelCommand "exit" }
$exitBtn.Location = New-Object System.Drawing.Point(142, 8)
$teamCard.Controls.Add($exitBtn)
$assistBtn = New-FlatButton "掉队自动拉人：关" 146 30 {
    # 立即切换显示状态（不等待 mod 回写），保证操作有即时反馈
    $script:AssistWanted = -not $script:AssistWanted
    # mod 状态每秒才写回一次，点击后 1.5 秒内不允许刷新覆盖按钮状态
    $script:AssistHoldUntil = (Get-Date).AddSeconds(1.5)
    $assistBtn.Text = if ($script:AssistWanted) { "掉队自动拉人：开" } else { "掉队自动拉人：关" }
    $assistBtn.BackColor = if ($script:AssistWanted) { $ThemeAccentDark } else { $ThemeBtn }
    $script:Footer.Text = if ($script:AssistWanted) { "已开启：距离过远且未跟上的队友会被自动拉回" } else { "已关闭自动拉人" }
    # 发送绝对指令（开启 / 关闭），避免与 mod 状态不同步
    Send-PanelCommand $(if ($script:AssistWanted) { "assist_on" } else { "assist_off" })
}
$assistBtn.Location = New-Object System.Drawing.Point(264, 8)
$teamCard.Controls.Add($assistBtn)

# 工具
$form.Controls.Add((New-Caption "工具" 18 458 300))
$toolCard = New-Card 16 480 398 46
$form.Controls.Add($toolCard)
$refreshBtn = New-FlatButton "刷新状态" 92 30 { Send-PanelCommand "status" }
$refreshBtn.Location = New-Object System.Drawing.Point(8, 8)
$toolCard.Controls.Add($refreshBtn)
$levelsBtn = New-FlatButton "关卡列表" 92 30 {
    Send-PanelCommand "levels"
    $state = Read-State
    $current = "$($state['level'])"
    $selected = "$($state['selected'])"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("当前关卡：$current      选中：$selected")
    $lines.Add("")
    $number = 1
    foreach ($name in $LEVELS) {
        $mark = ""
        if ($name -eq $current) { $mark += "  ← 当前" }
        if ($name -eq $selected) { $mark += "  ★ 选中" }
        $lines.Add(("[{0,2}] {1}{2}" -f $number, $name, $mark))
        $number++
    }
    $lines.Add("")
    $lines.Add("在下拉框中选择关卡，再点击「前往选中关卡」即可全队切图。")
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), "关卡列表") | Out-Null
}
$levelsBtn.Location = New-Object System.Drawing.Point(104, 8)
$toolCard.Controls.Add($levelsBtn)
$logBtn = New-FlatButton "打开日志" 92 30 {
    if ($script:GameDir) {
        $log = Join-Path $script:GameDir "EscapeTheBackrooms\Binaries\Win64\ue4ss\UE4SS.log"
        if (Test-Path -LiteralPath $log) {
            Start-Process notepad.exe $log
        } else {
            # 尚未启动过游戏时日志文件确实不存在，避免按钮表现为「点击无反应」
            $dir = Split-Path -Parent $log
            if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe $dir }
            $script:Footer.Text = "尚无 UE4SS.log：请先启动一次游戏（mod 仅在游戏启动时注入）"
        }
    } else {
        $script:Footer.Text = "未找到游戏目录，请重新执行一次一键安装.bat"
    }
}
$logBtn.Location = New-Object System.Drawing.Point(200, 8)
$toolCard.Controls.Add($logBtn)

# 启动游戏按钮单独占一行，显示更醒目
$startCard = New-Card 16 532 398 56
$form.Controls.Add($startCard)
$startBtn = New-FlatButton "▶  启 动 游 戏" 382 40 { Start-Process "steam://rungameid/1943950" }
$startBtn.Location = New-Object System.Drawing.Point(8, 8)
$startBtn.Font = New-Object System.Drawing.Font($FONT_NAME, 11.5, [System.Drawing.FontStyle]::Bold)
$startBtn.BackColor = $ThemeAccentDark
$startBtn.FlatAppearance.BorderColor = $ThemeAccent
$startCard.Controls.Add($startBtn)

$script:Footer = New-Object System.Windows.Forms.Label
$script:Footer.Text = "就绪：游戏内按 F6 可显示 / 隐藏本窗口"
$script:Footer.Location = New-Object System.Drawing.Point(18, 596)
$script:Footer.Size = New-Object System.Drawing.Size(398, 20)
$script:Footer.ForeColor = $ThemeOk
$form.Controls.Add($script:Footer)

$tip = New-Object System.Windows.Forms.Label
$tip.Text = "提示：人数需在建房前设置；跳关需为房主"
$tip.Location = New-Object System.Drawing.Point(18, 618)
$tip.Size = New-Object System.Drawing.Size(398, 20)
$tip.ForeColor = [System.Drawing.Color]::FromArgb(120, 128, 140)
$form.Controls.Add($tip)

# 作者署名
$author = New-Object System.Windows.Forms.Label
$author.Text = "作者：彧晟Eason    ·    ETB 房主 mod"
$author.Location = New-Object System.Drawing.Point(18, 638)
$author.Size = New-Object System.Drawing.Size(398, 18)
$author.TextAlign = "MiddleCenter"
$author.ForeColor = [System.Drawing.Color]::FromArgb(120, 134, 150)
$author.Font = New-Object System.Drawing.Font($FONT_NAME, 8.5)
$form.Controls.Add($author)

# ---------------------------------------------------------------- 功能说明（悬停提示）
$script:ToolTip = New-Object System.Windows.Forms.ToolTip
$script:ToolTip.AutoPopDelay = 15000
$script:ToolTip.InitialDelay = 250
$script:ToolTip.ReshowDelay = 100
$script:ToolTip.ShowAlways = $true

$HELP = @{}
$HELP["8"] = "目标人数设为 8（含房主）。需在建房前设置，建房后修改需重开房间。"
$HELP["12"] = "目标人数设为 12（含房主）。需在建房前设置，建房后修改需重开房间。"
$HELP["16"] = "目标人数设为 16（含房主）。需在建房前设置，建房后修改需重开房间。"
$HELP["24"] = "目标人数设为 24（含房主）。需在建房前设置，建房后修改需重开房间。"
$HELP["32"] = "目标人数设为 32（含房主）。人数越多，对房主带宽要求越高。"
$HELP["prev"] = "在关卡列表中选择上一关（仅选择，不切换地图）。"
$HELP["next_select"] = "在关卡列表中选择下一关（仅选择，不切换地图）。"
$HELP["travel"] = "将整队切换至选中的关卡；非房主操作无效。"
$HELP["skip"] = "跳过当前关卡：若本关存在出口，先将全员送进出口区域，由游戏自行结算过关；未找到出口则直接切换至下一关。"
$HELP["gather"] = "将其他玩家瞬移至房主身边，用于集合与清点人数。"
$HELP["exit"] = "将所有人瞬移至出口区域，由游戏判定全员到齐后进入下一关。需在能看到出口的关卡中使用。"
$HELP["assist"] = "【掉队自动拉人】开启后每隔数秒检查一次：玩家与房主距离超过约 100 米且持续未跟随时，将被自动拉回房主身边。前往出口途中可保持开启。"
$HELP["refresh"] = "立即令 mod 回写一次状态（通常每秒自动刷新）。"
$HELP["levels"] = "将完整关卡列表输出到屏幕与 UE4SS.log，并标出当前关卡。"
$HELP["log"] = "使用记事本打开 mod 日志 ue4ss\UE4SS.log，用于排查问题。"
$HELP["start"] = "通过 Steam 启动游戏。"

# mod 上报的最近一次动作 → 中文提示
$EVENT_TEXT = @{
    "idle"                    = "就绪"
    "ok_gather"               = "✅ 已将队员拉到房主身边"
    "ok_exit"                 = "✅ 已将队员送进出口区域（人员到齐后结算）"
    "ok_assist"               = "✅ 掉队玩家已拉回"
    "ok_assist_on"            = "✅ 掉队自动拉人：已开启"
    "ok_assist_off"           = "✅ 掉队自动拉人：已关闭"
    "ok_max"                  = "✅ 人数上限已设置（建房时生效）"
    "ok_select"               = "✅ 已切换选中关卡"
    "ok_status"               = "✅ 状态已刷新"
    "ok_levels"               = "✅ 关卡列表已输出到日志"
    "no_exit_zone"            = "⚠ 本关尚未找到出口区域：请靠近出口所在区域后重试"
    "no_exit_position"        = "⚠ 已找到出口但无法读取坐标，详见日志"
    "exit_teleport_failed"    = "⚠ 已找到出口但拉取玩家失败，详见日志"
    "skip_started"            = "✅ 已触发跳过/结算"
    "travel_queued"           = "⏳ 正在切换地图（全队），请稍候"
    "ok_travel"               = "✅ 已切换地图（全队）"
    "travel_failed"           = "⚠ 切换地图失败，详见日志"
    "bad_level"               = "⚠ 该关卡不在列表中，已拒绝切换（防止崩溃）"
}

function Set-Help([object]$Control, [string]$Key) {
    if (-not $HELP.ContainsKey($Key)) { return }
    $text = $HELP[$Key]
    $script:ToolTip.SetToolTip($Control, $text)
    $Control.Add_MouseEnter({ $script:Tip.Text = $text })
    $Control.Add_MouseLeave({ $script:Tip.Text = "提示：人数需在建房前设置；跳关需为房主" })
}

$script:Tip = $tip

foreach ($key in $script:PlayerButtons.Keys) { Set-Help $script:PlayerButtons[$key] "$key" }
Set-Help $prevBtn "prev"
Set-Help $nextBtn "next_select"
Set-Help $goBtn "travel"
Set-Help $skipBtn "skip"
Set-Help $gatherBtn "gather"
Set-Help $exitBtn "exit"
Set-Help $assistBtn "assist"
Set-Help $refreshBtn "refresh"
Set-Help $levelsBtn "levels"
Set-Help $logBtn "log"
Set-Help $startBtn "start"
# 下拉框不挂悬浮提示：提示气泡会覆盖展开的列表，点击选项时易误判为「点不动」

$helpBtn = New-FlatButton "? 说明" 92 24 {
    $text = @(
        "【最大人数】建房前点击 8/12/16/24/32，决定房间可容纳的人数（含房主）。",
        "",
        "【关卡】",
        "  ◀ / ▶ ：在关卡列表中选择上一关 / 下一关（仅选择，不切换地图）",
        "  前往选中关卡：将整队切换至所选关卡",
        "  跳过当前关：存在出口区域时走正常结算（全队计为过关），否则直接前往下一关",
        "",
        "【队伍】",
        "  全员集合到房主：将所有玩家移至房主身边",
        "  全员进出口：将所有玩家送至出口区域 → 触发全员过关结算",
        "  掉队自动拉人：与房主距离超过约 100 米且持续未跟随时，自动拉回房主身边（自动收队）",
        "    前往出口途中可保持开启，边走边收拢掉队玩家",
        "",
        "【工具】刷新状态 / 关卡列表 / 打开日志 / 启动游戏",
        "",
        "所有操作均要求当前玩家为房主（服务器）。"
    ) -join "`r`n"
    [System.Windows.Forms.MessageBox]::Show($text, "功能说明") | Out-Null
}
$helpBtn.Location = New-Object System.Drawing.Point(322, 32)
$helpBtn.Font = New-Object System.Drawing.Font($FONT_NAME, 8.5)
$form.Controls.Add($helpBtn)
$script:ToolTip.SetToolTip($helpBtn, "显示功能说明")
$helpBtn.BringToFront()
$script:HookDot.BringToFront()

# ---------------------------------------------------------------- 刷新
$script:AssistWanted = $false          # 按钮的本地状态（点击后先按此显示）
$script:AssistHoldUntil = [datetime]::MinValue
$script:HotkeyHint = "F6"
$script:HotkeyNote = ""
$script:LastAssist = $false
$script:LastEvent = ""
$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 500
$refreshTimer.Add_Tick({
    $state = Read-State
    if ($state.Count -eq 0) {
        $script:HookDot.Text = "● 等待 mod"
        $script:HookDot.ForeColor = $ThemeWarn
        $script:Footer.Text = "等待 mod 状态…（请先启动游戏并进入大厅）"
        return
    }
    # 心跳过期表示游戏未运行（状态文件为上次遗留），此时不应沿用旧状态，
    # 否则会显示「掉队自动拉人：开」这类实际上早已复位的状态。
    $modAlive = Test-ModAlive
    $hookOk = $modAlive -and ("$($state['hook'])" -like "*true*")
    $script:HookDot.Text = if ($hookOk) { "● 已连接" } elseif (-not $modAlive) { "● 游戏没开" } else { "● 未连接" }
    $script:HookDot.ForeColor = if ($hookOk) { $ThemeOk } else { $ThemeWarn }

    $script:LevelText.Text = "当前关卡：$($state['level'])    更新 $($state['updated'])"
    $script:MembersText.Text = "人数：$($state['players']) / 上限 $($state['max_players'])"
    $hostText = if ("$($state['host'])" -eq "True") { "是" } else { "否" }
    $assistOn = $modAlive -and ("$($state['assist'])" -eq "True")
    # 点击后 1.5 秒内以本地点击结果为准，否则按钮会先回退再跳回，出现闪烁
    if ((Get-Date) -lt $script:AssistHoldUntil) { $assistOn = [bool]$script:AssistWanted }
    $script:AssistWanted = $assistOn
    $assistText = if ($assistOn) { "开" } else { "关" }
    $script:RoleText.Text = "房主：$hostText    掉队自动拉人：$assistText"
    $script:SelectedText.Text = "选中：[$($state['selected_index'])] $($state['selected'])"

    # 仅在事件变化时更新底部提示，避免覆盖「已发送…」这类即时提示
    $event = "$($state['last_event'])"
    if ($event -ne $script:LastEvent) {
        $script:LastEvent = $event
        if ($EVENT_TEXT.ContainsKey($event)) { $script:Footer.Text = $EVENT_TEXT[$event] }
    }

    # 命令确认：mod 每执行一条命令会将 seq 加 1，并在 ack 中写入命令名。
    # 仅在游戏内 mod 完全未运行时才退回快捷键通道，避免重复触发。
    if ($script:Pending) {
        $seqNow = 0
        [void][int]::TryParse("$($state['seq'])", [ref]$seqNow)
        $acked = ("$($state['ack'])" -eq $script:Pending.Command) -or ($seqNow -ne [int]$script:Pending.Seq)
        if ($acked) {
            $script:Pending = $null
        } elseif (((Get-Date) - $script:Pending.Sent).TotalSeconds -gt 4) {
            $command = $script:Pending.Command
            $script:Pending = $null
            if (-not $modAlive) {
                # mod 未运行意味着快捷键也无人接收，发送按键无效，此处直接说明原因
                $script:Footer.Text = "命令未生效（$command）：mod 未运行，请重启游戏或重新执行一键安装.bat"
            } elseif (Invoke-CommandFallback $command) {
                $script:Footer.Text = "文件通道无响应，已改用游戏内快捷键：$command"
            } else {
                $script:Footer.Text = "命令已发送但尚未执行（$command）：请稍候或再次点击"
            }
        }
    }

    $assistBtn.Text = if ($assistOn) { "掉队自动拉人：开" } else { "掉队自动拉人：关" }
    $assistBtn.BackColor = if ($assistOn) { $ThemeAccentDark } else { $ThemeBtn }

    $currentMax = 0
    [void][int]::TryParse("$($state['max_players'])", [ref]$currentMax)
    foreach ($key in $script:PlayerButtons.Keys) {
        $button = $script:PlayerButtons[$key]
        if ($key -eq $currentMax) {
            $button.BackColor = $ThemeAccentDark
            $button.FlatAppearance.BorderColor = $ThemeAccent
        } else {
            $button.BackColor = $ThemeBtn
            $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(62, 70, 82)
        }
    }
    $selectedIndex = 0
    # 用户正在展开下拉框时不更新其选项，否则列表会被刷新覆盖，表现为「点不动」
    if (-not $levelCombo.DroppedDown -and [int]::TryParse("$($state['selected_index'])", [ref]$selectedIndex)) {
        if ($selectedIndex -ge 1 -and $selectedIndex -le $LEVELS.Count -and $levelCombo.SelectedIndex -ne ($selectedIndex - 1)) {
            $script:SyncingCombo = $true
            $levelCombo.SelectedIndex = $selectedIndex - 1
            $script:SyncingCombo = $false
        }
    }
})
$levelCombo.Add_SelectedIndexChanged({
    if ($script:SyncingCombo) { return }
    Send-PanelCommand ("select " + ($levelCombo.SelectedIndex + 1))
})
$refreshTimer.Start()

# ---------------------------------------------------------------- F6 全局热键
$form.Add_HotkeyPressed({
    try {
        if ($form.Visible) {
            $form.Hide()
            Write-PanelLog "hidden by F6"
        } else {
            $form.Show()
            $form.TopMost = $true
            [void]$form.BringToFront()
            Write-PanelLog "shown by F6"
        }
    } catch {
        Write-PanelLog ("hotkey error: " + $_.Exception.Message)
    }
})

# 窗口收起时停止刷新：既不占用 CPU，也不与游戏争抢磁盘
$form.Add_VisibleChanged({
    if ($form.Visible) { if (-not $refreshTimer.Enabled) { $refreshTimer.Start() } }
    else { $refreshTimer.Stop() }
})

$form.Add_Shown({
    [void]$form.Handle
    # F6 为无修饰键，极易被截图 / 录屏 / 输入法占用。被占用后不能静默忽略：
    # 用户按 F6 无反应会误认为 mod 故障。此处先退到 Ctrl+Alt+F6，并将实际热键写入标题栏。
    if ($form.RegisterHotkey($VK_F6)) {
        Write-PanelLog "F6 hotkey registered"
    } elseif ($form.RegisterHotkey($VK_F6, 0x3)) {
        Write-PanelLog "F6 occupied, registered Ctrl+Alt+F6 instead"
        $script:HotkeyHint = "Ctrl+Alt+F6"
        $script:HotkeyNote = "F6 已被其他程序占用，按 Ctrl+Alt+F6 也可显示 / 收起本窗口"
    } else {
        Write-PanelLog "hotkey registration failed (F6 and Ctrl+Alt+F6 both occupied)"
        $script:HotkeyNote = "全局热键均已被占用：请使用桌面「ETB 控制台」或 HostPanel.bat 重新打开"
    }
    $form.Text = "ETB 房主控制台   [$($script:HotkeyHint) 显示 / 收起]"
    if ($script:HotkeyNote) {
        $tip.Text = $script:HotkeyNote
        $script:Footer.Text = $script:HotkeyNote
    }
})

$form.Add_FormClosing({
    try { Set-Content -LiteralPath $script:PosPath -Value ("{0},{1}" -f $form.Left, $form.Top) -Encoding ASCII } catch { }
})

Write-PanelLog "panel shown"
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
Write-PanelLog "panel closed"

}
catch {
    $message = $_.Exception.Message
    $detail = $_.ScriptStackTrace
    Write-PanelLog ("ERROR: " + $message + " | " + $detail)
    try {
        [System.Windows.Forms.MessageBox]::Show("控制台启动失败：`n`n$message`n`n$detail", "ETB 控制台 - 错误") | Out-Null
    } catch {
        Write-Host "控制台启动失败：$message"
        Write-Host $detail
        Read-Host "按回车退出"
    }
}
