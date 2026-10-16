# ManoSegura 🖐️🔒

**ES** · Una "mano remota" segura para que un asistente de IA controle **una sola ventana** en **un monitor elegido** de Windows, siempre con tu permiso.
**EN** · A safe "remote hand" that lets an AI assistant control **one window** on **one chosen monitor** in Windows — always with your permission.

PowerShell 5.1+, un solo archivo, sin descargas, sin admin. / Single file, no downloads, no admin.

---

## Español

### Instalación
1. Descarga el zip de [Releases](../../releases) y descomprímelo (p. ej. `D:\Tools\ManoSegura`).
2. Copia `config.example.json` a `config.json` y elige el monitor:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\ManoSegura.ps1 monitors
   ```
   Pon en `TargetMonitor`: `primary`, un índice (`1`), el nombre (`\\.\DISPLAY2`) o parte del ID del monitor (`ACR`, `DEL`...).
   También vale la variable de entorno `MANOSEGURA_MONITOR`.
3. Arranca la escucha de pánico: `.\ManoSegura.ps1 start-panic` (se arranca sola en la primera acción).

### Seguridad
- **Permiso por acción**: aparece un diálogo en tu monitor (Permitir / Cancelar; se cancela solo a los 20 s).
- **Modo confianza**: marca la casilla para permitir sin preguntar durante N minutos (máx. configurable). `trust-off` lo quita.
- **Pánico `Ctrl+Alt+P`**: mata las acciones en curso, desactiva ManoSegura y borra el modo confianza. Solo tú puedes reactivarla con `enable` (siempre pide confirmación).
- **Reglas duras en el código (no se desactivan ni con modo confianza)**: rechaza ventanas de **login/contraseña**, **Gmail/correo web**, **X/Twitter** y **pagos/banca** (PayPal, Stripe, checkout, tarjeta, banco, cripto…). Se comprueba antes *y después* de enfocar.
- Nunca escribe en campos de contraseña (UI Automation `IsPassword`).
- Solo actúa dentro de la ventana objetivo y en el monitor objetivo. Bloquea `Win`, `Alt+F4`, `Ctrl+Alt+Supr`, `Ctrl+Shift+Esc`.
- Registro local en `logs\manosegura.log` (no sale de tu PC).

### Comandos
| Comando | Qué hace |
|---|---|
| `monitors`, `list-windows`, `status`, `version` | Información |
| `focus <hwnd\|título>` | Elige ventana objetivo (por hwnd es lo más fiable) |
| `screenshot [ruta.png]` | Captura la ventana objetivo |
| `screenshot monitor [nombre\|n] [ruta.png]` | Captura un monitor |
| `screenshot hwnd <hwnd> [ruta.png]` | Captura otra ventana |
| `click x y [left\|right\|double]` | Clic (coordenadas relativas a la ventana) |
| `type "texto"` | Escribe tecleando |
| `paste "texto"` | Pega rápido (portapapeles + Ctrl+V, restaura el portapapeles) |
| `key ctrl+l` / `enter` / `tab`… | Atajos |
| `scroll [pasos] [x y]` | Rueda (negativo = abajo) |
| `wait [ms]` | Pausa (máx. 10 s) |
| `batch <steps.json>` | Lista de pasos con **un solo permiso** (máx. 50) |
| `check-title "título"` | Prueba las reglas de bloqueo |
| `disable` / `enable` / `trust-off` | Control |

Añade `--dry-run` (o `MANOSEGURA_DRYRUN=1`) para simular sin tocar nada.
Cada captura también se copia a `shots\latest.png`. Cambia la carpeta con `ShotsDir`.
Códigos de salida: `0` OK, `2` rechazado por seguridad/error, `3` cancelado por el usuario.

---

## English

### Install
1. Download the zip from [Releases](../../releases) and unzip it.
2. Copy `config.example.json` to `config.json`, run `monitors` and set `TargetMonitor` to `primary`, an index, a device name (`\\.\DISPLAY2`) or part of the monitor ID. Env var `MANOSEGURA_MONITOR` also works.
3. `start-panic` starts the panic listener (also auto-started on the first action).

### Safety
- **Per-action confirmation** dialog on your monitor (auto-cancels after 20 s).
- **Trust mode**: tick the box to allow actions without asking for N minutes. `trust-off` ends it.
- **Panic `Ctrl+Alt+P`**: kills running actions, disables the tool, clears trust. Only `enable` (always confirmed) turns it back on.
- **Hard rules in code (trust mode can't bypass them)**: refuses **login/password** pages, **Gmail/webmail**, **X/Twitter** and **payment/banking** windows. Checked before *and after* focusing.
- Never types into password fields. Acts only inside the target window on the target monitor. Blocks `Win`, `Alt+F4`, `Ctrl+Alt+Del`, `Ctrl+Shift+Esc`.
- Local log only (`logs\manosegura.log`).

### Commands
Same as the table above. `--dry-run` simulates. Exit codes: `0` ok, `2` refused/error, `3` cancelled by user.

---

## For AI assistants / Para asistentes de IA

```powershell
$M = 'D:\Tools\ManoSegura\ManoSegura.ps1'
function mano { powershell -NoProfile -ExecutionPolicy Bypass -File $M @args }

mano list-windows                 # find the hwnd
mano focus 123456                 # user approves once (can enable trust mode)
mano screenshot                   # -> shots\latest.png, look at it
mano click 200 140
mano paste "hello"
mano key enter

# Or one approval for everything: write the steps to a JSON file
$steps = '{"steps":[{"cmd":"focus","args":["123456"]},{"cmd":"key","args":["ctrl+l"]},{"cmd":"paste","args":["https://example.com"]},{"cmd":"key","args":["enter"]},{"cmd":"wait","args":["800"]},{"cmd":"screenshot","args":[]}]}'
$f = Join-Path $env:TEMP 'mano_steps.json'; Set-Content $f $steps -Encoding UTF8
mano batch $f
```
Rules for bots: always look at a screenshot before clicking; if you get exit code `3`, the user said no — do not retry; if `2`, read the message; never try to work around the blocked-window rules.

## Licencia / License
ManoSegura Source-Available License v1.0 (adapted from the CloudTerm SAL). Use it freely; don't modify, redistribute or sell it without permission. See [LICENSE](LICENSE).
