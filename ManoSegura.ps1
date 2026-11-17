#Requires -Version 5.1
<#
.SYNOPSIS
  ManoSegura 2.0 - "mano remota" segura para que un asistente de IA controle UNA ventana
  en UN monitor de Windows, con interfaz grafica, mas opciones y menos tramites.

.DESCRIPTION
  - Interfaz grafica (comando "ui" o sin argumentos): ventanas, acciones, ajustes y registro.
  - CLI simple y scriptable para todo lo demas.
  - Safety basico: ventana objetivo unica, monitor elegido, bloqueo de campos de contrasena
    y ventanas sensibles, tecla de panico, modo confianza con caducidad.
  - Sin descargas, sin admin, sin ventanas ocultas, sin comandos codificados.

.NOTES
  Copyright (c) 2026 pilahito - CloudTerm Source-Available License v1.0 (adapted). See LICENSE.
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'
$script:Version = '2.0.0'
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { '' }
if (-not $script:ScriptPath) {
    try { $script:ScriptPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $script:ScriptPath = (Get-Location).Path }
}
$script:Root = if ($env:MANOSEGURA_ROOT) { $env:MANOSEGURA_ROOT } else {
    $rootCandidate = Split-Path -Parent $script:ScriptPath
    if ($rootCandidate) { $rootCandidate } else { (Get-Location).Path }
}
$script:HostProcessName = ''
try { $script:HostProcessName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName } catch { }
$script:IsLibrary = ($env:MANOSEGURA_LIBRARY -eq '1') -or (($MyInvocation.InvocationName -eq '.') -and ($script:HostProcessName -in @('powershell', 'pwsh')))
$script:IsCompiledExe = ($script:HostProcessName -and ($script:HostProcessName -notin @('powershell', 'pwsh')))
$script:DryRun = $false
$script:AutoYes = $false
$script:NativeReady = $false
$script:BatchApproved = $false
$script:Gui = $null
$script:CursorBadge = $null
$script:Cfg = $null
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:ExitCode = 0

# =====================================================================================================
# 0. Interop nativo (lazy) / native interop (lazy)
# =====================================================================================================
$script:NativeCode = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace ManoNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public static class Win {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT r, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hWnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, IntPtr extra);
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);
    }
}
'@

$script:FormCode = @'
using System;
using System.Windows.Forms;

namespace ManoForms {
    public class NoActivateForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                return cp;
            }
        }
    }

    public class CursorBadgeForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT (click-through)
                return cp;
            }
        }
    }

    public class HotkeyWindow : NativeWindow {
        public event EventHandler Hotkey;
        public HotkeyWindow(IntPtr handle) { AssignHandle(handle); }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) {
                EventHandler handler = Hotkey;
                if (handler != null) { handler(this, EventArgs.Empty); }
            }
            base.WndProc(ref m);
        }
    }
}
'@

function Ensure-ManoNative {
    if ($script:NativeReady) { return }
    if (-not ('ManoNative.Win' -as [type])) {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        Add-Type -TypeDefinition $script:NativeCode
    }
    if (-not ('ManoForms.NoActivateForm' -as [type])) {
        Add-Type -TypeDefinition $script:FormCode -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')
    }
    try { [void][ManoNative.Win]::SetProcessDPIAware() } catch { }
    $script:NativeReady = $true
}

# =====================================================================================================
# 1. Errores, avisos y registro / errors, warnings and logging
# =====================================================================================================
class ManoError : System.Exception {
    [int]$Code
    ManoError([string]$message, [int]$code) : base($message) { $this.Code = $code }
}

function Write-ManoLog {
    param([string]$Message)
    if (-not $script:LogFile) { return }
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-ManoClipped {
    param([string]$Text, [int]$Max = 200)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + '...'
}

function Throw-ManoError {
    param([string]$Message, [int]$Code = 1)
    throw [ManoError]::new($Message, $Code)
}

# =====================================================================================================
# 2. Configuracion / configuration
# =====================================================================================================
function Get-ManoDefaultConfig {
    [ordered]@{
        TargetMonitor         = 'primary'
        ConfirmMode           = 'ask'
        ConfirmTimeoutSec     = 20
        TrustMaxMinutes       = 120
        ShotsDir              = ''
        ShotFormat            = 'png'
        ClickDelayMs          = 30
        MaxBatchSteps         = 50
        Overlay               = $true
        BlockSensitiveWindows = $true
        BlockedTitles         = @()
        PanicHotkey           = 'Ctrl+Alt+P'
        LogLines              = 500
        AiName                = 'IA'
        ShowAiLabel           = $true
    }
}

function Import-ManoConfig {
    param([string]$Path)

    $cfg = Get-ManoDefaultConfig
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $json = $raw | ConvertFrom-Json
        } catch {
            $warnings.Add("config.json no valido, uso los valores por defecto: $($_.Exception.Message)")
            $json = $null
        }
        if ($null -ne $json) {
            foreach ($key in @('TargetMonitor', 'ConfirmMode', 'ConfirmTimeoutSec', 'TrustMaxMinutes', 'ShotsDir', 'ShotFormat', 'ClickDelayMs', 'MaxBatchSteps', 'Overlay', 'BlockSensitiveWindows', 'BlockedTitles', 'PanicHotkey', 'LogLines', 'AiName', 'ShowAiLabel')) {
                if ($null -ne $json.PSObject.Properties[$key]) {
                    if ($key -eq 'BlockedTitles') { $cfg[$key] = @($json.$key) }
                    else { $cfg[$key] = $json.$key }
                }
            }
        }
    }

    $cfg.ConfirmMode = ([string]$cfg.ConfirmMode).Trim().ToLowerInvariant()
    if ($cfg.ConfirmMode -notin @('ask', 'auto')) {
        $warnings.Add("ConfirmMode '$($cfg.ConfirmMode)' no valido (ask/auto); uso 'ask'.")
        $cfg.ConfirmMode = 'ask'
    }
    foreach ($item in @(
            @{ Key = 'ConfirmTimeoutSec'; Min = 5; Max = 300 },
            @{ Key = 'TrustMaxMinutes'; Min = 1; Max = 1440 },
            @{ Key = 'ClickDelayMs'; Min = 0; Max = 1000 },
            @{ Key = 'MaxBatchSteps'; Min = 1; Max = 200 },
            @{ Key = 'LogLines'; Min = 50; Max = 5000 }
        )) {
        $n = 0
        $parsed = [int]::TryParse([string]$cfg[$item.Key], [ref]$n)
        if (-not $parsed) {
            $warnings.Add("$($item.Key) no es un numero; uso el valor por defecto.")
            $cfg[$item.Key] = (Get-ManoDefaultConfig)[$item.Key]
        } elseif ($n -lt $item.Min -or $n -gt $item.Max) {
            $clamped = if ($n -lt $item.Min) { $item.Min } else { $item.Max }
            $warnings.Add("$($item.Key)=$n fuera de rango ($($item.Min)-$($item.Max)); uso $clamped.")
            $cfg[$item.Key] = $clamped
        } else {
            $cfg[$item.Key] = $n
        }
    }
    $cfg.ShotFormat = ([string]$cfg.ShotFormat).Trim().ToLowerInvariant()
    if ($cfg.ShotFormat -notin @('png', 'jpg', 'jpeg')) {
        $warnings.Add("ShotFormat '$($cfg.ShotFormat)' no valido (png/jpg); uso 'png'.")
        $cfg.ShotFormat = 'png'
    }
    if ($cfg.ShotFormat -eq 'jpeg') { $cfg.ShotFormat = 'jpg' }
    foreach ($b in @('Overlay', 'BlockSensitiveWindows', 'ShowAiLabel')) {
        $v = $cfg[$b]
        if ($v -is [string]) { $cfg[$b] = ($v -match '^(?i)(true|1|si|yes)$') }
        else { $cfg[$b] = [bool]$v }
    }
    $cfg.AiName = ([string]$cfg.AiName).Trim() -replace '[\x00-\x1f]', ''
    if (-not $cfg.AiName) { $cfg.AiName = 'IA' }
    if ($cfg.AiName.Length -gt 32) { $cfg.AiName = $cfg.AiName.Substring(0, 32) }

    if ($cfg.BlockedTitles -is [string]) { $cfg.BlockedTitles = @([string]$cfg.BlockedTitles) }
    $cfg.BlockedTitles = @(@($cfg.BlockedTitles) | Where-Object { $_ -and "$_".Trim() } | ForEach-Object { [string]$_ })

    $hotkeyOk = $true
    try { Convert-ManoHotkey ([string]$cfg.PanicHotkey) | Out-Null } catch { $hotkeyOk = $false }
    if (-not $hotkeyOk) {
        $warnings.Add("PanicHotkey '$($cfg.PanicHotkey)' no se entiende; uso Ctrl+Alt+P.")
        $cfg.PanicHotkey = 'Ctrl+Alt+P'
    }
    $target = ([string]$cfg.TargetMonitor).Trim()
    if (-not $target) { $cfg.TargetMonitor = 'primary' } else { $cfg.TargetMonitor = $target }

    [pscustomobject]@{ Config = $cfg; Warnings = @($warnings) }
}

function Save-ManoConfig {
    param([System.Collections.IDictionary]$Config)
    $json = [ordered]@{}
    foreach ($key in (Get-ManoDefaultConfig).Keys) { $json[$key] = $Config[$key] }
    ($json | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    Write-ManoLog 'config.json guardado'
}

function Set-ManoConfigValue {
    param([string]$Key, [string]$Value)
    $defaults = Get-ManoDefaultConfig
    if (-not $defaults.Contains($Key)) { Throw-ManoError "Ajuste desconocido: $Key. Ajustes: $((($defaults.Keys) -join ', '))" 1 }
    $new = [ordered]@{}
    foreach ($k in $defaults.Keys) { $new[$k] = $script:Cfg[$k] }
    if ($Key -eq 'BlockedTitles') {
        $new[$Key] = @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } elseif ($Key -in @('Overlay', 'BlockSensitiveWindows')) {
        $new[$Key] = ($Value -match '^(?i)(true|1|si|yes|on)$')
    } else {
        $new[$Key] = $Value
    }
    Save-ManoConfig $new
    $loaded = Import-ManoConfig -Path $script:ConfigFile
    $script:Cfg = $loaded.Config
    Write-ManoLog "config: $Key=$Value"
    "OK $Key = $($script:Cfg[$Key])"
}

# =====================================================================================================
# 3. Entorno y estado / environment and state
# =====================================================================================================
function Initialize-ManoEnvironment {
    param([string]$RootPath)

    $script:Root = $RootPath
    $script:ConfigFile = Join-Path $script:Root 'config.json'
    $script:StateDir = Join-Path $script:Root 'state'
    $script:LogsDir = Join-Path $script:Root 'logs'
    $loaded = Import-ManoConfig -Path $script:ConfigFile
    $script:Cfg = $loaded.Config
    $script:Warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in $loaded.Warnings) { $script:Warnings.Add($w) }

    $shots = if ($script:Cfg.ShotsDir) { [Environment]::ExpandEnvironmentVariables([string]$script:Cfg.ShotsDir) } else { Join-Path $script:Root 'shots' }
    $script:ShotsDir = $shots
    foreach ($dir in @($script:StateDir, $script:LogsDir, $script:ShotsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    }
    $script:DisabledFlag = Join-Path $script:StateDir 'disabled.flag'
    $script:TrustFile = Join-Path $script:StateDir 'trust.txt'
    $script:TargetFile = Join-Path $script:StateDir 'target.txt'
    $script:AiFile = Join-Path $script:StateDir 'ai.txt'
    $script:LogFile = Join-Path $script:LogsDir 'manosegura.log'
    $script:CurrentAiName = Get-ManoAiName
}

function Test-ManoDisabled { Test-Path -LiteralPath $script:DisabledFlag }

function Set-ManoDisabled {
    param([bool]$Disabled)
    if ($Disabled) {
        Set-Content -LiteralPath $script:DisabledFlag -Value (Get-Date).ToString('o')
        Write-ManoLog 'DESACTIVADA'
    } else {
        Remove-Item -LiteralPath $script:DisabledFlag -Force -ErrorAction SilentlyContinue
        Write-ManoLog 'ACTIVADA'
    }
}

function Get-ManoTrustExpiry {
    param([string]$Text)
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse("$Text".Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return $null }
    $t.ToLocalTime()
}

function Test-ManoTrustValue {
    param([string]$Text, [datetime]$Now, [int]$MaxMinutes)
    $t = Get-ManoTrustExpiry $Text
    if ($null -eq $t) { return $false }
    ($t -gt $Now) -and ($t -le $Now.AddMinutes($MaxMinutes + 1))
}

function Test-ManoTrustActive {
    if (-not (Test-Path -LiteralPath $script:TrustFile)) { return $false }
    try {
        Test-ManoTrustValue (Get-Content -LiteralPath $script:TrustFile -Raw) (Get-Date) ([int]$script:Cfg.TrustMaxMinutes)
    } catch {
        return $false
    }
}

function Set-ManoTrustMinutes {
    param([int]$Minutes)
    $max = [int]$script:Cfg.TrustMaxMinutes
    if ($Minutes -lt 1) { $Minutes = 1 }
    if ($Minutes -gt $max) { $Minutes = $max }
    (Get-Date).AddMinutes($Minutes).ToString('o') | Set-Content -LiteralPath $script:TrustFile
    Write-ManoLog "modo confianza $Minutes min"
    $Minutes
}


function Convert-ManoTrustSpec {
    param([string]$Spec)
    $text = ("$Spec" -replace '\s', '').ToLowerInvariant()
    if (-not $text) { Throw-ManoError 'Uso: trust 10m | 30m | 1h | 2h | 3h | 90 | 1h30m' 1 }
    $pattern = '(\d+(?:\.\d+)?)(horas?|mins?|minutos?|h|m)?'
    $timeParts = [regex]::Matches($text, $pattern)
    if ($timeParts.Count -eq 0) { Throw-ManoError "No entiendo el tiempo '$Spec'. Ejemplos: 10m, 30m, 1h, 2h, 3h, 90, 1h30m." 1 }
    $consumed = ($timeParts | ForEach-Object { $_.Value }) -join ''
    if ($consumed -ne $text) { Throw-ManoError "No entiendo el tiempo '$Spec'. Ejemplos: 10m, 30m, 1h, 2h, 3h, 90, 1h30m." 1 }
    $total = 0.0
    foreach ($match in $timeParts) {
        $number = [double]$match.Groups[1].Value
        $unit = $match.Groups[2].Value
        if ($unit -eq 'h' -or $unit -like 'hora*') { $total += $number * 60 } else { $total += $number }
    }
    $minutes = [int][math]::Round($total)
    if ($minutes -lt 1) { Throw-ManoError 'El tiempo minimo es 1 minuto.' 1 }
    $minutes
}

function Add-ManoTrustMinutes {
    param([int]$Minutes)
    if ($Minutes -lt 1) { $Minutes = 1 }
    $now = Get-Date
    $max = [int]$script:Cfg.TrustMaxMinutes
    $base = $now
    $extended = $false
    if (Test-ManoTrustActive) {
        try { $expiry = Get-ManoTrustExpiry (Get-Content -LiteralPath $script:TrustFile -Raw) } catch { $expiry = $null }
        if ($expiry -and $expiry -gt $now) { $base = $expiry; $extended = $true }
    }
    $target = $base.AddMinutes($Minutes)
    $limit = $now.AddMinutes($max)
    $capped = $false
    if ($target -gt $limit) { $target = $limit; $capped = $true }
    $target.ToString('o') | Set-Content -LiteralPath $script:TrustFile
    Write-ManoLog "modo confianza hasta $($target.ToString('HH:mm')) (extendido=$extended)"
    [pscustomobject]@{ Expiry = $target; TotalMinutes = [int][math]::Round(($target - $now).TotalMinutes); Extended = $extended; Capped = $capped }
}

function Get-ManoTrustRemainingMinutes {
    if (-not (Test-ManoTrustActive)) { return 0 }
    try { $expiry = Get-ManoTrustExpiry (Get-Content -LiteralPath $script:TrustFile -Raw) } catch { return 0 }
    if (-not $expiry) { return 0 }
    [int][math]::Ceiling(($expiry - (Get-Date)).TotalMinutes)
}

function Clear-ManoTrust {
    Remove-Item -LiteralPath $script:TrustFile -Force -ErrorAction SilentlyContinue
    Write-ManoLog 'modo confianza desactivado'
}

function Set-ManoTarget {
    param([IntPtr]$Hwnd)
    "$([int64]$Hwnd)" | Set-Content -LiteralPath $script:TargetFile
}

function Get-ManoAiName {
    if ($env:MANOSEGURA_AI_NAME) {
        $envName = ([string]$env:MANOSEGURA_AI_NAME).Trim() -replace '[\x00-\x1f]', ''
        if ($envName) { return $envName }
    }
    if ($script:AiFile -and (Test-Path -LiteralPath $script:AiFile)) {
        try {
            $stored = (Get-Content -LiteralPath $script:AiFile -Raw).Trim() -replace '[\x00-\x1f]', ''
            if ($stored) { return $stored }
        } catch { }
    }
    if ($script:Cfg -and $script:Cfg.AiName) { return [string]$script:Cfg.AiName }
    'IA'
}

function Set-ManoAiName {
    param([string]$Name)
    $clean = ([string]$Name).Trim() -replace '[\x00-\x1f]', ''
    if (-not $clean) { Throw-ManoError 'Uso: ai <nombre> (ej: ai Claude)' 1 }
    if ($clean.Length -gt 32) { $clean = $clean.Substring(0, 32) }
    $clean | Set-Content -LiteralPath $script:AiFile
    $script:CurrentAiName = $clean
    Write-ManoLog "IA: $clean"
    $clean
}

function Get-ManoTarget {
    Ensure-ManoNative
    if (-not (Test-Path -LiteralPath $script:TargetFile)) { Throw-ManoError 'No hay ventana objetivo. Usa: use <hwnd|titulo> o elige una en la interfaz (ui).' 1 }
    $text = (Get-Content -LiteralPath $script:TargetFile -Raw).Trim()
    $value = [int64]0
    if (-not [int64]::TryParse($text, [ref]$value)) { Throw-ManoError 'La ventana objetivo guardada no es valida. Vuelve a elegirla.' 1 }
    $hwnd = [IntPtr]$value
    if (-not [ManoNative.Win]::IsWindow($hwnd)) { Throw-ManoError 'La ventana objetivo ya no existe. Elige otra.' 1 }
    $hwnd
}

# =====================================================================================================
# 4. Utilidades puras (testables) / pure helpers (testable)
# =====================================================================================================
function Get-ManoBlockRegex {
    param([string[]]$Extra = @())
    $pattern = '(?i)(\blog ?in\b|\bsign ?in\b|\bsign ?up\b|iniciar sesi|inicio de sesi|acceder a tu cuenta|contrase|\bpassword\b|passwort|\b2fa\b|verificaci.n en dos|one-time code|' +
        'gmail|mail\.google|inbox \(|bandeja de entrada|outlook\.live|' +
        'paypal|stripe|checkout|\bpago\b|\bpagar\b|payment|billing|facturaci|tarjeta|credit card|\bbank|\bbanco|banca online|bizum|transferencia|wallet|cartera|coinbase|binance|crypto|cripto)'
    $escaped = @(@($Extra) | Where-Object { $_ } | ForEach-Object { [regex]::Escape([string]$_) })
    if ($escaped.Count -gt 0) { $pattern = $pattern.TrimEnd(')') + '|' + ($escaped -join '|') + ')' }
    $pattern
}

function Test-ManoTitleBlocked {
    param([string]$Title, [string[]]$Extra = @())
    if (-not $Title) { return $false }
    [bool]($Title -match (Get-ManoBlockRegex -Extra $Extra))
}

function Convert-ManoKeyCombo {
    param([string]$Combo)
    $c = ("$Combo" -replace '\s', '').ToLowerInvariant()
    if (-not $c) { Throw-ManoError 'Combinacion de teclas vacia. Ejemplo: ctrl+s' 1 }
    $aliases = @{ escape = 'esc'; esc = 'esc'; supr = 'delete'; del = 'delete'; ins = 'insert'; intro = 'enter'; return = 'enter'; pgup = 'pageup'; pgdn = 'pagedown'; espacio = 'space'; bksp = 'backspace' }
    $sendMap = @{
        enter = '{ENTER}'; tab = '{TAB}'; esc = '{ESC}'; backspace = '{BACKSPACE}'; delete = '{DELETE}'
        insert = '{INSERT}'; up = '{UP}'; down = '{DOWN}'; left = '{LEFT}'; right = '{RIGHT}'
        home = '{HOME}'; end = '{END}'; pageup = '{PGUP}'; pagedown = '{PGDN}'; space = ' '
    }
    foreach ($i in 1..12) { $sendMap["f$i"] = "{F$i}" }

    $parts = if ($c -eq '+') { @('+') } else { @($c -split '\+') }
    $mods = New-Object System.Collections.Generic.List[string]
    $key = ''
    foreach ($part in $parts) {
        if (-not $part) { continue }
        if ($part -in @('ctrl', 'control', 'ctl')) { if (-not $mods.Contains('ctrl')) { $mods.Add('ctrl') }; continue }
        if ($part -eq 'alt') { if (-not $mods.Contains('alt')) { $mods.Add('alt') }; continue }
        if ($part -in @('shift', 'mayus')) { if (-not $mods.Contains('shift')) { $mods.Add('shift') }; continue }
        if ($part -in @('win', 'windows', 'super', 'meta', 'lwin', 'rwin', 'cmd')) { Throw-ManoError 'La tecla Windows no esta permitida.' 1 }
        $k = if ($aliases.ContainsKey($part)) { $aliases[$part] } else { $part }
        if (-not ($sendMap.ContainsKey($k) -or $k.Length -eq 1)) { Throw-ManoError "Tecla desconocida: $part" 1 }
        if ($key) { Throw-ManoError "Combinacion con dos teclas principales: $Combo" 1 }
        $key = $k
    }
    if (-not $key) { Throw-ManoError "Combinacion sin tecla principal: $Combo" 1 }

    $normalized = (@(@('ctrl', 'alt', 'shift') | Where-Object { $mods.Contains($_) }) + @($key)) -join '+'
    if ($normalized -in @('ctrl+alt+delete', 'alt+f4', 'ctrl+shift+esc')) { Throw-ManoError "Combinacion bloqueada por seguridad: $normalized" 1 }

    $prefix = ''
    foreach ($m in @('ctrl', 'alt', 'shift')) {
        if ($mods.Contains($m)) { $prefix += $(switch ($m) { 'ctrl' { '^' } 'alt' { '%' } 'shift' { '+' } }) }
    }
    $keySend = if ($sendMap.ContainsKey($key)) { $sendMap[$key] } else { $key -replace '([+^%~(){}\[\]])', '{$1}' }
    [pscustomobject]@{ Normalized = $normalized; Mods = [string[]]@($mods); Key = $key; SendKeys = "$prefix$keySend" }
}

function Convert-ManoHotkey {
    param([string]$Combo)
    $parsed = Convert-ManoKeyCombo $Combo
    $mods = 0
    if ($parsed.Mods -contains 'alt') { $mods = $mods -bor 0x0001 }
    if ($parsed.Mods -contains 'ctrl') { $mods = $mods -bor 0x0002 }
    if ($parsed.Mods -contains 'shift') { $mods = $mods -bor 0x0004 }
    $key = $parsed.Key
    $vk = -1
    if ($key.Length -eq 1 -and $key -match '^[a-z0-9]$') { $vk = [int][char]$key.ToUpperInvariant() }
    elseif ($key -match '^f([1-9]|1[0-2])$') { $vk = 0x70 + ([int]$Matches[1] - 1) }
    else {
        $map = @{ enter = 0x0D; tab = 0x09; esc = 0x1B; space = 0x20; backspace = 0x08; delete = 0x2E; insert = 0x2D; home = 0x24; end = 0x23; pageup = 0x21; pagedown = 0x22; up = 0x26; down = 0x28; left = 0x25; right = 0x27 }
        if ($map.ContainsKey($key)) { $vk = $map[$key] }
    }
    if ($vk -lt 0) { Throw-ManoError "No puedo usar '$Combo' como atajo global. Usa letras, numeros o F1-F12." 1 }
    [pscustomobject]@{ Modifiers = $mods; VirtualKey = $vk; Normalized = $parsed.Normalized }
}

function Convert-ManoBatch {
    param([string]$Json, [int]$MaxSteps = 50)
    try { $obj = $Json | ConvertFrom-Json } catch { Throw-ManoError "batch: JSON no valido: $($_.Exception.Message)" 1 }
    if ($null -eq $obj) { Throw-ManoError 'batch: JSON vacio.' 1 }
    $steps = if ($obj -is [array]) { @($obj) } elseif ($null -ne $obj.PSObject.Properties['steps']) { @($obj.steps) } else { @($obj) }
    $steps = @($steps | Where-Object { $null -ne $_ })
    if ($steps.Count -eq 0) { Throw-ManoError 'batch: no hay pasos.' 1 }
    if ($steps.Count -gt $MaxSteps) { Throw-ManoError "batch: maximo $MaxSteps pasos (hay $($steps.Count))." 1 }
    $allowed = @('focus', 'screenshot', 'click', 'type', 'paste', 'key', 'scroll', 'drag', 'wait')
    $result = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($step in $steps) {
        $i++
        if ($null -eq $step.PSObject.Properties['cmd']) { Throw-ManoError "batch: el paso $i no tiene 'cmd'." 1 }
        $cmd = ([string]$step.cmd).Trim().ToLowerInvariant()
        if ($cmd -notin $allowed) { Throw-ManoError "batch: paso $i con comando no permitido '$cmd'." 1 }
        $argsList = New-Object System.Collections.Generic.List[string]
        if ($null -ne $step.PSObject.Properties['args'] -and $null -ne $step.args) {
            foreach ($a in @($step.args)) {
                if ($a -is [string] -or $a -is [ValueType]) { $argsList.Add([string]$a) }
                else { Throw-ManoError "batch: paso $i con argumentos no validos." 1 }
            }
        }
        $result.Add([pscustomobject]@{ Index = $i; Cmd = $cmd; Args = [string[]]$argsList.ToArray() })
    }
    [object[]]$result.ToArray()
}

function Select-ManoMonitor {
    param([object[]]$Monitors, [string]$Spec)
    $all = @($Monitors | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0) { return $null }
    $s = "$Spec".Trim()
    if (-not $s -or $s -in @('primary', 'primario', 'principal')) { return ($all | Where-Object { $_.Primary } | Select-Object -First 1) }
    if ($s -match '^\d+$') { $i = [int]$s; if ($i -ge 0 -and $i -lt $all.Count) { return $all[$i] }; return $null }
    if ($s -match '^(?i)(left|izquierda|izq)$') { return ($all | Sort-Object -Property { $_.Bounds.X } | Select-Object -First 1) }
    if ($s -match '^(?i)(right|derecha|der)$') { return ($all | Sort-Object -Property { $_.Bounds.X } -Descending | Select-Object -First 1) }
    if ($s -match '^(?i)(?:x=)?(-?\d+)\s*,\s*(-?\d+)$') {
        $px = [int]$Matches[1]; $py = [int]$Matches[2]
        return ($all | Where-Object { Test-ManoPointInRect $px $py $_.Bounds } | Select-Object -First 1)
    }
    if ($s -match '^(?i)x=(-?\d+)$') {
        $px = [int]$Matches[1]
        return ($all | Where-Object { $_.Bounds.X -eq $px } | Select-Object -First 1)
    }
    $byName = @($all | Where-Object { $_.DeviceName -eq $s -or $_.DeviceName -like "*\$s" })
    if ($byName.Count -gt 0) { return $byName[0] }
    $byId = @($all | Where-Object { $_.MonitorId -and $_.MonitorId.IndexOf($s, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($byId.Count -gt 0) { return $byId[0] }
    $null
}

function Test-ManoPointInRect {
    param([int]$X, [int]$Y, $Rect)
    ($X -ge $Rect.X) -and ($Y -ge $Rect.Y) -and ($X -lt ($Rect.X + $Rect.Width)) -and ($Y -lt ($Rect.Y + $Rect.Height))
}

function Test-ManoRectInside {
    param($Inner, $Outer)
    ($Inner.X -ge $Outer.X) -and ($Inner.Y -ge $Outer.Y) -and
    (($Inner.X + $Inner.Width) -le ($Outer.X + $Outer.Width)) -and
    (($Inner.Y + $Inner.Height) -le ($Outer.Y + $Outer.Height))
}

function Format-ManoRect {
    param($Rect)
    "$($Rect.X),$($Rect.Y) $($Rect.Width)x$($Rect.Height)"
}

# =====================================================================================================
# 5. Monitores y ventanas / monitors and windows
# =====================================================================================================
function Get-ManoMonitors {
    Ensure-ManoNative
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $dd = New-Object ManoNative.DISPLAY_DEVICE
        $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
        $ids = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ([ManoNative.Win]::EnumDisplayDevices($screen.DeviceName, $i, [ref]$dd, 0)) {
            $ids.Add("$($dd.DeviceID) $($dd.DeviceString)")
            $i++
        }
        $list.Add([pscustomobject]@{
                DeviceName = $screen.DeviceName
                Bounds     = $screen.Bounds
                Primary    = $screen.Primary
                MonitorId  = ($ids -join ' ; ')
            })
    }
    [object[]]$list.ToArray()
}

function Get-ManoTargetMonitor {
    $monitors = Get-ManoMonitors
    $monitor = Select-ManoMonitor -Monitors $monitors -Spec ([string]$script:Cfg.TargetMonitor)
    if ($null -eq $monitor) {
        Throw-ManoError "No encuentro el monitor '$($script:Cfg.TargetMonitor)'. Usa: monitors" 1
    }
    $monitor
}

function Get-ManoWindowRect {
    param([IntPtr]$Hwnd)
    Ensure-ManoNative
    $r = New-Object ManoNative.RECT
    $ok = $false
    try { if ([ManoNative.Win]::DwmGetWindowAttribute($Hwnd, 9, [ref]$r, 16) -eq 0) { $ok = $true } } catch { }
    if (-not $ok) { [void][ManoNative.Win]::GetWindowRect($Hwnd, [ref]$r) }
    [System.Drawing.Rectangle]::FromLTRB($r.Left, $r.Top, $r.Right, $r.Bottom)
}

function Get-ManoWindowTitle {
    param([IntPtr]$Hwnd)
    Ensure-ManoNative
    $sb = New-Object System.Text.StringBuilder 512
    [void][ManoNative.Win]::GetWindowText($Hwnd, $sb, 512)
    $sb.ToString()
}

function Get-ManoWindows {
    Ensure-ManoNative
    $list = New-Object System.Collections.ArrayList
    $callback = [ManoNative.Win+EnumProc] {
        param($h, $p)
        [void]$p
        if ([ManoNative.Win]::IsWindowVisible($h)) { [void]$list.Add($h) }
        $true
    }
    [void][ManoNative.Win]::EnumWindows($callback, [IntPtr]::Zero)
    $target = Get-ManoTargetMonitor
    $processNames = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { $processNames[[uint32]$p.Id] = $p.ProcessName }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($h in $list) {
        $title = Get-ManoWindowTitle $h
        if (-not $title) { continue }
        $procId = [uint32]0
        [void][ManoNative.Win]::GetWindowThreadProcessId($h, [ref]$procId)
        $rect = Get-ManoWindowRect $h
        $processName = $processNames[$procId]
        $result.Add([pscustomobject]@{
                Hwnd       = [int64]$h
                Proceso    = $processName
                Titulo     = $title
                Rect       = $rect
                Monitor    = if (Test-ManoRectInside $rect $target.Bounds) { $target.DeviceName } else { '' }
                EnObjetivo = Test-ManoRectInside $rect $target.Bounds
                Bloqueada  = Test-ManoTitleBlocked -Title $title -Extra $script:Cfg.BlockedTitles
            })
    }
    [object[]]$result.ToArray()
}

function Find-ManoWindow {
    param([string]$Query)
    $q = "$Query".Trim()
    if (-not $q) { Throw-ManoError 'Uso: use <hwnd|parte del titulo>' 1 }
    $windows = Get-ManoWindows
    $byHandle = @($windows | Where-Object { "$($_.Hwnd)" -eq $q })
    if ($byHandle.Count -eq 1) { return $byHandle[0] }
    $byTitle = @($windows | Where-Object { $_.Titulo -like "*$q*" })
    if ($byTitle.Count -eq 1) { return $byTitle[0] }
    $byProcess = @($windows | Where-Object { $_.Proceso -like "*$q*" })
    if ($byProcess.Count -eq 1) { return $byProcess[0] }
    if ($byTitle.Count -gt 1) {
        $choices = ($byTitle | ForEach-Object { "$($_.Hwnd)  $($_.Titulo)" }) -join [Environment]::NewLine
        Throw-ManoError "Hay $($byTitle.Count) ventanas que coinciden con '$q'. Usa el hwnd:`n$choices" 1
    }
    Throw-ManoError "No encuentro ninguna ventana que coincida con '$q'. Prueba: list" 1
}

function Assert-ManoWindowAllowed {
    param([IntPtr]$Hwnd)
    $title = Get-ManoWindowTitle $Hwnd
    if ($script:Cfg.BlockSensitiveWindows -and (Test-ManoTitleBlocked -Title $title -Extra $script:Cfg.BlockedTitles)) {
        Throw-ManoError "Ventana PROHIBIDA por seguridad (login, contrasena, correo, pagos): '$title'" 2
    }
    $title
}

function Assert-ManoWindowOnMonitor {
    param([IntPtr]$Hwnd)
    $rect = Get-ManoWindowRect $Hwnd
    $target = Get-ManoTargetMonitor
    if (-not (Test-ManoRectInside $rect $target.Bounds)) {
        Throw-ManoError "La ventana ($(Format-ManoRect $rect)) no esta entera en el monitor objetivo $($target.DeviceName) ($(Format-ManoRect $target.Bounds)). Muevela alli o cambia TargetMonitor." 1
    }
    $rect
}

# =====================================================================================================
# 6. Confirmacion / confirmation
# =====================================================================================================
function Confirm-ManoAction {
    param([string]$Description, [switch]$NoTrust)

    if ($script:DryRun) {
        Write-ManoLog "[dry-run] pediria permiso: $(Get-ManoClipped ($Description -replace "`r`n", ' | ') 300)"
        Write-Output "[dry-run] pediria permiso: $(Get-ManoClipped ($Description -replace "`r`n", ' | ') 300)"
        return $true
    }
    if ($script:AutoYes) {
        Write-ManoLog "AUTO (--yes): $(Get-ManoClipped ($Description -replace "`r`n", ' | ') 300)"
        return $true
    }
    if (-not $NoTrust -and (Test-ManoTrustActive)) {
        Write-ManoLog "AUTO (modo confianza): $(Get-ManoClipped ($Description -replace "`r`n", ' | ') 300)"
        return $true
    }
    if ($script:Cfg.ConfirmMode -eq 'auto') {
        Write-ManoLog "AUTO (ConfirmMode=auto): $(Get-ManoClipped ($Description -replace "`r`n", ' | ') 300)"
        return $true
    }

    Ensure-ManoNative
    $monitor = Get-ManoTargetMonitor
    $timeout = [int]$script:Cfg.ConfirmTimeoutSec
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ManoSegura - permiso para $(Get-ManoAiName)"
    $form.TopMost = $true
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Size = New-Object System.Drawing.Size(640, 380)
    $form.BackColor = Get-ManoUiColor 'Bg'
    $form.ForeColor = Get-ManoUiColor 'Text'
    $form.Location = New-Object System.Drawing.Point(($monitor.Bounds.X + [int](($monitor.Bounds.Width - 640) / 2)), ($monitor.Bounds.Y + [int](($monitor.Bounds.Height - 380) / 2)))
    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = 'Top'
    $accent.Height = 4
    $accent.BackColor = Get-ManoUiColor 'Warn'
    $form.Controls.Add($accent)
    [void](New-ManoUiLabel -Parent $form -Text 'Permiso necesario' -X 24 -Y 24 -W 400 -H 28 -Size 15 -Bold)
    [void](New-ManoUiLabel -Parent $form -Text "$(Get-ManoAiName) quiere hacer esto en la ventana objetivo:" -X 24 -Y 56 -W 580 -H 20 -Size 9 -Color 'Muted')
    $label = New-Object System.Windows.Forms.TextBox
    $label.Multiline = $true
    $label.ReadOnly = $true
    $label.ScrollBars = 'Vertical'
    $label.BorderStyle = 'None'
    $label.BackColor = Get-ManoUiColor 'Card'
    $label.ForeColor = Get-ManoUiColor 'Text'
    $label.Location = New-Object System.Drawing.Point(24, 84)
    $label.Size = New-Object System.Drawing.Size(592, 120)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $label.Text = $Description
    $form.Controls.Add($label)

    $check = New-Object System.Windows.Forms.CheckBox
    $check.Location = New-Object System.Drawing.Point(24, 220)
    $check.Size = New-Object System.Drawing.Size(170, 24)
    $check.Text = 'Confianza (min):'
    $check.ForeColor = Get-ManoUiColor 'Text'
    $check.BackColor = Get-ManoUiColor 'Bg'
    $preset = New-Object System.Windows.Forms.ComboBox
    $preset.Location = New-Object System.Drawing.Point(204, 220)
    $preset.Size = New-Object System.Drawing.Size(130, 26)
    $preset.DropDownStyle = 'DropDownList'
    $preset.BackColor = Get-ManoUiColor 'CardAlt'
    $preset.ForeColor = Get-ManoUiColor 'Text'
    [void]$preset.Items.AddRange(@('10 min', '30 min', '1 h', '2 h', '3 h'))
    $numeric = New-Object System.Windows.Forms.NumericUpDown
    $numeric.Location = New-Object System.Drawing.Point(344, 220)
    $numeric.Size = New-Object System.Drawing.Size(70, 26)
    $numeric.Minimum = 1
    $numeric.Maximum = [int]$script:Cfg.TrustMaxMinutes
    $numeric.Value = [math]::Min(10, [int]$script:Cfg.TrustMaxMinutes)
    $numeric.BackColor = Get-ManoUiColor 'CardAlt'
    $numeric.ForeColor = Get-ManoUiColor 'Text'
    $numeric.BorderStyle = 'FixedSingle'
    if ($NoTrust) { $check.Enabled = $false; $numeric.Enabled = $false; $preset.Enabled = $false }
    $preset.Add_SelectedIndexChanged({
            $map = @{ '10 min' = 10; '30 min' = 30; '1 h' = 60; '2 h' = 120; '3 h' = 180 }
            $key = [string]$preset.SelectedItem
            if ($map.ContainsKey($key)) { $numeric.Value = [math]::Min([int]$map[$key], [int]$numeric.Maximum) }
        })
    $form.Controls.AddRange(@($check, $preset, $numeric))

    $count = New-Object System.Windows.Forms.Label
    $count.Location = New-Object System.Drawing.Point(24, 258)
    $count.Size = New-Object System.Drawing.Size(300, 20)
    $count.ForeColor = Get-ManoUiColor 'Muted'
    $count.BackColor = Get-ManoUiColor 'Bg'
    $form.Controls.Add($count)

    $ok = New-ManoUiButton -Parent $form -Text 'Permitir' -X 492 -Y 312 -W 124 -H 40 -Kind primary
    $cancel = New-ManoUiButton -Parent $form -Text 'Cancelar' -X 364 -Y 312 -W 118 -H 40 -Kind subtle

    $script:ConfirmResult = $false
    $script:ConfirmLeft = $timeout
    $ok.Add_Click({ $script:ConfirmResult = $true; $form.Close() })
    $cancel.Add_Click({ $form.Close() })
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
            $script:ConfirmLeft--
            $count.Text = "Se cancela solo en $($script:ConfirmLeft) s"
            if ($script:ConfirmLeft -le 0 -or (Test-ManoDisabled)) { $form.Close() }
        })
    $form.CancelButton = $cancel
    $count.Text = "Se cancela solo en $timeout s"
    $form.Add_Shown({ $form.Activate(); $cancel.Focus() })
    $timer.Start()
    [void]$form.ShowDialog()
    $timer.Stop()
    $form.Dispose()

    if (Test-ManoDisabled) { $script:ConfirmResult = $false }
    if ($script:ConfirmResult -and $check.Checked) { [void](Set-ManoTrustMinutes ([int]$numeric.Value)) }
    $verdict = if ($script:ConfirmResult) { 'PERMITIDO' } else { 'CANCELADO' }
    Write-ManoLog "$verdict : $(Get-ManoClipped ($Description -replace "`r`n", ' | ') 300)"
    [bool]$script:ConfirmResult
}


function Focus-ManoWindow {
    param([IntPtr]$Hwnd)
    Ensure-ManoNative
    if ([ManoNative.Win]::GetForegroundWindow() -eq $Hwnd) { return $true }
    if ($script:DryRun) { return $true }
    if ([ManoNative.Win]::IsIconic($Hwnd)) { [void][ManoNative.Win]::ShowWindow($Hwnd, 9) }
    $foreground = [ManoNative.Win]::GetForegroundWindow()
    $me = [ManoNative.Win]::GetCurrentThreadId()
    $t1 = [ManoNative.Win]::GetWindowThreadProcessId($foreground, [IntPtr]::Zero)
    $t2 = [ManoNative.Win]::GetWindowThreadProcessId($Hwnd, [IntPtr]::Zero)
    [void][ManoNative.Win]::AttachThreadInput($me, $t1, $true)
    [void][ManoNative.Win]::AttachThreadInput($me, $t2, $true)
    try {
        [ManoNative.Win]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
        [ManoNative.Win]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
        [void][ManoNative.Win]::BringWindowToTop($Hwnd)
        [void][ManoNative.Win]::SetForegroundWindow($Hwnd)
    } finally {
        [void][ManoNative.Win]::AttachThreadInput($me, $t1, $false)
        [void][ManoNative.Win]::AttachThreadInput($me, $t2, $false)
    }
    for ($i = 0; $i -lt 15; $i++) {
        if ([ManoNative.Win]::GetForegroundWindow() -eq $Hwnd) { return $true }
        Start-Sleep -Milliseconds 20
    }
    $false
}

function Assert-ManoNotPasswordField {
    if ($script:DryRun) { return }
    Ensure-ManoNative
    try { $focused = [System.Windows.Automation.AutomationElement]::FocusedElement } catch { $focused = $null }
    if ($null -eq $focused) { Throw-ManoError 'No puedo comprobar el campo enfocado; no escribo.' 1 }
    $isPassword = $false
    try { $isPassword = $focused.Current.IsPassword } catch { $isPassword = $false }
    if ($isPassword) { Throw-ManoError 'El campo enfocado es de CONTRASENA. Nunca escribo ahi.' 2 }
}

function Prepare-ManoAction {
    param([string]$Description)
    Ensure-ManoNative
    if (Test-ManoDisabled) { Throw-ManoError 'ManoSegura esta DESACTIVADA (boton de panico). Usa: enable' 2 }
    $hwnd = Get-ManoTarget
    $title = Assert-ManoWindowAllowed $hwnd
    [void](Assert-ManoWindowOnMonitor $hwnd)
    if (-not $script:BatchApproved) {
        if (-not (Confirm-ManoAction "$Description`r`nVentana: $title")) { Throw-ManoError "CANCELADO: $Description" 2 }
    }
    if (Test-ManoDisabled) { Throw-ManoError 'ManoSegura esta DESACTIVADA.' 2 }
    if (-not (Focus-ManoWindow $hwnd)) { Throw-ManoError 'No pude traer la ventana objetivo al frente.' 1 }
    [void](Assert-ManoWindowAllowed $hwnd)
    [pscustomobject]@{ Hwnd = $hwnd; Rect = (Get-ManoWindowRect $hwnd); Title = $title }
}

# =====================================================================================================
# 8. Capturas e input / screenshots and input
# =====================================================================================================
function Save-ManoBitmap {
    param($Bitmap, [string]$Path)

    if (-not $Path) {
        $ext = if ($script:Cfg.ShotFormat -eq 'jpg') { 'jpg' } else { 'png' }
        $Path = Join-Path $script:ShotsDir ("shot_{0:yyyyMMdd_HHmmss_fff}.{1}" -f (Get-Date), $ext)
    }
    $format = if ($Path -match '(?i)\.jpe?g$') { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
    $Bitmap.Save($Path, $format)
    $Bitmap.Dispose()
    Copy-Item -LiteralPath $Path -Destination (Join-Path $script:ShotsDir 'latest.png') -Force -ErrorAction SilentlyContinue
    Write-ManoLog "captura $Path"
    $Path
}

function Save-ManoScreenRect {
    param($Rect, [string]$Path)
    if ($script:DryRun) { return "[dry-run] capturaria $(Format-ManoRect $Rect)" }
    $bitmap = New-Object System.Drawing.Bitmap($Rect.Width, $Rect.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($Rect.Location, [System.Drawing.Point]::Empty, $Rect.Size)
    $graphics.Dispose()
    Save-ManoBitmap -Bitmap $bitmap -Path $Path
}

function Invoke-ManoClick {
    param([int]$X, [int]$Y, [string]$Button = 'left')
    $prepared = Prepare-ManoAction "Clic $Button en ($X,$Y)"
    $rect = $prepared.Rect
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $rect.Width -or $Y -ge $rect.Height) { Throw-ManoError "($X,$Y) esta fuera de la ventana ($($rect.Width)x$($rect.Height))." 1 }
    $screenX = $rect.X + $X
    $screenY = $rect.Y + $Y
    $target = Get-ManoTargetMonitor
    if (-not (Test-ManoPointInRect $screenX $screenY $target.Bounds)) { Throw-ManoError 'El punto no esta en el monitor objetivo.' 1 }
    if ($script:DryRun) { return "[dry-run] clic $Button en pantalla ($screenX,$screenY)" }
    [void][ManoNative.Win]::SetCursorPos($screenX, $screenY)
    Start-Sleep -Milliseconds ([int]$script:Cfg.ClickDelayMs)
    switch ($Button) {
        'right' {
            [ManoNative.Win]::mouse_event(0x0008, 0, 0, 0, [IntPtr]::Zero)
            [ManoNative.Win]::mouse_event(0x0010, 0, 0, 0, [IntPtr]::Zero)
        }
        'double' {
            [ManoNative.Win]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
            [ManoNative.Win]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 40
            [ManoNative.Win]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
            [ManoNative.Win]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        }
        default {
            [ManoNative.Win]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
            [ManoNative.Win]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        }
    }
    Write-ManoLog "HECHO clic $Button ($X,$Y) -> ($screenX,$screenY)"
    "OK clic $Button en ($X,$Y)"
}

function Invoke-ManoTypeText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { Throw-ManoError 'Uso: type "texto"' 1 }
    [void](Prepare-ManoAction "Escribir el texto:`r`n`"$(Get-ManoClipped $Text 200)`"")
    Assert-ManoNotPasswordField
    if ($script:DryRun) { return "[dry-run] escribiria $($Text.Length) caracteres" }
    $escaped = ($Text -replace '([+^%~(){}\[\]])', '{$1}') -replace "`r?`n", '{ENTER}'
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
    Write-ManoLog "HECHO escribir $($Text.Length) caracteres"
    "OK escrito ($($Text.Length) caracteres)"
}

function Invoke-ManoPasteText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { Throw-ManoError 'Uso: paste "texto"' 1 }
    [void](Prepare-ManoAction "Pegar el texto (portapapeles + Ctrl+V):`r`n`"$(Get-ManoClipped $Text 200)`"")
    Assert-ManoNotPasswordField
    if ($script:DryRun) { return "[dry-run] pegaria $($Text.Length) caracteres" }
    $old = $null
    try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $old = [System.Windows.Forms.Clipboard]::GetText() } } catch { }
    [System.Windows.Forms.Clipboard]::SetText($Text)
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 120
    try { if ($null -ne $old) { [System.Windows.Forms.Clipboard]::SetText($old) } else { [System.Windows.Forms.Clipboard]::Clear() } } catch { }
    Write-ManoLog "HECHO pegar $($Text.Length) caracteres"
    "OK pegado ($($Text.Length) caracteres)"
}

function Invoke-ManoKeyCombo {
    param([string]$Combo)
    $parsed = Convert-ManoKeyCombo $Combo
    [void](Prepare-ManoAction "Pulsar teclas: $Combo")
    if ($script:DryRun) { return "[dry-run] teclas $Combo" }
    [System.Windows.Forms.SendKeys]::SendWait($parsed.SendKeys)
    Write-ManoLog "HECHO tecla $Combo"
    "OK tecla $Combo"
}

function Invoke-ManoScroll {
    param([int]$Steps = -3, [int]$X = -1, [int]$Y = -1)
    $hwnd = Get-ManoTarget
    $rect = Assert-ManoWindowOnMonitor $hwnd
    if ($X -lt 0) { $X = [int]($rect.Width / 2) }
    if ($Y -lt 0) { $Y = [int]($rect.Height / 2) }
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $rect.Width -or $Y -ge $rect.Height) { Throw-ManoError 'Punto fuera de la ventana.' 1 }
    $direction = if ($Steps -lt 0) { 'abajo' } else { 'arriba' }
    $prepared = Prepare-ManoAction "Desplazar $([math]::Abs($Steps)) pasos hacia $direction en ($X,$Y)"
    if ($script:DryRun) { return "[dry-run] scroll $Steps" }
    [void][ManoNative.Win]::SetCursorPos($prepared.Rect.X + $X, $prepared.Rect.Y + $Y)
    [ManoNative.Win]::mouse_event(0x0800, 0, 0, 120 * $Steps, [IntPtr]::Zero)
    Write-ManoLog "HECHO scroll $Steps"
    "OK scroll $Steps"
}

function Invoke-ManoDrag {
    param([int]$FromX, [int]$FromY, [int]$ToX, [int]$ToY)
    $prepared = Prepare-ManoAction "Arrastrar de ($FromX,$FromY) a ($ToX,$ToY)"
    $rect = $prepared.Rect
    foreach ($point in @(@($FromX, $FromY), @($ToX, $ToY))) {
        if ($point[0] -lt 0 -or $point[1] -lt 0 -or $point[0] -ge $rect.Width -or $point[1] -ge $rect.Height) {
            Throw-ManoError "($($point[0]),$($point[1])) esta fuera de la ventana." 1
        }
    }
    if ($script:DryRun) { return "[dry-run] arrastraria de ($FromX,$FromY) a ($ToX,$ToY)" }
    $startX = $rect.X + $FromX
    $startY = $rect.Y + $FromY
    $endX = $rect.X + $ToX
    $endY = $rect.Y + $ToY
    [void][ManoNative.Win]::SetCursorPos($startX, $startY)
    Start-Sleep -Milliseconds 30
    [ManoNative.Win]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    $steps = 12
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($startX + (($endX - $startX) * $i / $steps))
        $y = [int]($startY + (($endY - $startY) * $i / $steps))
        [void][ManoNative.Win]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 15
    }
    [ManoNative.Win]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Write-ManoLog "HECHO drag ($FromX,$FromY)->($ToX,$ToY)"
    "OK arrastrado a ($ToX,$ToY)"
}

function Invoke-ManoScreenshot {
    param([string]$Mode = 'window', [string]$Path = '', [string]$MonitorSpec = '', [string]$HwndText = '')

    Ensure-ManoNative
    switch ($Mode) {
        'monitor' {
            $spec = if ($MonitorSpec) { $MonitorSpec } else { [string]$script:Cfg.TargetMonitor }
            $monitor = Select-ManoMonitor -Monitors (Get-ManoMonitors) -Spec $spec
            if ($null -eq $monitor) { Throw-ManoError "No encuentro el monitor '$spec'. Usa: monitors" 1 }
            return "Captura monitor $($monitor.DeviceName): $(Save-ManoScreenRect $monitor.Bounds $Path)"
        }
        'hwnd' {
            if (-not $HwndText) { Throw-ManoError 'Uso: shot --hwnd <hwnd> [ruta]' 1 }
            $value = [int64]0
            if (-not [int64]::TryParse($HwndText, [ref]$value)) { Throw-ManoError "hwnd no valido: $HwndText" 1 }
            $hwnd = [IntPtr]$value
            if (-not [ManoNative.Win]::IsWindow($hwnd)) { Throw-ManoError 'Ese hwnd no existe.' 1 }
            [void](Assert-ManoWindowAllowed $hwnd)
            $rect = Assert-ManoWindowOnMonitor $hwnd
            return "Captura ventana: $(Save-ManoScreenRect $rect $Path)"
        }
        default {
            $hwnd = Get-ManoTarget
            $title = Assert-ManoWindowAllowed $hwnd
            $rect = Assert-ManoWindowOnMonitor $hwnd
            if (-not $script:BatchApproved -and -not (Test-ManoTrustActive) -and $script:Cfg.ConfirmMode -ne 'auto' -and -not $script:DryRun -and -not $script:AutoYes) {
                if (-not (Confirm-ManoAction "Capturar la ventana '$(Get-ManoClipped $title 120)'")) { Throw-ManoError 'CANCELADO: captura' 2 }
            }
            return "Captura: $(Save-ManoScreenRect $rect $Path)  (ventana $($rect.Width)x$($rect.Height) en $($rect.X),$($rect.Y))"
        }
    }
}

# =====================================================================================================
# 9. Acciones / actions
# =====================================================================================================
function Invoke-ManoAction {
    param([string]$Action, [string[]]$ActionArgs = @())

    $a = @($ActionArgs)
    $showBadge = $false
    if (-not $script:Gui) {
        try { Update-ManoCursorBadge; [System.Windows.Forms.Application]::DoEvents(); $showBadge = $true } catch { }
    }
    try {
    switch ($Action.ToLowerInvariant()) {
        'focus' {
            if ($a.Count -lt 1) { Throw-ManoError 'Uso: focus <hwnd|titulo>' 1 }
            $window = Find-ManoWindow ($a -join ' ')
            $hwnd = [IntPtr][int64]$window.Hwnd
            [void](Assert-ManoWindowAllowed $hwnd)
            [void](Assert-ManoWindowOnMonitor $hwnd)
            if (-not $script:BatchApproved) {
                if (-not (Confirm-ManoAction "Elegir ventana objetivo: $($window.Titulo)")) { Throw-ManoError 'CANCELADO: focus' 2 }
            }
            Set-ManoTarget $hwnd
            [void](Focus-ManoWindow $hwnd)
            "OK objetivo: $($window.Hwnd)  $($window.Titulo)"
        }
        'screenshot' {
            $mode = 'window'; $path = ''; $monitorSpec = ''; $hwndText = ''
            for ($i = 0; $i -lt $a.Count; $i++) {
                switch -Regex ($a[$i]) {
                    '^--?monitor$' { if ($i + 1 -lt $a.Count) { $mode = 'monitor'; $monitorSpec = $a[++$i] } }
                    '^--?hwnd$' { if ($i + 1 -lt $a.Count) { $mode = 'hwnd'; $hwndText = $a[++$i] } }
                    '^--?format$' {
                        if ($i + 1 -lt $a.Count) {
                            $f = $a[++$i].TrimStart('.').ToLowerInvariant()
                            if ($f -in @('png', 'jpg', 'jpeg')) { $script:Cfg.ShotFormat = if ($f -eq 'jpeg') { 'jpg' } else { $f } }
                        }
                    }
                    '^--' { }
                    default { if (-not $path) { $path = $a[$i] } }
                }
            }
            Invoke-ManoScreenshot -Mode $mode -Path $path -MonitorSpec $monitorSpec -HwndText $hwndText
        }
        'click' {
            if ($a.Count -lt 2) { Throw-ManoError 'Uso: click x y [left|right|double]' 1 }
            $button = if ($a.Count -ge 3) { $a[2].ToLowerInvariant() } else { 'left' }
            if ($button -notin @('left', 'right', 'double')) { Throw-ManoError "Boton no valido: $button (left/right/double)" 1 }
            Invoke-ManoClick -X ([int]$a[0]) -Y ([int]$a[1]) -Button $button
        }
        'type' { Invoke-ManoTypeText ($a -join ' ') }
        'paste' { Invoke-ManoPasteText ($a -join ' ') }
        'key' { Invoke-ManoKeyCombo ($a -join '') }
        'scroll' {
            $steps = if ($a.Count -ge 1) { [int]$a[0] } else { -3 }
            $x = if ($a.Count -ge 3) { [int]$a[1] } else { -1 }
            $y = if ($a.Count -ge 3) { [int]$a[2] } else { -1 }
            Invoke-ManoScroll -Steps $steps -X $x -Y $y
        }
        'drag' {
            if ($a.Count -lt 4) { Throw-ManoError 'Uso: drag x1 y1 x2 y2' 1 }
            Invoke-ManoDrag -FromX ([int]$a[0]) -FromY ([int]$a[1]) -ToX ([int]$a[2]) -ToY ([int]$a[3])
        }
        'wait' {
            $ms = if ($a.Count -ge 1) { [int]$a[0] } else { 300 }
            if ($ms -lt 0) { $ms = 0 }
            if ($ms -gt 10000) { $ms = 10000 }
            if (-not $script:DryRun) { Start-Sleep -Milliseconds $ms }
            "OK espera $ms ms"
        }
        default { Throw-ManoError "Accion desconocida: $Action" 1 }
    }
    } finally {
        if ($showBadge) { try { Hide-ManoCursorBadge } catch { } }
    }
}

function Invoke-ManoBatchFile {
    param([string]$Source)
    $json = if ($Source -eq '-') { [Console]::In.ReadToEnd() } elseif (Test-Path -LiteralPath $Source) { Get-Content -LiteralPath $Source -Raw -Encoding UTF8 } else { $Source }
    $steps = Convert-ManoBatch -Json $json -MaxSteps ([int]$script:Cfg.MaxBatchSteps)
    if (Test-ManoDisabled) { Throw-ManoError 'ManoSegura esta DESACTIVADA.' 2 }
    $needsTarget = @($steps | Where-Object { $_.Cmd -in @('click', 'type', 'paste', 'key', 'scroll', 'drag') -or ($_.Cmd -eq 'screenshot' -and -not ($_.Args.Count -and ($_.Args[0] -in @('--monitor', '--hwnd')))) }).Count -gt 0
    if ($needsTarget -and $steps[0].Cmd -ne 'focus') { [void](Get-ManoTarget) }
    $summary = ($steps | ForEach-Object { "$($_.Index). $($_.Cmd) $(Get-ManoClipped ($_.Args -join ' ') 120)" }) -join "`r`n"
    if (-not (Confirm-ManoAction "Ejecutar $($steps.Count) pasos:`r`n$summary")) { Throw-ManoError 'CANCELADO: batch' 2 }
    $script:BatchApproved = $true
    try {
        foreach ($step in $steps) {
            if (Test-ManoDisabled) { Throw-ManoError 'PANICO: batch detenido.' 2 }
            $result = Invoke-ManoAction -Action $step.Cmd -ActionArgs $step.Args
            "[$($step.Index)/$($steps.Count)] $result"
        }
    } finally {
        $script:BatchApproved = $false
    }
    Write-ManoLog "HECHO batch $($steps.Count) pasos"
    "OK batch ($($steps.Count) pasos)"
}

# =====================================================================================================
# 10. Panico / panic
# =====================================================================================================
function Invoke-ManoPanic {
    Set-ManoDisabled -Disabled $true
    Clear-ManoTrust
    Write-ManoLog 'PANICO: acciones detenidas y ManoSegura desactivada'
    if ($script:Gui -and $script:Gui.Form -and -not $script:Gui.Form.IsDisposed) {
        Update-ManoGuiStatus
    }
    'PANICO: ManoSegura desactivada. Usa "enable" (o el boton Activar) para volver.'
}

# =====================================================================================================
# 11. Interfaz grafica / graphical interface
# =====================================================================================================
# =====================================================================================================
# 11. Interfaz grafica / graphical interface (tema oscuro moderno)
# =====================================================================================================
$script:Palette = @{
    Bg         = '#0B0F14'
    Side       = '#080B10'
    Card       = '#141B24'
    CardAlt    = '#1B2430'
    Text       = '#E8EEF5'
    Muted      = '#8FA1B5'
    Accent     = '#3DDC97'
    AccentText = '#052016'
    Danger     = '#E5484D'
    Warn       = '#F5A524'
    Border     = '#222C38'
}

function Get-ManoUiColor {
    param([string]$Name)
    [System.Drawing.ColorTranslator]::FromHtml($script:Palette[$Name])
}

function New-ManoUiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [double]$Size = 9.5, [switch]$Bold, [string]$Color = 'Text')
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $fontStyle = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $fontStyle)
    $label.ForeColor = Get-ManoUiColor $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($label)
    $label
}

function New-ManoUiButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Kind = 'ghost', [scriptblock]$OnClick)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = 'Hand'
    $button.TextAlign = 'MiddleCenter'
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    switch ($Kind) {
        'primary' {
            $button.BackColor = Get-ManoUiColor 'Accent'
            $button.ForeColor = Get-ManoUiColor 'AccentText'
            $button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(211, 255, 233)
        }
        'danger' {
            $button.BackColor = Get-ManoUiColor 'Danger'
            $button.ForeColor = [System.Drawing.Color]::White
            $button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 90, 94)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(190, 45, 50)
        }
        'subtle' {
            $button.BackColor = Get-ManoUiColor 'CardAlt'
            $button.ForeColor = Get-ManoUiColor 'Text'
            $button.FlatAppearance.BorderColor = Get-ManoUiColor 'Border'
            $button.FlatAppearance.BorderSize = 1
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(32, 42, 54)
        }
        default {
            $button.BackColor = Get-ManoUiColor 'CardAlt'
            $button.ForeColor = Get-ManoUiColor 'Text'
            $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(32, 42, 54)
            $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(25, 34, 44)
        }
    }
    if ($OnClick) { $button.Add_Click($OnClick) }
    $Parent.Controls.Add($button)
    $button
}

function New-ManoUiCard {
    param($Parent, [string]$Title, [int]$X, [int]$Y, [int]$W, [int]$H)
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($W, $H)
    $card.BackColor = Get-ManoUiColor 'Card'
    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 0)
    $accent.Size = New-Object System.Drawing.Size(3, $H)
    $accent.BackColor = Get-ManoUiColor 'Accent'
    $card.Controls.Add($accent)
    if ($Title) { [void](New-ManoUiLabel -Parent $card -Text $Title -X 14 -Y 10 -W ($W - 28) -H 22 -Size 11 -Bold -Color 'Text') }
    $Parent.Controls.Add($card)
    $card
}

function Update-ManoGuiStatus {
    if (-not $script:Gui -or -not $script:Gui.Form -or $script:Gui.Form.IsDisposed) { return }
    $g = $script:Gui
    $disabled = Test-ManoDisabled
    $trust = Test-ManoTrustActive
    $targetText = '(ninguna)'
    try {
        if (Test-Path -LiteralPath $script:TargetFile) {
            $value = [int64]0
            if ([int64]::TryParse((Get-Content -LiteralPath $script:TargetFile -Raw).Trim(), [ref]$value)) {
                $hwnd = [IntPtr]$value
                if ([ManoNative.Win]::IsWindow($hwnd)) { $targetText = "$value  $(Get-ManoWindowTitle $hwnd)" }
            }
        }
    } catch { }
    $monitorText = '?'
    try {
        $monitor = Get-ManoTargetMonitor
        $monitorText = "$($monitor.DeviceName) $(Format-ManoRect $monitor.Bounds)"
    } catch { }
    if ($disabled) {
        $stateText = 'DESACTIVADA'
        $stateColor = Get-ManoUiColor 'Danger'
    } elseif ($trust) {
        $stateText = 'CONFIANZA'
        $stateColor = Get-ManoUiColor 'Warn'
    } else {
        $stateText = 'ACTIVA'
        $stateColor = Get-ManoUiColor 'Accent'
    }
    if ($trust) {
        $expiry = Get-ManoTrustExpiry (Get-Content -LiteralPath $script:TrustFile -Raw -ErrorAction SilentlyContinue)
        if ($expiry) { $stateText += '  ' + $expiry.ToString('HH:mm') }
    }
    if ($g.SideState) {
        $g.SideState.Text = $stateText
        $g.SideState.ForeColor = $stateColor
    }
    if ($g.SideTarget) { $g.SideTarget.Text = 'Ventana: ' + (Get-ManoClipped $targetText 40) }
    if ($g.SideMonitor) { $g.SideMonitor.Text = 'Monitor: ' + (Get-ManoClipped $monitorText 34) }
    if ($g.SideHotkey) { $g.SideHotkey.Text = 'Panico: ' + $script:Cfg.PanicHotkey }
    if ($g.TopTrust) {
        $g.TopTrust.Text = if ($trust) { 'Ampliar tiempo' } else { 'Confiar' }
        $g.TopTrust.BackColor = if ($trust) { Get-ManoUiColor 'Warn' } else { Get-ManoUiColor 'Accent' }
        $g.TopTrust.ForeColor = Get-ManoUiColor 'AccentText'
    }
    if ($g.TopUntrust) { $g.TopUntrust.Visible = $trust }
    if ($g.TopActivate) { $g.TopActivate.Enabled = $disabled; $g.TopActivate.Visible = $disabled }
    if ($g.Panic) { $g.Panic.Enabled = -not $disabled }
    $aiName = Get-ManoAiName
    if ($g.StatusLabel) {
        $g.StatusLabel.Text = 'Estado: ' + $stateText + '   |   IA: ' + $aiName + '   |   Ventana: ' + (Get-ManoClipped $targetText 45) + '   |   Monitor: ' + $monitorText
    }
    if ($g.Form) { $g.Form.Text = "ManoSegura $($script:Version) - mano remota segura - IA: $aiName" }
}

function Show-ManoOverlayEdges {
    param($Rect, [System.Drawing.Color]$Color)
    if (-not $script:Gui) { return }
    $g = $script:Gui
    if (-not $g.OverlayForms) {
        $forms = New-Object System.Collections.Generic.List[object]
        foreach ($i in 1..4) {
            $f = New-Object ManoForms.NoActivateForm
            $f.FormBorderStyle = 'None'
            $f.ShowInTaskbar = $false
            $f.TopMost = $true
            $f.StartPosition = 'Manual'
            $f.BackColor = $Color
            $f.Opacity = 0.92
            $forms.Add($f)
        }
        $g.OverlayForms = $forms
    }
    $thickness = 4
    $top = New-Object System.Drawing.Rectangle($Rect.X, $Rect.Y, $Rect.Width, $thickness)
    $bottom = New-Object System.Drawing.Rectangle($Rect.X, ($Rect.Y + $Rect.Height - $thickness), $Rect.Width, $thickness)
    $left = New-Object System.Drawing.Rectangle($Rect.X, $Rect.Y, $thickness, $Rect.Height)
    $right = New-Object System.Drawing.Rectangle(($Rect.X + $Rect.Width - $thickness), $Rect.Y, $thickness, $Rect.Height)
    $rects = @($top, $bottom, $left, $right)
    for ($i = 0; $i -lt 4; $i++) {
        $f = $g.OverlayForms[$i]
        $f.BackColor = $Color
        $f.Bounds = $rects[$i]
        if (-not $f.Visible) { $f.Show() }
    }
    $g.OverlayShown = $true
}

function Hide-ManoConsoleWindow {
    if ($script:IsLibrary) { return }
    try {
        Ensure-ManoNative
        $console = [ManoNative.Win]::GetConsoleWindow()
        if ($console -ne [IntPtr]::Zero) { [void][ManoNative.Win]::ShowWindow($console, 0) }
    } catch { }
}

function Hide-ManoOverlay {
    if (-not $script:Gui -or -not $script:Gui.OverlayForms) { return }
    foreach ($f in $script:Gui.OverlayForms) {
        if ($f.Visible) { $f.Hide() }
    }
    $script:Gui.OverlayShown = $false
}

function Ensure-ManoCursorBadge {
    Ensure-ManoNative
    if ($script:CursorBadge) { return }
    $form = New-Object ManoForms.CursorBadgeForm
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.BackColor = Get-ManoUiColor 'Card'
    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleLeft'
    $label.Padding = New-Object System.Windows.Forms.Padding(8, 0, 10, 0)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $label.ForeColor = Get-ManoUiColor 'Accent'
    $label.BackColor = Get-ManoUiColor 'Card'
    $form.Controls.Add($label)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Left'
    $bar.Width = 3
    $bar.BackColor = Get-ManoUiColor 'Accent'
    $form.Controls.Add($bar)
    $script:CursorBadge = @{ Form = $form; Label = $label }
}

function Update-ManoCursorBadge {
    if (-not $script:Cfg) { return }
    if (-not $script:Cfg.ShowAiLabel -or (Test-ManoDisabled)) { Hide-ManoCursorBadge; return }
    try {
        Ensure-ManoCursorBadge
        $badge = $script:CursorBadge
        $name = Get-ManoAiName
        $text = "$([char]0x270B) $name"
        if ($badge.Label.Text -ne $text) {
            $badge.Label.Text = $text
            $measured = [System.Windows.Forms.TextRenderer]::MeasureText($text, $badge.Label.Font)
            $badge.Form.Size = New-Object System.Drawing.Size(($measured.Width + 30), [math]::Max(28, $measured.Height + 10))
        }
        $position = [System.Windows.Forms.Cursor]::Position
        $screen = [System.Windows.Forms.Screen]::FromPoint($position)
        $area = $screen.WorkingArea
        $x = $position.X + 20
        $y = $position.Y + 20
        if (($x + $badge.Form.Width) -gt ($area.X + $area.Width)) { $x = $position.X - $badge.Form.Width - 12 }
        if (($y + $badge.Form.Height) -gt ($area.Y + $area.Height)) { $y = $position.Y - $badge.Form.Height - 12 }
        if ($x -lt $area.X) { $x = $area.X }
        if ($y -lt $area.Y) { $y = $area.Y }
        $badge.Form.Location = New-Object System.Drawing.Point($x, $y)
        if (-not $badge.Form.Visible) { $badge.Form.Show() }
    } catch { }
}

function Hide-ManoCursorBadge {
    if ($script:CursorBadge -and $script:CursorBadge.Form -and $script:CursorBadge.Form.Visible) {
        try { $script:CursorBadge.Form.Hide() } catch { }
    }
}

function Update-ManoOverlay {
    if (-not $script:Gui -or -not $script:Gui.Form -or $script:Gui.Form.IsDisposed) { return }
    $show = $false
    if ($script:Cfg.Overlay -and -not (Test-ManoDisabled)) {
        try {
            if (Test-Path -LiteralPath $script:TargetFile) {
                $hwnd = Get-ManoTarget
                if ([ManoNative.Win]::IsWindowVisible($hwnd) -and -not [ManoNative.Win]::IsIconic($hwnd)) {
                    $rect = Get-ManoWindowRect $hwnd
                    $color = if (Test-ManoTrustActive) { Get-ManoUiColor 'Danger' } else { Get-ManoUiColor 'Warn' }
                    Show-ManoOverlayEdges -Rect $rect -Color $color
                    $show = $true
                }
            }
        } catch { }
    }
    if (-not $show) { Hide-ManoOverlay }
}

function Update-ManoGuiWindowList {
    if (-not $script:Gui -or -not $script:Gui.Form -or $script:Gui.Form.IsDisposed) { return }
    $g = $script:Gui
    if (-not $g.WindowGrid) { return }
    try {
        $windows = Get-ManoWindows
        $filter = ([string]$g.FilterBox.Text).Trim()
        $g.WindowGrid.SuspendLayout()
        $g.WindowGrid.Rows.Clear()
        foreach ($window in $windows) {
            if ($filter -and ($window.Titulo -notlike "*$filter*") -and ($window.Proceso -notlike "*$filter*")) { continue }
            $process = if ($window.Proceso) { [string]$window.Proceso } else { '?' }
            $monitor = if ($window.Monitor) { [string]$window.Monitor } else { '-' }
            $blocked = if ($window.Bloqueada) { 'SI' } else { '' }
            $index = $g.WindowGrid.Rows.Add("$($window.Hwnd)", $process, $window.Titulo, $monitor, $blocked)
            $row = $g.WindowGrid.Rows[$index]
            $row.Tag = $window.Hwnd
            if ($window.Bloqueada) { $row.DefaultCellStyle.ForeColor = Get-ManoUiColor 'Danger' }
        }
        $g.WindowGrid.ResumeLayout()
        $g.LastRefresh = Get-Date
        if ($g.CountLabel) { $g.CountLabel.Text = "$($g.WindowGrid.Rows.Count) ventanas" }
    } catch {
        try { $g.WindowGrid.ResumeLayout() } catch { }
    }
}

function Show-ManoInputDialog {
    param([string]$Title, [string]$Label, [string]$DefaultValue = '')
    Ensure-ManoNative
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(460, 190)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.BackColor = Get-ManoUiColor 'Bg'
    $form.ForeColor = Get-ManoUiColor 'Text'
    [void](New-ManoUiLabel -Parent $form -Text $Label -X 16 -Y 16 -W 420 -H 22 -Size 9.5)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(16, 44)
    $box.Size = New-Object System.Drawing.Size(412, 26)
    $box.BackColor = Get-ManoUiColor 'Card'
    $box.ForeColor = Get-ManoUiColor 'Text'
    $box.BorderStyle = 'FixedSingle'
    $box.Text = $DefaultValue
    $form.Controls.Add($box)
    $ok = New-ManoUiButton -Parent $form -Text 'Aceptar' -X 246 -Y 96 -W 88 -H 34 -Kind primary
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-ManoUiButton -Parent $form -Text 'Cancelar' -X 340 -Y 96 -W 88 -H 34 -Kind subtle
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $result = $form.ShowDialog()
    $value = $box.Text
    $form.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $value } else { $null }
}

function Invoke-ManoGuiAction {
    param([scriptblock]$Script, [object[]]$Arguments = @())
    if (-not $script:Gui -or -not $script:Gui.Form) { return }
    try {
        $output = & $Script @Arguments
        if ($output) { $script:Gui.LogBox.AppendText("$output" + [Environment]::NewLine) }
        Update-ManoGuiStatus
        Update-ManoOverlay
    } catch [ManoError] {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ManoSegura', 'OK', 'Warning')
        $script:Gui.LogBox.AppendText('ERROR: ' + $_.Exception.Message + [Environment]::NewLine)
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ManoSegura - error', 'OK', 'Error')
        $script:Gui.LogBox.AppendText('ERROR: ' + $_.Exception.Message + [Environment]::NewLine)
    }
    $script:Gui.LogBox.SelectionStart = $script:Gui.LogBox.TextLength
    $script:Gui.LogBox.ScrollToCaret()
}

function Show-ManoSection {
    param([string]$Name)
    if (-not $script:Gui) { return }
    $g = $script:Gui
    foreach ($key in $g.Sections.Keys) {
        $g.Sections[$key].Visible = ($key -eq $Name)
    }
    foreach ($entry in $g.NavItems) {
        $active = ($entry.Name -eq $Name)
        $entry.Button.BackColor = if ($active) { Get-ManoUiColor 'Card' } else { Get-ManoUiColor 'Side' }
        $entry.Button.ForeColor = if ($active) { Get-ManoUiColor 'Text' } else { Get-ManoUiColor 'Muted' }
        $entry.Bar.Visible = $active
    }
    if ($g.HeaderTitle) { $g.HeaderTitle.Text = $g.SectionTitles[$Name] }
    if ($g.HeaderSub) { $g.HeaderSub.Text = $g.SectionSubtitles[$Name] }
    $g.ActiveSection = $Name
}

function New-ManoNavItem {
    param($Parent, [string]$Name, [string]$Text, [int]$Y)
    $holder = New-Object System.Windows.Forms.Panel
    $holder.Location = New-Object System.Drawing.Point(0, $Y)
    $holder.Size = New-Object System.Drawing.Size(236, 46)
    $holder.BackColor = Get-ManoUiColor 'Side'
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point(0, 8)
    $bar.Size = New-Object System.Drawing.Size(3, 30)
    $bar.BackColor = Get-ManoUiColor 'Accent'
    $bar.Visible = $false
    $button = New-Object System.Windows.Forms.Button
    $button.Text = '   ' + $Text
    $button.Location = New-Object System.Drawing.Point(3, 0)
    $button.Size = New-Object System.Drawing.Size(233, 46)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.TextAlign = 'MiddleLeft'
    $button.TabStop = $false
    $button.BackColor = Get-ManoUiColor 'Side'
    $button.ForeColor = Get-ManoUiColor 'Muted'
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $button.Cursor = 'Hand'
    $button.Add_Click($OnClick)
    $holder.Controls.Add($bar)
    $holder.Controls.Add($button)
    $Parent.Controls.Add($holder)
    [pscustomobject]@{ Name = $Name; Button = $button; Bar = $bar; Holder = $holder }
}

function Show-ManoGui {
    Ensure-ManoNative
    Hide-ManoConsoleWindow
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ManoSegura $($script:Version) - mano remota segura"
    $form.Size = New-Object System.Drawing.Size(1180, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(1020, 680)
    $monitor = Get-ManoTargetMonitor
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(($monitor.Bounds.X + [int](($monitor.Bounds.Width - 1180) / 2)), ($monitor.Bounds.Y + [int](($monitor.Bounds.Height - 760) / 2)))
    $form.BackColor = Get-ManoUiColor 'Bg'
    $form.ForeColor = Get-ManoUiColor 'Text'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

    $g = @{
        Form = $form; OverlayForms = $null; OverlayShown = $false; LastRefresh = (Get-Date)
        Sections = @{}; NavItems = @(); ActiveSection = 'windows'
        SectionTitles = @{ windows = 'Ventanas'; actions = 'Acciones'; settings = 'Ajustes'; log = 'Registro' }
        SectionSubtitles = @{
            windows  = 'Elige la ventana que puede controlar el asistente (una sola).'
            actions  = 'Acciones puntuales sobre la ventana objetivo.'
            settings = 'Opciones de ManoSegura; se guardan en config.json.'
            log      = 'Historial de acciones y avisos.'
        }
    }
    $script:Gui = $g

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 2
    $root.RowCount = 2
    $root.BackColor = Get-ManoUiColor 'Bg'
    $root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 236))) | Out-Null
    $root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $form.Controls.Add($root)

    # ---------------- barra lateral ----------------
    $side = New-Object System.Windows.Forms.Panel
    $side.Dock = 'Fill'
    $side.Margin = New-Object System.Windows.Forms.Padding(0)
    $side.BackColor = Get-ManoUiColor 'Side'
    $root.Controls.Add($side, 0, 0)
    $root.SetRowSpan($side, 2)

    $logo = New-Object System.Windows.Forms.Panel
    $logo.Location = New-Object System.Drawing.Point(22, 22)
    $logo.Size = New-Object System.Drawing.Size(38, 38)
    $logo.BackColor = Get-ManoUiColor 'Accent'
    $side.Controls.Add($logo)
    $logoText = New-Object System.Windows.Forms.Label
    $logoText.Text = 'M'
    $logoText.Dock = 'Fill'
    $logoText.TextAlign = 'MiddleCenter'
    $logoText.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $logoText.ForeColor = Get-ManoUiColor 'AccentText'
    $logo.Controls.Add($logoText)
    [void](New-ManoUiLabel -Parent $side -Text 'ManoSegura' -X 70 -Y 22 -W 150 -H 22 -Size 14 -Bold)
    [void](New-ManoUiLabel -Parent $side -Text 'mano remota segura' -X 70 -Y 44 -W 150 -H 16 -Size 8.5 -Color 'Muted')

    $navY = 96
    foreach ($item in @(
            @{ Name = 'windows'; Text = 'Ventanas' },
            @{ Name = 'actions'; Text = 'Acciones' },
            @{ Name = 'settings'; Text = 'Ajustes' },
            @{ Name = 'log'; Text = 'Registro' }
        )) {
        $navName = $item.Name
        $navButton = New-ManoNavItem -Parent $side -Name $navName -Text $item.Text -Y $navY
        $g.NavItems += $navButton
        $navY += 50
    }

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 240
    $bottom.BackColor = Get-ManoUiColor 'Side'
    $side.Controls.Add($bottom)
    $line = New-Object System.Windows.Forms.Panel
    $line.Dock = 'Top'
    $line.Height = 1
    $line.BackColor = Get-ManoUiColor 'Border'
    $bottom.Controls.Add($line)
    $g.SideState = New-ManoUiLabel -Parent $bottom -Text 'ACTIVA' -X 22 -Y 16 -W 150 -H 20 -Size 9 -Bold -Color 'Accent'
    $g.SideTarget = New-ManoUiLabel -Parent $bottom -Text 'Ventana: (ninguna)' -X 22 -Y 44 -W 196 -H 18 -Size 8.5 -Color 'Muted'
    $g.SideMonitor = New-ManoUiLabel -Parent $bottom -Text 'Monitor: ?' -X 22 -Y 64 -W 196 -H 18 -Size 8.5 -Color 'Muted'
    $g.SideHotkey = New-ManoUiLabel -Parent $bottom -Text ('Panico: ' + $script:Cfg.PanicHotkey) -X 22 -Y 84 -W 196 -H 18 -Size 8.5 -Color 'Muted'
    $g.Panic = New-ManoUiButton -Parent $bottom -Text 'PANICO' -X 22 -Y 112 -W 192 -H 50 -Kind danger
    $g.Panic.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $g.Panic.Add_Click({
            Invoke-ManoPanic | Out-Null
            $script:Gui.LogBox.AppendText('PANICO: ManoSegura desactivada.' + [Environment]::NewLine)
            Update-ManoGuiStatus
        })
    [void](New-ManoUiLabel -Parent $bottom -Text 'Atajo de panico global.' -X 22 -Y 170 -W 196 -H 16 -Size 8 -Color 'Muted')
    [void](New-ManoUiLabel -Parent $bottom -Text "v$($script:Version)" -X 22 -Y 204 -W 100 -H 16 -Size 8 -Color 'Muted')

    # ---------------- area principal ----------------
    $main = New-Object System.Windows.Forms.Panel
    $main.Dock = 'Fill'
    $main.Margin = New-Object System.Windows.Forms.Padding(0)
    $main.Padding = New-Object System.Windows.Forms.Padding(24, 14, 24, 10)
    $main.BackColor = Get-ManoUiColor 'Bg'
    $root.Controls.Add($main, 1, 0)

    $mainTable = New-Object System.Windows.Forms.TableLayoutPanel
    $mainTable.Dock = 'Fill'
    $mainTable.Margin = New-Object System.Windows.Forms.Padding(0)
    $mainTable.ColumnCount = 1
    $mainTable.RowCount = 2
    $mainTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 74))) | Out-Null
    $mainTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $main.Controls.Add($mainTable)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Fill'
    $header.Margin = New-Object System.Windows.Forms.Padding(0)
    $header.BackColor = Get-ManoUiColor 'Bg'
    $mainTable.Controls.Add($header, 0, 0)

    $headTable = New-Object System.Windows.Forms.TableLayoutPanel
    $headTable.Dock = 'Fill'
    $headTable.Margin = New-Object System.Windows.Forms.Padding(0)
    $headTable.ColumnCount = 2
    $headTable.RowCount = 1
    $headTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $headTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 430))) | Out-Null
    $header.Controls.Add($headTable)

    $headLeft = New-Object System.Windows.Forms.Panel
    $headLeft.Dock = 'Fill'
    $headLeft.Margin = New-Object System.Windows.Forms.Padding(0)
    $headLeft.BackColor = Get-ManoUiColor 'Bg'
    $headTable.Controls.Add($headLeft, 0, 0)
    $g.HeaderTitle = New-ManoUiLabel -Parent $headLeft -Text 'Ventanas' -X 0 -Y 2 -W 460 -H 32 -Size 18 -Bold
    $g.HeaderSub = New-ManoUiLabel -Parent $headLeft -Text '' -X 0 -Y 40 -W 560 -H 20 -Size 9 -Color 'Muted'

    $headRight = New-Object System.Windows.Forms.Panel
    $headRight.Dock = 'Fill'
    $headRight.Margin = New-Object System.Windows.Forms.Padding(0)
    $headRight.BackColor = Get-ManoUiColor 'Bg'
    $headTable.Controls.Add($headRight, 1, 0)
    $g.TrustPreset = New-Object System.Windows.Forms.ComboBox
    $g.TrustPreset.Location = New-Object System.Drawing.Point(0, 15)
    $g.TrustPreset.Size = New-Object System.Drawing.Size(130, 28)
    $g.TrustPreset.DropDownStyle = 'DropDownList'
    $g.TrustPreset.BackColor = Get-ManoUiColor 'CardAlt'
    $g.TrustPreset.ForeColor = Get-ManoUiColor 'Text'
    $g.TrustPreset.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    [void]$g.TrustPreset.Items.AddRange(@('10 min', '30 min', '1 h', '2 h', '3 h', 'Personalizado...'))
    $g.TrustPreset.SelectedIndex = 0
    $headRight.Controls.Add($g.TrustPreset)
    $g.TopTrust = New-ManoUiButton -Parent $headRight -Text 'Confiar' -X 138 -Y 10 -W 150 -H 38 -Kind primary
    $g.TopTrust.Add_Click({
            $spec = [string]$script:Gui.TrustPreset.SelectedItem
            try {
                if ($spec -like 'Personalizado*') {
                    $custom = Show-ManoInputDialog -Title 'Tiempo de confianza' -Label 'Cuanto tiempo? (ej: 45m, 1h30m, 90)' -DefaultValue '45'
                    if (-not $custom) { return }
                    $minutes = Convert-ManoTrustSpec $custom
                } elseif ($spec -match '^(\d+)\s*min$') {
                    $minutes = [int]$Matches[1]
                } elseif ($spec -match '^(\d+)\s*h$') {
                    $minutes = [int]$Matches[1] * 60
                } else {
                    $minutes = Convert-ManoTrustSpec $spec
                }
                if (Test-ManoTrustActive) {
                    $result = Add-ManoTrustMinutes $minutes
                    $script:Gui.LogBox.AppendText("Confianza +$minutes min (hasta $($result.Expiry.ToString('HH:mm')))" + [Environment]::NewLine)
                } else {
                    [void](Set-ManoTrustMinutes $minutes)
                    $script:Gui.LogBox.AppendText("Confianza $minutes min" + [Environment]::NewLine)
                }
                Update-ManoGuiStatus
            } catch [ManoError] {
                [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ManoSegura', 'OK', 'Warning')
            } catch {
                [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ManoSegura', 'OK', 'Error')
            }
        })
    $g.TopUntrust = New-ManoUiButton -Parent $headRight -Text 'Quitar' -X 296 -Y 10 -W 80 -H 38 -Kind subtle
    $g.TopUntrust.Add_Click({ Clear-ManoTrust; Update-ManoGuiStatus })
    $g.TopActivate = New-ManoUiButton -Parent $headRight -Text 'Activar' -X 306 -Y 10 -W 100 -H 38 -Kind primary
    $g.TopActivate.Add_Click({
            Set-ManoDisabled -Disabled $false
            Update-ManoGuiStatus
        })

    $hostPanel = New-Object System.Windows.Forms.Panel
    $hostPanel.Dock = 'Fill'
    $hostPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $hostPanel.BackColor = Get-ManoUiColor 'Bg'
    $mainTable.Controls.Add($hostPanel, 0, 1)

    # ---------------- seccion Ventanas ----------------
    $windowsPanel = New-Object System.Windows.Forms.Panel
    $windowsPanel.Dock = 'Fill'
    $windowsPanel.BackColor = Get-ManoUiColor 'Bg'
    $hostPanel.Controls.Add($windowsPanel)
    $g.Sections['windows'] = $windowsPanel

    $winTable = New-Object System.Windows.Forms.TableLayoutPanel
    $winTable.Dock = 'Fill'
    $winTable.ColumnCount = 1
    $winTable.RowCount = 3
    $winTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44))) | Out-Null
    $winTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $winTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56))) | Out-Null
    $windowsPanel.Controls.Add($winTable)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = 'Fill'
    $toolbar.Margin = New-Object System.Windows.Forms.Padding(0)
    $toolbar.BackColor = Get-ManoUiColor 'Bg'
    $winTable.Controls.Add($toolbar, 0, 0)
    $g.FilterBox = New-Object System.Windows.Forms.TextBox
    $g.FilterBox.Location = New-Object System.Drawing.Point(0, 6)
    $g.FilterBox.Size = New-Object System.Drawing.Size(300, 28)
    $g.FilterBox.BackColor = Get-ManoUiColor 'Card'
    $g.FilterBox.ForeColor = Get-ManoUiColor 'Text'
    $g.FilterBox.BorderStyle = 'FixedSingle'
    $g.FilterBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $g.FilterBox.Add_TextChanged({ Update-ManoGuiWindowList })
    $toolbar.Controls.Add($g.FilterBox)
    $placeholder = New-ManoUiLabel -Parent $toolbar -Text 'Filtrar por titulo o proceso...' -X 10 -Y 10 -W 260 -H 18 -Size 9 -Color 'Muted'
    $placeholder.BackColor = Get-ManoUiColor 'Card'
    $placeholder.BringToFront()
    $g.FilterPlaceholder = $placeholder
    $placeholder.Add_Click({ $script:Gui.FilterBox.Focus(); $script:Gui.FilterPlaceholder.Visible = $false })
    $g.FilterBox.Add_GotFocus({ $script:Gui.FilterPlaceholder.Visible = $false })
    $g.FilterBox.Add_LostFocus({ if (-not $script:Gui.FilterBox.Text) { $script:Gui.FilterPlaceholder.Visible = $true } })
    $refresh = New-ManoUiButton -Parent $toolbar -Text 'Refrescar' -X 312 -Y 4 -W 96 -H 32 -Kind subtle
    $refresh.Add_Click({ Update-ManoGuiWindowList })
    $g.AutoRefresh = New-Object System.Windows.Forms.CheckBox
    $g.AutoRefresh.Text = 'Auto 5 s'
    $g.AutoRefresh.Location = New-Object System.Drawing.Point(420, 10)
    $g.AutoRefresh.Size = New-Object System.Drawing.Size(90, 22)
    $g.AutoRefresh.ForeColor = Get-ManoUiColor 'Muted'
    $g.AutoRefresh.BackColor = Get-ManoUiColor 'Bg'
    $g.AutoRefresh.Checked = $true
    $toolbar.Controls.Add($g.AutoRefresh)
    $g.CountLabel = New-ManoUiLabel -Parent $toolbar -Text '' -X 520 -Y 12 -W 120 -H 18 -Size 8.5 -Color 'Muted'

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.Margin = New-Object System.Windows.Forms.Padding(0)
    $grid.BackgroundColor = Get-ManoUiColor 'Card'
    $grid.BorderStyle = 'None'
    $grid.GridColor = Get-ManoUiColor 'Border'
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.ColumnHeadersHeight = 34
    $grid.RowTemplate.Height = 30
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = Get-ManoUiColor 'CardAlt'
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = Get-ManoUiColor 'Muted'
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Get-ManoUiColor 'CardAlt'
    $grid.DefaultCellStyle.BackColor = Get-ManoUiColor 'Card'
    $grid.DefaultCellStyle.ForeColor = Get-ManoUiColor 'Text'
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(31, 43, 56)
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $grid.Columns.Add('hwnd', 'HWND') | Out-Null
    $grid.Columns.Add('process', 'Proceso') | Out-Null
    $grid.Columns.Add('title', 'Titulo') | Out-Null
    $grid.Columns.Add('monitor', 'Monitor') | Out-Null
    $grid.Columns.Add('blocked', 'Bloq.') | Out-Null
    $grid.Columns['hwnd'].FillWeight = 12
    $grid.Columns['process'].FillWeight = 18
    $grid.Columns['title'].FillWeight = 46
    $grid.Columns['monitor'].FillWeight = 16
    $grid.Columns['blocked'].FillWeight = 8
    foreach ($name in @('hwnd', 'process', 'title', 'monitor', 'blocked')) { $grid.Columns[$name].SortMode = 'NotSortable' }
    $grid.Add_CellDoubleClick({ Use-ManoSelectedWindow })
    $winTable.Controls.Add($grid, 0, 1)
    $g.WindowGrid = $grid

    $windowsFooter = New-Object System.Windows.Forms.Panel
    $windowsFooter.Dock = 'Fill'
    $windowsFooter.Margin = New-Object System.Windows.Forms.Padding(0)
    $windowsFooter.BackColor = Get-ManoUiColor 'Bg'
    $winTable.Controls.Add($windowsFooter, 0, 2)
    $useButton = New-ManoUiButton -Parent $windowsFooter -Text 'Usar como objetivo' -X 0 -Y 12 -W 170 -H 36 -Kind primary
    $useButton.Add_Click({ Use-ManoSelectedWindow })
    $captureButton = New-ManoUiButton -Parent $windowsFooter -Text 'Capturar ventana' -X 180 -Y 12 -W 150 -H 36 -Kind subtle
    $captureButton.Add_Click({ Invoke-ManoGuiAction -Script { Invoke-ManoScreenshot -Mode window } })
    [void](New-ManoUiLabel -Parent $windowsFooter -Text 'Doble clic en una fila para elegirla.' -X 350 -Y 20 -W 300 -H 18 -Size 8.5 -Color 'Muted')

    # ---------------- seccion Acciones ----------------
    $actionsPanel = New-Object System.Windows.Forms.Panel
    $actionsPanel.Dock = 'Fill'
    $actionsPanel.BackColor = Get-ManoUiColor 'Bg'
    $actionsPanel.AutoScroll = $true
    $hostPanel.Controls.Add($actionsPanel)
    $actionsPanel.Visible = $false
    $g.Sections['actions'] = $actionsPanel
    Add-ManoGuiActionPanel -Parent $actionsPanel

    # ---------------- seccion Ajustes ----------------
    $settingsPanel = New-Object System.Windows.Forms.Panel
    $settingsPanel.Dock = 'Fill'
    $settingsPanel.BackColor = Get-ManoUiColor 'Bg'
    $settingsPanel.AutoScroll = $true
    $hostPanel.Controls.Add($settingsPanel)
    $settingsPanel.Visible = $false
    $g.Sections['settings'] = $settingsPanel
    Add-ManoGuiSettingsPanel -Parent $settingsPanel

    # ---------------- seccion Registro ----------------
    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = 'Fill'
    $logPanel.BackColor = Get-ManoUiColor 'Bg'
    $hostPanel.Controls.Add($logPanel)
    $logPanel.Visible = $false
    $g.Sections['log'] = $logPanel
    $logTable = New-Object System.Windows.Forms.TableLayoutPanel
    $logTable.Dock = 'Fill'
    $logTable.ColumnCount = 1
    $logTable.RowCount = 2
    $logTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $logTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $logPanel.Controls.Add($logTable)
    $g.LogBox = New-Object System.Windows.Forms.TextBox
    $g.LogBox.Multiline = $true
    $g.LogBox.ReadOnly = $true
    $g.LogBox.ScrollBars = 'Vertical'
    $g.LogBox.Dock = 'Fill'
    $g.LogBox.Margin = New-Object System.Windows.Forms.Padding(0)
    $g.LogBox.BackColor = [System.Drawing.Color]::FromArgb(6, 9, 12)
    $g.LogBox.ForeColor = [System.Drawing.Color]::FromArgb(198, 214, 229)
    $g.LogBox.BorderStyle = 'None'
    $g.LogBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $g.LogBox.WordWrap = $true
    $logTable.Controls.Add($g.LogBox, 0, 0)
    $logFooter = New-Object System.Windows.Forms.Panel
    $logFooter.Dock = 'Fill'
    $logFooter.Margin = New-Object System.Windows.Forms.Padding(0)
    $logFooter.BackColor = Get-ManoUiColor 'Bg'
    $logTable.Controls.Add($logFooter, 0, 1)
    $logRefresh = New-ManoUiButton -Parent $logFooter -Text 'Actualizar' -X 0 -Y 8 -W 110 -H 34 -Kind subtle
    $logRefresh.Add_Click({ Show-ManoGuiLog })
    $logOpen = New-ManoUiButton -Parent $logFooter -Text 'Abrir carpeta' -X 120 -Y 8 -W 130 -H 34 -Kind subtle
    $logOpen.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:LogsDir)`"" })

    # ---------------- barra inferior ----------------
    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Dock = 'Fill'
    $statusBar.Margin = New-Object System.Windows.Forms.Padding(0)
    $statusBar.BackColor = Get-ManoUiColor 'Side'
    $root.Controls.Add($statusBar, 1, 1)
    $g.StatusLabel = New-ManoUiLabel -Parent $statusBar -Text 'Listo.' -X 12 -Y 6 -W 900 -H 18 -Size 8.5 -Color 'Muted'
    $hintLabel = New-ManoUiLabel -Parent $statusBar -Text 'CLI: ManoSegura.ps1 help' -X 950 -Y 6 -W 220 -H 18 -Size 8.5 -Color 'Muted'
    $hintLabel.Anchor = 'Top,Right'

    $form.Add_Shown({
            try { $dark = 1; [void][ManoNative.Win]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4) } catch { }
            $initialSection = if ($env:MANOSEGURA_GUI_SECTION) { $env:MANOSEGURA_GUI_SECTION } else { 'windows' }
            Show-ManoSection $initialSection
            Update-ManoGuiStatus
            Update-ManoGuiWindowList
            Show-ManoGuiLog
            Register-ManoGuiHotkey
        })
    $form.Add_FormClosing({
            try { [void][ManoNative.Win]::UnregisterHotKey($script:Gui.Form.Handle, 1) } catch { }
            Hide-ManoOverlay
        })

    $g.BadgeTimer = New-Object System.Windows.Forms.Timer
    $g.BadgeTimer.Interval = 40
    $g.BadgeTimer.Add_Tick({ Update-ManoCursorBadge })
    $g.BadgeTimer.Start()

    $g.Timer = New-Object System.Windows.Forms.Timer
    $g.Timer.Interval = 500
    $g.Timer.Add_Tick({
            Update-ManoGuiStatus
            Update-ManoOverlay
            if ($script:Gui.AutoRefresh.Checked -and ((Get-Date) - $script:Gui.LastRefresh).TotalSeconds -ge 5) { Update-ManoGuiWindowList }
        })
    $g.Timer.Start()
    try {
        [void]$form.ShowDialog()
    } finally {
        $g.Timer.Stop()
        $g.BadgeTimer.Stop()
        Hide-ManoCursorBadge
        if ($script:CursorBadge -and $script:CursorBadge.Form) { $script:CursorBadge.Form.Dispose(); $script:CursorBadge = $null }
        Hide-ManoOverlay
        if ($g.OverlayForms) { foreach ($f in $g.OverlayForms) { $f.Dispose() } }
        $form.Dispose()
        $script:Gui = $null
    }
}


function Use-ManoSelectedWindow {
    if (-not $script:Gui -or -not $script:Gui.WindowGrid) { return }
    if ($script:Gui.WindowGrid.SelectedRows.Count -eq 0) { return }
    $row = $script:Gui.WindowGrid.SelectedRows[0]
    $hwndValue = [int64]$row.Tag
    Invoke-ManoGuiAction -Script {
        param($value)
        $hwnd = [IntPtr]$value
        if (-not [ManoNative.Win]::IsWindow($hwnd)) { Throw-ManoError 'Esa ventana ya no existe.' 1 }
        [void](Assert-ManoWindowAllowed $hwnd)
        [void](Assert-ManoWindowOnMonitor $hwnd)
        Set-ManoTarget $hwnd
        [void](Focus-ManoWindow $hwnd)
        "Objetivo: $value  $(Get-ManoWindowTitle $hwnd)"
    } -Arguments @($hwndValue)
}

function Add-ManoGuiActionPanel {
    param($Parent)

    $action = @{}
    $script:Gui.Action = $action

    $cards = @(
        @{ Title = 'Clic en la ventana'; X = 0; Y = 0; W = 400; H = 170 },
        @{ Title = 'Escribir o pegar'; X = 420; Y = 0; W = 400; H = 170 },
        @{ Title = 'Teclas'; X = 0; Y = 190; W = 400; H = 150 },
        @{ Title = 'Scroll y arrastre'; X = 420; Y = 190; W = 400; H = 190 },
        @{ Title = 'Esperar y batch'; X = 0; Y = 360; W = 400; H = 190 }
    )
    foreach ($info in $cards) {
        $info.Card = New-ManoUiCard -Parent $Parent -Title $info.Title -X $info.X -Y $info.Y -W $info.W -H $info.H
    }

    $clickCard = $cards[0].Card
    [void](New-ManoUiLabel -Parent $clickCard -Text 'X' -X 16 -Y 46 -W 18 -H 20 -Size 9 -Color 'Muted')
    $action.X = New-Object System.Windows.Forms.NumericUpDown
    $action.X.Location = New-Object System.Drawing.Point(38, 44)
    $action.X.Size = New-Object System.Drawing.Size(80, 26)
    $action.X.Maximum = 10000
    $action.X.BackColor = Get-ManoUiColor 'CardAlt'
    $action.X.ForeColor = Get-ManoUiColor 'Text'
    $action.X.BorderStyle = 'FixedSingle'
    $clickCard.Controls.Add($action.X)
    [void](New-ManoUiLabel -Parent $clickCard -Text 'Y' -X 130 -Y 46 -W 18 -H 20 -Size 9 -Color 'Muted')
    $action.Y = New-Object System.Windows.Forms.NumericUpDown
    $action.Y.Location = New-Object System.Drawing.Point(152, 44)
    $action.Y.Size = New-Object System.Drawing.Size(80, 26)
    $action.Y.Maximum = 10000
    $action.Y.BackColor = Get-ManoUiColor 'CardAlt'
    $action.Y.ForeColor = Get-ManoUiColor 'Text'
    $action.Y.BorderStyle = 'FixedSingle'
    $clickCard.Controls.Add($action.Y)
    $action.Button = New-Object System.Windows.Forms.ComboBox
    $action.Button.Location = New-Object System.Drawing.Point(244, 44)
    $action.Button.Size = New-Object System.Drawing.Size(90, 26)
    $action.Button.DropDownStyle = 'DropDownList'
    $action.Button.BackColor = Get-ManoUiColor 'CardAlt'
    $action.Button.ForeColor = Get-ManoUiColor 'Text'
    [void]$action.Button.Items.AddRange(@('left', 'right', 'double'))
    $action.Button.SelectedIndex = 0
    $clickCard.Controls.Add($action.Button)
    $clickButton = New-ManoUiButton -Parent $clickCard -Text 'Hacer clic' -X 16 -Y 88 -W 120 -H 34 -Kind primary
    $clickButton.Add_Click({
            $x = [int]$script:Gui.Action.X.Value
            $y = [int]$script:Gui.Action.Y.Value
            $button = [string]$script:Gui.Action.Button.SelectedItem
            Invoke-ManoGuiAction -Script { param($px, $py, $pb) Invoke-ManoClick -X $px -Y $py -Button $pb } -Arguments @($x, $y, $button)
        })
    [void](New-ManoUiLabel -Parent $clickCard -Text 'Coordenadas relativas a la ventana.' -X 16 -Y 132 -W 300 -H 18 -Size 8.5 -Color 'Muted')

    $typeCard = $cards[1].Card
    $action.TypeText = New-Object System.Windows.Forms.TextBox
    $action.TypeText.Location = New-Object System.Drawing.Point(16, 46)
    $action.TypeText.Size = New-Object System.Drawing.Size(300, 28)
    $action.TypeText.BackColor = Get-ManoUiColor 'CardAlt'
    $action.TypeText.ForeColor = Get-ManoUiColor 'Text'
    $action.TypeText.BorderStyle = 'FixedSingle'
    $typeCard.Controls.Add($action.TypeText)
    $typeButton = New-ManoUiButton -Parent $typeCard -Text 'Escribir' -X 16 -Y 88 -W 100 -H 34 -Kind primary
    $typeButton.Add_Click({
            $text = [string]$script:Gui.Action.TypeText.Text
            Invoke-ManoGuiAction -Script { param($value) Invoke-ManoTypeText $value } -Arguments @($text)
        })
    $pasteButton = New-ManoUiButton -Parent $typeCard -Text 'Pegar' -X 126 -Y 88 -W 100 -H 34 -Kind subtle
    $pasteButton.Add_Click({
            $text = [string]$script:Gui.Action.TypeText.Text
            Invoke-ManoGuiAction -Script { param($value) Invoke-ManoPasteText $value } -Arguments @($text)
        })
    [void](New-ManoUiLabel -Parent $typeCard -Text 'Nunca escribe en campos de contrasena.' -X 16 -Y 132 -W 300 -H 18 -Size 8.5 -Color 'Muted')

    $keyCard = $cards[2].Card
    $action.Key = New-Object System.Windows.Forms.TextBox
    $action.Key.Text = 'ctrl+s'
    $action.Key.Location = New-Object System.Drawing.Point(16, 46)
    $action.Key.Size = New-Object System.Drawing.Size(160, 28)
    $action.Key.BackColor = Get-ManoUiColor 'CardAlt'
    $action.Key.ForeColor = Get-ManoUiColor 'Text'
    $action.Key.BorderStyle = 'FixedSingle'
    $keyCard.Controls.Add($action.Key)
    $keyButton = New-ManoUiButton -Parent $keyCard -Text 'Pulsar' -X 186 -Y 44 -W 100 -H 34 -Kind primary
    $keyButton.Add_Click({
            $combo = [string]$script:Gui.Action.Key.Text
            Invoke-ManoGuiAction -Script { param($value) Invoke-ManoKeyCombo $value } -Arguments @($combo)
        })
    [void](New-ManoUiLabel -Parent $keyCard -Text 'Ejemplos: enter, tab, esc, ctrl+s, alt+f1' -X 16 -Y 88 -W 340 -H 18 -Size 8.5 -Color 'Muted')

    $scrollCard = $cards[3].Card
    $action.Scroll = New-Object System.Windows.Forms.NumericUpDown
    $action.Scroll.Location = New-Object System.Drawing.Point(16, 44)
    $action.Scroll.Size = New-Object System.Drawing.Size(70, 26)
    $action.Scroll.Minimum = -20
    $action.Scroll.Maximum = 20
    $action.Scroll.Value = -3
    $action.Scroll.BackColor = Get-ManoUiColor 'CardAlt'
    $action.Scroll.ForeColor = Get-ManoUiColor 'Text'
    $action.Scroll.BorderStyle = 'FixedSingle'
    $scrollCard.Controls.Add($action.Scroll)
    $scrollButton = New-ManoUiButton -Parent $scrollCard -Text 'Scroll' -X 96 -Y 42 -W 90 -H 32 -Kind subtle
    $scrollButton.Add_Click({
            $steps = [int]$script:Gui.Action.Scroll.Value
            Invoke-ManoGuiAction -Script { param($value) Invoke-ManoScroll -Steps $value } -Arguments @($steps)
        })
    [void](New-ManoUiLabel -Parent $scrollCard -Text 'Arrastrar: x1, y1 -> x2, y2' -X 16 -Y 82 -W 220 -H 18 -Size 8.5 -Color 'Muted')
    $action.Drag = @()
    for ($i = 0; $i -lt 4; $i++) {
        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Location = New-Object System.Drawing.Point((16 + $i * 62), 106)
        $num.Size = New-Object System.Drawing.Size(56, 26)
        $num.Maximum = 10000
        $num.BackColor = Get-ManoUiColor 'CardAlt'
        $num.ForeColor = Get-ManoUiColor 'Text'
        $num.BorderStyle = 'FixedSingle'
        $scrollCard.Controls.Add($num)
        $action.Drag += $num
    }
    $dragButton = New-ManoUiButton -Parent $scrollCard -Text 'Arrastrar' -X 268 -Y 104 -W 100 -H 30 -Kind primary
    $dragButton.Add_Click({
            $points = @(
                [int]$script:Gui.Action.Drag[0].Value, [int]$script:Gui.Action.Drag[1].Value,
                [int]$script:Gui.Action.Drag[2].Value, [int]$script:Gui.Action.Drag[3].Value
            )
            Invoke-ManoGuiAction -Script {
                param($x1, $y1, $x2, $y2)
                Invoke-ManoDrag -FromX $x1 -FromY $y1 -ToX $x2 -ToY $y2
            } -Arguments $points
        })

    $waitCard = $cards[4].Card
    $action.Wait = New-Object System.Windows.Forms.NumericUpDown
    $action.Wait.Location = New-Object System.Drawing.Point(16, 46)
    $action.Wait.Size = New-Object System.Drawing.Size(90, 26)
    $action.Wait.Minimum = 0
    $action.Wait.Maximum = 10000
    $action.Wait.Increment = 100
    $action.Wait.Value = 500
    $action.Wait.BackColor = Get-ManoUiColor 'CardAlt'
    $action.Wait.ForeColor = Get-ManoUiColor 'Text'
    $action.Wait.BorderStyle = 'FixedSingle'
    $waitCard.Controls.Add($action.Wait)
    $waitButton = New-ManoUiButton -Parent $waitCard -Text 'Esperar ms' -X 116 -Y 44 -W 110 -H 32 -Kind subtle
    $waitButton.Add_Click({
            $ms = [int]$script:Gui.Action.Wait.Value
            Invoke-ManoGuiAction -Script { param($value) Invoke-ManoAction -Action wait -ActionArgs @([string]$value) } -Arguments @($ms)
        })
    $batchButton = New-ManoUiButton -Parent $waitCard -Text 'Ejecutar batch (.json)...' -X 16 -Y 90 -W 220 -H 34 -Kind primary
    $batchButton.Add_Click({
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Filter = 'JSON (*.json)|*.json|Todos (*.*)|*.*'
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $path = $dialog.FileName
                Invoke-ManoGuiAction -Script { param($value) Invoke-ManoBatchFile $value } -Arguments @($path)
            }
        })
    [void](New-ManoUiLabel -Parent $waitCard -Text 'Valida todos los pasos antes de pedir permiso.' -X 16 -Y 134 -W 340 -H 18 -Size 8.5 -Color 'Muted')
}

function Add-ManoGuiSettingsPanel {
    param($Parent)

    $settings = @{}
    $script:Gui.Settings = $settings

    $general = New-ManoUiCard -Parent $Parent -Title 'General' -X 0 -Y 0 -W 860 -H 250
    $rows1 = @(
        @{ Label = 'Monitor objetivo'; Key = 'Target'; Control = 'text' },
        @{ Label = 'Confirmacion (ask/auto)'; Key = 'Mode'; Control = 'mode' },
        @{ Label = 'Timeout de confirmacion (s)'; Key = 'Timeout'; Control = 'timeout' },
        @{ Label = 'Confianza maxima (min)'; Key = 'Trust'; Control = 'trust' }
    )
    $y = 44
    foreach ($row in $rows1) {
        [void](New-ManoUiLabel -Parent $general -Text $row.Label -X 16 -Y ($y + 4) -W 220 -H 20 -Size 9 -Color 'Muted')
        if ($row.Control -eq 'text') {
            $settings.Target = New-Object System.Windows.Forms.TextBox
            $settings.Target.Text = [string]$script:Cfg.TargetMonitor
            $settings.Target.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Target.Size = New-Object System.Drawing.Size(250, 26)
            $settings.Target.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Target.ForeColor = Get-ManoUiColor 'Text'
            $settings.Target.BorderStyle = 'FixedSingle'
            $general.Controls.Add($settings.Target)
        } elseif ($row.Control -eq 'mode') {
            $settings.Mode = New-Object System.Windows.Forms.ComboBox
            $settings.Mode.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Mode.Size = New-Object System.Drawing.Size(120, 26)
            $settings.Mode.DropDownStyle = 'DropDownList'
            $settings.Mode.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Mode.ForeColor = Get-ManoUiColor 'Text'
            [void]$settings.Mode.Items.AddRange(@('ask', 'auto'))
            $settings.Mode.SelectedItem = [string]$script:Cfg.ConfirmMode
            $general.Controls.Add($settings.Mode)
        } elseif ($row.Control -eq 'timeout') {
            $settings.Timeout = New-Object System.Windows.Forms.NumericUpDown
            $settings.Timeout.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Timeout.Size = New-Object System.Drawing.Size(90, 26)
            $settings.Timeout.Minimum = 5
            $settings.Timeout.Maximum = 300
            $settings.Timeout.Value = [int]$script:Cfg.ConfirmTimeoutSec
            $settings.Timeout.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Timeout.ForeColor = Get-ManoUiColor 'Text'
            $settings.Timeout.BorderStyle = 'FixedSingle'
            $general.Controls.Add($settings.Timeout)
        } elseif ($row.Control -eq 'trust') {
            $settings.Trust = New-Object System.Windows.Forms.NumericUpDown
            $settings.Trust.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Trust.Size = New-Object System.Drawing.Size(90, 26)
            $settings.Trust.Minimum = 1
            $settings.Trust.Maximum = 1440
            $settings.Trust.Value = [int]$script:Cfg.TrustMaxMinutes
            $settings.Trust.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Trust.ForeColor = Get-ManoUiColor 'Text'
            $settings.Trust.BorderStyle = 'FixedSingle'
            $general.Controls.Add($settings.Trust)
        }
        $y += 44
    }

    $captures = New-ManoUiCard -Parent $Parent -Title 'Capturas' -X 0 -Y 266 -W 860 -H 250
    $rows2 = @(
        @{ Label = 'Carpeta (vacio = ./shots)'; Key = 'Shots'; Control = 'text' },
        @{ Label = 'Formato'; Key = 'Format'; Control = 'format' },
        @{ Label = 'Retardo del clic (ms)'; Key = 'ClickDelay'; Control = 'delay' },
        @{ Label = 'Maximo de pasos por batch'; Key = 'Batch'; Control = 'batch' }
    )
    $y = 44
    foreach ($row in $rows2) {
        [void](New-ManoUiLabel -Parent $captures -Text $row.Label -X 16 -Y ($y + 4) -W 220 -H 20 -Size 9 -Color 'Muted')
        if ($row.Control -eq 'text') {
            $settings.Shots = New-Object System.Windows.Forms.TextBox
            $settings.Shots.Text = [string]$script:Cfg.ShotsDir
            $settings.Shots.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Shots.Size = New-Object System.Drawing.Size(230, 26)
            $settings.Shots.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Shots.ForeColor = Get-ManoUiColor 'Text'
            $settings.Shots.BorderStyle = 'FixedSingle'
            $captures.Controls.Add($settings.Shots)
        } elseif ($row.Control -eq 'format') {
            $settings.Format = New-Object System.Windows.Forms.ComboBox
            $settings.Format.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Format.Size = New-Object System.Drawing.Size(100, 26)
            $settings.Format.DropDownStyle = 'DropDownList'
            $settings.Format.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Format.ForeColor = Get-ManoUiColor 'Text'
            [void]$settings.Format.Items.AddRange(@('png', 'jpg'))
            $settings.Format.SelectedItem = [string]$script:Cfg.ShotFormat
            $captures.Controls.Add($settings.Format)
        } elseif ($row.Control -eq 'delay') {
            $settings.ClickDelay = New-Object System.Windows.Forms.NumericUpDown
            $settings.ClickDelay.Location = New-Object System.Drawing.Point(250, $y)
            $settings.ClickDelay.Size = New-Object System.Drawing.Size(90, 26)
            $settings.ClickDelay.Minimum = 0
            $settings.ClickDelay.Maximum = 1000
            $settings.ClickDelay.Increment = 10
            $settings.ClickDelay.Value = [int]$script:Cfg.ClickDelayMs
            $settings.ClickDelay.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.ClickDelay.ForeColor = Get-ManoUiColor 'Text'
            $settings.ClickDelay.BorderStyle = 'FixedSingle'
            $captures.Controls.Add($settings.ClickDelay)
        } elseif ($row.Control -eq 'batch') {
            $settings.Batch = New-Object System.Windows.Forms.NumericUpDown
            $settings.Batch.Location = New-Object System.Drawing.Point(250, $y)
            $settings.Batch.Size = New-Object System.Drawing.Size(90, 26)
            $settings.Batch.Minimum = 1
            $settings.Batch.Maximum = 200
            $settings.Batch.Value = [int]$script:Cfg.MaxBatchSteps
            $settings.Batch.BackColor = Get-ManoUiColor 'CardAlt'
            $settings.Batch.ForeColor = Get-ManoUiColor 'Text'
            $settings.Batch.BorderStyle = 'FixedSingle'
            $captures.Controls.Add($settings.Batch)
        }
        $y += 44
    }

    $security = New-ManoUiCard -Parent $Parent -Title 'Seguridad' -X 0 -Y 532 -W 860 -H 250
    $settings.Overlay = New-Object System.Windows.Forms.CheckBox
    $settings.Overlay.Text = 'Mostrar borde en la ventana objetivo'
    $settings.Overlay.Checked = [bool]$script:Cfg.Overlay
    $settings.Overlay.Location = New-Object System.Drawing.Point(16, 44)
    $settings.Overlay.Size = New-Object System.Drawing.Size(400, 24)
    $settings.Overlay.ForeColor = Get-ManoUiColor 'Text'
    $settings.Overlay.BackColor = Get-ManoUiColor 'Card'
    $security.Controls.Add($settings.Overlay)
    $settings.Sensitive = New-Object System.Windows.Forms.CheckBox
    $settings.Sensitive.Text = 'Bloquear ventanas sensibles (login, pagos, correo)'
    $settings.Sensitive.Checked = [bool]$script:Cfg.BlockSensitiveWindows
    $settings.Sensitive.Location = New-Object System.Drawing.Point(16, 74)
    $settings.Sensitive.Size = New-Object System.Drawing.Size(400, 24)
    $settings.Sensitive.ForeColor = Get-ManoUiColor 'Text'
    $settings.Sensitive.BackColor = Get-ManoUiColor 'Card'
    $security.Controls.Add($settings.Sensitive)
    [void](New-ManoUiLabel -Parent $security -Text 'Titulos extra bloqueados (separados por coma)' -X 16 -Y 112 -W 300 -H 20 -Size 9 -Color 'Muted')
    $settings.Blocked = New-Object System.Windows.Forms.TextBox
    $settings.Blocked.Text = (@($script:Cfg.BlockedTitles) -join ', ')
    $settings.Blocked.Location = New-Object System.Drawing.Point(16, 136)
    $settings.Blocked.Size = New-Object System.Drawing.Size(480, 26)
    $settings.Blocked.BackColor = Get-ManoUiColor 'CardAlt'
    $settings.Blocked.ForeColor = Get-ManoUiColor 'Text'
    $settings.Blocked.BorderStyle = 'FixedSingle'
    $security.Controls.Add($settings.Blocked)
    [void](New-ManoUiLabel -Parent $security -Text 'Atajo global de panico' -X 16 -Y 172 -W 220 -H 20 -Size 9 -Color 'Muted')
    $settings.Hotkey = New-Object System.Windows.Forms.TextBox
    $settings.Hotkey.Text = [string]$script:Cfg.PanicHotkey
    $settings.Hotkey.Location = New-Object System.Drawing.Point(250, 168)
    $settings.Hotkey.Size = New-Object System.Drawing.Size(150, 26)
    $settings.Hotkey.BackColor = Get-ManoUiColor 'CardAlt'
    $settings.Hotkey.ForeColor = Get-ManoUiColor 'Text'
    $settings.Hotkey.BorderStyle = 'FixedSingle'
    $security.Controls.Add($settings.Hotkey)

    $advanced = New-ManoUiCard -Parent $Parent -Title 'Avanzado' -X 0 -Y 798 -W 860 -H 320
    [void](New-ManoUiLabel -Parent $advanced -Text 'Nombre de la IA (junto al raton)' -X 16 -Y 48 -W 250 -H 20 -Size 9 -Color 'Muted')
    $settings.AiName = New-Object System.Windows.Forms.TextBox
    $settings.AiName.Text = [string]$script:Cfg.AiName
    $settings.AiName.Location = New-Object System.Drawing.Point(270, 44)
    $settings.AiName.Size = New-Object System.Drawing.Size(200, 26)
    $settings.AiName.BackColor = Get-ManoUiColor 'CardAlt'
    $settings.AiName.ForeColor = Get-ManoUiColor 'Text'
    $settings.AiName.BorderStyle = 'FixedSingle'
    $advanced.Controls.Add($settings.AiName)
    $settings.ShowAiLabel = New-Object System.Windows.Forms.CheckBox
    $settings.ShowAiLabel.Text = 'Mostrar el nombre de la IA junto al raton'
    $settings.ShowAiLabel.Checked = [bool]$script:Cfg.ShowAiLabel
    $settings.ShowAiLabel.Location = New-Object System.Drawing.Point(16, 78)
    $settings.ShowAiLabel.Size = New-Object System.Drawing.Size(460, 24)
    $settings.ShowAiLabel.ForeColor = Get-ManoUiColor 'Text'
    $settings.ShowAiLabel.BackColor = Get-ManoUiColor 'Card'
    $advanced.Controls.Add($settings.ShowAiLabel)
    [void](New-ManoUiLabel -Parent $advanced -Text 'Lineas que muestra el registro' -X 16 -Y 116 -W 240 -H 20 -Size 9 -Color 'Muted')
    $settings.LogLines = New-Object System.Windows.Forms.NumericUpDown
    $settings.LogLines.Location = New-Object System.Drawing.Point(270, 112)
    $settings.LogLines.Size = New-Object System.Drawing.Size(100, 26)
    $settings.LogLines.Minimum = 50
    $settings.LogLines.Maximum = 5000
    $settings.LogLines.Increment = 50
    $settings.LogLines.Value = [int]$script:Cfg.LogLines
    $settings.LogLines.BackColor = Get-ManoUiColor 'CardAlt'
    $settings.LogLines.ForeColor = Get-ManoUiColor 'Text'
    $settings.LogLines.BorderStyle = 'FixedSingle'
    $advanced.Controls.Add($settings.LogLines)
    $save = New-ManoUiButton -Parent $advanced -Text 'Guardar ajustes' -X 16 -Y 168 -W 150 -H 40 -Kind primary
    $save.Add_Click({ Save-ManoGuiSettings })
    $open = New-ManoUiButton -Parent $advanced -Text 'Abrir config.json' -X 180 -Y 168 -W 150 -H 40 -Kind subtle
    $open.Add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$($script:ConfigFile)`"" })
    [void](New-ManoUiLabel -Parent $advanced -Text 'Los cambios se aplican al momento.' -X 16 -Y 224 -W 300 -H 18 -Size 8.5 -Color 'Muted')
}

function Save-ManoGuiSettings {
    if (-not $script:Gui -or -not $script:Gui.Settings) { return }
    $settings = $script:Gui.Settings
    $new = [ordered]@{}
    foreach ($key in (Get-ManoDefaultConfig).Keys) { $new[$key] = $script:Cfg[$key] }
    $new.TargetMonitor = [string]$settings.Target.Text
    $new.ConfirmMode = [string]$settings.Mode.SelectedItem
    $new.ConfirmTimeoutSec = [int]$settings.Timeout.Value
    $new.TrustMaxMinutes = [int]$settings.Trust.Value
    $new.ShotsDir = [string]$settings.Shots.Text
    $new.ShotFormat = [string]$settings.Format.SelectedItem
    $new.ClickDelayMs = [int]$settings.ClickDelay.Value
    $new.MaxBatchSteps = [int]$settings.Batch.Value
    $new.Overlay = [bool]$settings.Overlay.Checked
    $new.BlockSensitiveWindows = [bool]$settings.Sensitive.Checked
    $new.BlockedTitles = @(([string]$settings.Blocked.Text) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $new.PanicHotkey = [string]$settings.Hotkey.Text
    $new.LogLines = [int]$settings.LogLines.Value
    $new.AiName = [string]$settings.AiName.Text
    $new.ShowAiLabel = [bool]$settings.ShowAiLabel.Checked
    Save-ManoConfig $new
    $loaded = Import-ManoConfig -Path $script:ConfigFile
    $script:Cfg = $loaded.Config
    $script:CurrentAiName = Get-ManoAiName
    Write-ManoLog 'ajustes guardados desde la interfaz'
    if ($loaded.Warnings.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($loaded.Warnings -join [Environment]::NewLine), 'ManoSegura - avisos', 'OK', 'Warning')
    } else {
        [void][System.Windows.Forms.MessageBox]::Show('Ajustes guardados.', 'ManoSegura', 'OK', 'Information')
    }
    Update-ManoGuiStatus
}

function Register-ManoGuiHotkey {
    if (-not $script:Gui -or -not $script:Gui.Form) { return }
    $g = $script:Gui
    try {
        $hotkey = Convert-ManoHotkey ([string]$script:Cfg.PanicHotkey)
        $g.HotkeyWindow = New-Object ManoForms.HotkeyWindow($g.Form.Handle)
        $g.HotkeyWindow.add_Hotkey({ Invoke-ManoPanic | Out-Null; Update-ManoGuiStatus })
        $registered = [ManoNative.Win]::RegisterHotKey($g.Form.Handle, 1, [uint32]$hotkey.Modifiers, [uint32]$hotkey.VirtualKey)
        if (-not $registered -and $g.SideHotkey) { $g.SideHotkey.Text = 'Panico: atajo no disponible' }
    } catch {
        if ($g.SideHotkey) { $g.SideHotkey.Text = 'Panico: atajo no disponible' }
    }
}

function Show-ManoGuiLog {
    if (-not $script:Gui -or -not $script:Gui.LogBox) { return }
    try {
        if (Test-Path -LiteralPath $script:LogFile) {
            $lines = Get-Content -LiteralPath $script:LogFile -Tail ([int]$script:Cfg.LogLines) -Encoding UTF8
            $script:Gui.LogBox.Text = ($lines -join [Environment]::NewLine)
        }
    } catch { }
}


function Get-ManoHelpText {
    $launcher = if ($script:IsCompiledExe) { 'ManoSegura.exe' } else { 'powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\ManoSegura.ps1' }
    @"
ManoSegura $($script:Version) - mano remota segura para Windows
Uso: $launcher <comando> [args] [opciones]

Sin comando abre la interfaz grafica.

VENTANAS
  list                        lista ventanas visibles (hwnd, proceso, titulo, monitor)
  use <hwnd|titulo>           elige la ventana objetivo y la trae al frente
  monitors                    lista monitores y marca el objetivo

ACCIONES (pueden pedir permiso)
  shot [ruta]                 captura la ventana objetivo
  shot --monitor <spec> [ruta]  captura un monitor
  shot --hwnd <hwnd> [ruta]   captura otra ventana
  click x y [left|right|double]  clic en coordenadas relativas a la ventana
  type "texto"                escribe el texto
  paste "texto"               pega el texto (portapapeles + Ctrl+V)
  key ctrl+s                  pulsa una combinacion
  scroll [pasos] [x y]        scroll (negativo abajo)
  drag x1 y1 x2 y2            arrastra dentro de la ventana
  wait [ms]                   espera (max 10 s)
  batch <fichero.json|->       ejecuta varios pasos con un solo permiso

CONTROL
  status                      estado: ventana, monitor, confianza, desactivada
  trust [tiempo]              confianza temporal: 10m, 30m, 1h, 2h, 3h, 90, 1h30m
  trust add <tiempo>         anade tiempo a la confianza activa (o trust +30m)
  untrust                     quita el modo confianza
  panic                       desactiva ManoSegura y corta acciones
  enable                      reactiva ManoSegura
  disable                     desactiva ManoSegura
  ai [nombre]                 muestra o cambia el nombre de la IA (ej: ai Claude)
  config [show|path]          muestra la configuracion o su ruta
  config set <clave> <valor>  cambia un ajuste
  config reset                vuelve a la configuracion por defecto
  check <titulo>              prueba si un titulo esta bloqueado
  log [lineas]                ultimas lineas del registro
  version                     version
  help                        esta ayuda

OPCIONES
  --dry-run                   no toca el raton/teclado; solo explica que haria
  --yes                       no pide permiso (solo si tu lo decides)
  --format png|jpg            formato de captura (shot)
  --ai <nombre>               nombre de la IA que controla (se muestra junto al raton)

CONFIG (config.json)
  TargetMonitor: primary | 1 | left | right | x=-1920 | DISPLAY2
  ConfirmMode: ask (pide permiso) | auto (no pregunta)
  ConfirmTimeoutSec, TrustMaxMinutes, ShotsDir, ShotFormat, ClickDelayMs,
  MaxBatchSteps, Overlay, BlockSensitiveWindows, BlockedTitles, PanicHotkey, LogLines,
  AiName, ShowAiLabel

SEGURIDAD
  - Nunca escribe en campos de contrasena.
  - Bloquea ventanas de login, correo web, pagos y banca (lista configurable).
  - La ventana debe estar entera en el monitor objetivo.
  - Si el vigilante de panico no puede registrarse, la interfaz lo avisa.
  - Codigo de salida: 0 OK, 1 error, 2 cancelado/rechazado.

Ejemplos:
  $launcher ui
  $launcher list
  $launcher --ai Claude use "Notepad"
  $launcher --ai Claude shot
  $launcher --dry-run click 100 200
"@
}

function Show-ManoStatus {
    "ManoSegura $($script:Version)"
    "Ruta: $($script:Root)"
    "Config: $($script:ConfigFile)"
    "IA: $(Get-ManoAiName)"
    "Activada: $(-not (Test-ManoDisabled))"
    "Modo confianza: $(Test-ManoTrustActive)"
    if (Test-ManoTrustActive) {
        $expiry = Get-ManoTrustExpiry (Get-Content -LiteralPath $script:TrustFile -Raw -ErrorAction SilentlyContinue)
        if ($expiry) { "Confianza hasta: $($expiry.ToString('yyyy-MM-dd HH:mm:ss'))" }
        $remaining = Get-ManoTrustRemainingMinutes
        if ($remaining -gt 0) { "Confianza restante: $remaining min" }
    }
    try {
        $monitor = Get-ManoTargetMonitor
        "Monitor objetivo: $($monitor.DeviceName) $(Format-ManoRect $monitor.Bounds)"
    } catch { "Monitor objetivo: ERROR $($_.Exception.Message)" }
    $targetText = '(ninguno)'
    try {
        if (Test-Path -LiteralPath $script:TargetFile) {
            $value = [int64]0
            if ([int64]::TryParse((Get-Content -LiteralPath $script:TargetFile -Raw).Trim(), [ref]$value)) {
                $hwnd = [IntPtr]$value
                if ([ManoNative.Win]::IsWindow($hwnd)) { $targetText = "$value  $(Get-ManoWindowTitle $hwnd)" }
            }
        }
    } catch { }
    "Ventana objetivo: $targetText"
    "Capturas: $($script:ShotsDir)"
    "Atajo de panico: $($script:Cfg.PanicHotkey)"
    "Config: ConfirmMode=$($script:Cfg.ConfirmMode) Timeout=$($script:Cfg.ConfirmTimeoutSec)s TrustMax=$($script:Cfg.TrustMaxMinutes)min Overlay=$($script:Cfg.Overlay)"
    if ($script:Warnings.Count -gt 0) {
        'Avisos de configuracion:'
        foreach ($w in $script:Warnings) { "  - $w" }
    }
}

function Show-ManoMonitors {
    $monitors = Get-ManoMonitors
    $target = $null
    try { $target = Get-ManoTargetMonitor } catch { }
    $index = 0
    foreach ($monitor in $monitors) {
        $mark = if ($target -and $target.DeviceName -eq $monitor.DeviceName) { '*' } else { ' ' }
        "[$index] $mark $($monitor.DeviceName)  $(Format-ManoRect $monitor.Bounds)  primario=$($monitor.Primary)  id=$($monitor.MonitorId)"
        $index++
    }
    if ($script:Cfg.TargetMonitor) { "Objetivo configurado: $($script:Cfg.TargetMonitor)" }
}

function Show-ManoWindowList {
    $windows = Get-ManoWindows
    "{0,8}  {1,-16} {2,-16} {3,-44} {4}" -f 'Hwnd', 'Proceso', 'Monitor', 'Titulo', 'Bloq.'
    foreach ($window in $windows) {
        $process = if ($window.Proceso) { $window.Proceso } else { '?' }
        $monitor = if ($window.Monitor) { $window.Monitor } else { '-' }
        $blocked = if ($window.Bloqueada) { 'SI' } else { 'no' }
        "{0,8}  {1,-16} {2,-16} {3,-44} {4}" -f $window.Hwnd, (Get-ManoClipped $process 16), (Get-ManoClipped $monitor 16), (Get-ManoClipped $window.Titulo 44), $blocked
    }
    "Total: $($windows.Count) ventanas"
}

function Show-ManoConfig {
    $defaults = Get-ManoDefaultConfig
    foreach ($key in $defaults.Keys) {
        $value = $script:Cfg[$key]
        if ($value -is [array]) { $value = (@($value) -join ', ') }
        "$key = $value"
    }
    "Fichero: $($script:ConfigFile)"
    if ($script:Warnings.Count -gt 0) {
        'Avisos:'
        foreach ($w in $script:Warnings) { "  - $w" }
    }
}

function Initialize-ManoCliEnvironment {
    Initialize-ManoEnvironment -RootPath $script:Root
}

# =====================================================================================================
# 13. Punto de entrada / entry point
# =====================================================================================================
function Invoke-ManoMain {
    param([string[]]$RawArguments = @())

    Initialize-ManoCliEnvironment
    $argsList = New-Object System.Collections.Generic.List[string]
    $commandName = ''
    $rawArguments = @($RawArguments)
    for ($i = 0; $i -lt $rawArguments.Count; $i++) {
        $argument = [string]$rawArguments[$i]
        if ($argument -match '^--?ai$') {
            if ($i + 1 -lt $rawArguments.Count) {
                $i++
                [void](Set-ManoAiName ([string]$rawArguments[$i]))
            }
            continue
        }
        if ($argument -match '^--?dry-run$') { $script:DryRun = $true; continue }
        if ($argument -match '^--?yes$') { $script:AutoYes = $true; continue }
        if ($argument -match '^--?help$') { if (-not $commandName) { $commandName = 'help' }; continue }
        if ($argument -match '^--?version$') { if (-not $commandName) { $commandName = 'version' }; continue }
        if (-not $commandName -and -not $argument.StartsWith('-')) {
            $commandName = $argument
        } else {
            $argsList.Add($argument)
        }
    }

    $name = if ($commandName) { $commandName.ToLowerInvariant() } else { 'ui' }
    if ($name -eq 'focus') { $name = 'use' }
    Write-ManoLog "CMD [$((Get-ManoAiName))]: $name $((Get-ManoClipped ($argsList -join ' ') 200))$(if ($script:DryRun) { ' [dry-run]' })"

    try {
        switch ($name) {
            'ui' { Show-ManoGui; return }
            'version' { "ManoSegura $($script:Version)"; return }
            'help' { Get-ManoHelpText; return }
            'monitors' { Show-ManoMonitors; return }
            'list' { Show-ManoWindowList; return }
            'status' { Show-ManoStatus; return }
            'use' {
                if (-not $argsList.Count) { Throw-ManoError 'Uso: use <hwnd|titulo>' 1 }
                $window = Find-ManoWindow ($argsList -join ' ')
                $hwnd = [IntPtr][int64]$window.Hwnd
                [void](Assert-ManoWindowAllowed $hwnd)
                [void](Assert-ManoWindowOnMonitor $hwnd)
                if (-not (Confirm-ManoAction "Elegir como ventana objetivo y traerla al frente:`r`n$($window.Titulo)")) { Throw-ManoError 'CANCELADO: use' 2 }
                Set-ManoTarget $hwnd
                [void](Focus-ManoWindow $hwnd)
                "Objetivo: $($window.Hwnd)  $($window.Titulo)"
                return
            }
            'shot' { Invoke-ManoAction -Action screenshot -ActionArgs $argsList.ToArray(); return }
            'screenshot' { Invoke-ManoAction -Action screenshot -ActionArgs $argsList.ToArray(); return }
            'click' { Invoke-ManoAction -Action click -ActionArgs $argsList.ToArray(); return }
            'type' { Invoke-ManoAction -Action type -ActionArgs $argsList.ToArray(); return }
            'paste' { Invoke-ManoAction -Action paste -ActionArgs $argsList.ToArray(); return }
            'key' { Invoke-ManoAction -Action key -ActionArgs $argsList.ToArray(); return }
            'scroll' { Invoke-ManoAction -Action scroll -ActionArgs $argsList.ToArray(); return }
            'drag' { Invoke-ManoAction -Action drag -ActionArgs $argsList.ToArray(); return }
            'wait' { Invoke-ManoAction -Action wait -ActionArgs $argsList.ToArray(); return }
            'batch' {
                if (-not $argsList.Count) { Throw-ManoError 'Uso: batch <fichero.json|->' 1 }
                Invoke-ManoBatchFile -Source ($argsList -join ' ')
                return
            }
            'trust' {
                $raw = @($argsList)
                $isAdd = $false
                if ($raw.Count -ge 1 -and (($raw[0] -in @('add', '+', 'extender', 'sumar')) -or $raw[0].StartsWith('+'))) {
                    $isAdd = $true
                    if ($raw[0] -in @('add', '+', 'extender', 'sumar')) { $raw = @($raw | Select-Object -Skip 1) }
                    else { $raw[0] = $raw[0].TrimStart('+') }
                }
                $minutes = if ($raw.Count -ge 1) { Convert-ManoTrustSpec ($raw -join '') } else { 10 }
                if ($isAdd) {
                    $result = Add-ManoTrustMinutes $minutes
                    $limitNote = if ($result.Capped) { ' [limitado por TrustMaxMinutes]' } else { '' }
                    "OK confianza hasta $($result.Expiry.ToString('yyyy-MM-dd HH:mm')) (+$minutes min, total $($result.TotalMinutes) min)$limitNote"
                } else {
                    $actual = Set-ManoTrustMinutes $minutes
                    $limitNote = if ($actual -lt $minutes) { ' [limitado por TrustMaxMinutes]' } else { '' }
                    "OK modo confianza $actual min (hasta $((Get-Date).AddMinutes($actual).ToString('HH:mm')))$limitNote"
                }
                return
            }
            'untrust' { Clear-ManoTrust; 'OK modo confianza desactivado'; return }
            'panic' { Invoke-ManoPanic; return }
            'disable' { Set-ManoDisabled -Disabled $true; 'OK ManoSegura desactivada'; return }
            'enable' { Set-ManoDisabled -Disabled $false; 'OK ManoSegura activada'; return }
            'ai' {
                if ($argsList.Count -ge 1) {
                    $changed = Set-ManoAiName ($argsList -join ' ')
                    "OK IA = $changed"
                } else {
                    Get-ManoAiName
                }
                return
            }
            'config' {
                if (-not $argsList.Count -or $argsList[0] -eq 'show') { Show-ManoConfig; return }
                if ($argsList[0] -eq 'path') { $script:ConfigFile; return }
                if ($argsList[0] -eq 'reset') {
                    Save-ManoConfig (Get-ManoDefaultConfig)
                    Initialize-ManoEnvironment -RootPath $script:Root
                    'OK configuracion por defecto'
                    return
                }
                if ($argsList[0] -eq 'set' -and $argsList.Count -ge 3) {
                    Set-ManoConfigValue -Key $argsList[1] -Value (($argsList | Select-Object -Skip 2) -join ' ')
                    return
                }
                Throw-ManoError 'Uso: config [show|path|reset] | config set <clave> <valor>' 1
            }
            'check' {
                if (-not $argsList.Count) { Throw-ManoError 'Uso: check <titulo>' 1 }
                $title = $argsList -join ' '
                $blocked = Test-ManoTitleBlocked -Title $title -Extra $script:Cfg.BlockedTitles
                if ($blocked) { "BLOQUEADA: $title" } else { "permitida: $title" }
                return
            }
            'log' {
                $lines = if ($argsList.Count -ge 1) { [int]$argsList[0] } else { 40 }
                if (Test-Path -LiteralPath $script:LogFile) { Get-Content -LiteralPath $script:LogFile -Tail $lines -Encoding UTF8 } else { 'Sin registro todavia.' }
                return
            }
            default {
                Get-ManoHelpText
                Throw-ManoError "Comando desconocido: $CommandName" 2
            }
        }
    } catch [ManoError] {
        Write-ManoLog ('ERROR: ' + $_.Exception.Message)
        Write-Output ('ERROR: ' + $_.Exception.Message)
        $script:ExitCode = [int]$_.Exception.Code
        return
    } catch {
        Write-ManoLog ('EXCEPCION: ' + $_.Exception.Message)
        Write-Output ('ERROR: ' + $_.Exception.Message)
        $script:ExitCode = 1
        return
    }
}

if (-not $script:IsLibrary) {
    $script:ExitCode = 0
    if ($script:IsCompiledExe) {
        Invoke-ManoMain -RawArguments $Arguments | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
    } else {
        Invoke-ManoMain -RawArguments $Arguments
    }
    exit $script:ExitCode
}
