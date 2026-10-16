# ManoSegura v1.0.0 - safe "remote hand" for ONE window on ONE chosen monitor (Windows, PowerShell 5.1+).
# No downloads, no admin. Every action asks the user (or runs under a time-limited "trust mode").
# Panic key: Ctrl+Alt+P stops everything and disables the tool until the user runs "enable".
# Copyright (c) 2026 pilahito - CloudTerm Source-Available License v1.0 (adapted). See LICENSE.
param([Parameter(Position=0)][string]$Cmd = 'help', [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Self  = $MyInvocation.MyCommand.Path

# ---------- flags ----------
$DryRun = $false
if ($Rest) { if ($Rest -contains '--dry-run') { $DryRun = $true }; $Rest = @($Rest | Where-Object { $_ -ne '--dry-run' }) } else { $Rest = @() }
if ($env:MANOSEGURA_DRYRUN -eq '1') { $DryRun = $true }

# ---------- config ----------
$ConfigFile = Join-Path $Root 'config.json'
$Cfg = [ordered]@{ TargetMonitor = 'primary'; ShotsDir = ''; ConfirmTimeoutSec = 20; TrustMaxMinutes = 60; ExtraBlockedTitles = @() }
if (Test-Path $ConfigFile) {
  $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($k in @($Cfg.Keys)) { if ($null -ne $j.$k -and "$($j.$k)" -ne '') { $Cfg[$k] = $j.$k } }
}
if ($env:MANOSEGURA_MONITOR) { $Cfg.TargetMonitor = $env:MANOSEGURA_MONITOR }

$State = Join-Path $Root 'state'; $Logs = Join-Path $Root 'logs'
$Shots = if ($Cfg.ShotsDir) { [Environment]::ExpandEnvironmentVariables($Cfg.ShotsDir) } else { Join-Path $Root 'shots' }
foreach ($d in $State,$Logs,$Shots) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null } }
$DisabledFlag = Join-Path $State 'disabled.flag'; $TrustFile = Join-Path $State 'trust.txt'; $TargetFile = Join-Path $State 'target.txt'
$LogFile = Join-Path $Logs 'manosegura.log'

# ---------- HARD safety rules (cannot be disabled by config or trust mode) ----------
# Windows whose title matches are REFUSED: login/password pages, Gmail/webmail, X/Twitter, payment/banking.
$BlockedRegex = '(?i)(\blog ?in\b|\bsign ?in\b|\bsign ?up\b|iniciar sesi|inicio de sesi|acceder a tu cuenta|contrase|password|passwort|\b2fa\b|verificaci.n en dos|one-time code|' +
  'gmail|mail\.google|inbox \(|bandeja de entrada|outlook\.live|' +
  '\(\d+\) x$| / x$| on x:| en x:|\bx\.com\b|twitter|' +
  'paypal|stripe|checkout|\bpago\b|\bpagar\b|payment|\bpay\b|billing|facturaci|tarjeta|credit card|\bbank|\bbanco|banca online|bizum|transferencia|wallet|cartera|coinbase|binance|crypto|cripto)'
$extra = @($Cfg.ExtraBlockedTitles | Where-Object { $_ }) | ForEach-Object { [regex]::Escape("$_") }
if ($extra) { $BlockedRegex = $BlockedRegex.TrimEnd(')') + '|' + ($extra -join '|') + ')' }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
if (-not ('MS2.W' -as [type])) {
Add-Type -Namespace MS2 -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
public delegate bool EnumProc(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, int d, IntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE d, uint f);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString; public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey; }
'@ -UsingNamespace System.Text
}
[void][MS2.W]::SetProcessDPIAware()

class ManoError : System.Exception { [int]$Code; ManoError([string]$m, [int]$c) : base($m) { $this.Code = $c } }
function Log($m) { try { Add-Content -Path $LogFile -Encoding UTF8 -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $PID, $m) } catch {} }
function Fail($m) { Log "RECHAZADO: $m"; throw [ManoError]::new($m, 2) }
function Cancelled($m) { Log "CANCELADO: $m"; throw [ManoError]::new("CANCELADO: $m", 3) }

# ---------- monitors / windows ----------
$script:MonCache = $null
function Get-Monitors {
  if ($script:MonCache) { return $script:MonCache }
  $script:MonCache = @(foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $dd = New-Object MS2.W+DISPLAY_DEVICE; $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
    $ids = @(); $i = 0
    while ([MS2.W]::EnumDisplayDevices($s.DeviceName, $i, [ref]$dd, 0)) { $ids += "$($dd.DeviceID) $($dd.DeviceString)"; $i++ }
    [pscustomobject]@{ DeviceName=$s.DeviceName; Bounds=$s.Bounds; Primary=$s.Primary; MonitorId=($ids -join ' ; ') } })
  $script:MonCache
}
function Find-Monitor([string]$spec) {
  $all = Get-Monitors
  if (-not $spec -or $spec -eq 'primary') { return ($all | Where-Object Primary | Select-Object -First 1) }
  if ($spec -match '^\d+$') { $i = [int]$spec; if ($i -lt $all.Count) { return $all[$i] } }
  $m = @($all | Where-Object { $_.DeviceName -eq $spec }); if ($m.Count) { return $m[0] }
  $m = @($all | Where-Object { $_.MonitorId -like "*$spec*" }); if ($m.Count) { return $m[0] }
  Fail "No encuentro el monitor '$spec' (config TargetMonitor). Usa: monitors"
}
function Get-TargetMonitor { Find-Monitor "$($Cfg.TargetMonitor)" }
function Get-Rect($h) { $r = New-Object MS2.W+RECT; if ([MS2.W]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [void][MS2.W]::GetWindowRect($h, [ref]$r) }; [System.Drawing.Rectangle]::FromLTRB($r.L,$r.T,$r.R,$r.B) }
function Get-Title($h) { $sb = New-Object Text.StringBuilder 512; [void][MS2.W]::GetWindowText($h, $sb, 512); $sb.ToString() }
function Get-Windows {
  $list = New-Object Collections.ArrayList
  $cb = [MS2.W+EnumProc]{ param($h,$p) if ([MS2.W]::IsWindowVisible($h)) { [void]$list.Add($h) }; $true }
  [void][MS2.W]::EnumWindows($cb, [IntPtr]::Zero)
  $mon = Get-TargetMonitor; $procs = @{}; Get-Process | ForEach-Object { $procs[[uint32]$_.Id] = $_.ProcessName }
  foreach ($h in $list) { $t = Get-Title $h; if (-not $t) { continue }
    $pid2 = [uint32]0; [void][MS2.W]::GetWindowThreadProcessId($h, [ref]$pid2); $r = Get-Rect $h
    [pscustomobject]@{ Hwnd=[int64]$h; Proceso=$procs[$pid2]; Titulo=$t; Rect="$($r.X),$($r.Y) $($r.Width)x$($r.Height)"; EnMonitor=$mon.Bounds.Contains($r); Bloqueada=($t -match $BlockedRegex) } }
}
function Get-Target {
  if (-not (Test-Path $TargetFile)) { Fail 'No hay ventana objetivo. Usa: focus <hwnd|titulo>' }
  $h = [IntPtr][int64](Get-Content $TargetFile -Raw).Trim()
  if (-not [MS2.W]::IsWindow($h)) { Fail 'La ventana objetivo ya no existe.' }
  $h
}
function Assert-Allowed($h) { $t = Get-Title $h; if ($t -match $BlockedRegex) { Fail "Ventana PROHIBIDA por reglas de seguridad (login/contrasena, Gmail, X, pagos): '$t'" }; $t }
function Assert-OnMonitor($h) { $r = Get-Rect $h; $m = Get-TargetMonitor; if (-not $m.Bounds.Contains($r)) { Fail "La ventana ($r) no esta entera en el monitor objetivo $($m.DeviceName) ($($m.Bounds)). Muevela alli." }; $r }
function Assert-Enabled { if (Test-Path $DisabledFlag) { Fail 'ManoSegura esta DESACTIVADA (boton de panico). El usuario debe reactivarla con: enable' } }
function Trust-Active { if (Test-Path $TrustFile) { try { $t = [datetime]::Parse((Get-Content $TrustFile -Raw).Trim()); if ($t -gt (Get-Date)) { return $true } } catch {} }; $false }

function Ensure-Panic {
  if ($DryRun) { return }
  $m = $null; if ([Threading.Mutex]::TryOpenExisting('Local\ManoSeguraPanic', [ref]$m)) { $m.Dispose(); return }
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$Self`"",'_panic') | Out-Null
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 50; if ([Threading.Mutex]::TryOpenExisting('Local\ManoSeguraPanic', [ref]$m)) { $m.Dispose(); return } }
}

# ---------- confirmation dialog (on the target monitor) ----------
function Confirm-Action([string]$desc, [switch]$NoTrust) {
  if ($DryRun) { Write-Output "[dry-run] pediria permiso: $($desc -replace "`r`n",' | ')"; return $true }
  if (-not $NoTrust -and (Trust-Active)) { Log "AUTO (modo confianza): $desc"; return $true }
  $a = Get-TargetMonitor; $timeout = [int]$Cfg.ConfirmTimeoutSec
  $f = New-Object Windows.Forms.Form
  $f.Text = 'ManoSegura - confirmar accion'; $f.TopMost = $true; $f.FormBorderStyle = 'FixedDialog'; $f.ControlBox = $false; $f.ShowInTaskbar = $false
  $f.StartPosition = 'Manual'; $f.Size = New-Object Drawing.Size(560, 320); $f.BackColor = [Drawing.Color]::FromArgb(24,28,32); $f.ForeColor = [Drawing.Color]::White
  $f.Location = New-Object Drawing.Point(($a.Bounds.Right - 580), ($a.Bounds.Top + 40))
  $lbl = New-Object Windows.Forms.TextBox; $lbl.Multiline = $true; $lbl.ReadOnly = $true; $lbl.ScrollBars = 'Vertical'; $lbl.BorderStyle = 'None'
  $lbl.BackColor = $f.BackColor; $lbl.ForeColor = [Drawing.Color]::White; $lbl.Location = '15,12'; $lbl.Size = '520,160'; $lbl.Font = New-Object Drawing.Font('Segoe UI', 10)
  $lbl.Text = "El asistente quiere hacer / The assistant wants to:`r`n$desc`r`n`r`n(Ctrl+Alt+P = PANICO / PANIC)"
  $chk = New-Object Windows.Forms.CheckBox; $chk.Location = '15,180'; $chk.Size = '280,24'; $chk.Text = 'Modo confianza durante (min):'
  $num = New-Object Windows.Forms.NumericUpDown; $num.Location = '300,180'; $num.Size = '60,24'; $num.Minimum = 1; $num.Maximum = [int]$Cfg.TrustMaxMinutes; $num.Value = [math]::Min(10, [int]$Cfg.TrustMaxMinutes)
  if ($NoTrust) { $chk.Enabled = $false; $num.Enabled = $false }
  $cnt = New-Object Windows.Forms.Label; $cnt.Location = '15,220'; $cnt.Size = '230,24'
  $ok = New-Object Windows.Forms.Button; $ok.Text = 'Permitir'; $ok.Location = '310,240'; $ok.Size = '110,32'; $ok.BackColor = [Drawing.Color]::FromArgb(61,220,151); $ok.ForeColor = [Drawing.Color]::Black
  $no = New-Object Windows.Forms.Button; $no.Text = 'Cancelar'; $no.Location = '430,240'; $no.Size = '110,32'; $no.ForeColor = [Drawing.Color]::Black; $no.BackColor = [Drawing.Color]::LightGray
  $script:res = $false; $script:left = $timeout
  $ok.Add_Click({ $script:res = $true; $f.Close() }); $no.Add_Click({ $f.Close() })
  $tm = New-Object Windows.Forms.Timer; $tm.Interval = 1000
  $tm.Add_Tick({ $script:left--; $cnt.Text = "Se cancela solo en $($script:left) s"; if ($script:left -le 0 -or (Test-Path $DisabledFlag)) { $f.Close() } })
  $f.Controls.AddRange(@($lbl,$chk,$num,$cnt,$ok,$no)); $f.CancelButton = $no
  $cnt.Text = "Se cancela solo en $timeout s"; $f.Add_Shown({ $f.Activate(); $no.Focus() }); $tm.Start()
  [void]$f.ShowDialog(); $tm.Stop(); $f.Dispose()
  if (Test-Path $DisabledFlag) { $script:res = $false }
  if ($script:res -and $chk.Checked) { (Get-Date).AddMinutes([int]$num.Value).ToString('o') | Set-Content $TrustFile; Log "Usuario activo modo confianza $($num.Value) min" }
  Log ("{0}: {1}" -f ($(if ($script:res) {'PERMITIDO'} else {'CANCELADO'})), ($desc -replace "`r`n",' | '))
  $script:res
}

# ---------- focus (reliable, only when needed) ----------
function Focus-Window([IntPtr]$h) {
  if ([MS2.W]::GetForegroundWindow() -eq $h) { return $true }      # already focused: do nothing
  if ($DryRun) { return $true }
  if ([MS2.W]::IsIconic($h)) { [void][MS2.W]::ShowWindow($h, 9) }
  $fg = [MS2.W]::GetForegroundWindow(); $me = [MS2.W]::GetCurrentThreadId()
  $t1 = [MS2.W]::GetWindowThreadProcessId($fg, [IntPtr]::Zero); $t2 = [MS2.W]::GetWindowThreadProcessId($h, [IntPtr]::Zero)
  [void][MS2.W]::AttachThreadInput($me, $t1, $true); [void][MS2.W]::AttachThreadInput($me, $t2, $true)
  try {
    [MS2.W]::keybd_event(0x12, 0, 0, [IntPtr]::Zero); [MS2.W]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)   # ALT tap unlocks SetForegroundWindow
    [void][MS2.W]::BringWindowToTop($h); [void][MS2.W]::SetForegroundWindow($h)
  } finally { [void][MS2.W]::AttachThreadInput($me, $t1, $false); [void][MS2.W]::AttachThreadInput($me, $t2, $false) }
  for ($i = 0; $i -lt 15; $i++) { if ([MS2.W]::GetForegroundWindow() -eq $h) { return $true }; Start-Sleep -Milliseconds 20 }
  $false
}

# Validates target, asks permission (unless batch already approved), focuses.
$script:BatchApproved = $false
function Prepare-Action([string]$desc) {
  Assert-Enabled; Ensure-Panic
  $h = Get-Target; $t = Assert-Allowed $h; $r = Assert-OnMonitor $h
  if (-not $script:BatchApproved) { if (-not (Confirm-Action "$desc`r`nVentana: $t")) { Cancelled $desc } }
  Assert-Enabled
  if (-not (Focus-Window $h)) { Fail 'No pude traer la ventana objetivo al frente.' }
  [void](Assert-Allowed $h)   # title may have changed (e.g. navigated to a login page)
  @{ H=$h; R=(Get-Rect $h); T=$t }
}

function Assert-NotPasswordField {
  if ($DryRun) { return }
  try { $fe = [Windows.Automation.AutomationElement]::FocusedElement } catch { $fe = $null }
  if (-not $fe) { Fail 'No puedo comprobar el campo enfocado; no escribo.' }
  if ($fe.Current.IsPassword) { Fail 'El campo enfocado es de CONTRASENA. Nunca escribo ahi.' }
}

function Convert-Combo([string]$c) {
  if ($c -match '(?i)alt\+f4|ctrl\+alt\+(del|delete)|ctrl\+shift\+esc') { Fail "Combinacion bloqueada: $c" }
  $map = @{ enter='{ENTER}'; tab='{TAB}'; esc='{ESC}'; escape='{ESC}'; backspace='{BACKSPACE}'; delete='{DELETE}'; supr='{DELETE}'; up='{UP}'; down='{DOWN}'; left='{LEFT}'; right='{RIGHT}'; home='{HOME}'; end='{END}'; pageup='{PGUP}'; pagedown='{PGDN}'; space=' ' }
  1..12 | ForEach-Object { $map["f$_"] = "{F$_}" }
  $mods = ''; $keyPart = ''
  foreach ($p in ($c.ToLower() -split '\+')) {
    switch ($p) { 'ctrl' { $mods += '^' } 'control' { $mods += '^' } 'shift' { $mods += '+' } 'alt' { $mods += '%' }
      'win' { Fail 'La tecla Windows no esta permitida.' }
      default { if ($map.ContainsKey($p)) { $keyPart = $map[$p] } elseif ($p.Length -eq 1) { $keyPart = ($p -replace '([+^%~(){}\[\]])','{$1}') } else { Fail "Tecla desconocida: $p" } } }
  }
  if (-not $keyPart) { Fail 'Combinacion sin tecla principal.' }
  "$mods$keyPart"
}
function Clip($s) { if ($s.Length -gt 200) { $s.Substring(0,200) + '...' } else { $s } }

# ---------- screenshots ----------
function Save-Bitmap($bmp, $path) {
  if (-not $path) { $path = Join-Path $Shots ("shot_{0:yyyyMMdd_HHmmss_fff}.png" -f (Get-Date)) }
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Copy-Item $path (Join-Path $Shots 'latest.png') -Force -ErrorAction SilentlyContinue
  Log "Captura $path"; $path
}
function Shot-Rect([Drawing.Rectangle]$r, $path) {
  if ($DryRun) { return "[dry-run] capturaria $r" }
  $bmp = New-Object Drawing.Bitmap($r.Width, $r.Height); $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.Location, [Drawing.Point]::Empty, $r.Size); $g.Dispose()
  Save-Bitmap $bmp $path
}

# ---------- actions (shared by CLI and batch) ----------
function Do-Action([string]$c, [string[]]$a) {
  switch ($c) {
    'focus' {
      Assert-Enabled; $q = ($a -join ' '); if (-not $q) { Fail 'Uso: focus <hwnd|titulo>' }
      $w = @(Get-Windows | Where-Object { "$($_.Hwnd)" -eq $q }); if (-not $w.Count) { $w = @(Get-Windows | Where-Object { $_.Titulo -like "*$q*" }) }
      if ($w.Count -ne 1) { Fail "Coinciden $($w.Count) ventanas con '$q'. Usa el hwnd (list-windows)." }
      $h = [IntPtr]$w[0].Hwnd; [void](Assert-Allowed $h); [void](Assert-OnMonitor $h)
      if (-not $script:BatchApproved) { if (-not (Confirm-Action "Elegir como ventana objetivo y traerla al frente:`r`n$($w[0].Titulo)")) { Cancelled 'focus' } }
      if (-not $DryRun) { "$($w[0].Hwnd)" | Set-Content $TargetFile }
      [void](Focus-Window $h); return "Objetivo: $($w[0].Hwnd) $($w[0].Titulo) $($w[0].Rect)"
    }
    'screenshot' {
      # screenshot [path] | screenshot window [path] | screenshot monitor [name] [path] | screenshot hwnd <hwnd> [path]
      Assert-Enabled
      $mode = if ($a.Count -and $a[0] -in 'window','monitor','hwnd') { $a[0] } else { 'window' }
      $args2 = if ($a.Count -and $a[0] -in 'window','monitor','hwnd') { @($a | Select-Object -Skip 1) } else { @($a) }
      switch ($mode) {
        'monitor' { $spec = if ($args2.Count -and $args2[0] -notmatch '\.png$') { $args2[0] } else { "$($Cfg.TargetMonitor)" }
                    $p = @($args2 | Where-Object { $_ -match '\.png$' })[0]; $m = Find-Monitor $spec
                    return "Captura monitor $($m.DeviceName): $(Shot-Rect $m.Bounds $p)" }
        'hwnd'    { if (-not $args2.Count) { Fail 'Uso: screenshot hwnd <hwnd> [ruta.png]' }
                    $h = [IntPtr][int64]$args2[0]; if (-not [MS2.W]::IsWindow($h)) { Fail 'Ese hwnd no existe.' }
                    [void](Assert-Allowed $h); $r = Assert-OnMonitor $h; return "Captura ventana: $(Shot-Rect $r $args2[1])" }
        default   { $h = Get-Target; [void](Assert-Allowed $h); $r = Assert-OnMonitor $h
                    return "Captura: $(Shot-Rect $r $args2[0])  (ventana $($r.Width)x$($r.Height) en $($r.X),$($r.Y))" }
      }
    }
    'click' {
      if ($a.Count -lt 2) { Fail 'Uso: click x y [left|right|double]' }
      $x = [int]$a[0]; $y = [int]$a[1]; $btn = if ($a.Count -gt 2) { $a[2] } else { 'left' }
      $r = Assert-OnMonitor (Get-Target)
      if ($x -lt 0 -or $y -lt 0 -or $x -ge $r.Width -or $y -ge $r.Height) { Fail "($x,$y) esta fuera de la ventana ($($r.Width)x$($r.Height))." }
      $p = Prepare-Action "Clic $btn en ($x,$y) de la ventana"; $sx = $p.R.X + $x; $sy = $p.R.Y + $y
      if (-not (Get-TargetMonitor).Bounds.Contains($sx, $sy)) { Fail 'El punto no esta en el monitor objetivo.' }
      if ($DryRun) { return "[dry-run] clic $btn en pantalla ($sx,$sy)" }
      [void][MS2.W]::SetCursorPos($sx, $sy); Start-Sleep -Milliseconds 30
      if ($btn -eq 'right') { [MS2.W]::mouse_event(0x8,0,0,0,[IntPtr]::Zero); [MS2.W]::mouse_event(0x10,0,0,0,[IntPtr]::Zero) }
      else { [MS2.W]::mouse_event(0x2,0,0,0,[IntPtr]::Zero); [MS2.W]::mouse_event(0x4,0,0,0,[IntPtr]::Zero)
             if ($btn -eq 'double') { Start-Sleep -Milliseconds 40; [MS2.W]::mouse_event(0x2,0,0,0,[IntPtr]::Zero); [MS2.W]::mouse_event(0x4,0,0,0,[IntPtr]::Zero) } }
      Log "HECHO clic $btn ($x,$y) -> ($sx,$sy)"; return "OK clic $btn en ($x,$y)"
    }
    'type' {
      $text = ($a -join ' '); if (-not $text) { Fail 'Uso: type "texto"' }
      [void](Prepare-Action "Escribir el texto:`r`n`"$(Clip $text)`""); Assert-NotPasswordField
      if ($DryRun) { return "[dry-run] escribiria $($text.Length) caracteres" }
      $esc = ($text -replace '([+^%~(){}\[\]])','{$1}') -replace "`r?`n", '{ENTER}'
      [Windows.Forms.SendKeys]::SendWait($esc); Log "HECHO escribir $($text.Length) caracteres"; return "OK escrito ($($text.Length) caracteres)"
    }
    'paste' {
      # Fast: put text on clipboard, Ctrl+V, restore previous clipboard text.
      $text = ($a -join ' '); if (-not $text) { Fail 'Uso: paste "texto"' }
      [void](Prepare-Action "Pegar el texto (portapapeles + Ctrl+V):`r`n`"$(Clip $text)`""); Assert-NotPasswordField
      if ($DryRun) { return "[dry-run] pegaria $($text.Length) caracteres" }
      $old = $null; try { if ([Windows.Forms.Clipboard]::ContainsText()) { $old = [Windows.Forms.Clipboard]::GetText() } } catch {}
      [Windows.Forms.Clipboard]::SetText($text); [Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 120
      try { if ($null -ne $old) { [Windows.Forms.Clipboard]::SetText($old) } else { [Windows.Forms.Clipboard]::Clear() } } catch {}
      Log "HECHO pegar $($text.Length) caracteres"; return "OK pegado ($($text.Length) caracteres)"
    }
    'key' {
      $combo = $a -join ''; $sk = Convert-Combo $combo
      [void](Prepare-Action "Pulsar teclas: $combo")
      if ($DryRun) { return "[dry-run] teclas $combo" }
      [Windows.Forms.SendKeys]::SendWait($sk); Log "HECHO tecla $combo"; return "OK tecla $combo"
    }
    'scroll' {
      $amt = if ($a.Count -ge 1) { [int]$a[0] } else { -3 }
      $r = Assert-OnMonitor (Get-Target)
      $x = if ($a.Count -ge 3) { [int]$a[1] } else { [int]($r.Width/2) }; $y = if ($a.Count -ge 3) { [int]$a[2] } else { [int]($r.Height/2) }
      if ($x -lt 0 -or $y -lt 0 -or $x -ge $r.Width -or $y -ge $r.Height) { Fail 'Punto fuera de la ventana.' }
      $dir = if ($amt -lt 0) { 'abajo' } else { 'arriba' }
      $p = Prepare-Action "Desplazar $([math]::Abs($amt)) pasos hacia $dir en ($x,$y)"
      if ($DryRun) { return "[dry-run] scroll $amt" }
      [void][MS2.W]::SetCursorPos($p.R.X + $x, $p.R.Y + $y); [MS2.W]::mouse_event(0x800,0,0,120*$amt,[IntPtr]::Zero); Log "HECHO scroll $amt"; return "OK scroll $amt"
    }
    'wait' { $ms = if ($a.Count) { [int]$a[0] } else { 300 }; if ($ms -gt 10000) { $ms = 10000 }; if (-not $DryRun) { Start-Sleep -Milliseconds $ms }; return "OK espera $ms ms" }
    default { Fail "Comando desconocido: $c" }
  }
}

function Read-Steps([string]$src) {
  $json = if ($src -eq '-') { [Console]::In.ReadToEnd() } elseif (Test-Path $src) { Get-Content $src -Raw -Encoding UTF8 } else { $src }
  $obj = $json | ConvertFrom-Json
  $steps = if ($obj.steps) { @($obj.steps) } else { @($obj) }
  foreach ($s in $steps) {
    $c = "$($s.cmd)".ToLower(); if ($c -notin 'focus','screenshot','click','type','paste','key','scroll','wait') { Fail "Paso no permitido en batch: '$c'" }
    [pscustomobject]@{ Cmd=$c; Args=@($s.args | ForEach-Object { "$_" }) }
  }
}

# ---------- main ----------
Log "CMD: $Cmd $(Clip ($Rest -join ' '))$(if ($DryRun) {' [dry-run]'})"
$exit = 0
try {
switch ($Cmd) {
  '_panic' {
    $created = $false; $mtx = New-Object Threading.Mutex($true, 'Local\ManoSeguraPanic', [ref]$created); if (-not $created) { exit }
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class MsHot2 : System.Windows.Forms.NativeWindow { public event System.EventHandler Hot; public MsHot2(System.IntPtr h){ AssignHandle(h);} protected override void WndProc(ref System.Windows.Forms.Message m){ if (m.Msg==0x0312 && Hot!=null) Hot(this, System.EventArgs.Empty); base.WndProc(ref m);} }
'@
    $f = New-Object Windows.Forms.Form; $f.ShowInTaskbar = $false; $f.WindowState = 'Minimized'; $f.Opacity = 0
    $f.Add_Load({ if (-not [MS2.W]::RegisterHotKey($f.Handle, 1, 0x4003, 0x50)) { Log 'PANICO: no pude registrar Ctrl+Alt+P' } else { Log 'PANICO: escuchando Ctrl+Alt+P' } })
    $f.Add_HandleCreated({ $script:hw = New-Object MsHot2($f.Handle); $script:hw.add_Hot({
      Set-Content $DisabledFlag (Get-Date).ToString('o'); Remove-Item $TrustFile -ErrorAction SilentlyContinue
      Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ManoSegura\.ps1' -and $_.CommandLine -notmatch '_panic' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Log 'PANICO PULSADO: acciones detenidas, ManoSegura desactivada'
      [Windows.Forms.MessageBox]::Show('ManoSegura DESACTIVADA. Acciones pendientes canceladas.', 'ManoSegura - PANICO', 'OK', 'Warning', 'Button1', 'ServiceNotification') | Out-Null }) })
    [Windows.Forms.Application]::Run($f)
  }
  'version' { "ManoSegura $Version" }
  'monitors' { $tm = Get-TargetMonitor; $i = 0; Get-Monitors | ForEach-Object { "[{0}] {1}  {2}  primario={3}  objetivo={4}  id={5}" -f $i, $_.DeviceName, $_.Bounds, $_.Primary, ($_.DeviceName -eq $tm.DeviceName), $_.MonitorId; $i++ } }
  'list-windows' { Get-Windows | Format-Table -AutoSize | Out-String -Width 300 }
  'status' {
    $tm = Get-TargetMonitor
    "ManoSegura $Version"; "Desactivada: $(Test-Path $DisabledFlag)"; "Modo confianza: $(Trust-Active)"; "Monitor objetivo: $($tm.DeviceName) $($tm.Bounds)"; "Capturas: $Shots"
    "Objetivo: $(if (Test-Path $TargetFile) { $h=[IntPtr][int64](Get-Content $TargetFile -Raw).Trim(); "$h  $(Get-Title $h)" } else { '(ninguno)' })"
    $m = $null; "Panico escuchando: $([Threading.Mutex]::TryOpenExisting('Local\ManoSeguraPanic',[ref]$m))" }
  'start-panic' { Ensure-Panic; 'Escucha de panico (Ctrl+Alt+P) activa.' }
  'batch' {
    if (-not $Rest.Count) { Fail 'Uso: batch <steps.json>' }
    $steps = @(Read-Steps ($Rest -join ' ')); if (-not $steps.Count) { Fail 'Batch vacio.' }
    if ($steps.Count -gt 50) { Fail 'Maximo 50 pasos por batch.' }
    Assert-Enabled; Ensure-Panic
    $summary = ($steps | ForEach-Object -Begin { $n = 0 } -Process { $n++; "$n. $($_.Cmd) $(Clip ($_.Args -join ' '))" }) -join "`r`n"
    $needsTarget = @($steps | Where-Object { $_.Cmd -in 'click','type','paste','key','scroll' -or ($_.Cmd -eq 'screenshot' -and -not ($_.Args.Count -and $_.Args[0] -in 'monitor','hwnd')) }).Count -gt 0
    if ($needsTarget -and $steps[0].Cmd -ne 'focus') { $h = Get-Target; $t = Assert-Allowed $h; $summary += "`r`nVentana: $t" }
    if (-not (Confirm-Action "Ejecutar $($steps.Count) pasos:`r`n$summary")) { Cancelled 'batch' }
    $script:BatchApproved = $true; $i = 0
    foreach ($s in $steps) { $i++; Assert-Enabled; "[$i/$($steps.Count)] $(Do-Action $s.Cmd $s.Args)" }
    Log "HECHO batch $($steps.Count) pasos"; "OK batch ($($steps.Count) pasos)"
  }
  'enable' {
    if (-not (Test-Path $DisabledFlag)) { 'Ya estaba activada.'; break }
    Remove-Item $DisabledFlag; if (Confirm-Action 'REACTIVAR ManoSegura despues del boton de panico' -NoTrust) { 'Reactivada.' } else { Set-Content $DisabledFlag (Get-Date).ToString('o'); 'Sigue desactivada.' } }
  'disable' { Set-Content $DisabledFlag (Get-Date).ToString('o'); Remove-Item $TrustFile -ErrorAction SilentlyContinue; Log 'Desactivada por comando'; 'Desactivada.' }
  'trust-off' { Remove-Item $TrustFile -ErrorAction SilentlyContinue; 'Modo confianza desactivado.' }
  'check-title' { $t = $Rest -join ' '; if ($t -match $BlockedRegex) { "BLOQUEADA: $t" } else { "permitida: $t" } }
  { $_ -in 'focus','screenshot','click','type','paste','key','scroll','wait' } { Do-Action $Cmd $Rest }
  default { @"
ManoSegura $Version - uso / usage:  powershell -NoProfile -ExecutionPolicy Bypass -File ManoSegura.ps1 <comando> [--dry-run]
  version | monitors | list-windows | status | start-panic
  focus <hwnd|titulo>                 elegir ventana objetivo (pide permiso)
  screenshot [ruta.png]               captura la ventana objetivo
  screenshot monitor [nombre|n] [ruta.png]   captura un monitor (por defecto el objetivo)
  screenshot hwnd <hwnd> [ruta.png]   captura otra ventana
  click x y [left|right|double]       coords relativas a la ventana
  type "texto"  |  paste "texto"      (rechaza campos de contrasena)
  key ctrl+l | enter | tab ...
  scroll [pasos(-abajo/+arriba)] [x y]
  wait [ms]
  batch <steps.json>                  un permiso para toda la lista
  check-title "titulo"                prueba las reglas de bloqueo
  disable | enable | trust-off        Panico: Ctrl+Alt+P
Config: config.json (TargetMonitor, ShotsDir, ConfirmTimeoutSec, TrustMaxMinutes, ExtraBlockedTitles)
"@ }
}
} catch [ManoError] { Write-Output "ERROR: $($_.Exception.Message)"; $exit = $_.Exception.Code }
  catch { Log "EXCEPCION: $($_.Exception.Message)"; Write-Output "ERROR: $($_.Exception.Message)"; $exit = 1 }
exit $exit
