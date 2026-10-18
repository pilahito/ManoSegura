# Pester 5+ tests for the pure logic of ManoSegura (run on Windows and Linux/macOS).
# Run:  Invoke-Pester -Path ./tests -Output Detailed
BeforeDiscovery { $script:IsWin = ($env:OS -eq 'Windows_NT') }
BeforeAll {
  $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ManoSegura.ps1'
  $env:MANOSEGURA_LIBRARY = '1'
  . $script:ScriptPath
  $env:MANOSEGURA_LIBRARY = $null
  $script:OnWindows = Test-ManoWindowsHost

  function Get-ErrId([scriptblock]$Block) {
    try { & $Block; return '<no error>' } catch { if ($_.Exception -is [ManoError]) { return $_.Exception.Id } else { return "other: $($_.Exception.Message)" } }
  }
  function Initialize-TestRoot([string]$ConfigJson) {
    $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    if ($ConfigJson) { Set-Content -LiteralPath (Join-Path $dir 'config.json') -Value $ConfigJson -Encoding UTF8 }
    $dir
  }
  function ConvertTo-TestMonitor([string]$Name, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Primary, [string]$Id) {
    [pscustomobject]@{ DeviceName = $Name; Bounds = [pscustomobject]@{ X = $X; Y = $Y; Width = $W; Height = $H }; Primary = $Primary; MonitorId = $Id }
  }
}

Describe 'Argumentos / flags' {
  It 'separa --dry-run, --json y idioma' {
    $r = ConvertFrom-ManoArgument @('click', '10', '-20', '--dry-run', '--json', '--en')
    $r.DryRun | Should -BeTrue
    $r.Json | Should -BeTrue
    $r.Lang | Should -Be 'en'
    $r.Rest | Should -Be @('click', '10', '-20')
  }
  It 'ignora nulos y deja el texto intacto' {
    (ConvertFrom-ManoArgument @('type', 'hola mundo', $null)).Rest | Should -Be @('type', 'hola mundo')
  }
}

Describe 'Mensajes bilingues' {
  It 'cada mensaje tiene ES y EN con los mismos marcadores' {
    foreach ($k in $script:Messages.Keys) {
      $pair = $script:Messages[$k]
      $pair.Count | Should -Be 2 -Because $k
      $es = @([regex]::Matches($pair[0], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
      $en = @([regex]::Matches($pair[1], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
      ($es -join ',') | Should -Be ($en -join ',') -Because $k
    }
  }
  It 'codigos de salida: 2 rechazo, 3 cancelado, 4 limite' {
    (Get-ManoError 'E_BLOCKED_WINDOW' @('x')).Code | Should -Be 2
    (Get-ManoError 'E_CANCELLED' @('x')).Code | Should -Be 3
    (Get-ManoError 'E_RATE_LIMIT' @(60, 5)).Code | Should -Be 4
  }
  It 'el idioma elige el texto' {
    $t = Get-ManoText 'E_TARGET_GONE'
    $script:Lang = 'en'; Select-ManoLanguage $t | Should -Be 'The target window no longer exists.'
    $script:Lang = 'both'; Select-ManoLanguage $t | Should -Match ' / '
    $script:Lang = 'es'; Select-ManoLanguage $t | Should -Be 'La ventana objetivo ya no existe.'
  }
}

Describe 'Reglas de titulos (duras)' {
  It 'bloquea <_>' -ForEach @(
    'Iniciar sesión - Cuentas de Google', 'Sign in to GitHub', 'Log in | Discord', 'Recuperar contraseña', 'Enter password',
    'Recibidos (3) - correo@example.com - Gmail', 'Bandeja de entrada - Outlook', 'Inbox (12) - Proton Mail',
    'Inicio / X', '(5) Home / X', 'Elon on X: "hola"', 'twitter.com', 'TweetDeck',
    'PayPal: Resumen', 'Stripe Checkout', 'Pagar pedido', 'Billing settings', 'Tarjeta de crédito', 'BBVA | Banca online', 'Bizum',
    'Coinbase - Wallet', 'Binance', 'Revolut', 'Bitwarden', 'KeePassXC', '1Password',
    'Kaspersky Premium', 'Seguridad de Windows', 'Windows Security', 'Control de cuentas de usuario',
    'ManoSegura - confirmar / confirm', 'ManoSegura - PANICO', 'ManoSegura'
  ) { Test-ManoBlockedTitle $_ | Should -BeTrue }

  It 'permite <_>' -ForEach @(
    'Sin título: Bloc de notas', 'Untitled - Notepad', 'PixelSoft - Godot Engine', 'main.gd - Visual Studio Code', 'ManoSegura.ps1 - Visual Studio Code',
    'YouTube - Brave', 'Wikipedia, la enciclopedia libre - Google Chrome', 'Calculadora', 'Explorador de archivos', ''
  ) { Test-ManoBlockedTitle $_ | Should -BeFalse }

  It 'ExtraBlockedTitles solo anade (y se escapa como texto literal)' {
    Test-ManoBlockedTitle 'Mi Banco (privado) [1]' @('(privado) [1]') | Should -BeTrue
    Test-ManoBlockedTitle 'Notas a+b' @('a+b') | Should -BeTrue
    Test-ManoBlockedTitle 'Notas ab' @('a+b') | Should -BeFalse
    Test-ManoBlockedTitle 'Gmail' @('otra cosa') | Should -BeTrue
  }
}

Describe 'Reglas de URL' {
  It 'Navigation=off rechaza todo' { (Test-ManoUrl 'https://example.com' 'off').Id | Should -Be 'E_NAV_OFF' }
  It 'rechaza esquemas peligrosos: <_>' -ForEach @('javascript:alert(1)', 'file:///C:/Windows/win.ini', 'data:text/html,hi', 'chrome://settings', 'brave://settings', 'about:blank', 'ftp://example.com') {
    (Test-ManoUrl $_ 'ask').Id | Should -BeIn @('E_URL_SCHEME', 'E_URL_INVALID')
  }
  It 'rechaza URL con credenciales' { (Test-ManoUrl 'https://user:pw@example.com/' 'ask').Id | Should -Be 'E_URL_CREDENTIALS' }
  It 'rechaza espacios / saltos de linea' { (Test-ManoUrl "https://example.com/`nenter" 'ask').Id | Should -Be 'E_URL_INVALID' }
  It 'bloquea <_>' -ForEach @(
    'https://mail.google.com/mail/u/0/', 'https://gmail.com', 'https://accounts.google.com/signin', 'https://x.com/home', 'https://twitter.com', 'https://t.co/abc',
    'https://www.paypal.com/es/home', 'https://checkout.stripe.com/pay/x', 'https://www.bbva.es', 'https://www.santander.com', 'https://www.ing.es',
    'https://online.mybank.example', 'https://login.example.com', 'https://example.com/login', 'https://example.com/account/sign-in?next=/',
    'https://shop.example.com/checkout/step1', 'https://outlook.live.com/mail', 'https://proton.me/mail', 'https://www.binance.com/'
  ) { (Test-ManoUrl $_ 'ask').Id | Should -Be 'E_URL_BLOCKED' }
  It 'permite <_> en modo ask (pidiendo permiso explicito)' -ForEach @('https://example.com', 'https://github.com/pilahito/ManoSegura', 'https://es.wikipedia.org/wiki/Godot', 'https://docs.godotengine.org/en/stable/') {
    $r = Test-ManoUrl $_ 'ask'
    $r.Ok | Should -BeTrue
    $r.NeedsExplicitConfirm | Should -BeTrue
  }
  It 'anade https:// a un dominio suelto' { (Test-ManoUrl 'example.com/docs' 'ask').Normalized | Should -Be 'https://example.com/docs' }
  It 'allowlist por dominio incluye subdominios pero no dominios parecidos' {
    $l = @('example.com')
    (Test-ManoUrl 'https://docs.example.com/a' 'allowlist' $l).Ok | Should -BeTrue
    (Test-ManoUrl 'https://example.com' 'allowlist' $l).NeedsExplicitConfirm | Should -BeFalse
    (Test-ManoUrl 'https://example.com.evil.net' 'allowlist' $l).Id | Should -Be 'E_URL_NOT_ALLOWED'
    (Test-ManoUrl 'https://notexample.com' 'allowlist' $l).Id | Should -Be 'E_URL_NOT_ALLOWED'
  }
  It 'allowlist por prefijo respeta los limites de ruta' {
    $l = @('https://github.com/pilahito')
    (Test-ManoUrl 'https://github.com/pilahito/ManoSegura' 'allowlist' $l).Ok | Should -BeTrue
    (Test-ManoUrl 'https://github.com/pilahito' 'allowlist' $l).Ok | Should -BeTrue
    (Test-ManoUrl 'https://github.com/pilahitoevil/x' 'allowlist' $l).Id | Should -Be 'E_URL_NOT_ALLOWED'
  }
  It 'la allowlist nunca desbloquea una URL prohibida' {
    (Test-ManoUrl 'https://mail.google.com' 'allowlist' @('google.com')).Id | Should -Be 'E_URL_BLOCKED'
  }
  It 'ExtraBlockedUrls anade bloqueos' {
    (Test-ManoUrl 'https://example.com/privado/x' 'ask' @() @('/privado/')).Id | Should -Be 'E_URL_BLOCKED'
  }
}

Describe 'Navegadores y barra de direcciones' {
  It 'detecta navegadores: <_>' -ForEach @('brave', 'brave.exe', 'Chrome', 'msedge', 'firefox', 'opera', 'vivaldi') { Test-ManoBrowser $_ | Should -BeTrue }
  It 'no confunde apps: <_>' -ForEach @('notepad', 'Godot_v4.7-stable_win64', 'Code', 'explorer', '') { Test-ManoBrowser $_ | Should -BeFalse }
  It 'ExtraBrowsers' { Test-ManoBrowser 'MiNavegador.exe' @('minavegador') | Should -BeTrue }
  It 'reconoce la barra de direcciones' {
    Test-ManoAddressBarElement 'Barra de direcciones y de búsqueda' '' '' | Should -BeTrue
    Test-ManoAddressBarElement 'Address and search bar' '' 'OmniboxViewViews' | Should -BeTrue
    Test-ManoAddressBarElement 'Buscar con Google o introducir dirección' 'urlbar-input' '' | Should -BeTrue
    Test-ManoAddressBarElement 'Mensaje' 'prompt-textarea' 'ProseMirror' | Should -BeFalse
  }
}

Describe 'Teclas' {
  It 'normaliza combinaciones' {
    (ConvertTo-ManoCombo 'Shift+Ctrl+N').Normalized | Should -Be 'ctrl+shift+n'
    (ConvertTo-ManoCombo 'ctrl + Supr').Normalized | Should -Be 'ctrl+delete'
    (ConvertTo-ManoCombo 'ctrl++').Normalized | Should -Be 'ctrl++'
    (ConvertTo-ManoCombo 'Escape').Key | Should -Be 'esc'
  }
  It 'rechaza Win, teclas desconocidas, sin tecla o con dos' {
    Get-ErrId { ConvertTo-ManoCombo 'win+r' } | Should -Be 'E_KEY_WIN'
    Get-ErrId { ConvertTo-ManoCombo 'ctrl+foo' } | Should -Be 'E_KEY_UNKNOWN'
    Get-ErrId { ConvertTo-ManoCombo 'ctrl+shift' } | Should -Be 'E_KEY_NOKEY'
    Get-ErrId { ConvertTo-ManoCombo 'a+b' } | Should -Be 'E_KEY_TWO'
  }
  It 'bloqueo duro (cualquier app): <_>' -ForEach @('alt+f4', 'shift+alt+f4', 'ctrl+alt+del', 'ctrl+alt+supr', 'ctrl+shift+esc', 'alt+tab', 'alt+shift+tab', 'ctrl+esc') {
    Get-ManoComboBlock (ConvertTo-ManoCombo $_) $false $false | Should -Not -BeNullOrEmpty
  }
  It 'navegador: barra de direcciones bloqueada: <_>' -ForEach @('ctrl+l', 'alt+d', 'f6', 'ctrl+e', 'ctrl+k') {
    (Get-ManoComboBlock (ConvertTo-ManoCombo $_) $true $true).Id | Should -Be 'E_KEY_ADDRESSBAR'
  }
  It 'navegador: pestanas/ventanas nuevas bloqueadas salvo AllowNewTabs: <_>' -ForEach @('ctrl+t', 'ctrl+n', 'ctrl+shift+n', 'ctrl+shift+t', 'ctrl+shift+p', 'alt+enter') {
    (Get-ManoComboBlock (ConvertTo-ManoCombo $_) $true $false).Id | Should -Be 'E_KEY_NEWTAB'
    Get-ManoComboBlock (ConvertTo-ManoCombo $_) $true $true | Should -BeNullOrEmpty
  }
  It 'fuera del navegador ctrl+l / ctrl+t / ctrl+n se permiten' {
    foreach ($c in 'ctrl+l', 'ctrl+t', 'ctrl+n') { Get-ManoComboBlock (ConvertTo-ManoCombo $c) $false $false | Should -BeNullOrEmpty }
  }
  It 'convierte a SendKeys' {
    ConvertTo-ManoSendKey (ConvertTo-ManoCombo 'ctrl+shift+s') | Should -Be '^+s'
    ConvertTo-ManoSendKey (ConvertTo-ManoCombo 'alt+f2') | Should -Be '%{F2}'
    ConvertTo-ManoSendKey (ConvertTo-ManoCombo 'ctrl++') | Should -Be '^{+}'
    ConvertTo-ManoSendKey (ConvertTo-ManoCombo 'enter') | Should -Be '{ENTER}'
  }
  It 'escapa texto para SendKeys' {
    ConvertTo-ManoSendKeyText "a+b^c%d~(e){f}[g]`nh`tz" | Should -Be 'a{+}b{^}c{%}d{~}{(}e{)}{{}f{}}{[}g{]}{ENTER}h{TAB}z'
  }
}

Describe 'Monitores y coordenadas negativas' {
  BeforeAll {
    $script:Mons = @(
      (ConvertTo-TestMonitor '\\.\DISPLAY1' 0 0 1920 1080 $true 'MONITOR\GSM5B7F LG')
      (ConvertTo-TestMonitor '\\.\DISPLAY2' -1920 0 1920 1080 $false 'MONITOR\ACR0A1B Acer')
      (ConvertTo-TestMonitor '\\.\DISPLAY3' 1920 -200 2560 1440 $false 'MONITOR\DEL4321 Dell')
    )
  }
  It '<Spec> -> <Expected>' -ForEach @(
    @{ Spec = 'primary'; Expected = '\\.\DISPLAY1' }, @{ Spec = ''; Expected = '\\.\DISPLAY1' }, @{ Spec = '1'; Expected = '\\.\DISPLAY2' },
    @{ Spec = 'left'; Expected = '\\.\DISPLAY2' }, @{ Spec = 'izquierda'; Expected = '\\.\DISPLAY2' }, @{ Spec = 'derecha'; Expected = '\\.\DISPLAY3' },
    @{ Spec = 'x=-1920'; Expected = '\\.\DISPLAY2' }, @{ Spec = '-1920'; Expected = '\\.\DISPLAY2' }, @{ Spec = '-100,500'; Expected = '\\.\DISPLAY2' },
    @{ Spec = '2000,-150'; Expected = '\\.\DISPLAY3' }, @{ Spec = 'DISPLAY2'; Expected = '\\.\DISPLAY2' }, @{ Spec = '\\.\DISPLAY3'; Expected = '\\.\DISPLAY3' },
    @{ Spec = 'ACR'; Expected = '\\.\DISPLAY2' }, @{ Spec = 'acer'; Expected = '\\.\DISPLAY2' }
  ) { (Select-ManoMonitor $script:Mons $Spec).DeviceName | Should -Be $Expected }
  It 'devuelve null si no existe' {
    Select-ManoMonitor $script:Mons '7' | Should -BeNullOrEmpty
    Select-ManoMonitor $script:Mons 'SAMSUNG' | Should -BeNullOrEmpty
    Select-ManoMonitor $script:Mons '5000,5000' | Should -BeNullOrEmpty
  }
  It 'ventana en el monitor de la izquierda (X negativa)' {
    $acer = $script:Mons[1].Bounds
    Test-ManoRectInside ([pscustomobject]@{ X = -1900; Y = 10; Width = 800; Height = 600 }) $acer | Should -BeTrue
    Test-ManoRectInside ([pscustomobject]@{ X = -1920; Y = 0; Width = 1920; Height = 1080 }) $acer | Should -BeTrue
    Test-ManoRectInside ([pscustomobject]@{ X = -300; Y = 10; Width = 800; Height = 600 }) $acer | Should -BeFalse
    Test-ManoPointInside -1 500 $acer | Should -BeTrue
    Test-ManoPointInside 0 500 $acer | Should -BeFalse
    Test-ManoPointInside -1921 500 $acer | Should -BeFalse
  }
  It 'Format-ManoRect' { Format-ManoRect ([pscustomobject]@{ X = -1920; Y = 0; Width = 1920; Height = 1080 }) | Should -Be '-1920,0 1920x1080' }
}

Describe 'Borde visible (overlay)' {
  It 'va por fuera cuando hay sitio' {
    $e = Get-ManoOverlayEdge ([pscustomobject]@{ X = -1500; Y = 100; Width = 800; Height = 600 }) ([pscustomobject]@{ X = -1920; Y = 0; Width = 1920; Height = 1080 }) 3
    ($e | Where-Object Side -EQ 'top').Y | Should -Be 97
    ($e | Where-Object Side -EQ 'left').X | Should -Be -1503
    ($e | Where-Object Side -EQ 'right').X | Should -Be -700
    ($e | Where-Object Side -EQ 'top').Width | Should -Be 806
    ($e | Where-Object Side -EQ 'left').Height | Should -Be 606
  }
  It 'va por dentro con la ventana maximizada y nunca sale del monitor' {
    $m = [pscustomobject]@{ X = -1920; Y = 0; Width = 1920; Height = 1080 }
    $e = Get-ManoOverlayEdge ([pscustomobject]@{ X = -1920; Y = 0; Width = 1920; Height = 1040 }) $m 3
    foreach ($r in $e) { Test-ManoRectInside $r $m | Should -BeTrue -Because $r.Side }
    ($e | Where-Object Side -EQ 'bottom').Y | Should -Be 1040
  }
}

Describe 'Modo confianza' {
  It 'valida la caducidad y rechaza ficheros falsificados demasiado largos' {
    $now = Get-Date
    Test-ManoTrustValue ($now.AddMinutes(5).ToString('o')) $now 60 | Should -BeTrue
    Test-ManoTrustValue ($now.AddMinutes(-1).ToString('o')) $now 60 | Should -BeFalse
    Test-ManoTrustValue ($now.AddDays(30).ToString('o')) $now 60 | Should -BeFalse
    Test-ManoTrustValue 'basura' $now 60 | Should -BeFalse
    Test-ManoTrustValue '' $now 60 | Should -BeFalse
  }
}

Describe 'Limite de velocidad' {
  It 'permite hasta el maximo y calcula la espera' {
    $now = [datetime]'2026-10-18T12:00:00'
    $hist = @(1..3 | ForEach-Object { $now.AddSeconds(-50 + $_) })
    (Test-ManoRateLimit $hist $now 5).Allowed | Should -BeTrue
    $r = Test-ManoRateLimit $hist $now 3
    $r.Allowed | Should -BeFalse
    $r.RetryAfterSec | Should -Be 11
  }
  It 'olvida eventos viejos e ignora marcas del futuro' {
    $now = [datetime]'2026-10-18T12:00:00'
    (Test-ManoRateLimit @($now.AddMinutes(-5), $now.AddMinutes(-2)) $now 1).Allowed | Should -BeTrue
    (Test-ManoRateLimit @($now.AddHours(3)) $now 1).Allowed | Should -BeTrue
  }
  It 'un batch mayor que el limite nunca cabe' {
    (Test-ManoRateLimit @() (Get-Date) 10 -Count 11).NeverFits | Should -BeTrue
  }
  It 'Register-ManoRate cuenta entre procesos (fichero) y lanza E_RATE_LIMIT con codigo 4' {
    Initialize-ManoPath -Root (Initialize-TestRoot '{ "MaxActionsPerMinute": 2 }')
    $script:DryRun = $false
    Register-ManoRate 1; Register-ManoRate 1
    $e = $null; try { Register-ManoRate 1 } catch { $e = $_.Exception }
    $e.Id | Should -Be 'E_RATE_LIMIT'
    $e.Code | Should -Be 4
    Get-ErrId { Register-ManoRate 3 } | Should -Be 'E_RATE_BATCH'
  }
}

Describe 'Registro de auditoria con cadena de hashes' {
  BeforeAll {
    $script:Chain = {
      $prev = $script:GenesisHash; $lines = @()
      foreach ($i in 1..3) {
        $rec = Get-ManoAuditRecord -Seq $i -Prev $prev -EventName 'HECHO' -Detail "paso $i áé`nlinea" -Time "2026-10-18 12:00:0$i.000 +02:00" -ProcessId 1234
        $lines += (ConvertTo-Json -InputObject $rec -Compress); $prev = $rec.hash
      }
      , $lines
    }
  }
  It 'una cadena correcta valida' {
    $l = & $script:Chain
    $v = Test-ManoAuditChain $l
    $v.Ok | Should -BeTrue
    $v.Count | Should -Be 3
  }
  It 'detecta un detalle modificado' {
    $l = & $script:Chain; $l[1] = $l[1] -replace 'paso 2', 'paso X'
    $v = Test-ManoAuditChain $l
    $v.Ok | Should -BeFalse
    $v.BrokenAt | Should -Be 2
    $v.Reason | Should -Be 'hash'
  }
  It 'detecta una linea borrada en medio' {
    $l = & $script:Chain
    (Test-ManoAuditChain @($l[0], $l[2])).Ok | Should -BeFalse
  }
  It 'detecta un recorte al final con audit.head' {
    $l = & $script:Chain
    $head = ($l[2] | ConvertFrom-Json).hash
    (Test-ManoAuditChain @($l[0], $l[1]) $head).Reason | Should -Be 'head'
  }
  It 'Write-ManoAudit escribe una cadena verificable' {
    Initialize-ManoPath -Root (Initialize-TestRoot '')
    Write-ManoAudit 'CMD' 'focus 123'; Write-ManoAudit 'PERMITIDO' "clic`r`nleft"; Write-ManoAudit 'HECHO' 'ñandú'
    $lines = @(Get-Content -LiteralPath $script:AuditFile -Encoding UTF8)
    $lines.Count | Should -Be 3
    $head = ((Get-Content -LiteralPath $script:AuditHead -Raw).Trim() -split ' ')[-1]
    (Test-ManoAuditChain $lines $head).Ok | Should -BeTrue
  }
}

Describe 'Batch' {
  It 'acepta {steps:[...]} y convierte numeros a texto' {
    $s = @(ConvertFrom-ManoBatch '{"steps":[{"cmd":"focus","args":["123"]},{"cmd":"CLICK","args":[10,20]},{"cmd":"wait"}]}')
    $s.Count | Should -Be 3
    $s[1].Cmd | Should -Be 'click'
    $s[1].Args | Should -Be @('10', '20')
    $s[2].Args.Count | Should -Be 0
  }
  It 'acepta una lista directa' { @(ConvertFrom-ManoBatch '[{"cmd":"wait","args":["100"]}]').Count | Should -Be 1 }
  It 'acepta navigate' { (ConvertFrom-ManoBatch '[{"cmd":"navigate","args":["https://example.com"]}]').Cmd | Should -Be 'navigate' }
  It 'rechaza <Json> con <Id>' -ForEach @(
    @{ Json = '{"steps":[{"cmd":"batch","args":["x.json"]}]}'; Id = 'E_BATCH_STEP' },
    @{ Json = '{"steps":[{"cmd":"enable"}]}'; Id = 'E_BATCH_STEP' },
    @{ Json = '{"steps":[{"cmd":"disable"}]}'; Id = 'E_BATCH_STEP' },
    @{ Json = '{"steps":[{"cmd":"type","args":[{"a":1}]}]}'; Id = 'E_BATCH_ARGS' },
    @{ Json = '{"steps":["click"]}'; Id = 'E_BATCH_FORMAT' },
    @{ Json = '{"steps":[]}'; Id = 'E_BATCH_EMPTY' },
    @{ Json = '{no json'; Id = 'E_BATCH_JSON' }
  ) { Get-ErrId { ConvertFrom-ManoBatch $Json } | Should -Be $Id }
  It 'maximo 50 pasos' {
    $j = '[' + ((1..51 | ForEach-Object { '{"cmd":"wait"}' }) -join ',') + ']'
    Get-ErrId { ConvertFrom-ManoBatch $j } | Should -Be 'E_BATCH_TOO_LONG'
  }
  It 'cuenta acciones para el limite (wait y screenshot no cuentan)' {
    Get-ManoActionCount @(ConvertFrom-ManoBatch '[{"cmd":"focus","args":["1"]},{"cmd":"wait"},{"cmd":"screenshot"},{"cmd":"key","args":["enter"]}]') | Should -Be 2
  }
  It 'Read-ManoBatchSource lee JSON literal y ficheros' {
    Read-ManoBatchSource '{"steps":[]}' | Should -Be '{"steps":[]}'
    $f = Join-Path $TestDrive 'steps.json'; Set-Content -LiteralPath $f -Value '[{"cmd":"wait"}]' -Encoding UTF8
    (Read-ManoBatchSource $f).Trim() | Should -Be '[{"cmd":"wait"}]'
  }
  It 'el ejemplo del repo es valido' {
    $ex = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples/steps.example.json'
    @(ConvertFrom-ManoBatch (Read-ManoBatchSource $ex)).Count | Should -BeGreaterThan 0
  }
}

Describe 'Configuracion' {
  It 'sin config.json usa los valores por defecto' {
    $c = Import-ManoConfig -Path (Join-Path $TestDrive 'no-existe.json')
    $c.TargetMonitor | Should -Be 'primary'
    $c.Navigation | Should -Be 'off'
    $c.AllowNewTabs | Should -BeFalse
    $c.MaxActionsPerMinute | Should -Be 60
  }
  It 'config.example.json carga y es estricto por defecto' {
    $c = Import-ManoConfig -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.example.json')
    $c.Navigation | Should -Be 'off'
    $c.AllowNewTabs | Should -BeFalse
  }
  It 'una config v1.0 sigue funcionando' {
    $p = Join-Path (Initialize-TestRoot '{ "TargetMonitor": "ACR", "ShotsDir": "", "ConfirmTimeoutSec": 20, "TrustMaxMinutes": 60, "ExtraBlockedTitles": ["Banco"] }') 'config.json'
    $c = Import-ManoConfig -Path $p
    $c.TargetMonitor | Should -Be 'ACR'
    $c.ExtraBlockedTitles | Should -Be @('Banco')
  }
  It 'lee valores nuevos' {
    $p = Join-Path (Initialize-TestRoot '{ "Navigation": "Allowlist", "UrlAllowlist": ["example.com"], "AllowNewTabs": "true", "MaxActionsPerMinute": "30", "Language": "en" }') 'config.json'
    $c = Import-ManoConfig -Path $p
    $c.Navigation | Should -Be 'allowlist'
    $c.UrlAllowlist | Should -Be @('example.com')
    $c.AllowNewTabs | Should -BeTrue
    $c.MaxActionsPerMinute | Should -Be 30
    $c.Language | Should -Be 'en'
  }
  It 'rechaza <Json> con <Id>' -ForEach @(
    @{ Json = '{ "TrustMaxMinutes": 999 }'; Id = 'E_CONFIG_RANGE' },
    @{ Json = '{ "MaxActionsPerMinute": 100000 }'; Id = 'E_CONFIG_RANGE' },
    @{ Json = '{ "ConfirmTimeoutSec": 1 }'; Id = 'E_CONFIG_RANGE' },
    @{ Json = '{ "ConfirmTimeoutSec": "veinte" }'; Id = 'E_CONFIG_VALUE' },
    @{ Json = '{ "Navigation": "always" }'; Id = 'E_CONFIG_VALUE' },
    @{ Json = '{ "AllowNewTabs": "quizas" }'; Id = 'E_CONFIG_VALUE' },
    @{ Json = '{ roto'; Id = 'E_CONFIG_JSON' },
    @{ Json = '[1,2]'; Id = 'E_CONFIG_JSON' }
  ) {
    $p = Join-Path (Initialize-TestRoot $Json) 'config.json'
    Get-ErrId { Import-ManoConfig -Path $p } | Should -Be $Id
  }
  It 'MANOSEGURA_MONITOR / MANOSEGURA_LANG sobrescriben' {
    $c = Import-ManoConfig -Path '' -MonitorOverride 'x=-1920' -LanguageOverride 'EN'
    $c.TargetMonitor | Should -Be 'x=-1920'
    $c.Language | Should -Be 'en'
  }
}

Describe 'Salida JSON' {
  It 'escapa caracteres no ASCII y sigue siendo JSON valido' {
    $j = ConvertTo-ManoJson ([ordered]@{ ok = $true; msg = 'contraseña ñ €' })
    $j | Should -Not -Match '[^\x00-\x7F]'
    ($j | ConvertFrom-Json).msg | Should -Be 'contraseña ñ €'
  }
  It 'Format-ManoText usa message' { Format-ManoText @((Get-ManoResult 'x' 'hola' @{ a = 1 })) | Should -Be 'hola' }
}

Describe 'Dry-run y reglas aplicadas a acciones (con mocks, sin tocar la pantalla)' {
  BeforeAll {
    Initialize-ManoPath -Root (Initialize-TestRoot '{ "Navigation": "ask", "UrlAllowlist": ["example.com"] }')
    $script:Proc = 'notepad'; $script:Title = 'Sin título: Bloc de notas'
    Mock Get-ManoTarget { [IntPtr]123 }
    Mock Get-ManoTitle { $script:Title }
    Mock Get-ManoWindowProcess { $script:Proc }
    Mock Assert-ManoOnMonitor { [pscustomobject]@{ X = -1900; Y = 10; Width = 800; Height = 600 } }
    Mock Get-ManoRect { [pscustomobject]@{ X = -1900; Y = 10; Width = 800; Height = 600 } }
    Mock Get-ManoTargetMonitor { ConvertTo-TestMonitor '\\.\DISPLAY2' -1920 0 1920 1080 $false 'ACR' }
    Mock Invoke-ManoFocus { $true }
  }
  BeforeEach {
    $script:DryRun = $true; $script:BatchApproved = $false; $script:Notes.Clear(); $script:Partial.Clear()
    $script:Proc = 'notepad'; $script:Title = 'Sin título: Bloc de notas'
    Remove-Item -LiteralPath $script:DisabledFlag -ErrorAction SilentlyContinue
  }
  It 'key en dry-run: no pulsa nada y anota el permiso' {
    $r = Invoke-ManoAction 'key' @('ctrl+a')
    $r.dryRun | Should -BeTrue
    $script:Notes[0] | Should -Match 'pediria permiso'
  }
  It 'click calcula coordenadas de pantalla negativas' {
    $r = Invoke-ManoAction 'click' @('10', '20')
    $r.screenX | Should -Be -1890
    $r.screenY | Should -Be 30
  }
  It 'click fuera de la ventana se rechaza' { Get-ErrId { Invoke-ManoAction 'click' @('900', '20') } | Should -Be 'E_OUT_OF_WINDOW' }
  It 'click con numero invalido' { Get-ErrId { Invoke-ManoAction 'click' @('diez', '20') } | Should -Be 'E_BAD_NUMBER' }
  It 'ventana prohibida se rechaza incluso en dry-run' {
    $script:Title = 'Recibidos - Gmail'
    Get-ErrId { Invoke-ManoAction 'paste' @('hola') } | Should -Be 'E_BLOCKED_WINDOW'
  }
  It 'Ctrl+L en un navegador se rechaza antes de pedir permiso' {
    $script:Proc = 'brave'
    Get-ErrId { Invoke-ManoAction 'key' @('ctrl+l') } | Should -Be 'E_KEY_ADDRESSBAR'
    $script:Notes.Count | Should -Be 0
  }
  It 'Ctrl+T en Brave se rechaza (pestanas nuevas)' {
    $script:Proc = 'brave'
    Get-ErrId { Invoke-ManoAction 'key' @('ctrl+t') } | Should -Be 'E_KEY_NEWTAB'
  }
  It 'navigate solo en navegadores' { Get-ErrId { Invoke-ManoAction 'navigate' @('https://example.com') } | Should -Be 'E_NAV_NOT_BROWSER' }
  It 'navigate a una URL prohibida se rechaza' {
    $script:Proc = 'brave'
    Get-ErrId { Invoke-ManoAction 'navigate' @('https://mail.google.com') } | Should -Be 'E_URL_BLOCKED'
  }
  It 'navigate permitido en dry-run' {
    $script:Proc = 'brave'
    (Invoke-ManoAction 'navigate' @('example.com/docs')).url | Should -Be 'https://example.com/docs'
  }
  It 'desactivada (panico) => E_DISABLED' {
    Set-Content -LiteralPath $script:DisabledFlag -Value 'x'
    Get-ErrId { Invoke-ManoAction 'key' @('enter') } | Should -Be 'E_DISABLED'
    Get-ErrId { $null = Invoke-ManoAction 'wait' @('10') } | Should -Be '<no error>'
  }
  It 'wait limita a 10 s y en dry-run no espera' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    (Invoke-ManoAction 'wait' @('999999')).ms | Should -Be 10000
    $sw.ElapsedMilliseconds | Should -BeLessThan 2000
  }
  It 'batch completo en dry-run (un solo permiso)' {
    $f = Join-Path $TestDrive 'b.json'
    Set-Content -LiteralPath $f -Value '{"steps":[{"cmd":"key","args":["ctrl+a"]},{"cmd":"paste","args":["hola"]},{"cmd":"wait","args":["50"]}]}' -Encoding UTF8
    $r = Invoke-ManoCommand 'batch' @($f)
    $r.message | Should -Be 'OK batch (3 pasos)'
    $script:Partial.Count | Should -Be 3
    @($script:Notes | Where-Object { $_ -match 'pediria permiso' }).Count | Should -Be 1
    $script:BatchApproved | Should -BeFalse
  }
  It 'batch con una tecla prohibida falla antes de pedir permiso' {
    $script:Proc = 'brave'
    Get-ErrId { Invoke-ManoCommand 'batch' @('[{"cmd":"key","args":["win+r"]}]') } | Should -Be 'E_KEY_WIN'
    $script:Notes.Count | Should -Be 0
  }
  It 'batch con URL prohibida falla antes de pedir permiso' {
    Get-ErrId { Invoke-ManoCommand 'batch' @('[{"cmd":"navigate","args":["https://x.com"]}]') } | Should -Be 'E_URL_BLOCKED'
  }
  AfterAll { $script:DryRun = $false }
}

Describe 'CLI (proceso real)' {
  BeforeAll {
    $script:Exe = (Get-Process -Id $PID).Path
    $script:Run = { param([string[]]$CliArgs) $out = & $script:Exe -NoProfile -File $script:ScriptPath @CliArgs; [pscustomobject]@{ Out = ($out -join "`n"); Exit = $LASTEXITCODE } }
  }
  It 'version --json' {
    $r = & $script:Run @('version', '--json')
    $r.Exit | Should -Be 0
    ($r.Out | ConvertFrom-Json).results[0].version | Should -Be $script:Version
  }
  It 'check-title --json bloquea Gmail' {
    $r = & $script:Run @('check-title', 'Recibidos - Gmail', '--json')
    ($r.Out | ConvertFrom-Json).results[0].blocked | Should -BeTrue
  }
  It 'check-key en navegador' {
    $r = & $script:Run @('check-key', 'ctrl+n', 'browser', '--json')
    ($r.Out | ConvertFrom-Json).results[0].allowed | Should -BeFalse
  }
  It 'comando desconocido => exit 2 y error bilingue en JSON' {
    $r = & $script:Run @('formatear-disco', '--json')
    $r.Exit | Should -Be 2
    $j = $r.Out | ConvertFrom-Json
    $j.ok | Should -BeFalse
    $j.error.id | Should -Be 'E_UNKNOWN_CMD'
    $j.error.en | Should -Match 'Unknown command'
  }
  It 'fuera de Windows los comandos de pantalla dicen E_NOT_WINDOWS' -Skip:$script:IsWin {
    $r = & $script:Run @('click', '1', '2', '--json')
    ($r.Out | ConvertFrom-Json).error.id | Should -Be 'E_NOT_WINDOWS'
  }
  It 'el script no usa -ExecutionPolicy Bypass, ni -EncodedCommand, ni ventanas ocultas' {
    $src = Get-Content -LiteralPath $script:ScriptPath -Raw
    $src | Should -Not -Match '(?i)''-ExecutionPolicy''\s*,\s*''Bypass''|-ExecutionPolicy\s+Bypass\s+-File'
    $src | Should -Not -Match '(?i)-EncodedCommand|FromBase64String'
    $src | Should -Not -Match '(?i)WindowStyle\s+Hidden'
    $src | Should -Not -Match '(?i)Invoke-Expression|\biex\b|DownloadString|Invoke-WebRequest|Net\.WebClient'
  }
}

Describe 'Windows nativo (solo en Windows)' -Skip:(-not $script:IsWin) {
  It 'compila las llamadas nativas y el atajo de panico' {
    { Initialize-ManoNative } | Should -Not -Throw
    { if (-not ('MsHot3' -as [type])) { Add-Type -ReferencedAssemblies (Get-ManoFormsReference) -TypeDefinition $script:HotKeyCode } } | Should -Not -Throw
  }
  It 'monitors --json lista al menos un monitor' {
    $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:ScriptPath monitors --json
    $j = ($out -join "`n") | ConvertFrom-Json
    $j.ok | Should -BeTrue
    @($j.results).Count | Should -BeGreaterThan 0
  }
  It 'list-windows --json funciona' {
    $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:ScriptPath list-windows --json
    (($out -join "`n") | ConvertFrom-Json).ok | Should -BeTrue
  }
}
