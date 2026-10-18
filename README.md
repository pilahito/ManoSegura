# ManoSegura 🖐️🔒

**ES** · Una "mano remota" segura para que un asistente de IA controle **una sola ventana** en **un monitor elegido** de Windows, siempre con tu permiso.
**EN** · A safe "remote hand" that lets an AI assistant control **one window** on **one chosen monitor** in Windows, always with your permission.

PowerShell 5.1+ (también 7), un solo archivo, sin descargas, sin admin, **sin `-ExecutionPolicy Bypass`**.
Single file, no downloads, no admin, **no `-ExecutionPolicy Bypass` needed**.

[![tests](../../actions/workflows/tests.yml/badge.svg)](../../actions/workflows/tests.yml)

---

## Español

### Novedades de la 1.1
- **Amigable con el antivirus**: ya no hace falta `-ExecutionPolicy Bypass`, ni ventanas ocultas, ni comandos codificados. El vigilante de pánico se ve: icono en la bandeja, cartel abajo en tu monitor y un **borde naranja** alrededor de la ventana controlada (rojo en modo confianza).
- **Navegadores más seguros**: bloquea la barra de direcciones (`Ctrl+L`, `Alt+D`, `F6`…) y escribir en ella; para navegar existe `navigate <url>`, que pasa por las reglas de URL y tu lista permitida. Bloquea abrir **pestañas o ventanas nuevas** (`Ctrl+T`, `Ctrl+N`, `Ctrl+Shift+N`…) y avisa y para si aparece una ventana de navegador nueva (por ejemplo, Brave abriéndose solo).
- **Límite de velocidad** (acciones por minuto), **registro de auditoría con cadena de hashes** (`verify-log`), **salida JSON** (`--json`), errores claros en español e inglés, DPI por monitor y monitores con coordenadas negativas (p. ej. un monitor a la izquierda en X = -1920).
- Más reglas duras: gestores de contraseñas, antivirus o seguridad de Windows, más correo web y pagos, y los propios diálogos de ManoSegura (la IA no puede pulsar "Permitir" por ti).

### Instalación (sin Bypass)
1. Descarga el zip de [Releases](../../releases) y descomprímelo, por ejemplo en `D:\Tools\ManoSegura`.
2. Quita la marca de "descargado de Internet" (solo una vez):
   ```powershell
   Get-ChildItem D:\Tools\ManoSegura -Recurse | Unblock-File
   ```
3. Permite scripts locales para tu usuario (no necesita admin; es lo que recomienda Microsoft):
   ```powershell
   Get-ExecutionPolicy -List                      # mira cómo está
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
   Si prefieres no cambiarlo, usa `-ExecutionPolicy RemoteSigned` en cada llamada, que también es mucho menos sospechoso que `Bypass`.
4. Copia `config.example.json` a `config.json` y elige el monitor:
   ```powershell
   powershell -NoProfile -File D:\Tools\ManoSegura\ManoSegura.ps1 monitors
   ```
   En `TargetMonitor` puedes poner `primary`, un índice (`1`), `left`/`izquierda`, `right`/`derecha`, la X del monitor (`x=-1920`), un punto (`-1920,0`), el nombre (`DISPLAY2` o `\\.\DISPLAY2`) o parte del ID (`ACR`, `DEL`…). También vale la variable de entorno `MANOSEGURA_MONITOR`.
5. `start-panic` arranca el vigilante de pánico; también se arranca solo en la primera acción. Si no puede arrancar, ManoSegura **no actúa**.

#### Opcional: firmar el script con tu propio certificado
Así puedes usar incluso la política `AllSigned`, y el antivirus ve un script firmado. Hazlo en tu PC (no necesita admin):
```powershell
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=ManoSegura local' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(3)
# Confía en él solo para tu usuario:
$tmp = Join-Path $env:TEMP 'ManoSegura-local.cer'; Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\Root | Out-Null      # Windows pedirá confirmación
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\TrustedPublisher | Out-Null
Remove-Item $tmp
Set-AuthenticodeSignature -FilePath D:\Tools\ManoSegura\ManoSegura.ps1 -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
Get-AuthenticodeSignature D:\Tools\ManoSegura\ManoSegura.ps1   # Status: Valid
```
Tendrás que volver a firmar cada vez que actualices el script. No compartas nunca el certificado ni lo exportes con su clave privada.

### Antivirus y Kaspersky
**Por qué puede saltar.** La detección por comportamiento (en Kaspersky, el componente de supervisión del sistema, con avisos tipo `PDM:Trojan.Win32.Generic`) se fija en patrones como PowerShell con `-ExecutionPolicy Bypass`, PowerShell que lanza otro PowerShell oculto, scripts temporales con nombres aleatorios, cerrar procesos y llamadas a `user32` para teclado o ratón. Una herramienta de control remoto hace por fuerza algunas de esas cosas, así que la 1.1 evita todo lo demás:

| Lo que hace ManoSegura 1.1 | Lo que **no** hace |
|---|---|
| Archivo con nombre claro, en su carpeta | Scripts temporales con nombres raros |
| Vigilante visible: consola minimizada, icono de bandeja, cartel, borde | Ventanas ocultas (`-WindowStyle Hidden`) |
| Funciona con `RemoteSigned` o firmado | `-ExecutionPolicy Bypass`, `-EncodedCommand`, Base64, `Invoke-Expression` |
| Solo cierra **sus propios** procesos al pulsar pánico | Cerrar otros programas |
| Todo en local | Descargar nada, red, autoarranque, tareas programadas, registro de Windows |

**Si Kaspersky aún avisa:**
1. Si dice que es de ManoSegura (la ruta apunta a su carpeta), elige *Probar desinfectar sin reiniciar* o ciérralo; no uses *Desinfectar y reiniciar* sin comprobarlo.
2. Añade una **exclusión solo para la carpeta** de ManoSegura (Kaspersky Standard, Plus o Premium; los nombres pueden variar según la versión):
   *Ajustes* (engranaje, abajo) → *Configuración de seguridad* → *Exclusiones y acciones al detectar objetos* → *Gestionar exclusiones* → *Añadir* → *Examinar* → elige `D:\Tools\ManoSegura\` → deja la regla *Activa* → *Añadir*.
   Más seguro todavía: excluye por **hash del archivo** (campo *Hash del archivo*; obtenlo con `Get-FileHash .\ManoSegura.ps1`). Tendrás que actualizarlo con cada versión.
3. **No** añadas `powershell.exe` como *aplicación de confianza* ni desactives la supervisión del sistema: eso dejaría pasar cualquier script malicioso.
4. Si crees que es un falso positivo, envíalo a Kaspersky (<https://opentip.kaspersky.com/> o su soporte).

### Seguridad
- **Permiso por acción**: aparece un diálogo en tu monitor, escalado a su DPI (Permitir o Cancelar; se cancela solo a los 20 s).
- **Modo confianza**: marca la casilla para permitir sin preguntar durante N minutos (máximo configurable, tope duro de 240). `trust-off` o el menú de la bandeja lo quitan. Un `trust.txt` escrito a mano con una fecha lejana se ignora.
- **Pánico `Ctrl+Alt+P`** o el menú de la bandeja: detiene las acciones en curso, desactiva ManoSegura y borra el modo confianza. Solo tú puedes reactivarla con `enable`, que siempre pide confirmación y nunca usa el modo confianza.
- **Reglas duras en el código**: ni la configuración ni el modo confianza las desactivan. Rechaza ventanas de **login o contraseña**, **Gmail y correo web**, **X/Twitter**, **pagos y banca**, **gestores de contraseñas**, **antivirus y seguridad de Windows** y los **diálogos de ManoSegura**. Se comprueba antes de actuar, después de enfocar y **después de cada acción**: si la página cambia a una prohibida, se para y quita el modo confianza.
- Nunca escribe ni pega en campos de contraseña (UI Automation `IsPassword`), ni en la barra de direcciones del navegador.
- Solo actúa dentro de la ventana objetivo y en el monitor objetivo. Mientras escribe comprueba que la ventana sigue al frente. Bloquea `Win`, `Ctrl+Esc`, `Alt+F4`, `Alt+Tab`, `Ctrl+Alt+Supr` y `Ctrl+Shift+Esc`.
- **Navegadores** (Brave, Chrome, Edge, Firefox, Opera, Vivaldi…):
  - `Navigation`: `off` (por defecto, sin navegar), `allowlist` (solo URLs de `UrlAllowlist`) o `ask` (cualquier URL no prohibida, pero fuera de la lista **siempre pregunta**, aunque haya modo confianza).
  - Solo `http`/`https`. Nunca `javascript:`, `file:`, `data:`, `chrome://`…, ni URLs con usuario y contraseña. Correo, X, pagos, bancos y páginas de login están prohibidos.
  - Pestañas y ventanas nuevas bloqueadas salvo `AllowNewTabs: true`. Si aun así aparece una ventana de navegador nueva tras una acción, ManoSegura para, lo registra y quita el modo confianza.
- **Límite de velocidad**: `MaxActionsPerMinute` (60 por defecto) cuenta también los diálogos, para que nadie te llene la pantalla de avisos.
- **Registros locales** (no salen de tu PC): `logs\manosegura.log` (legible) y `logs\audit.jsonl` (cada línea lleva el hash de la anterior). `verify-log` detecta líneas borradas, cambiadas o recortadas al final.
- Lo que **no** protege: un programa que ya tenga control total de tu usuario podría borrar o cambiar los ficheros de estado. ManoSegura evita errores y abusos de un asistente que la usa, no sustituye al antivirus.

### Comandos
| Comando | Qué hace |
|---|---|
| `monitors`, `list-windows`, `status`, `config`, `version` | Información |
| `focus <hwnd\|título>` | Elige la ventana objetivo (por hwnd es lo más fiable) |
| `screenshot [ruta.png]` | Captura la ventana objetivo |
| `screenshot monitor [nombre\|n] [ruta.png]` | Captura un monitor |
| `screenshot hwnd <hwnd> [ruta.png]` | Captura otra ventana |
| `click x y [left\|right\|double]` | Clic (coordenadas relativas a la ventana) |
| `type "texto"` | Escribe tecleando |
| `paste "texto"` | Pega rápido (portapapeles + Ctrl+V, y luego lo restaura) |
| `key ctrl+a` / `enter` / `tab`… | Atajos |
| `scroll [pasos] [x y]` | Rueda (negativo = abajo) |
| `wait [ms]` | Pausa (máx. 10 s; se corta con el pánico) |
| `navigate <url>` | Navega en el navegador objetivo (según `Navigation`) |
| `batch <steps.json\|->` | Lista de pasos con **un solo permiso** (máx. 50; se valida todo antes de preguntar) |
| `check-title`, `check-url`, `check-key <combo> [browser]` | Prueba las reglas |
| `verify-log` | Comprueba la cadena de hashes del registro |
| `disable` / `enable` / `trust-off` | Control |

Opciones: `--dry-run` (o `MANOSEGURA_DRYRUN=1`) simula sin tocar nada; `--json` (o `MANOSEGURA_JSON=1`) devuelve un objeto JSON; `--en` / `--es` cambian el idioma de los errores (o `Language` en la config).
Códigos de salida: `0` OK, `2` rechazado por seguridad o error, `3` cancelado por el usuario, `4` límite de velocidad (espera y reintenta).

### Configuración (`config.json`)
| Clave | Por defecto | Notas |
|---|---|---|
| `TargetMonitor` | `primary` | Ver instalación |
| `ShotsDir` | `shots` | Carpeta de capturas (`latest.png` siempre es la última) |
| `ConfirmTimeoutSec` | `20` | 5–300 |
| `TrustMaxMinutes` | `60` | 1–240 |
| `ExtraBlockedTitles` | `[]` | Solo **añade** bloqueos de títulos |
| `Language` | `es` | `es`, `en` o `both` |
| `Navigation` | `off` | `off`, `allowlist` o `ask` |
| `UrlAllowlist` | `[]` | `example.com` (incluye subdominios) o prefijos `https://github.com/usuario` |
| `ExtraBlockedUrls` | `[]` | Texto que, si aparece en la URL, la bloquea |
| `AllowNewTabs` | `false` | Permitir `Ctrl+T`, `Ctrl+N`… y ventanas nuevas |
| `MaxActionsPerMinute` | `60` | 1–300 |
| `Overlay` | `true` | Borde alrededor de la ventana controlada |
| `GuardIdleMinutes` | `30` | El vigilante se cierra tras ese tiempo sin acciones (vuelve a arrancar solo) |
| `ExtraBrowsers` | `[]` | Nombres de proceso extra que tratar como navegador |

---

## English

### What's new in 1.1
- **Antivirus-friendly**: no `-ExecutionPolicy Bypass`, no hidden windows, no encoded commands. The panic guard is visible: a tray icon, a banner at the bottom of your monitor and an **orange border** around the controlled window (red in trust mode).
- **Safer browsers**: address-bar shortcuts (`Ctrl+L`, `Alt+D`, `F6`…) and typing into the address bar are refused; use `navigate <url>`, which goes through the URL rules and your allowlist. Opening **new tabs or windows** (`Ctrl+T`, `Ctrl+N`, `Ctrl+Shift+N`…) is blocked, and if a new browser window shows up after an action (e.g. Brave opening by itself), it stops and reports it.
- **Rate limit**, a **hash-chained audit log** (`verify-log`), **JSON output** (`--json`), clear Spanish/English errors, per-monitor DPI, and monitors at negative coordinates (e.g. a monitor on the left at X = -1920).
- More hard rules: password managers, antivirus and Windows Security, more webmail and payments, and ManoSegura's own dialogs (the AI cannot click "Allow" for you).

### Install (no Bypass)
1. Download the zip from [Releases](../../releases) and unzip it (e.g. `D:\Tools\ManoSegura`).
2. `Get-ChildItem D:\Tools\ManoSegura -Recurse | Unblock-File`
3. `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (no admin), or pass `-ExecutionPolicy RemoteSigned` on each call.
4. Copy `config.example.json` to `config.json`, run `monitors` and set `TargetMonitor` (`primary`, an index, `left`/`right`, `x=-1920`, a point `-1920,0`, `DISPLAY2`, or part of the monitor ID). The `MANOSEGURA_MONITOR` env var also works.
5. `start-panic` starts the panic guard (it also starts on the first action). If it can't start, ManoSegura refuses to act.

Optional self-signing: see the Spanish section above. The commands are the same, and you must re-sign after every update.

### Antivirus / Kaspersky
Behaviour detection reacts to patterns like `-ExecutionPolicy Bypass`, hidden nested PowerShell, randomly named temp scripts, killing processes and `user32` input calls. Version 1.1 removes everything except what a remote-hand tool fundamentally needs, and it only ever stops its **own** processes, on panic.
To whitelist it in Kaspersky: *Settings* (gear, bottom) → *Security settings* → *Exclusions and actions on object detection* → *Manage exclusions* → *Add* → *Browse* to the ManoSegura folder (or use the *File hash* field with `Get-FileHash .\ManoSegura.ps1`) → *Active* → *Add*.
**Never** add `powershell.exe` as a trusted application or turn off behaviour monitoring. Report false positives at <https://opentip.kaspersky.com/>.

### Safety
- Per-action confirmation dialog on your monitor, DPI-scaled, auto-cancelling after 20 s.
- Trust mode for N minutes (hard cap 240); `trust-off` or the tray menu ends it. A hand-written `trust.txt` with a far-future date is ignored.
- Panic `Ctrl+Alt+P` or the tray menu stops running actions, disables the tool and clears trust. Only `enable` turns it back on, and it always asks and never uses trust mode.
- **Hard rules in code** (config and trust mode can't bypass them): login/password, Gmail/webmail, X/Twitter, payments/banking, password managers, antivirus/Windows Security and ManoSegura's own dialogs. They are checked before acting, after focusing and **after every action**.
- Never types into password fields or the browser address bar. Acts only inside the target window on the target monitor, and checks the window is still in front while typing. Blocks `Win`, `Ctrl+Esc`, `Alt+F4`, `Alt+Tab`, `Ctrl+Alt+Del` and `Ctrl+Shift+Esc`.
- Browsers: `Navigation` is `off` (default), `allowlist` or `ask` (URLs outside the allowlist always ask, even in trust mode). Only `http`/`https`, no embedded credentials, and mail/X/payment/bank/login URLs are refused. New tabs and windows are blocked unless `AllowNewTabs` is set.
- `MaxActionsPerMinute` rate limit (default 60), which also limits dialogs.
- Local logs only: `logs\manosegura.log` and the hash-chained `logs\audit.jsonl` (`verify-log`).

### Commands
Same as the table above. `--dry-run` simulates, `--json` prints one JSON object, and `--en`/`--es` set the message language.
Exit codes: `0` ok, `2` refused/error, `3` cancelled by user, `4` rate limited (wait and retry).

---

## For AI assistants / Para asistentes de IA

```powershell
$M = 'D:\Tools\ManoSegura\ManoSegura.ps1'
function mano { powershell -NoProfile -File $M @args --json | ConvertFrom-Json }   # no -ExecutionPolicy Bypass

(mano list-windows).results | Format-Table Hwnd, Proceso, Titulo, EnMonitor, Bloqueada
mano focus 123456                 # the user approves once (may enable trust mode)
mano screenshot                   # -> results[0].path (also shots\latest.png); LOOK at it
mano click 200 140
mano paste "hello"
mano key enter
mano navigate https://example.com # only if the user set Navigation = allowlist/ask

# One approval for a whole list (max 50 steps, all validated before asking):
$steps = '{"steps":[{"cmd":"focus","args":["123456"]},{"cmd":"key","args":["ctrl+a"]},{"cmd":"paste","args":["hola"]},{"cmd":"wait","args":["300"]},{"cmd":"screenshot","args":[]}]}'
$steps | powershell -NoProfile -File $M batch - --json
```
JSON shape: `{ ok, version, command, dryRun, exitCode, results: [...], notes: [...], error: { id, code, es, en } }`.

Rules for bots:
- Always look at a screenshot before clicking.
- Exit code `3` / `E_CANCELLED` means the user said no: **do not retry**.
- `2` means refused: read `error.id` and `error.en`/`error.es`. `4` means rate limited: wait the seconds given in the message, then continue more slowly.
- Never try to work around the blocked-window, URL or key rules.
- Never run it with `-ExecutionPolicy Bypass` or from hidden or temporary scripts.
- Never open new browser windows or tabs unless the user allowed it.

## Desarrollo / Development
```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser; Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester ./tests -Output Detailed
```
`. .\ManoSegura.ps1` with `$env:MANOSEGURA_LIBRARY = '1'` loads the functions without touching the screen (used by the tests). CI runs on `windows-latest` with Windows PowerShell 5.1 and PowerShell 7.

## Licencia / License
ManoSegura Source-Available License v1.0 (adapted from the CloudTerm SAL). Use it freely; don't modify, redistribute or sell it without permission. See [LICENSE](LICENSE).
