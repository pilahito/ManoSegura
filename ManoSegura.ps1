#Requires -Version 5.1
<#
.SYNOPSIS
  ManoSegura - "mano remota" segura: un asistente de IA controla UNA ventana en UN monitor elegido de Windows,
  siempre con tu permiso. / A safe "remote hand": an AI assistant controls ONE window on ONE chosen monitor.

.DESCRIPTION
  - Sin descargas, sin admin, sin ventanas ocultas, sin comandos codificados. / No downloads, no admin, no hidden windows.
  - Cada accion pide permiso (o usa un "modo confianza" con tiempo limite). / Every action asks first (or time-limited trust).
  - Panico / panic: Ctrl+Alt+P detiene todo y desactiva ManoSegura hasta que TU ejecutes "enable".
  - Mientras esta activa se ve: icono en la bandeja, cartel abajo en el monitor y un borde alrededor de la ventana controlada.
  Uso / usage:  powershell -NoProfile -File .\ManoSegura.ps1 <comando> [args] [--dry-run] [--json] [--en|--es]
  Instalacion sin "-ExecutionPolicy Bypass": ver README.md (Unblock-File + RemoteSigned, o firma propia).

.NOTES
  Copyright (c) 2026 pilahito - ManoSegura Source-Available License v1.0 (adaptada de CloudTerm SAL). Ver LICENSE.
#>
param(
  [Parameter(Position = 0)][string]$Cmd = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$script:Version   = '1.1.0'
$script:Self      = $MyInvocation.MyCommand.Path
$script:Root      = Split-Path -Parent $script:Self
# Dot-sourcing (". .\ManoSegura.ps1") only defines the functions, for tests. Nothing on screen is touched.
$script:IsLibrary = ($MyInvocation.InvocationName -eq '.') -or ($env:MANOSEGURA_LIBRARY -eq '1')
$script:DryRun    = $false
$script:JsonMode  = $false
$script:Lang      = 'es'
$script:BatchApproved = $false
$script:MaxBatchSteps = 50
$script:GenesisHash   = ('0' * 64)
$script:Notes   = New-Object System.Collections.Generic.List[string]
$script:Partial = New-Object System.Collections.Generic.List[object]
$script:MutexPanic = 'Local\ManoSeguraPanic'
$script:MutexState = 'Local\ManoSeguraState'

# =====================================================================================================
# 1. Mensajes bilingues / bilingual messages  (id -> @(es, en))
# =====================================================================================================
$script:Messages = @{
  E_USAGE            = @('Uso: {0}', 'Usage: {0}')
  E_UNKNOWN_CMD      = @('Comando desconocido: {0}. Usa: help', 'Unknown command: {0}. Use: help')
  E_NOT_WINDOWS      = @('Este comando solo funciona en Windows.', 'This command only works on Windows.')
  E_DISABLED         = @('ManoSegura esta DESACTIVADA (boton de panico). Solo el usuario puede reactivarla con: enable', 'ManoSegura is DISABLED (panic button). Only the user can re-enable it with: enable')
  E_NO_TARGET        = @('No hay ventana objetivo. Usa: focus <hwnd|titulo>', 'No target window. Use: focus <hwnd|title>')
  E_TARGET_GONE      = @('La ventana objetivo ya no existe.', 'The target window no longer exists.')
  E_HWND_GONE        = @('Ese hwnd no existe: {0}', 'That hwnd does not exist: {0}')
  E_AMBIGUOUS        = @('Coinciden {0} ventanas con ''{1}''. Usa el hwnd (list-windows).', '{0} windows match ''{1}''. Use the hwnd (list-windows).')
  E_BLOCKED_WINDOW   = @('Ventana PROHIBIDA por las reglas de seguridad (login/contrasena, correo web, X, pagos, seguridad): ''{0}''', 'Window FORBIDDEN by the safety rules (login/password, webmail, X, payments, security): ''{0}''')
  E_NOW_BLOCKED      = @('La ventana ha pasado a una pagina PROHIBIDA (''{0}''). Paro y quito el modo confianza.', 'The window switched to a FORBIDDEN page (''{0}''). Stopping and revoking trust mode.')
  E_OFF_MONITOR      = @('La ventana ({0}) no esta entera en el monitor objetivo {1} ({2}). Muevela alli.', 'The window ({0}) is not fully on the target monitor {1} ({2}). Move it there.')
  E_MONITOR_NOT_FOUND= @('No encuentro el monitor ''{0}'' (TargetMonitor). Usa: monitors', 'Monitor ''{0}'' not found (TargetMonitor). Use: monitors')
  E_FOCUS_FAILED     = @('No pude traer la ventana objetivo al frente.', 'Could not bring the target window to the front.')
  E_FOCUS_LOST       = @('La ventana objetivo perdio el foco; paro para no escribir en otra ventana.', 'The target window lost focus; stopping so nothing is typed into another window.')
  E_FIELD_UNKNOWN    = @('No puedo comprobar el campo enfocado; no escribo.', 'Cannot inspect the focused field; not typing.')
  E_PASSWORD_FIELD   = @('El campo enfocado es de CONTRASENA. Nunca escribo ni pego ahi.', 'The focused field is a PASSWORD field. I never type or paste there.')
  E_ADDRESS_BAR      = @('El foco esta en la barra de direcciones del navegador. Para navegar usa: navigate <url>', 'Focus is on the browser address bar. To navigate use: navigate <url>')
  E_KEY_BLOCKED      = @('Combinacion bloqueada: {0}', 'Blocked key combination: {0}')
  E_KEY_WIN          = @('La tecla Windows (y Ctrl+Esc) no esta permitida.', 'The Windows key (and Ctrl+Esc) is not allowed.')
  E_KEY_UNKNOWN      = @('Tecla desconocida: {0}', 'Unknown key: {0}')
  E_KEY_NOKEY        = @('Combinacion sin tecla principal: {0}', 'Key combination without a main key: {0}')
  E_KEY_TWO          = @('Combinacion con dos teclas principales: {0}', 'Key combination with two main keys: {0}')
  E_KEY_ADDRESSBAR   = @('Atajo de barra de direcciones bloqueado en navegadores ({0}). Usa: navigate <url>', 'Address-bar shortcut blocked in browsers ({0}). Use: navigate <url>')
  E_KEY_NEWTAB       = @('Abrir pestanas o ventanas nuevas esta bloqueado ({0}). El usuario puede activarlo con AllowNewTabs en config.json.', 'Opening new tabs or windows is blocked ({0}). The user can allow it with AllowNewTabs in config.json.')
  E_NEW_WINDOW       = @('Se abrio una ventana nueva de navegador: {0}. Modo confianza retirado; revisa la pantalla.', 'A new browser window opened: {0}. Trust mode revoked; check the screen.')
  E_NAV_OFF          = @('La navegacion esta desactivada (Navigation = "off" en config.json).', 'Navigation is disabled (Navigation = "off" in config.json).')
  E_NAV_NOT_BROWSER  = @('La ventana objetivo no es un navegador.', 'The target window is not a browser.')
  E_NAV_NO_ADDRESSBAR= @('No pude confirmar que el foco este en la barra de direcciones; no escribo la URL.', 'Could not confirm the focus is on the address bar; not typing the URL.')
  E_URL_INVALID      = @('URL no valida: {0}', 'Invalid URL: {0}')
  E_URL_SCHEME       = @('Solo se permiten URLs http/https: {0}', 'Only http/https URLs are allowed: {0}')
  E_URL_CREDENTIALS  = @('URL con usuario/contrasena incrustados no permitida: {0}', 'URLs with embedded user/password are not allowed: {0}')
  E_URL_BLOCKED      = @('URL PROHIBIDA por las reglas de seguridad (correo, X, pagos, banca, login): {0}', 'URL FORBIDDEN by the safety rules (mail, X, payments, banking, login): {0}')
  E_URL_NOT_ALLOWED  = @('La URL no esta en UrlAllowlist: {0}', 'The URL is not in UrlAllowlist: {0}')
  E_RATE_LIMIT       = @('Limite de velocidad: maximo {0} acciones por minuto. Espera {1} s.', 'Rate limit: at most {0} actions per minute. Wait {1} s.')
  E_RATE_BATCH       = @('El batch tiene {0} acciones y el limite es {1} por minuto. Dividelo.', 'The batch has {0} actions and the limit is {1} per minute. Split it.')
  E_OUT_OF_WINDOW    = @('({0},{1}) esta fuera de la ventana ({2}x{3}).', '({0},{1}) is outside the window ({2}x{3}).')
  E_POINT_OFF_MONITOR= @('El punto ({0},{1}) no esta en el monitor objetivo.', 'Point ({0},{1}) is not on the target monitor.')
  E_BAD_NUMBER       = @('Numero no valido: {0}', 'Invalid number: {0}')
  E_BAD_BUTTON       = @('Boton no valido: {0} (left|right|double)', 'Invalid button: {0} (left|right|double)')
  E_SHOT_PATH        = @('La captura debe guardarse como .png: {0}', 'Screenshots must be saved as .png: {0}')
  E_BATCH_JSON       = @('El batch no es JSON valido: {0}', 'The batch is not valid JSON: {0}')
  E_BATCH_EMPTY      = @('Batch vacio.', 'Empty batch.')
  E_BATCH_TOO_LONG   = @('Maximo {0} pasos por batch (hay {1}).', 'At most {0} steps per batch (got {1}).')
  E_BATCH_STEP       = @('Paso {0}: comando no permitido en batch: ''{1}''', 'Step {0}: command not allowed in batch: ''{1}''')
  E_BATCH_FORMAT     = @('Paso {0}: debe ser un objeto {{"cmd":..., "args":[...]}}', 'Step {0}: must be an object {{"cmd":..., "args":[...]}}')
  E_BATCH_ARGS       = @('Paso {0}: "args" debe ser una lista de textos o numeros.', 'Step {0}: "args" must be a list of strings or numbers.')
  E_CONFIG_JSON      = @('config.json no es JSON valido: {0}', 'config.json is not valid JSON: {0}')
  E_CONFIG_VALUE     = @('config.json: valor no valido para {0}: ''{1}''', 'config.json: invalid value for {0}: ''{1}''')
  E_CONFIG_RANGE     = @('config.json: {0} = {1} fuera de rango ({2}..{3}).', 'config.json: {0} = {1} out of range ({2}..{3}).')
  E_GUARD            = @('No pude arrancar el vigilante de panico (Ctrl+Alt+P), asi que no actuo. Revisa la instalacion (Unblock-File / RemoteSigned, ver README).', 'Could not start the panic guard (Ctrl+Alt+P), so I will not act. Check the install (Unblock-File / RemoteSigned, see README).')
  E_CANCELLED        = @('CANCELADO por el usuario: {0}', 'CANCELLED by the user: {0}')
  E_AUDIT_BROKEN     = @('REGISTRO DE AUDITORIA ALTERADO en la linea {0} ({1}).', 'AUDIT LOG TAMPERED at line {0} ({1}).')
  E_INTERNAL         = @('Error interno: {0}', 'Internal error: {0}')
}

class ManoError : System.Exception {
  [string]$Id; [int]$Code; [string]$Es; [string]$En
  ManoError([string]$id, [int]$code, [string]$es, [string]$en) : base($es) { $this.Id = $id; $this.Code = $code; $this.Es = $es; $this.En = $en }
}

function Get-ManoText {
  param([string]$Id, [object[]]$Arguments = @())
  $pair = $script:Messages[$Id]
  if (-not $pair) { $pair = @($Id, $Id) }
  $fa = @($Arguments)
  [pscustomobject]@{ Id = $Id; Es = ($pair[0] -f $fa); En = ($pair[1] -f $fa) }
}

# Returns the exception; use as:  throw (Get-ManoError 'E_X' @(args))
# Exit codes: 2 = refused/error, 3 = cancelled by the user, 4 = rate limited (wait and retry).
function Get-ManoError {
  param([string]$Id, [object[]]$Arguments = @(), [int]$Code = 0)
  if (-not $Code) { $Code = switch ($Id) { 'E_CANCELLED' { 3 } 'E_RATE_LIMIT' { 4 } default { 2 } } }
  $t = Get-ManoText $Id $Arguments
  [ManoError]::new($Id, $Code, $t.Es, $t.En)
}

function Select-ManoLanguage {
  param($Text)
  switch ($script:Lang) { 'en' { $Text.En } 'both' { "$($Text.Es) / $($Text.En)" } default { $Text.Es } }
}

# =====================================================================================================
# 2. Logica pura (testeable en cualquier SO) / pure logic (testable on any OS)
# =====================================================================================================
function ConvertFrom-ManoArgument {
  param([string[]]$Arguments)
  $list = New-Object System.Collections.Generic.List[string]
  $flags = [ordered]@{ DryRun = $false; Json = $false; Lang = ''; Rest = @() }
  foreach ($a in @($Arguments)) {
    if ($null -eq $a) { continue }
    switch -Exact ($a) {
      '--dry-run' { $flags.DryRun = $true }
      '--json'    { $flags.Json = $true }
      '--en'      { $flags.Lang = 'en' }
      '--es'      { $flags.Lang = 'es' }
      default     { $list.Add($a) }
    }
  }
  $flags.Rest = $list.ToArray()
  [pscustomobject]$flags
}

function Get-ManoClipped {
  param([string]$Text, [int]$Max = 200)
  if ($null -eq $Text) { return '' }
  if ($Text.Length -gt $Max) { $Text.Substring(0, $Max) + '...' } else { $Text }
}

# ---------- config ----------
$script:ConfigDefaults = [ordered]@{
  TargetMonitor       = 'primary'
  ShotsDir            = ''
  ConfirmTimeoutSec   = 20
  TrustMaxMinutes     = 60
  ExtraBlockedTitles  = @()
  Language            = 'es'
  Navigation          = 'off'
  UrlAllowlist        = @()
  ExtraBlockedUrls    = @()
  AllowNewTabs        = $false
  MaxActionsPerMinute = 60
  Overlay             = $true
  GuardIdleMinutes    = 30
  ExtraBrowsers       = @()
}
# Hard ceilings: config can make things stricter, never looser than these.
$script:ConfigRanges  = @{ ConfirmTimeoutSec = @(5, 300); TrustMaxMinutes = @(1, 240); MaxActionsPerMinute = @(1, 300); GuardIdleMinutes = @(1, 1440) }
$script:ConfigChoices = @{ Language = @('es', 'en', 'both'); Navigation = @('off', 'allowlist', 'ask') }

function ConvertTo-ManoConfigValue {
  param([string]$Key, $Value)
  $def = $script:ConfigDefaults[$Key]
  if ($def -is [bool]) {
    if ($Value -is [bool]) { return $Value }
    $s = "$Value".Trim().ToLowerInvariant()
    if ($s -in @('true', '1', 'yes', 'si')) { return $true }
    if ($s -in @('false', '0', 'no')) { return $false }
    throw (Get-ManoError 'E_CONFIG_VALUE' @($Key, $Value))
  }
  if ($def -is [int]) {
    $n = 0
    if ($Value -is [bool] -or -not [int]::TryParse("$Value", [ref]$n)) { throw (Get-ManoError 'E_CONFIG_VALUE' @($Key, $Value)) }
    $rg = $script:ConfigRanges[$Key]
    if ($rg -and ($n -lt $rg[0] -or $n -gt $rg[1])) { throw (Get-ManoError 'E_CONFIG_RANGE' @($Key, $n, $rg[0], $rg[1])) }
    return $n
  }
  if ($def -is [array]) {
    $out = @(@($Value) | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() })
    return , $out
  }
  $s = "$Value".Trim()
  $choices = $script:ConfigChoices[$Key]
  if ($choices) {
    $s = $s.ToLowerInvariant()
    if ($s -notin $choices) { throw (Get-ManoError 'E_CONFIG_VALUE' @($Key, $Value)) }
  }
  $s
}

function Import-ManoConfig {
  param([string]$Path, [string]$MonitorOverride, [string]$LanguageOverride)
  $cfg = [ordered]@{}
  foreach ($k in $script:ConfigDefaults.Keys) { $cfg[$k] = $script:ConfigDefaults[$k] }
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($raw -and $raw.Trim()) {
      try { $j = $raw | ConvertFrom-Json } catch { throw (Get-ManoError 'E_CONFIG_JSON' @($_.Exception.Message)) }
      if ($j -isnot [pscustomobject]) { throw (Get-ManoError 'E_CONFIG_JSON' @('se esperaba un objeto { } / expected an object { }')) }
      foreach ($k in @($script:ConfigDefaults.Keys)) {
        $p = $j.PSObject.Properties[$k]
        if ($null -eq $p) { continue }
        $v = $p.Value
        if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { continue }
        $cfg[$k] = ConvertTo-ManoConfigValue $k $v
      }
    }
  }
  if ($MonitorOverride) { $cfg.TargetMonitor = $MonitorOverride }
  if ($LanguageOverride) { $cfg.Language = ConvertTo-ManoConfigValue 'Language' $LanguageOverride }
  $cfg
}

# ---------- HARD title rules (cannot be disabled by config or trust mode; config can only ADD) ----------
# v1.0 rules, unchanged: login/password, Gmail/webmail, X/Twitter, payments/banking.
$script:BlockedTitleCore = '\blog ?in\b|\bsign ?in\b|\bsign ?up\b|iniciar sesi|inicio de sesi|acceder a tu cuenta|contrase|password|passwort|\b2fa\b|verificaci.n en dos|one-time code|' +
  'gmail|mail\.google|inbox \(|bandeja de entrada|outlook\.live|' +
  '\(\d+\) x$| / x$| on x:| en x:|\bx\.com\b|twitter|' +
  'paypal|stripe|checkout|\bpago\b|\bpagar\b|payment|\bpay\b|billing|facturaci|tarjeta|credit card|\bbank|\bbanco|banca online|bizum|transferencia|wallet|cartera|coinbase|binance|crypto|cripto'
# v1.1 additions: more webmail, password managers, more payments, security/antivirus UIs, ManoSegura's own windows.
$script:BlockedTitleAdded = 'proton ?mail|yahoo mail|mail\.yahoo|tuta ?mail|tutanota|outlook\.office|tweetdeck|' +
  'bitwarden|1password|keepass|lastpass|dashlane|nordpass|' +
  'revolut|klarna|\biban\b|' +
  'kaspersky|windows defender|microsoft defender|seguridad de windows|windows security|control de cuentas de usuario|user account control|' +
  '^manosegura( -|$)'

function Get-ManoBlockedTitleRegex {
  param([string[]]$Extra)
  $parts = @($script:BlockedTitleCore, $script:BlockedTitleAdded)
  $ex = @(@($Extra) | Where-Object { $_ } | ForEach-Object { [regex]::Escape("$_") })
  if ($ex.Count) { $parts += ($ex -join '|') }
  '(?i)(' + ($parts -join '|') + ')'
}

function Test-ManoBlockedTitle {
  param([string]$Title, [string[]]$Extra)
  if (-not $Title) { return $false }
  [bool]([regex]::IsMatch($Title, (Get-ManoBlockedTitleRegex $Extra)))
}

# ---------- URL rules ----------
$script:BlockedHostRegex = '(?i)(' +
  '(^|\.)(gmail|paypal|stripe|coinbase|binance|kraken|revolut|klarna|bizum|protonmail|proton|tutanota|tuta|twitter|tweetdeck|bitwarden|1password|lastpass|dashlane|' +
  'caixabank|santander|bbva|ing|sabadell|bankinter|unicaja|kutxabank|ibercaja|abanca|openbank|evobanco|cajamar)\.[a-z.]+$|' +
  '(^|\.)(mail\.google|accounts\.google|pay\.google|outlook\.live|outlook\.office|outlook\.office365|mail\.yahoo|login\.yahoo|login\.microsoftonline|login\.live|account\.microsoft|appleid\.apple)\.com$|' +
  '(^|\.)x\.com$|(^|\.)t\.co$|' +
  '^(login|signin|sso|auth|accounts?|secure|banking|pay|payments?|checkout|billing|wallet|mail|webmail|correo)\.|' +
  'bank|banco)'
$script:BlockedPathRegex = '(?i)(^|/)(login|log-in|signin|sign-in|signup|sign-up|auth|oauth2?|sso|password|passwd|reset-password|checkout|payment|payments|pay|billing|wallet|2fa|mfa)(/|$|\.)'

function Test-ManoUrlInList {
  param([uri]$Uri, [string[]]$List)
  $hn = $Uri.DnsSafeHost.ToLowerInvariant()
  foreach ($e in @($List)) {
    $e = "$e".Trim()
    if (-not $e) { continue }
    if ($e -match '^(?i)https?://') {
      $abs = $Uri.AbsoluteUri
      if ($abs.StartsWith($e, [StringComparison]::OrdinalIgnoreCase)) {
        if ($e.EndsWith('/') -or $abs.Length -eq $e.Length -or ($abs[$e.Length] -in @([char]'/', [char]'?', [char]'#'))) { return $true }
      }
      continue
    }
    $pat = $e.ToLowerInvariant().TrimStart('*').TrimStart('.')
    if ($pat -and ($hn -eq $pat -or $hn.EndsWith('.' + $pat))) { return $true }
  }
  $false
}

# Pure: decides if "navigate <url>" may run. Returns an object; never throws.
function Test-ManoUrl {
  param([string]$Url, [string]$Mode = 'ask', [string[]]$Allowlist, [string[]]$ExtraBlocked)
  $r = [ordered]@{ Ok = $false; Id = ''; Url = $Url; Normalized = ''; Host = ''; InAllowlist = $false; NeedsExplicitConfirm = $true }
  if ($Mode -eq 'off') { $r.Id = 'E_NAV_OFF'; return [pscustomobject]$r }
  $u = "$Url".Trim()
  if (-not $u -or $u -match '[\s\x00-\x1f\x7f]') { $r.Id = 'E_URL_INVALID'; return [pscustomobject]$r }
  if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.\-]*:' -and $u -match '^[^/\\]+\.[^/\\]+') { $u = 'https://' + $u }
  $uri = $null
  if (-not [uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { $r.Id = 'E_URL_INVALID'; return [pscustomobject]$r }
  if ($uri.Scheme -notin @('http', 'https')) { $r.Id = 'E_URL_SCHEME'; return [pscustomobject]$r }
  if ($uri.UserInfo) { $r.Id = 'E_URL_CREDENTIALS'; return [pscustomobject]$r }
  $hn = $uri.DnsSafeHost.ToLowerInvariant()
  $r.Host = $hn; $r.Normalized = $uri.AbsoluteUri
  if (-not $hn) { $r.Id = 'E_URL_INVALID'; return [pscustomobject]$r }
  $blocked = [regex]::IsMatch($hn, $script:BlockedHostRegex) -or [regex]::IsMatch($uri.AbsolutePath, $script:BlockedPathRegex)
  foreach ($x in @($ExtraBlocked)) { if ($x -and $uri.AbsoluteUri.IndexOf("$x", [StringComparison]::OrdinalIgnoreCase) -ge 0) { $blocked = $true } }
  if ($blocked) { $r.Id = 'E_URL_BLOCKED'; return [pscustomobject]$r }
  $r.InAllowlist = Test-ManoUrlInList $uri $Allowlist
  if ($Mode -eq 'allowlist' -and -not $r.InAllowlist) { $r.Id = 'E_URL_NOT_ALLOWED'; return [pscustomobject]$r }
  $r.Ok = $true
  $r.NeedsExplicitConfirm = -not $r.InAllowlist
  [pscustomobject]$r
}

# ---------- browsers ----------
$script:BrowserNames = @('chrome', 'msedge', 'brave', 'firefox', 'opera', 'vivaldi', 'iexplore', 'chromium', 'waterfox', 'librewolf',
  'thorium', 'browser', 'arc', 'zen', 'floorp', 'palemoon', 'seamonkey', 'maxthon', 'duckduckgo', 'yandex', 'whale', 'epic', 'slimjet', 'ucbrowser')

function Test-ManoBrowser {
  param([string]$ProcessName, [string[]]$Extra)
  if (-not $ProcessName) { return $false }
  $n = ($ProcessName -replace '(?i)\.exe$', '').ToLowerInvariant()
  $all = @($script:BrowserNames) + @(@($Extra) | Where-Object { $_ } | ForEach-Object { ("$_" -replace '(?i)\.exe$', '').ToLowerInvariant() })
  $n -in $all
}

# Chromium omnibox / Firefox urlbar, by locale-independent ids first, then by localized names.
function Test-ManoAddressBarElement {
  param([string]$Name, [string]$AutomationId, [string]$ClassName)
  if ($ClassName -match '(?i)OmniboxView|LocationBar|AddressBar') { return $true }
  if ($AutomationId -match '(?i)urlbar|addressbar|omnibox|address_bar') { return $true }
  [bool]($Name -match '(?i)(address and search bar|barra de direcciones|search or enter (web )?address|buscar o (escribir|introducir)|introduce (una )?direcci|escribe (una )?direcci|enter address|direcci.n web)')
}

# ---------- keys ----------
$script:KeyAlias = @{ escape = 'esc'; supr = 'delete'; del = 'delete'; ins = 'insert'; intro = 'enter'; return = 'enter'; pgup = 'pageup'; pgdn = 'pagedown'; espacio = 'space'; bksp = 'backspace' }
$script:KeySendMap = @{ enter = '{ENTER}'; tab = '{TAB}'; esc = '{ESC}'; backspace = '{BACKSPACE}'; delete = '{DELETE}'; insert = '{INSERT}'; up = '{UP}'; down = '{DOWN}'
  left = '{LEFT}'; right = '{RIGHT}'; home = '{HOME}'; end = '{END}'; pageup = '{PGUP}'; pagedown = '{PGDN}'; space = ' ' }
1..12 | ForEach-Object { $script:KeySendMap["f$_"] = "{F$_}" }
$script:ComboAddressBar   = @('ctrl+l', 'alt+d', 'f6', 'shift+f6', 'ctrl+e', 'ctrl+k', 'alt+home')
$script:ComboNewTab       = @('ctrl+t', 'ctrl+n', 'ctrl+shift+n', 'ctrl+shift+t', 'ctrl+shift+p', 'alt+enter', 'ctrl+shift+enter')
$script:ComboWindowSwitch = @('alt+tab', 'alt+shift+tab', 'ctrl+alt+tab', 'alt+esc', 'alt+shift+esc')

function ConvertTo-ManoCombo {
  param([string]$Combo)
  $c = ("$Combo" -replace '\s', '').ToLowerInvariant()
  if (-not $c) { throw (Get-ManoError 'E_KEY_NOKEY' @($Combo)) }
  if ($c -eq '+') { $parts = @('+') }
  elseif ($c.EndsWith('++')) { $parts = @($c.Substring(0, $c.Length - 2) -split '\+') + @('+') }
  else { $parts = @($c -split '\+') }
  $mods = New-Object System.Collections.Generic.List[string]; $key = ''
  foreach ($p in $parts) {
    if ($p -eq '') { continue }
    $m = switch ($p) { { $_ -in 'ctrl', 'control', 'ctl' } { 'ctrl' } { $_ -in 'shift', 'mayus' } { 'shift' } 'alt' { 'alt' } default { '' } }
    if ($m) { if (-not $mods.Contains($m)) { $mods.Add($m) }; continue }
    if ($p -in @('win', 'windows', 'super', 'meta', 'lwin', 'rwin', 'cmd')) { throw (Get-ManoError 'E_KEY_WIN') }
    $k = if ($script:KeyAlias.ContainsKey($p)) { $script:KeyAlias[$p] } else { $p }
    if (-not ($script:KeySendMap.ContainsKey($k) -or $k.Length -eq 1)) { throw (Get-ManoError 'E_KEY_UNKNOWN' @($p)) }
    if ($key) { throw (Get-ManoError 'E_KEY_TWO' @($Combo)) }
    $key = $k
  }
  if (-not $key) { throw (Get-ManoError 'E_KEY_NOKEY' @($Combo)) }
  $ordered = @(@('ctrl', 'alt', 'shift') | Where-Object { $mods.Contains($_) })
  [pscustomobject]@{ Mods = [string[]]$ordered; Key = $key; Normalized = ((@($ordered) + @($key)) -join '+') }
}

# Pure: $null if allowed, else @{ Id; Arg }.
function Get-ManoComboBlock {
  param($Parts, [bool]$IsBrowser, [bool]$AllowNewTabs)
  $m = @($Parts.Mods); $k = $Parts.Key; $n = $Parts.Normalized
  if ($m -contains 'alt' -and $k -eq 'f4') { return @{ Id = 'E_KEY_BLOCKED'; Arg = $n } }
  if ($m -contains 'ctrl' -and $m -contains 'alt' -and $k -eq 'delete') { return @{ Id = 'E_KEY_BLOCKED'; Arg = $n } }
  if ($m -contains 'ctrl' -and $m -contains 'shift' -and $k -eq 'esc') { return @{ Id = 'E_KEY_BLOCKED'; Arg = $n } }
  if ($n -eq 'ctrl+esc') { return @{ Id = 'E_KEY_WIN'; Arg = $n } }
  if ($n -in $script:ComboWindowSwitch) { return @{ Id = 'E_KEY_BLOCKED'; Arg = $n } }
  if ($IsBrowser) {
    if ($n -in $script:ComboAddressBar) { return @{ Id = 'E_KEY_ADDRESSBAR'; Arg = $n } }
    if (-not $AllowNewTabs -and $n -in $script:ComboNewTab) { return @{ Id = 'E_KEY_NEWTAB'; Arg = $n } }
  }
  $null
}

function ConvertTo-ManoSendKey {
  param($Parts)
  $mods = ''
  foreach ($m in @($Parts.Mods)) { $mods += switch ($m) { 'ctrl' { '^' } 'alt' { '%' } 'shift' { '+' } } }
  $k = $Parts.Key
  $kp = if ($script:KeySendMap.ContainsKey($k)) { $script:KeySendMap[$k] } else { ($k -replace '([+^%~(){}\[\]])', '{$1}') }
  "$mods$kp"
}

function ConvertTo-ManoSendKeyText {
  param([string]$Text)
  (($Text -replace '([+^%~(){}\[\]])', '{$1}') -replace "`r?`n", '{ENTER}') -replace "`t", '{TAB}'
}

# ---------- monitors / geometry (Bounds need X, Y, Width, Height) ----------
function Test-ManoPointInside {
  param([int]$X, [int]$Y, $Rect)
  ($X -ge $Rect.X) -and ($Y -ge $Rect.Y) -and ($X -lt ($Rect.X + $Rect.Width)) -and ($Y -lt ($Rect.Y + $Rect.Height))
}

function Test-ManoRectInside {
  param($Inner, $Outer)
  ($Inner.X -ge $Outer.X) -and ($Inner.Y -ge $Outer.Y) -and (($Inner.X + $Inner.Width) -le ($Outer.X + $Outer.Width)) -and (($Inner.Y + $Inner.Height) -le ($Outer.Y + $Outer.Height))
}

function Format-ManoRect {
  param($Rect)
  "$($Rect.X),$($Rect.Y) $($Rect.Width)x$($Rect.Height)"
}

# Spec: primary | <index> | left/izquierda | right/derecha | x=-1920 | -1920 | -1920,0 (a point) | \\.\DISPLAY2 | DISPLAY2 | part of the monitor id (ACR, DEL...)
function Select-ManoMonitor {
  param([object[]]$Monitors, [string]$Spec)
  $all = @($Monitors)
  if (-not $all.Count) { return $null }
  $s = "$Spec".Trim()
  if (-not $s -or $s -in @('primary', 'primario', 'principal')) { return ($all | Where-Object { $_.Primary } | Select-Object -First 1) }
  if ($s -match '^\d+$') { $i = [int]$s; if ($i -lt $all.Count) { return $all[$i] }; return $null }
  if ($s -match '^(?i)(left|izquierda|izq)$') { return ($all | Sort-Object -Property { $_.Bounds.X } | Select-Object -First 1) }
  if ($s -match '^(?i)(right|derecha|der)$') { return ($all | Sort-Object -Property { $_.Bounds.X } -Descending | Select-Object -First 1) }
  if ($s -match '^(?i)(?:x=)?(-?\d+)\s*,\s*(-?\d+)$') {
    $px = [int]$Matches[1]; $py = [int]$Matches[2]
    return ($all | Where-Object { Test-ManoPointInside $px $py $_.Bounds } | Select-Object -First 1)
  }
  if ($s -match '^(?i)x=(-?\d+)$' -or $s -match '^(-\d+)$') {
    $px = [int]$Matches[1]
    return ($all | Where-Object { $_.Bounds.X -eq $px } | Select-Object -First 1)
  }
  $m = @($all | Where-Object { $_.DeviceName -eq $s -or $_.DeviceName -like "*\$s" })
  if ($m.Count) { return $m[0] }
  $m = @($all | Where-Object { $_.MonitorId -and $_.MonitorId.IndexOf($s, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
  if ($m.Count) { return $m[0] }
  $null
}

# Border rectangles around a window: outside it when there is room on the monitor, otherwise just inside.
function Get-ManoOverlayEdge {
  param($Window, $Monitor, [int]$Thickness = 3)
  $t = [math]::Max(1, $Thickness)
  $wr = $Window.X + $Window.Width; $wb = $Window.Y + $Window.Height
  $mr = $Monitor.X + $Monitor.Width; $mb = $Monitor.Y + $Monitor.Height
  $l  = if ($Window.X - $t -ge $Monitor.X) { $Window.X - $t } else { $Window.X }
  $rx = if ($wr + $t -le $mr) { $wr } else { $wr - $t }
  $tp = if ($Window.Y - $t -ge $Monitor.Y) { $Window.Y - $t } else { $Window.Y }
  $bt = if ($wb + $t -le $mb) { $wb } else { $wb - $t }
  $w = $rx + $t - $l; $h = $bt + $t - $tp
  @(
    [pscustomobject]@{ Side = 'top';    X = $l;  Y = $tp; Width = $w; Height = $t }
    [pscustomobject]@{ Side = 'bottom'; X = $l;  Y = $bt; Width = $w; Height = $t }
    [pscustomobject]@{ Side = 'left';   X = $l;  Y = $tp; Width = $t; Height = $h }
    [pscustomobject]@{ Side = 'right';  X = $rx; Y = $tp; Width = $t; Height = $h }
  )
}

# ---------- trust / rate limit ----------
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
  # A trust file further in the future than the allowed maximum was not written by the dialog: ignore it.
  ($t -gt $Now) -and ($t -le $Now.AddMinutes($MaxMinutes + 1))
}

function Test-ManoRateLimit {
  param([datetime[]]$History, [datetime]$Now, [int]$Max, [int]$Count = 1, [int]$WindowSec = 60)
  $from = $Now.AddSeconds(-$WindowSec); $until = $Now.AddSeconds(5)
  $recent = @(@($History) | Where-Object { $_ -gt $from -and $_ -le $until } | Sort-Object)
  $res = [ordered]@{ Allowed = $true; RetryAfterSec = 0; NeverFits = $false; Recent = $recent }
  if ($Count -gt $Max) { $res.Allowed = $false; $res.NeverFits = $true; $res.RetryAfterSec = $WindowSec; return [pscustomobject]$res }
  if ($recent.Count + $Count -le $Max) { return [pscustomobject]$res }
  $k = $recent.Count + $Count - $Max
  $free = $recent[$k - 1].AddSeconds($WindowSec)
  $res.Allowed = $false
  $res.RetryAfterSec = [int][math]::Max(1, [math]::Ceiling(($free - $Now).TotalSeconds))
  [pscustomobject]$res
}

# ---------- audit log with hash chain ----------
function Get-ManoSha256 {
  param([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Text")) } finally { $sha.Dispose() }
  -join ($b | ForEach-Object { $_.ToString('x2') })
}

function Get-ManoAuditPayload {
  param([string]$Seq, [string]$Time, [string]$ProcessId, [string]$EventName, [string]$Detail, [string]$Prev)
  "manosegura-audit-v1`n$Seq`n$Time`n$ProcessId`n$EventName`n$Detail`n$Prev"
}

function Get-ManoAuditRecord {
  param([long]$Seq, [string]$Prev, [string]$EventName, [string]$Detail, [string]$Time, [int]$ProcessId)
  $ev = ("$EventName" -replace "[`r`n]+", ' ')
  $d  = Get-ManoClipped ("$Detail" -replace "`r?`n", ' | ') 1000
  $hash = Get-ManoSha256 (Get-ManoAuditPayload "$Seq" $Time "$ProcessId" $ev $d $Prev)
  [ordered]@{ seq = $Seq; time = $Time; pid = $ProcessId; event = $ev; detail = $d; prev = $Prev; hash = $hash }
}

function Test-ManoAuditChain {
  param([string[]]$Lines, [string]$HeadHash)
  $prev = $script:GenesisHash; $expect = 1; $n = 0; $count = 0
  foreach ($line in @($Lines)) {
    $n++
    if (-not "$line".Trim()) { continue }
    try { $o = $line | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Count = $count; BrokenAt = $n; Reason = 'json' } }
    if ("$($o.seq)" -ne "$expect") { return [pscustomobject]@{ Ok = $false; Count = $count; BrokenAt = $n; Reason = 'seq' } }
    if ("$($o.prev)" -ne $prev)    { return [pscustomobject]@{ Ok = $false; Count = $count; BrokenAt = $n; Reason = 'prev' } }
    $calc = Get-ManoSha256 (Get-ManoAuditPayload "$($o.seq)" "$($o.time)" "$($o.pid)" "$($o.event)" "$($o.detail)" "$($o.prev)")
    if ($calc -ne "$($o.hash)") { return [pscustomobject]@{ Ok = $false; Count = $count; BrokenAt = $n; Reason = 'hash' } }
    $prev = $calc; $expect++; $count++
  }
  if ($HeadHash -and $HeadHash -ne $prev) { return [pscustomobject]@{ Ok = $false; Count = $count; BrokenAt = $n; Reason = 'head' } }
  [pscustomobject]@{ Ok = $true; Count = $count; BrokenAt = 0; Reason = '' }
}

# ---------- batch ----------
$script:BatchCommands = @('focus', 'screenshot', 'click', 'type', 'paste', 'key', 'scroll', 'wait', 'navigate')

function ConvertFrom-ManoBatch {
  param([string]$Json, [int]$MaxSteps = 50)
  try { $obj = $Json | ConvertFrom-Json } catch { throw (Get-ManoError 'E_BATCH_JSON' @($_.Exception.Message)) }
  if ($null -eq $obj) { throw (Get-ManoError 'E_BATCH_EMPTY') }
  if ($obj -is [array]) { $steps = @($obj) }
  elseif ($obj -is [pscustomobject] -and $obj.PSObject.Properties['steps']) { $steps = @($obj.steps) }
  else { $steps = @($obj) }
  $steps = @($steps | Where-Object { $null -ne $_ })
  if (-not $steps.Count) { throw (Get-ManoError 'E_BATCH_EMPTY') }
  if ($steps.Count -gt $MaxSteps) { throw (Get-ManoError 'E_BATCH_TOO_LONG' @($MaxSteps, $steps.Count)) }
  $i = 0
  foreach ($s in $steps) {
    $i++
    if ($s -isnot [pscustomobject] -or -not $s.PSObject.Properties['cmd']) { throw (Get-ManoError 'E_BATCH_FORMAT' @($i)) }
    $c = "$($s.cmd)".Trim().ToLowerInvariant()
    if ($c -notin $script:BatchCommands) { throw (Get-ManoError 'E_BATCH_STEP' @($i, $c)) }
    $av = New-Object System.Collections.Generic.List[string]
    $ap = $s.PSObject.Properties['args']
    if ($ap -and $null -ne $ap.Value) {
      foreach ($x in @($ap.Value)) {
        if ($x -is [string] -or $x -is [ValueType]) { $av.Add([string]$x) } else { throw (Get-ManoError 'E_BATCH_ARGS' @($i)) }
      }
    }
    [pscustomobject]@{ Index = $i; Cmd = $c; Args = [string[]]$av.ToArray() }
  }
}

function Read-ManoBatchSource {
  param([string]$Source)
  if ($Source -eq '-') { return [Console]::In.ReadToEnd() }
  $t = $Source.TrimStart()
  if ($t.StartsWith('{') -or $t.StartsWith('[')) { return $Source }
  if (Test-Path -LiteralPath $Source -PathType Leaf) { return (Get-Content -LiteralPath $Source -Raw -Encoding UTF8) }
  $Source
}

function Get-ManoActionCount {
  param([object[]]$Steps)
  @(@($Steps) | Where-Object { $_.Cmd -notin @('wait', 'screenshot') }).Count
}

function Get-ManoInt {
  param([string]$Text)
  $n = 0
  if (-not [int]::TryParse("$Text", [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { throw (Get-ManoError 'E_BAD_NUMBER' @($Text)) }
  $n
}

# ---------- output ----------
# JSON with every non-ASCII char escaped (\uXXXX), so it survives any console code page.
function ConvertTo-ManoJson {
  param($InputObject)
  $j = ConvertTo-Json -InputObject $InputObject -Depth 8 -Compress
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $j.ToCharArray()) {
    if ([int]$ch -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) }
  }
  $sb.ToString()
}

function Get-ManoResult {
  param([string]$Action, [string]$Message, [hashtable]$Data)
  $o = [ordered]@{ action = $Action; message = $Message }
  if ($Data) { foreach ($kv in $Data.GetEnumerator()) { $o[$kv.Key] = $kv.Value } }   # GetEnumerator: a key named 'keys' must not hide .Keys
  [pscustomobject]$o
}

function Format-ManoText {
  param([object[]]$Results)
  $objs = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($Results)) {
    if ($null -eq $r) { continue }
    if ($r -is [string]) { $r; continue }
    if ($r.PSObject.Properties['message']) { "$($r.message)"; continue }
    $objs.Add($r)
  }
  if ($objs.Count -eq 1) { ($objs[0] | Format-List | Out-String -Width 300).Trim() }
  elseif ($objs.Count -gt 1) { ($objs | Format-Table -AutoSize | Out-String -Width 300).TrimEnd() }
}

# =====================================================================================================
# 3. Estado y registros / state and logs
# =====================================================================================================
function Initialize-ManoPath {
  param([string]$Root)
  $script:Root = $Root
  $script:ConfigFile = Join-Path $Root 'config.json'
  $script:Cfg = Import-ManoConfig -Path $script:ConfigFile -MonitorOverride $env:MANOSEGURA_MONITOR -LanguageOverride $env:MANOSEGURA_LANG
  $script:StateDir = Join-Path $Root 'state'
  $script:LogsDir  = Join-Path $Root 'logs'
  $script:ShotsDir = if ($script:Cfg.ShotsDir) { [Environment]::ExpandEnvironmentVariables($script:Cfg.ShotsDir) } else { Join-Path $Root 'shots' }
  foreach ($d in $script:StateDir, $script:LogsDir, $script:ShotsDir) { if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) } }
  $script:DisabledFlag = Join-Path $script:StateDir 'disabled.flag'
  $script:TrustFile    = Join-Path $script:StateDir 'trust.txt'
  $script:TargetFile   = Join-Path $script:StateDir 'target.txt'
  $script:RateFile     = Join-Path $script:StateDir 'rate.txt'
  $script:ActivityFile = Join-Path $script:StateDir 'last-action.txt'
  $script:AuditHead    = Join-Path $script:StateDir 'audit.head'
  $script:LogFile      = Join-Path $script:LogsDir 'manosegura.log'
  $script:AuditFile    = Join-Path $script:LogsDir 'audit.jsonl'
}

function Invoke-ManoLocked {
  param([string]$Name, [scriptblock]$Script, [object[]]$ArgumentList = @())
  $m = New-Object System.Threading.Mutex($false, $Name)
  $got = $false
  try {
    try { $got = $m.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    & $Script @ArgumentList
  } finally { if ($got) { $m.ReleaseMutex() }; $m.Dispose() }
}

function Write-ManoLog {
  param([string]$Message)
  try {
    if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 5MB) {
      Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
    }
    Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $PID, $Message)
  } catch { Write-Verbose "log: $($_.Exception.Message)" }
}

function Get-ManoLastLine {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
  try {
    $len = $fs.Length
    if ($len -eq 0) { return $null }
    $take = [int][math]::Min($len, 16384); [void]$fs.Seek(-$take, 'End')
    $buf = New-Object byte[] $take; [void]$fs.Read($buf, 0, $take)
  } finally { $fs.Dispose() }
  $lines = @([Text.Encoding]::UTF8.GetString($buf) -split "`r?`n" | Where-Object { $_.Trim() })
  if ($lines.Count) { $lines[-1] } else { $null }
}

function Write-ManoAudit {
  param([string]$EventName, [string]$Detail)
  try {
    Invoke-ManoLocked 'Local\ManoSeguraAudit' -ArgumentList @($EventName, $Detail) -Script {
      param($ev, $dt)
      $prev = $script:GenesisHash; $seq = 1
      $last = Get-ManoLastLine $script:AuditFile
      if ($last) { $lo = $last | ConvertFrom-Json; $prev = "$($lo.hash)"; $seq = [long]$lo.seq + 1 }
      $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz', [Globalization.CultureInfo]::InvariantCulture)
      $rec = Get-ManoAuditRecord -Seq $seq -Prev $prev -EventName $ev -Detail $dt -Time $now -ProcessId $PID
      $line = ConvertTo-Json -InputObject $rec -Compress
      $enc = New-Object System.Text.UTF8Encoding($false)
      [IO.File]::AppendAllText($script:AuditFile, $line + "`n", $enc)
      [IO.File]::WriteAllText($script:AuditHead, "$($rec.seq) $($rec.hash)", $enc)
    }
  } catch { Write-ManoLog "AUDITORIA FALLO: $($_.Exception.Message)" }
}

function Write-ManoEvent {
  param([string]$EventName, [string]$Detail)
  Write-ManoLog "$($EventName): $Detail"
  Write-ManoAudit $EventName $Detail
}

function Test-ManoTrust {
  if (-not (Test-Path -LiteralPath $script:TrustFile)) { return $false }
  $txt = ''
  try { $txt = Get-Content -LiteralPath $script:TrustFile -Raw } catch { return $false }
  Test-ManoTrustValue $txt (Get-Date) ([int]$script:Cfg.TrustMaxMinutes)
}

function Revoke-ManoTrust {
  param([string]$Reason)
  if (Test-Path -LiteralPath $script:TrustFile) {
    Remove-Item -LiteralPath $script:TrustFile -Force -ErrorAction SilentlyContinue
    Write-ManoEvent 'CONFIANZA_RETIRADA' $Reason
  }
}

function Register-ManoRate {
  param([int]$Count = 1)
  if ($script:DryRun -or $Count -le 0) { return }
  $max = [int]$script:Cfg.MaxActionsPerMinute
  $res = Invoke-ManoLocked $script:MutexState -ArgumentList @($Count, $max) -Script {
    param($n, $limit)
    $hist = @()
    if (Test-Path -LiteralPath $script:RateFile) {
      $hist = @(Get-Content -LiteralPath $script:RateFile | ForEach-Object { $tk = 0L; if ([long]::TryParse("$_", [ref]$tk)) { [datetime]::new($tk, [DateTimeKind]::Utc) } })
    }
    $now = [datetime]::UtcNow
    $r = Test-ManoRateLimit -History $hist -Now $now -Max $limit -Count $n
    $keep = @($r.Recent)
    if ($r.Allowed) { $keep += @(1..$n | ForEach-Object { $now }) }
    Set-Content -LiteralPath $script:RateFile -Value @($keep | ForEach-Object { $_.Ticks }) -Encoding ASCII
    $r
  }
  if ($res.NeverFits) { throw (Get-ManoError 'E_RATE_BATCH' @($Count, $max)) }
  if (-not $res.Allowed) { throw (Get-ManoError 'E_RATE_LIMIT' @($max, $res.RetryAfterSec)) }
}

function Assert-ManoEnabled {
  if (Test-Path -LiteralPath $script:DisabledFlag) { throw (Get-ManoError 'E_DISABLED') }
}

function Write-ManoActivity {
  try { Set-Content -LiteralPath $script:ActivityFile -Value (Get-Date).ToString('o') -Encoding ASCII } catch { Write-Verbose 'activity' }
}

# =====================================================================================================
# 4. Windows: nativo, ventanas, dialogos / native, windows, dialogs (Windows only)
# =====================================================================================================
function Test-ManoWindowsHost { ($env:OS -eq 'Windows_NT') -or ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) }

$script:NativeCode = @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr v);
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint f);
public delegate bool EnumProc(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
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
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, int d, IntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE d, uint f);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString; public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey; }
'@

function Initialize-ManoNative {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
  if (-not ('ManoSegura.Native' -as [type])) {
    Add-Type -Namespace ManoSegura -Name Native -UsingNamespace System.Text -MemberDefinition $script:NativeCode
  }
  Initialize-ManoDpi
}

# Per-monitor DPI awareness so window rects, cursor and screen bounds all use the same physical pixels,
# also on mixed-DPI setups and monitors at negative coordinates (e.g. X = -1920).
function Initialize-ManoDpi {
  $ok = $false
  try { $ok = [ManoSegura.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $ok = $false }   # PER_MONITOR_AWARE_V2 (Win10 1703+)
  if (-not $ok) { try { $ok = ([ManoSegura.Native]::SetProcessDpiAwareness(2) -eq 0) } catch { $ok = $false } }   # Win8.1+
  if (-not $ok) { try { [void][ManoSegura.Native]::SetProcessDPIAware() } catch { Write-Verbose 'dpi' } }
  try { [void][ManoSegura.Native]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { Write-Verbose 'thread dpi' }
}

function Get-ManoDpiScale {
  param($Monitor)
  try {
    $pt = New-Object ManoSegura.Native+POINT
    $pt.X = [int]($Monitor.Bounds.X + $Monitor.Bounds.Width / 2); $pt.Y = [int]($Monitor.Bounds.Y + $Monitor.Bounds.Height / 2)
    $hm = [ManoSegura.Native]::MonitorFromPoint($pt, 2)
    $dx = [uint32]0; $dy = [uint32]0
    if ([ManoSegura.Native]::GetDpiForMonitor($hm, 0, [ref]$dx, [ref]$dy) -eq 0 -and $dx -gt 0) { return [math]::Max(1.0, $dx / 96.0) }
  } catch { Write-Verbose 'dpi scale' }
  1.0
}

$script:MonCache = $null
function Get-ManoMonitor {
  if ($script:MonCache) { return $script:MonCache }
  $script:MonCache = @(foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
      $dd = New-Object ManoSegura.Native+DISPLAY_DEVICE; $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
      $ids = @(); $i = 0
      while ([ManoSegura.Native]::EnumDisplayDevices($s.DeviceName, $i, [ref]$dd, 0)) { $ids += "$($dd.DeviceID) $($dd.DeviceString)"; $i++ }
      [pscustomobject]@{ DeviceName = $s.DeviceName; Bounds = $s.Bounds; WorkingArea = $s.WorkingArea; Primary = $s.Primary; MonitorId = ($ids -join ' ; ') }
    })
  $script:MonCache
}

function Find-ManoMonitor {
  param([string]$Spec)
  $m = Select-ManoMonitor (Get-ManoMonitor) $Spec
  if (-not $m) { throw (Get-ManoError 'E_MONITOR_NOT_FOUND' @($Spec)) }
  $m
}
function Get-ManoTargetMonitor { Find-ManoMonitor "$($script:Cfg.TargetMonitor)" }

function Get-ManoRect {
  param([IntPtr]$Handle)
  $r = New-Object ManoSegura.Native+RECT
  if ([ManoSegura.Native]::DwmGetWindowAttribute($Handle, 9, [ref]$r, 16) -ne 0) { [void][ManoSegura.Native]::GetWindowRect($Handle, [ref]$r) }
  [System.Drawing.Rectangle]::FromLTRB($r.L, $r.T, $r.R, $r.B)
}
function Get-ManoTitle {
  param([IntPtr]$Handle)
  $sb = New-Object Text.StringBuilder 512; [void][ManoSegura.Native]::GetWindowText($Handle, $sb, 512); $sb.ToString()
}
function Get-ManoWindowProcess {
  param([IntPtr]$Handle)
  $p = [uint32]0; [void][ManoSegura.Native]::GetWindowThreadProcessId($Handle, [ref]$p)
  try { (Get-Process -Id ([int]$p) -ErrorAction Stop).ProcessName } catch { '' }
}

function Get-ManoWindow {
  param([switch]$AllMonitors)
  $list = New-Object Collections.ArrayList
  $cb = [ManoSegura.Native+EnumProc] { param($hw, $lp) if ([ManoSegura.Native]::IsWindowVisible($hw)) { [void]$list.Add($hw) }; $null -ne $lp }
  [void][ManoSegura.Native]::EnumWindows($cb, [IntPtr]::Zero)
  $mon = $null; if (-not $AllMonitors) { $mon = Get-ManoTargetMonitor }
  $procs = @{}; Get-Process | ForEach-Object { $procs[[uint32]$_.Id] = $_.ProcessName }
  $extra = @($script:Cfg.ExtraBlockedTitles)
  foreach ($hw in $list) {
    $t = Get-ManoTitle $hw
    if (-not $t) { continue }
    $p = [uint32]0; [void][ManoSegura.Native]::GetWindowThreadProcessId($hw, [ref]$p); $r = Get-ManoRect $hw
    $pn = $procs[$p]
    [pscustomobject]@{
      Hwnd = [int64]$hw; Proceso = $pn; Titulo = $t; Rect = (Format-ManoRect $r)
      EnMonitor = $(if ($mon) { Test-ManoRectInside $r $mon.Bounds } else { $null })
      Bloqueada = (Test-ManoBlockedTitle $t $extra); Navegador = (Test-ManoBrowser $pn $script:Cfg.ExtraBrowsers)
    }
  }
}

# Snapshot of visible browser windows (any browser, any monitor): used to detect windows that appear by surprise.
function Get-ManoBrowserWindowSet {
  if ($script:DryRun) { return @() }
  @(Get-ManoWindow -AllMonitors | Where-Object { $_.Navegador } | ForEach-Object { $_.Hwnd })
}

function Get-ManoTarget {
  if (-not (Test-Path -LiteralPath $script:TargetFile)) { throw (Get-ManoError 'E_NO_TARGET') }
  $v = 0L
  if (-not [long]::TryParse((Get-Content -LiteralPath $script:TargetFile -Raw).Trim(), [ref]$v)) { throw (Get-ManoError 'E_NO_TARGET') }
  $h = [IntPtr]$v
  if (-not [ManoSegura.Native]::IsWindow($h)) { throw (Get-ManoError 'E_TARGET_GONE') }
  $h
}
function Assert-ManoAllowed {
  param([IntPtr]$Handle)
  $t = Get-ManoTitle $Handle
  if (Test-ManoBlockedTitle $t @($script:Cfg.ExtraBlockedTitles)) { throw (Get-ManoError 'E_BLOCKED_WINDOW' @($t)) }
  $t
}
function Assert-ManoOnMonitor {
  param([IntPtr]$Handle)
  $r = Get-ManoRect $Handle; $m = Get-ManoTargetMonitor
  if (-not (Test-ManoRectInside $r $m.Bounds)) { throw (Get-ManoError 'E_OFF_MONITOR' @((Format-ManoRect $r), $m.DeviceName, (Format-ManoRect $m.Bounds))) }
  $r
}

# The panic guard runs in its own VISIBLE process (minimized console + tray icon + banner); no hidden windows, no Bypass.
function Assert-ManoGuard {
  if ($script:DryRun) { return }
  $m = $null
  if ([Threading.Mutex]::TryOpenExisting($script:MutexPanic, [ref]$m)) { $m.Dispose(); return }
  $exe = (Get-Process -Id $PID).Path
  Start-Process -FilePath $exe -WindowStyle Minimized -ArgumentList @('-NoProfile', '-STA', '-File', "`"$script:Self`"", '_guard') | Out-Null
  for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 100
    if ([Threading.Mutex]::TryOpenExisting($script:MutexPanic, [ref]$m)) { $m.Dispose(); return }
  }
  throw (Get-ManoError 'E_GUARD')
}

function Get-ManoFont {
  param([double]$Px, [switch]$Bold)
  $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
  New-Object Drawing.Font('Segoe UI', [float]$Px, $style, [Drawing.GraphicsUnit]::Pixel)
}

function New-ManoDialogControl {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory control only.')]
  param([string]$Type, [double]$Scale, [int]$X, [int]$Y, [int]$Width, [int]$Height, [double]$FontPx = 13, [switch]$Bold)
  $c = New-Object "Windows.Forms.$Type"
  $c.Location = New-Object Drawing.Point([int]($X * $Scale), [int]($Y * $Scale))
  $c.Size = New-Object Drawing.Size([int]($Width * $Scale), [int]($Height * $Scale))
  $c.Font = Get-ManoFont ($FontPx * $Scale) -Bold:$Bold
  $c
}

# ---------- confirmation dialog (on the target monitor, scaled to its DPI) ----------
function Request-ManoPermission {
  param([string]$Description, [switch]$NoTrust, [switch]$IgnoreDisabled, [switch]$Warning)
  $flat = $Description -replace "`r?`n", ' | '
  if ($script:DryRun) { $script:Notes.Add("[dry-run] pediria permiso / would ask: $flat"); return $true }
  if (-not $NoTrust -and (Test-ManoTrust)) { Write-ManoEvent 'AUTO_CONFIANZA' $flat; return $true }
  $a = Get-ManoTargetMonitor; $s = Get-ManoDpiScale $a; $timeout = [int]$script:Cfg.ConfirmTimeoutSec
  $f = New-Object Windows.Forms.Form
  $f.Text = 'ManoSegura - confirmar / confirm'; $f.TopMost = $true; $f.FormBorderStyle = 'FixedDialog'; $f.ControlBox = $false; $f.ShowInTaskbar = $true
  $f.StartPosition = 'Manual'; $f.AutoScaleMode = 'None'
  $f.ClientSize = New-Object Drawing.Size([int](580 * $s), [int](330 * $s))
  $f.BackColor = [Drawing.Color]::FromArgb(24, 28, 32); $f.ForeColor = [Drawing.Color]::White
  $f.Location = New-Object Drawing.Point([int]($a.WorkingArea.Right - $f.Width - 20 * $s), [int]($a.WorkingArea.Top + 40 * $s))
  $hdr = New-ManoDialogControl 'Label' $s 15 10 550 26 17 -Bold
  $hdr.Text = if ($Warning) { 'ATENCION / WARNING - el asistente quiere / the assistant wants to:' } else { 'El asistente quiere / The assistant wants to:' }
  $hdr.ForeColor = if ($Warning) { [Drawing.Color]::FromArgb(255, 170, 60) } else { [Drawing.Color]::FromArgb(61, 220, 151) }
  $lbl = New-ManoDialogControl 'TextBox' $s 15 42 550 150 14
  $lbl.Multiline = $true; $lbl.ReadOnly = $true; $lbl.ScrollBars = 'Vertical'; $lbl.BorderStyle = 'None'
  $lbl.BackColor = $f.BackColor; $lbl.ForeColor = [Drawing.Color]::White
  $lbl.Text = "$Description`r`n`r`n(Ctrl+Alt+P = PANICO / PANIC)"
  $chk = New-ManoDialogControl 'CheckBox' $s 15 202 300 26; $chk.Text = 'Modo confianza / trust mode (min):'
  $num = New-ManoDialogControl 'NumericUpDown' $s 320 202 70 26
  $num.Minimum = 1; $num.Maximum = [int]$script:Cfg.TrustMaxMinutes; $num.Value = [math]::Min(10, [int]$script:Cfg.TrustMaxMinutes)
  if ($NoTrust) { $chk.Enabled = $false; $num.Enabled = $false }
  $cnt = New-ManoDialogControl 'Label' $s 15 245 290 26
  $ok = New-ManoDialogControl 'Button' $s 310 280 125 36; $ok.Text = 'Permitir / Allow'
  $ok.BackColor = [Drawing.Color]::FromArgb(61, 220, 151); $ok.ForeColor = [Drawing.Color]::Black
  $no = New-ManoDialogControl 'Button' $s 443 280 125 36; $no.Text = 'Cancelar / Cancel'
  $no.ForeColor = [Drawing.Color]::Black; $no.BackColor = [Drawing.Color]::LightGray
  $script:DlgResult = $false; $script:DlgLeft = $timeout
  $ok.Add_Click({ $script:DlgResult = $true; $f.Close() }); $no.Add_Click({ $f.Close() })
  $tm = New-Object Windows.Forms.Timer; $tm.Interval = 1000
  $tm.Add_Tick({
      $script:DlgLeft--; $cnt.Text = "Se cancela sola en $($script:DlgLeft) s / auto-cancel"
      if ($script:DlgLeft -le 0 -or (-not $IgnoreDisabled -and (Test-Path -LiteralPath $script:DisabledFlag))) { $f.Close() } })
  $f.Controls.AddRange(@($hdr, $lbl, $chk, $num, $cnt, $ok, $no)); $f.CancelButton = $no
  $cnt.Text = "Se cancela sola en $timeout s / auto-cancel"; $f.Add_Shown({ $f.Activate(); [void]$no.Focus() }); $tm.Start()
  [void]$f.ShowDialog(); $tm.Stop(); $f.Dispose()
  if (-not $IgnoreDisabled -and (Test-Path -LiteralPath $script:DisabledFlag)) { $script:DlgResult = $false }
  if ($script:DlgResult -and $chk.Checked) {
    (Get-Date).AddMinutes([int]$num.Value).ToString('o') | Set-Content -LiteralPath $script:TrustFile -Encoding ASCII
    Write-ManoEvent 'CONFIANZA_CONCEDIDA' "$($num.Value) min"
  }
  Write-ManoEvent $(if ($script:DlgResult) { 'PERMITIDO' } else { 'CANCELADO' }) $flat
  $script:DlgResult
}

# ---------- focus (only when needed) ----------
function Invoke-ManoFocus {
  param([IntPtr]$Handle)
  if ([ManoSegura.Native]::GetForegroundWindow() -eq $Handle) { return $true }
  if ($script:DryRun) { return $true }
  if ([ManoSegura.Native]::IsIconic($Handle)) { [void][ManoSegura.Native]::ShowWindow($Handle, 9) }
  $fg = [ManoSegura.Native]::GetForegroundWindow(); $me = [ManoSegura.Native]::GetCurrentThreadId()
  $t1 = [ManoSegura.Native]::GetWindowThreadProcessId($fg, [IntPtr]::Zero); $t2 = [ManoSegura.Native]::GetWindowThreadProcessId($Handle, [IntPtr]::Zero)
  [void][ManoSegura.Native]::AttachThreadInput($me, $t1, $true); [void][ManoSegura.Native]::AttachThreadInput($me, $t2, $true)
  try {
    [ManoSegura.Native]::keybd_event(0x12, 0, 0, [IntPtr]::Zero); [ManoSegura.Native]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)   # ALT tap unlocks SetForegroundWindow
    [void][ManoSegura.Native]::BringWindowToTop($Handle); [void][ManoSegura.Native]::SetForegroundWindow($Handle)
  } finally { [void][ManoSegura.Native]::AttachThreadInput($me, $t1, $false); [void][ManoSegura.Native]::AttachThreadInput($me, $t2, $false) }
  for ($i = 0; $i -lt 15; $i++) { if ([ManoSegura.Native]::GetForegroundWindow() -eq $Handle) { return $true }; Start-Sleep -Milliseconds 20 }
  $false
}

function Assert-ManoForeground {
  param([IntPtr]$Handle)
  if ($script:DryRun) { return }
  Assert-ManoEnabled
  if ([ManoSegura.Native]::GetForegroundWindow() -ne $Handle) { throw (Get-ManoError 'E_FOCUS_LOST') }
}

# Checks the focused UI element: never a password field; in browsers never the address bar (only "navigate" uses it).
function Assert-ManoSafeField {
  param($Prep, [switch]$KeyOnly, [string]$Combo)
  if ($script:DryRun) { return }
  try { $fe = [Windows.Automation.AutomationElement]::FocusedElement } catch { $fe = $null }
  if (-not $fe) {
    if ($KeyOnly -and -not $Prep.IsBrowser) { return }
    throw (Get-ManoError 'E_FIELD_UNKNOWN')
  }
  $cur = $fe.Current
  $pasteKey = $Combo -in @('ctrl+v', 'shift+insert')
  if ($cur.IsPassword -and (-not $KeyOnly -or $pasteKey)) { throw (Get-ManoError 'E_PASSWORD_FIELD') }
  if ($Prep.IsBrowser -and (Test-ManoAddressBarElement $cur.Name $cur.AutomationId $cur.ClassName)) { throw (Get-ManoError 'E_ADDRESS_BAR') }
}

# Validates target, rate limit, asks permission (unless the batch was already approved), focuses.
function Invoke-ManoPrepare {
  param([string]$Description, [switch]$NoTrust, [switch]$Warning)
  Assert-ManoEnabled; Assert-ManoGuard
  $h = Get-ManoTarget; $t = Assert-ManoAllowed $h; [void](Assert-ManoOnMonitor $h)
  $proc = Get-ManoWindowProcess $h; $isB = Test-ManoBrowser $proc $script:Cfg.ExtraBrowsers
  if (-not $script:BatchApproved) {
    Register-ManoRate 1
    $kind = if ($isB) { 'navegador / browser' } else { 'app' }
    if (-not (Request-ManoPermission "$Description`r`nVentana / window: $t`r`nProceso / process: $proc ($kind)" -NoTrust:$NoTrust -Warning:$Warning)) { throw (Get-ManoError 'E_CANCELLED' @($Description)) }
  }
  Assert-ManoEnabled
  $before = Get-ManoBrowserWindowSet
  if (-not (Invoke-ManoFocus $h)) { throw (Get-ManoError 'E_FOCUS_FAILED') }
  [void](Assert-ManoAllowed $h)   # the title may have changed (e.g. navigated to a login page)
  Write-ManoActivity
  @{ H = $h; R = (Get-ManoRect $h); T = $t; Proc = $proc; IsBrowser = $isB; Before = $before }
}

# After an action: the window must still be allowed, and no surprise browser windows may have appeared.
function Assert-ManoAfterAction {
  param($Prep, [int]$DelayMs = 250)
  if ($script:DryRun) { return }
  Start-Sleep -Milliseconds $DelayMs
  if ([ManoSegura.Native]::IsWindow($Prep.H)) {
    $t = Get-ManoTitle $Prep.H
    if (Test-ManoBlockedTitle $t @($script:Cfg.ExtraBlockedTitles)) {
      Revoke-ManoTrust 'pagina prohibida tras la accion'
      Write-ManoEvent 'BLOQUEO_TRAS_ACCION' $t
      throw (Get-ManoError 'E_NOW_BLOCKED' @($t))
    }
  }
  if (-not $script:Cfg.AllowNewTabs) {
    $known = @($Prep.Before)
    $new = @(Get-ManoWindow -AllMonitors | Where-Object { $_.Navegador -and $known -notcontains $_.Hwnd })
    if ($new.Count) {
      $desc = ($new | ForEach-Object { "$($_.Proceso) '$($_.Titulo)' (hwnd $($_.Hwnd))" }) -join '; '
      Revoke-ManoTrust 'ventana de navegador nueva'
      Write-ManoEvent 'VENTANA_NUEVA' $desc
      throw (Get-ManoError 'E_NEW_WINDOW' @($desc))
    }
  }
}

# ---------- screenshots ----------
function Save-ManoBitmap {
  param($Bitmap, [string]$Path)
  if (-not $Path) { $Path = Join-Path $script:ShotsDir ("shot_{0:yyyyMMdd_HHmmss_fff}.png" -f (Get-Date)) }
  $Bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $Bitmap.Dispose()
  Copy-Item -LiteralPath $Path -Destination (Join-Path $script:ShotsDir 'latest.png') -Force -ErrorAction SilentlyContinue
  Write-ManoLog "Captura $Path"; $Path
}
function Save-ManoScreenRect {
  param($Rect, [string]$Path)
  if ($Path -and $Path -notmatch '(?i)\.png$') { throw (Get-ManoError 'E_SHOT_PATH' @($Path)) }
  if ($script:DryRun) { return "[dry-run] $(Format-ManoRect $Rect)" }
  $bmp = New-Object Drawing.Bitmap($Rect.Width, $Rect.Height)
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($Rect.Location, [Drawing.Point]::Empty, $Rect.Size); $g.Dispose()
  Save-ManoBitmap $bmp $Path
}

# ---------- clipboard paste (restores the previous text) ----------
function Invoke-ManoPasteText {
  param([string]$Text)
  $old = $null
  try { if ([Windows.Forms.Clipboard]::ContainsText()) { $old = [Windows.Forms.Clipboard]::GetText() } } catch { $old = $null }
  [Windows.Forms.Clipboard]::SetText($Text); [Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 120
  try { if ($null -ne $old) { [Windows.Forms.Clipboard]::SetText($old) } else { [Windows.Forms.Clipboard]::Clear() } } catch { Write-Verbose 'clipboard restore' }
}

# =====================================================================================================
# 5. Acciones (CLI y batch) / actions (shared by CLI and batch)
# =====================================================================================================
function Invoke-ManoFocusCommand {
  param([string[]]$Arguments)
  Assert-ManoEnabled; Assert-ManoGuard
  $q = (@($Arguments) -join ' ').Trim()
  if (-not $q) { throw (Get-ManoError 'E_USAGE' @('focus <hwnd|titulo>')) }
  $all = @(Get-ManoWindow)
  $w = @($all | Where-Object { "$($_.Hwnd)" -eq $q })
  if (-not $w.Count) { $w = @($all | Where-Object { $_.Titulo.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
  if ($w.Count -ne 1) { throw (Get-ManoError 'E_AMBIGUOUS' @($w.Count, $q)) }
  $h = [IntPtr]$w[0].Hwnd; [void](Assert-ManoAllowed $h); [void](Assert-ManoOnMonitor $h)
  if (-not $script:BatchApproved) {
    Register-ManoRate 1
    $d = "Elegir como ventana objetivo y traerla al frente / select as target and bring to front:`r`n$($w[0].Titulo)`r`nProceso / process: $($w[0].Proceso)"
    if (-not (Request-ManoPermission $d)) { throw (Get-ManoError 'E_CANCELLED' @('focus')) }
  }
  if (-not $script:DryRun) { "$($w[0].Hwnd)" | Set-Content -LiteralPath $script:TargetFile -Encoding ASCII }
  [void](Invoke-ManoFocus $h); Write-ManoActivity
  Write-ManoEvent 'HECHO' "focus $($w[0].Hwnd) $($w[0].Titulo)"
  Get-ManoResult 'focus' "Objetivo: $($w[0].Hwnd) $($w[0].Titulo) $($w[0].Rect)" @{ hwnd = $w[0].Hwnd; title = $w[0].Titulo; process = $w[0].Proceso; rect = $w[0].Rect; browser = $w[0].Navegador }
}

function Invoke-ManoScreenshotCommand {
  param([string[]]$Arguments)
  # screenshot [path] | screenshot window [path] | screenshot monitor [name] [path] | screenshot hwnd <hwnd> [path]
  Assert-ManoEnabled
  $a = @($Arguments)
  $mode = if ($a.Count -and $a[0] -in 'window', 'monitor', 'hwnd') { $a[0] } else { 'window' }
  $rest = if ($a.Count -and $a[0] -in 'window', 'monitor', 'hwnd') { @($a | Select-Object -Skip 1) } else { $a }
  switch ($mode) {
    'monitor' {
      $spec = if ($rest.Count -and $rest[0] -notmatch '(?i)\.png$') { $rest[0] } else { "$($script:Cfg.TargetMonitor)" }
      $p = @($rest | Where-Object { $_ -match '(?i)\.png$' }) | Select-Object -First 1
      $m = Find-ManoMonitor $spec; $path = Save-ManoScreenRect $m.Bounds $p
      return (Get-ManoResult 'screenshot' "Captura monitor $($m.DeviceName): $path" @{ path = $path; rect = (Format-ManoRect $m.Bounds); monitor = $m.DeviceName })
    }
    'hwnd' {
      if (-not $rest.Count) { throw (Get-ManoError 'E_USAGE' @('screenshot hwnd <hwnd> [ruta.png]')) }
      $v = 0L; if (-not [long]::TryParse($rest[0], [ref]$v)) { throw (Get-ManoError 'E_BAD_NUMBER' @($rest[0])) }
      $h = [IntPtr]$v; if (-not [ManoSegura.Native]::IsWindow($h)) { throw (Get-ManoError 'E_HWND_GONE' @($rest[0])) }
      [void](Assert-ManoAllowed $h); $r = Assert-ManoOnMonitor $h
      $path = Save-ManoScreenRect $r ($rest | Select-Object -Skip 1 -First 1)
      return (Get-ManoResult 'screenshot' "Captura ventana: $path" @{ path = $path; rect = (Format-ManoRect $r) })
    }
    default {
      $h = Get-ManoTarget; [void](Assert-ManoAllowed $h); $r = Assert-ManoOnMonitor $h
      $path = Save-ManoScreenRect $r ($rest | Select-Object -First 1)
      return (Get-ManoResult 'screenshot' "Captura: $path  (ventana $($r.Width)x$($r.Height) en $($r.X),$($r.Y))" @{ path = $path; rect = (Format-ManoRect $r) })
    }
  }
}

function Invoke-ManoClickCommand {
  param([string[]]$Arguments)
  $a = @($Arguments)
  if ($a.Count -lt 2) { throw (Get-ManoError 'E_USAGE' @('click x y [left|right|double]')) }
  $x = Get-ManoInt $a[0]; $y = Get-ManoInt $a[1]; $btn = if ($a.Count -gt 2) { $a[2].ToLowerInvariant() } else { 'left' }
  if ($btn -notin 'left', 'right', 'double') { throw (Get-ManoError 'E_BAD_BUTTON' @($btn)) }
  Assert-ManoEnabled
  $r = Assert-ManoOnMonitor (Get-ManoTarget)
  if ($x -lt 0 -or $y -lt 0 -or $x -ge $r.Width -or $y -ge $r.Height) { throw (Get-ManoError 'E_OUT_OF_WINDOW' @($x, $y, $r.Width, $r.Height)) }
  $p = Invoke-ManoPrepare "Clic $btn en ($x,$y) de la ventana / $btn click at ($x,$y)"
  $sx = $p.R.X + $x; $sy = $p.R.Y + $y   # screen coords; negative on a monitor left of / above the primary one
  if (-not (Test-ManoPointInside $sx $sy (Get-ManoTargetMonitor).Bounds)) { throw (Get-ManoError 'E_POINT_OFF_MONITOR' @($sx, $sy)) }
  if ($script:DryRun) { return (Get-ManoResult 'click' "[dry-run] clic $btn en pantalla ($sx,$sy)" @{ x = $x; y = $y; screenX = $sx; screenY = $sy; dryRun = $true }) }
  Assert-ManoForeground $p.H
  [void][ManoSegura.Native]::SetCursorPos($sx, $sy); Start-Sleep -Milliseconds 30
  if ($btn -eq 'right') { [ManoSegura.Native]::mouse_event(0x8, 0, 0, 0, [IntPtr]::Zero); [ManoSegura.Native]::mouse_event(0x10, 0, 0, 0, [IntPtr]::Zero) }
  else {
    [ManoSegura.Native]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); [ManoSegura.Native]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero)
    if ($btn -eq 'double') { Start-Sleep -Milliseconds 40; [ManoSegura.Native]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); [ManoSegura.Native]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero) }
  }
  Write-ManoEvent 'HECHO' "clic $btn ($x,$y) -> ($sx,$sy)"
  Assert-ManoAfterAction $p
  Get-ManoResult 'click' "OK clic $btn en ($x,$y)" @{ x = $x; y = $y; screenX = $sx; screenY = $sy }
}

function Invoke-ManoTextCommand {
  param([string]$Mode, [string[]]$Arguments)
  $text = (@($Arguments) -join ' ')
  if (-not $text) { throw (Get-ManoError 'E_USAGE' @("$Mode `"texto`"")) }
  $verb = if ($Mode -eq 'paste') { 'Pegar el texto (portapapeles + Ctrl+V) / paste' } else { 'Escribir el texto / type' }
  $p = Invoke-ManoPrepare "$($verb):`r`n`"$(Get-ManoClipped $text)`""
  Assert-ManoSafeField $p
  if ($script:DryRun) { return (Get-ManoResult $Mode "[dry-run] $(if ($Mode -eq 'paste') { 'pegaria' } else { 'escribiria' }) $($text.Length) caracteres" @{ chars = $text.Length; dryRun = $true }) }
  if ($Mode -eq 'paste') {
    Assert-ManoForeground $p.H
    Invoke-ManoPasteText $text
  } else {
    # Typed in small chunks: between chunks the panic flag and the foreground window are re-checked.
    for ($i = 0; $i -lt $text.Length; $i += 24) {
      Assert-ManoForeground $p.H
      [Windows.Forms.SendKeys]::SendWait((ConvertTo-ManoSendKeyText $text.Substring($i, [math]::Min(24, $text.Length - $i))))
    }
  }
  Write-ManoEvent 'HECHO' "$Mode $($text.Length) caracteres"
  Assert-ManoAfterAction $p
  Get-ManoResult $Mode "OK $(if ($Mode -eq 'paste') { 'pegado' } else { 'escrito' }) ($($text.Length) caracteres)" @{ chars = $text.Length }
}

function Invoke-ManoKeyCommand {
  param([string[]]$Arguments)
  $combo = (@($Arguments) -join ''); $parts = ConvertTo-ManoCombo $combo
  Assert-ManoEnabled
  $h = Get-ManoTarget; $isB = Test-ManoBrowser (Get-ManoWindowProcess $h) $script:Cfg.ExtraBrowsers
  $blk = Get-ManoComboBlock $parts $isB ([bool]$script:Cfg.AllowNewTabs)
  if ($blk) { throw (Get-ManoError $blk.Id @($blk.Arg)) }
  $p = Invoke-ManoPrepare "Pulsar teclas / press keys: $($parts.Normalized)"
  Assert-ManoSafeField $p -KeyOnly -Combo $parts.Normalized
  if ($script:DryRun) { return (Get-ManoResult 'key' "[dry-run] teclas $($parts.Normalized)" @{ keys = $parts.Normalized; dryRun = $true }) }
  Assert-ManoForeground $p.H
  [Windows.Forms.SendKeys]::SendWait((ConvertTo-ManoSendKey $parts))
  Write-ManoEvent 'HECHO' "tecla $($parts.Normalized)"
  Assert-ManoAfterAction $p
  Get-ManoResult 'key' "OK tecla $($parts.Normalized)" @{ keys = $parts.Normalized }
}

function Invoke-ManoScrollCommand {
  param([string[]]$Arguments)
  $a = @($Arguments)
  $amt = if ($a.Count -ge 1) { Get-ManoInt $a[0] } else { -3 }
  $amt = [math]::Max(-50, [math]::Min(50, $amt))
  Assert-ManoEnabled
  $r = Assert-ManoOnMonitor (Get-ManoTarget)
  $x = if ($a.Count -ge 3) { Get-ManoInt $a[1] } else { [int]($r.Width / 2) }
  $y = if ($a.Count -ge 3) { Get-ManoInt $a[2] } else { [int]($r.Height / 2) }
  if ($x -lt 0 -or $y -lt 0 -or $x -ge $r.Width -or $y -ge $r.Height) { throw (Get-ManoError 'E_OUT_OF_WINDOW' @($x, $y, $r.Width, $r.Height)) }
  $dir = if ($amt -lt 0) { 'abajo / down' } else { 'arriba / up' }
  $p = Invoke-ManoPrepare "Desplazar / scroll $([math]::Abs($amt)) pasos $dir en ($x,$y)"
  if ($script:DryRun) { return (Get-ManoResult 'scroll' "[dry-run] scroll $amt" @{ amount = $amt; dryRun = $true }) }
  Assert-ManoForeground $p.H
  [void][ManoSegura.Native]::SetCursorPos($p.R.X + $x, $p.R.Y + $y); [ManoSegura.Native]::mouse_event(0x800, 0, 0, 120 * $amt, [IntPtr]::Zero)
  Write-ManoEvent 'HECHO' "scroll $amt"
  Assert-ManoAfterAction $p
  Get-ManoResult 'scroll' "OK scroll $amt" @{ amount = $amt }
}

function Invoke-ManoWaitCommand {
  param([string[]]$Arguments)
  $a = @($Arguments)
  $ms = if ($a.Count) { Get-ManoInt $a[0] } else { 300 }
  $ms = [math]::Max(0, [math]::Min(10000, $ms))
  if (-not $script:DryRun) { for ($left = $ms; $left -gt 0; $left -= 100) { Assert-ManoEnabled; Start-Sleep -Milliseconds ([math]::Min(100, $left)) } }
  Get-ManoResult 'wait' "OK espera $ms ms" @{ ms = $ms }
}

function Invoke-ManoNavigateCommand {
  param([string[]]$Arguments)
  $url = (@($Arguments) -join ' ').Trim()
  if (-not $url) { throw (Get-ManoError 'E_USAGE' @('navigate <url>')) }
  $u = Test-ManoUrl -Url $url -Mode $script:Cfg.Navigation -Allowlist $script:Cfg.UrlAllowlist -ExtraBlocked $script:Cfg.ExtraBlockedUrls
  if (-not $u.Ok) { throw (Get-ManoError $u.Id @($url)) }
  Assert-ManoEnabled
  $h = Get-ManoTarget
  if (-not (Test-ManoBrowser (Get-ManoWindowProcess $h) $script:Cfg.ExtraBrowsers)) { throw (Get-ManoError 'E_NAV_NOT_BROWSER') }
  # Outside the allowlist, navigation always asks, even in trust mode.
  $p = Invoke-ManoPrepare "NAVEGAR a / NAVIGATE to:`r`n$($u.Normalized)" -NoTrust:($u.NeedsExplicitConfirm) -Warning
  if ($script:DryRun) { return (Get-ManoResult 'navigate' "[dry-run] navegaria a $($u.Normalized)" @{ url = $u.Normalized; dryRun = $true }) }
  Assert-ManoForeground $p.H
  [Windows.Forms.SendKeys]::SendWait('^l'); Start-Sleep -Milliseconds 150
  $fe = $null; try { $fe = [Windows.Automation.AutomationElement]::FocusedElement } catch { $fe = $null }
  if (-not $fe -or $fe.Current.IsPassword -or -not (Test-ManoAddressBarElement $fe.Current.Name $fe.Current.AutomationId $fe.Current.ClassName)) {
    [Windows.Forms.SendKeys]::SendWait('{ESC}')
    throw (Get-ManoError 'E_NAV_NO_ADDRESSBAR')
  }
  Assert-ManoForeground $p.H
  Invoke-ManoPasteText $u.Normalized; [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Write-ManoEvent 'HECHO' "navegar $($u.Normalized)"
  Assert-ManoAfterAction $p -DelayMs 800
  Get-ManoResult 'navigate' "OK navegando a $($u.Normalized)" @{ url = $u.Normalized }
}

function Invoke-ManoAction {
  param([string]$Command, [string[]]$Arguments)
  switch ($Command) {
    'focus'      { return (Invoke-ManoFocusCommand $Arguments) }
    'screenshot' { return (Invoke-ManoScreenshotCommand $Arguments) }
    'click'      { return (Invoke-ManoClickCommand $Arguments) }
    'type'       { return (Invoke-ManoTextCommand 'type' $Arguments) }
    'paste'      { return (Invoke-ManoTextCommand 'paste' $Arguments) }
    'key'        { return (Invoke-ManoKeyCommand $Arguments) }
    'scroll'     { return (Invoke-ManoScrollCommand $Arguments) }
    'wait'       { return (Invoke-ManoWaitCommand $Arguments) }
    'navigate'   { return (Invoke-ManoNavigateCommand $Arguments) }
    default      { throw (Get-ManoError 'E_UNKNOWN_CMD' @($Command)) }
  }
}

# =====================================================================================================
# 6. Vigilante de panico (proceso visible) / panic guard (visible process)
#    Tray icon + banner at the bottom of the target monitor + coloured border around the controlled window.
# =====================================================================================================
$script:HotKeyCode = @'
public class MsHot3 : System.Windows.Forms.NativeWindow {
  public event System.EventHandler Hot;
  public MsHot3(System.IntPtr h) { AssignHandle(h); }
  protected override void WndProc(ref System.Windows.Forms.Message m) { if (m.Msg == 0x0312 && Hot != null) Hot(this, System.EventArgs.Empty); base.WndProc(ref m); }
}
'@

function Get-ManoFormsReference {
  if ($PSVersionTable.PSEdition -eq 'Desktop') { return @('System.Windows.Forms') }
  $rx = '^(System\.Windows\.Forms(\.Primitives)?|System\.ComponentModel\.Primitives|System\.Runtime|System\.Private\.CoreLib|Microsoft\.Win32\.Primitives)$'
  @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic -and $_.Location -and $_.GetName().Name -match $rx } | ForEach-Object { $_.Location })
}

function Invoke-ManoPanic {
  Set-Content -LiteralPath $script:DisabledFlag -Value (Get-Date).ToString('o') -Encoding ASCII
  Remove-Item -LiteralPath $script:TrustFile -Force -ErrorAction SilentlyContinue
  # Stops ONLY other running ManoSegura commands (never the guard itself, never other programs).
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ManoSegura\.ps1' -and $_.CommandLine -notmatch '\b_(guard|panic)\b' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Write-ManoEvent 'PANICO' 'acciones detenidas, ManoSegura desactivada / actions stopped, ManoSegura disabled'
}

function Show-ManoTopmostNoActivate {
  param($Form, [int]$X, [int]$Y, [int]$Width, [int]$Height)
  $hw = $Form.Handle
  # WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT: never steals focus, clicks pass through.
  $ex = [ManoSegura.Native]::GetWindowLong($hw, -20) -bor 0x080800A0
  [void][ManoSegura.Native]::SetWindowLong($hw, -20, $ex)
  [void][ManoSegura.Native]::SetWindowPos($hw, [IntPtr](-1), $X, $Y, $Width, $Height, 0x0050)   # HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW
}

function New-ManoPlainForm {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory form only.')]
  param([Drawing.Color]$Color, [double]$Opacity = 0.9)
  $f = New-Object Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true; $f.StartPosition = 'Manual'; $f.AutoScaleMode = 'None'
  $f.BackColor = $Color; $f.Opacity = $Opacity; $f.Text = ''; $f.MinimumSize = New-Object Drawing.Size(1, 1)
  [void]$f.Handle
  $f
}

function Update-ManoGuardView {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only repaints the guard''s own banner and border.')]
  param()
  $g = $script:Guard
  $disabled = Test-Path -LiteralPath $script:DisabledFlag
  $trust = (-not $disabled) -and (Test-ManoTrust)
  if ($disabled) { $g.Label.Text = 'ManoSegura DESACTIVADA - "enable" para reactivar / DISABLED'; $g.Label.ForeColor = $g.Grey }
  elseif ($trust) {
    $until = Get-ManoTrustExpiry (Get-Content -LiteralPath $script:TrustFile -Raw)
    $hhmm = if ($until) { $until.ToString('HH:mm') } else { '?' }
    $g.Label.Text = "ManoSegura - MODO CONFIANZA hasta $hhmm - Ctrl+Alt+P = PANICO"; $g.Label.ForeColor = $g.Red
  } else { $g.Label.Text = 'ManoSegura activa - pide permiso - Ctrl+Alt+P = PANICO'; $g.Label.ForeColor = $g.Orange }
  $show = $false
  if (-not $disabled -and $script:Cfg.Overlay -and (Test-Path -LiteralPath $script:TargetFile)) {
    $v = 0L
    if ([long]::TryParse((Get-Content -LiteralPath $script:TargetFile -Raw).Trim(), [ref]$v)) {
      $h = [IntPtr]$v
      if ([ManoSegura.Native]::IsWindow($h) -and [ManoSegura.Native]::IsWindowVisible($h) -and -not [ManoSegura.Native]::IsIconic($h)) {
        $edges = Get-ManoOverlayEdge (Get-ManoRect $h) $g.Monitor.Bounds $g.Thickness
        $key = (($edges | ForEach-Object { "$($_.X),$($_.Y),$($_.Width),$($_.Height)" }) -join ';') + "|$trust"
        $g.Tick++
        if ($key -ne $g.EdgeKey -or ($g.Tick % 10 -eq 0)) {   # re-assert topmost every ~3 s
          $col = if ($trust) { $g.Red } else { $g.Orange }
          for ($i = 0; $i -lt 4; $i++) { $g.Edges[$i].BackColor = $col; Show-ManoTopmostNoActivate $g.Edges[$i] $edges[$i].X $edges[$i].Y $edges[$i].Width $edges[$i].Height }
          $g.EdgeKey = $key
        }
        $show = $true
      }
    }
  }
  if (-not $show -and $g.EdgeKey) { foreach ($e in $g.Edges) { [void][ManoSegura.Native]::ShowWindow($e.Handle, 0) }; $g.EdgeKey = '' }
  # Close quietly after a while without actions (the next action starts the guard again).
  $last = $g.Started
  if (Test-Path -LiteralPath $script:ActivityFile) { $t = Get-ManoTrustExpiry (Get-Content -LiteralPath $script:ActivityFile -Raw); if ($t -and $t -gt $last) { $last = $t } }
  if (-not $trust -and ((Get-Date) - $last).TotalMinutes -gt [int]$script:Cfg.GuardIdleMinutes) {
    Write-ManoEvent 'VIGILANTE' 'cerrado por inactividad / closed after inactivity'
    [Windows.Forms.Application]::ExitThread()
  }
}

function Invoke-ManoGuardLoop {
  $created = $false
  $mtx = New-Object Threading.Mutex($true, $script:MutexPanic, [ref]$created)
  if (-not $created) { $mtx.Dispose(); return 'Vigilante ya activo / guard already running.' }
  $g = @{ Edges = @(); EdgeKey = ''; Tick = 0; Started = (Get-Date) }
  $script:Guard = $g
  try {
    if (-not ('MsHot3' -as [type])) { Add-Type -ReferencedAssemblies (Get-ManoFormsReference) -TypeDefinition $script:HotKeyCode }
    $g.Monitor = Get-ManoTargetMonitor; $s = Get-ManoDpiScale $g.Monitor; $g.Thickness = [int][math]::Max(2, 3 * $s)
    $g.Orange = [Drawing.Color]::FromArgb(255, 140, 0); $g.Red = [Drawing.Color]::FromArgb(230, 40, 40); $g.Grey = [Drawing.Color]::FromArgb(150, 150, 150)
    # Banner at the bottom-centre of the target monitor (over the taskbar, so it never covers the app's content).
    $g.Banner = New-ManoPlainForm ([Drawing.Color]::FromArgb(20, 20, 20)) 0.88
    $g.Banner.Text = 'ManoSegura'
    $g.Label = New-Object Windows.Forms.Label
    $g.Label.Dock = 'Fill'; $g.Label.TextAlign = 'MiddleCenter'; $g.Label.Font = Get-ManoFont (14 * $s) -Bold; $g.Label.ForeColor = $g.Orange
    $g.Banner.Controls.Add($g.Label)
    $bw = [int](600 * $s); $bh = [int](28 * $s)
    $bx = [int]($g.Monitor.Bounds.X + ($g.Monitor.Bounds.Width - $bw) / 2); $by = [int]($g.Monitor.Bounds.Y + $g.Monitor.Bounds.Height - $bh - 2)
    Show-ManoTopmostNoActivate $g.Banner $bx $by $bw $bh
    $g.Edges = @(1..4 | ForEach-Object { New-ManoPlainForm $g.Orange 0.85 })
    # Tray icon with a menu: the visible way to stop everything.
    $g.Tray = New-Object Windows.Forms.NotifyIcon
    $g.Tray.Icon = [Drawing.SystemIcons]::Shield; $g.Tray.Text = 'ManoSegura activa - Ctrl+Alt+P = PANICO'; $g.Tray.Visible = $true
    $menu = New-Object Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('PANICO: desactivar ya / PANIC (Ctrl+Alt+P)', $null, { Invoke-ManoPanic })
    [void]$menu.Items.Add('Quitar modo confianza / end trust mode', $null, { Revoke-ManoTrust 'menu de la bandeja' })
    [void]$menu.Items.Add('Abrir registros / open logs', $null, { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:LogsDir`"" })
    [void]$menu.Items.Add('Cerrar vigilante / close guard', $null, { [Windows.Forms.Application]::ExitThread() })
    $g.Tray.ContextMenuStrip = $menu
    $g.Tray.ShowBalloonTip(4000, 'ManoSegura', 'Activa: pide permiso para cada accion. Ctrl+Alt+P = PANICO.', 'Info')
    # Panic hotkey Ctrl+Alt+P (MOD_CONTROL | MOD_ALT | MOD_NOREPEAT).
    $g.Hot = New-Object MsHot3($g.Banner.Handle)
    $g.Hot.add_Hot({
        Invoke-ManoPanic
        [void][Windows.Forms.MessageBox]::Show('ManoSegura DESACTIVADA. Acciones pendientes canceladas. / DISABLED, pending actions cancelled.', 'ManoSegura - PANICO', 'OK', 'Warning') })
    if ([ManoSegura.Native]::RegisterHotKey($g.Banner.Handle, 1, 0x4003, 0x50)) { Write-ManoEvent 'VIGILANTE' 'escuchando Ctrl+Alt+P' }
    else {
      Write-ManoEvent 'VIGILANTE' 'no pude registrar Ctrl+Alt+P (lo usa otro programa); usa el icono de la bandeja'
      $g.Tray.ShowBalloonTip(6000, 'ManoSegura', 'Ctrl+Alt+P no disponible: usa el menu del icono de la bandeja para el PANICO.', 'Warning')
    }
    $tm = New-Object Windows.Forms.Timer; $tm.Interval = 300
    $tm.Add_Tick({ try { Update-ManoGuardView } catch { Write-ManoLog "VIGILANTE error: $($_.Exception.Message)" } })
    $tm.Start()
    [Windows.Forms.Application]::Run()
    $tm.Stop()
  } finally {
    if ($g.Banner) { try { [void][ManoSegura.Native]::UnregisterHotKey($g.Banner.Handle, 1) } catch { Write-Verbose 'unregister' } }
    if ($g.Tray) { $g.Tray.Visible = $false; $g.Tray.Dispose() }
    foreach ($e in @($g.Edges)) { if ($e) { $e.Dispose() } }
    if ($g.Banner) { $g.Banner.Dispose() }
    $mtx.ReleaseMutex(); $mtx.Dispose()
  }
  'Vigilante cerrado / guard closed.'
}

# =====================================================================================================
# 7. Comandos / commands
# =====================================================================================================
$script:HelpText = @'
ManoSegura {0} - uso / usage:
  powershell -NoProfile -File .\ManoSegura.ps1 <comando> [args] [--dry-run] [--json] [--en|--es]
  (sin -ExecutionPolicy Bypass: ver README / no Bypass needed, see README)

  version | monitors | list-windows | status | config | start-panic
  focus <hwnd|titulo>                        elegir ventana objetivo (pide permiso)
  screenshot [ruta.png]                      captura la ventana objetivo
  screenshot monitor [nombre|n] [ruta.png]   captura un monitor (por defecto el objetivo)
  screenshot hwnd <hwnd> [ruta.png]          captura otra ventana
  click x y [left|right|double]              coords relativas a la ventana
  type "texto"  |  paste "texto"             (rechaza campos de contrasena y la barra de direcciones)
  key ctrl+a | enter | tab ...               (bloquea Win, Alt+F4, Alt+Tab; en navegadores Ctrl+L, Ctrl+T, Ctrl+N...)
  scroll [pasos(-abajo/+arriba)] [x y]
  wait [ms]
  navigate <url>                             navegar en el navegador objetivo (segun Navigation / UrlAllowlist)
  batch <steps.json|->                       un permiso para toda la lista (max. 50 pasos)
  check-title "titulo" | check-url <url> | check-key <combo> [browser]     prueba las reglas
  verify-log                                 comprueba la cadena de hashes del registro de auditoria
  disable | enable | trust-off               Panico: Ctrl+Alt+P
Codigos de salida / exit codes: 0 OK, 2 rechazado/error, 3 cancelado por el usuario, 4 limite de velocidad
Config: config.json (ver config.example.json y README)
'@

# Commands that never touch the screen (they also work off Windows, e.g. in CI).
$script:NativeFree = @('version', 'help', '--help', '-h', '/?', 'config', 'check-title', 'check-url', 'check-key', 'verify-log', 'disable', 'trust-off')

function Invoke-ManoBatchCommand {
  param([string[]]$Arguments)
  $a = @($Arguments)
  if (-not $a.Count) { throw (Get-ManoError 'E_USAGE' @('batch <steps.json|->')) }
  $steps = @(ConvertFrom-ManoBatch (Read-ManoBatchSource ($a -join ' ')) $script:MaxBatchSteps)
  Assert-ManoEnabled; Assert-ManoGuard
  $summary = ($steps | ForEach-Object { "$($_.Index). $($_.Cmd) $(Get-ManoClipped ($_.Args -join ' ') 120)" }) -join "`r`n"
  $needsTarget = @($steps | Where-Object { $_.Cmd -in 'click', 'type', 'paste', 'key', 'scroll', 'navigate' -or ($_.Cmd -eq 'screenshot' -and -not ($_.Args.Count -and $_.Args[0] -in 'monitor', 'hwnd')) }).Count -gt 0
  if ($needsTarget -and $steps[0].Cmd -ne 'focus') { $h = Get-ManoTarget; $t = Assert-ManoAllowed $h; $summary += "`r`nVentana / window: $t" }
  # Every step is validated before asking: bad keys and forbidden URLs fail now, not half-way through.
  $explicit = $false
  foreach ($st in $steps) {
    if ($st.Cmd -eq 'key') { [void](ConvertTo-ManoCombo ($st.Args -join '')) }
    if ($st.Cmd -eq 'navigate') {
      $u = Test-ManoUrl -Url ($st.Args -join ' ') -Mode $script:Cfg.Navigation -Allowlist $script:Cfg.UrlAllowlist -ExtraBlocked $script:Cfg.ExtraBlockedUrls
      if (-not $u.Ok) { throw (Get-ManoError $u.Id @($st.Args -join ' ')) }
      if ($u.NeedsExplicitConfirm) { $explicit = $true }
    }
  }
  Register-ManoRate (Get-ManoActionCount $steps)
  if (-not (Request-ManoPermission "Ejecutar / run $($steps.Count) pasos:`r`n$summary" -NoTrust:$explicit -Warning:$explicit)) { throw (Get-ManoError 'E_CANCELLED' @('batch')) }
  $script:BatchApproved = $true
  try {
    foreach ($st in $steps) {
      Assert-ManoEnabled
      $r = Invoke-ManoAction $st.Cmd $st.Args
      $r.message = "[$($st.Index)/$($steps.Count)] $($r.message)"
      $script:Partial.Add($r)
    }
  } finally { $script:BatchApproved = $false }
  Write-ManoEvent 'HECHO' "batch $($steps.Count) pasos"
  Get-ManoResult 'batch' "OK batch ($($steps.Count) pasos)" @{ steps = $steps.Count }
}

function Invoke-ManoCommand {
  param([string]$Command, [string[]]$Arguments)
  $a = @($Arguments)
  switch ($Command) {
    { $_ -in '_guard', '_panic' } { return (Invoke-ManoGuardLoop) }
    'version' { return (Get-ManoResult 'version' "ManoSegura $script:Version" @{ version = $script:Version }) }
    'config' { return [pscustomobject]$script:Cfg }
    'monitors' {
      $tm = Get-ManoTargetMonitor; $i = 0
      return @(foreach ($mo in Get-ManoMonitor) {
          [pscustomobject][ordered]@{ Indice = $i; Nombre = $mo.DeviceName; Rect = (Format-ManoRect $mo.Bounds); Escala = [math]::Round((Get-ManoDpiScale $mo), 2)
            Primario = $mo.Primary; Objetivo = ($mo.DeviceName -eq $tm.DeviceName); Id = $mo.MonitorId }
          $i++
        })
    }
    'list-windows' { return @(Get-ManoWindow) }
    'status' {
      $tm = Get-ManoTargetMonitor; $m = $null
      $tgt = '(ninguno)'
      if (Test-Path -LiteralPath $script:TargetFile) { $v = 0L; if ([long]::TryParse((Get-Content -LiteralPath $script:TargetFile -Raw).Trim(), [ref]$v)) { $tgt = "$v  $(Get-ManoTitle ([IntPtr]$v))" } }
      return [pscustomobject][ordered]@{
        Version = $script:Version; Desactivada = (Test-Path -LiteralPath $script:DisabledFlag); ModoConfianza = (Test-ManoTrust)
        MonitorObjetivo = "$($tm.DeviceName) $(Format-ManoRect $tm.Bounds)"; Objetivo = $tgt; Navegacion = $script:Cfg.Navigation
        PestanasNuevas = $script:Cfg.AllowNewTabs; LimitePorMinuto = $script:Cfg.MaxActionsPerMinute; Capturas = $script:ShotsDir
        PanicoEscuchando = [Threading.Mutex]::TryOpenExisting($script:MutexPanic, [ref]$m)
      }
    }
    'start-panic' { Assert-ManoGuard; return (Get-ManoResult 'start-panic' 'Vigilante de panico (Ctrl+Alt+P) activo: icono en la bandeja y cartel en el monitor.') }
    'batch' { return (Invoke-ManoBatchCommand $a) }
    'enable' {
      if (-not (Test-Path -LiteralPath $script:DisabledFlag)) { return (Get-ManoResult 'enable' 'Ya estaba activada. / Already enabled.') }
      # The flag stays in place until the user confirms; trust mode never applies here.
      if (Request-ManoPermission 'REACTIVAR ManoSegura despues del boton de panico / RE-ENABLE after panic' -NoTrust -IgnoreDisabled -Warning) {
        if (-not $script:DryRun) { Remove-Item -LiteralPath $script:DisabledFlag -Force }
        Write-ManoEvent 'REACTIVADA' 'por el usuario'
        return (Get-ManoResult 'enable' 'Reactivada. / Re-enabled.')
      }
      return (Get-ManoResult 'enable' 'Sigue desactivada. / Still disabled.')
    }
    'disable' {
      Set-Content -LiteralPath $script:DisabledFlag -Value (Get-Date).ToString('o') -Encoding ASCII
      Remove-Item -LiteralPath $script:TrustFile -Force -ErrorAction SilentlyContinue
      Write-ManoEvent 'DESACTIVADA' 'por comando'
      return (Get-ManoResult 'disable' 'Desactivada. / Disabled.')
    }
    'trust-off' { Revoke-ManoTrust 'trust-off'; return (Get-ManoResult 'trust-off' 'Modo confianza desactivado. / Trust mode off.') }
    'check-title' {
      $t = $a -join ' '; $b = Test-ManoBlockedTitle $t @($script:Cfg.ExtraBlockedTitles)
      return (Get-ManoResult 'check-title' $(if ($b) { "BLOQUEADA: $t" } else { "permitida: $t" }) @{ title = $t; blocked = $b })
    }
    'check-url' {
      $raw = $a -join ' '
      # With Navigation = off every URL is refused; still show what the hard rules would say.
      $mode = if ($script:Cfg.Navigation -eq 'off') { $script:Notes.Add('Navigation = off: navigate esta desactivado / navigate is disabled'); 'ask' } else { $script:Cfg.Navigation }
      $u = Test-ManoUrl -Url $raw -Mode $mode -Allowlist $script:Cfg.UrlAllowlist -ExtraBlocked $script:Cfg.ExtraBlockedUrls
      $msg = if ($u.Ok) { "permitida: $($u.Normalized)$(if ($u.NeedsExplicitConfirm) { ' (siempre pedira permiso / always asks)' })" }
             else { "BLOQUEADA [$($u.Id)]: $(Select-ManoLanguage (Get-ManoText $u.Id @($raw)))" }
      return (Get-ManoResult 'check-url' $msg @{ url = $raw; allowed = $u.Ok; reason = $u.Id; normalized = $u.Normalized; inAllowlist = $u.InAllowlist })
    }
    'check-key' {
      if (-not $a.Count) { throw (Get-ManoError 'E_USAGE' @('check-key <combo> [browser]')) }
      $isB = ($a.Count -gt 1 -and $a[-1] -in 'browser', 'navegador')
      $parts = ConvertTo-ManoCombo $a[0]; $blk = Get-ManoComboBlock $parts $isB ([bool]$script:Cfg.AllowNewTabs)
      $msg = if ($blk) { "BLOQUEADA: $(Select-ManoLanguage (Get-ManoText $blk.Id @($blk.Arg)))" } else { "permitida: $($parts.Normalized)" }
      return (Get-ManoResult 'check-key' $msg @{ keys = $parts.Normalized; browser = $isB; allowed = ($null -eq $blk) })
    }
    'verify-log' {
      $lines = @(); if (Test-Path -LiteralPath $script:AuditFile) { $lines = @(Get-Content -LiteralPath $script:AuditFile -Encoding UTF8) }
      $head = ''; if (Test-Path -LiteralPath $script:AuditHead) { $head = @((Get-Content -LiteralPath $script:AuditHead -Raw).Trim() -split ' ')[-1] }
      $v = Test-ManoAuditChain $lines $head
      if (-not $v.Ok) { throw (Get-ManoError 'E_AUDIT_BROKEN' @($v.BrokenAt, $v.Reason)) }
      return (Get-ManoResult 'verify-log' "Registro de auditoria integro: $($v.Count) entradas. / Audit log intact." @{ entries = $v.Count })
    }
    { $_ -in 'help', '--help', '-h', '/?' } { return ($script:HelpText -f $script:Version) }
    { $_ -in $script:BatchCommands } { return (Invoke-ManoAction $Command $a) }
    default { throw (Get-ManoError 'E_UNKNOWN_CMD' @($Command)) }
  }
}

# =====================================================================================================
# 8. Main
# =====================================================================================================
if ($script:IsLibrary) { return }

$parsed = ConvertFrom-ManoArgument (@($Cmd) + @($Rest))
$script:DryRun   = $parsed.DryRun -or ($env:MANOSEGURA_DRYRUN -eq '1')
$script:JsonMode = $parsed.Json -or ($env:MANOSEGURA_JSON -eq '1')
$argv = @($parsed.Rest)
$command = if ($argv.Count) { "$($argv[0])".ToLowerInvariant() } else { 'help' }
$cmdArgs = [string[]]@($argv | Select-Object -Skip 1)
$exitCode = 0; $results = @(); $err = $null
$script:KnownCommands = @($script:NativeFree) + @($script:BatchCommands) + @('_guard', '_panic', 'monitors', 'list-windows', 'status', 'start-panic', 'batch', 'enable')
try {
  if ($command -notin $script:KnownCommands) { throw (Get-ManoError 'E_UNKNOWN_CMD' @($command)) }
  Initialize-ManoPath -Root $script:Root
  $script:Lang = if ($parsed.Lang) { $parsed.Lang } else { $script:Cfg.Language }
  if ($command -notin $script:NativeFree) {
    if (-not (Test-ManoWindowsHost)) { throw (Get-ManoError 'E_NOT_WINDOWS') }
    Initialize-ManoNative
  }
  if ($command -notin '_guard', '_panic', 'help', 'version', 'status', 'config', 'verify-log') {
    Write-ManoEvent 'CMD' "$command $(Get-ManoClipped ($cmdArgs -join ' '))$(if ($script:DryRun) { ' [dry-run]' })"
  }
  $results = @(Invoke-ManoCommand $command $cmdArgs)
} catch [ManoError] {
  $e = $_.Exception; $exitCode = $e.Code
  $err = [ordered]@{ id = $e.Id; code = $e.Code; es = $e.Es; en = $e.En }
  if ($script:LogFile) { Write-ManoEvent $(if ($e.Code -eq 3) { 'CANCELADO' } else { 'RECHAZADO' }) "[$($e.Id)] $($e.Es)" }
} catch {
  $exitCode = 1; $t = Get-ManoText 'E_INTERNAL' @($_.Exception.Message)
  $err = [ordered]@{ id = 'E_INTERNAL'; code = 1; es = $t.Es; en = $t.En }
  if ($script:LogFile) { Write-ManoEvent 'EXCEPCION' "$($_.Exception.Message) @ linea $($_.InvocationInfo.ScriptLineNumber)" }
}

$all = @(@($script:Partial.ToArray()) + @($results) | Where-Object { $null -ne $_ })
if ($script:JsonMode) {
  $o = [ordered]@{ ok = ($exitCode -eq 0); version = $script:Version; command = $command; dryRun = $script:DryRun; exitCode = $exitCode; results = @($all); notes = @($script:Notes.ToArray()) }
  if ($err) { $o.error = $err }
  ConvertTo-ManoJson $o
} else {
  foreach ($n in $script:Notes) { $n }
  Format-ManoText $all
  if ($err) { "ERROR [$($err.id)]: $(Select-ManoLanguage ([pscustomobject]@{ Es = $err.es; En = $err.en }))" }
}
exit $exitCode
