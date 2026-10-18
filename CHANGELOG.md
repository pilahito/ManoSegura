# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versiones [SemVer](https://semver.org/lang/es/).

## [1.1.0] - 2026-10-18

### Antivirus / instalación
- Ya no hace falta `-ExecutionPolicy Bypass`. README con instalación `Unblock-File` + `RemoteSigned` (o `-ExecutionPolicy RemoteSigned` por llamada), firma propia opcional y una sección para Kaspersky (exclusión por carpeta o hash; nunca confiar en `powershell.exe`).
- El vigilante de pánico ya no es un PowerShell oculto con `Bypass`. Ahora es un proceso visible (consola minimizada) con **icono en la bandeja**, **cartel** en el monitor objetivo y menú (pánico, quitar confianza, abrir registros, cerrar). Se cierra solo tras `GuardIdleMinutes` sin acciones.
- Sin Base64, `-EncodedCommand`, `Invoke-Expression`, descargas ni scripts temporales. Un test lo comprueba.

### Seguridad (las reglas de la 1.0 se mantienen todas)
- `navigate <url>`: única forma de usar la barra de direcciones. Solo `http`/`https`, sin credenciales en la URL, con bloqueo duro de correo, X, pagos, bancos y login. Modos `Navigation` `off` (por defecto), `allowlist` o `ask`; fuera de `UrlAllowlist` siempre pregunta, aunque haya modo confianza.
- En navegadores se bloquean los atajos de barra de direcciones (`Ctrl+L`, `Alt+D`, `F6`, `Ctrl+E`, `Ctrl+K`…), escribir o pegar en la barra de direcciones y abrir pestañas o ventanas nuevas (`Ctrl+T`, `Ctrl+N`, `Ctrl+Shift+N`, `Ctrl+Shift+T`, `Ctrl+Shift+P`, `Alt+Enter`…) salvo `AllowNewTabs`.
- Tras cada acción se comprueba que no haya aparecido ninguna ventana de navegador nueva y que la ventana no haya pasado a una página prohibida. Si ocurre, para y quita el modo confianza.
- Límite de velocidad `MaxActionsPerMinute` (60 por defecto, tope 300), compartido entre procesos. Código de salida `4`.
- Borde visible (naranja; rojo en modo confianza) alrededor de la ventana controlada. No roba el foco y deja pasar los clics.
- Registro de auditoría `logs/audit.jsonl` con cadena de hashes SHA-256 y `state/audit.head`. Nuevo comando `verify-log`.
- Nuevas reglas duras de títulos: gestores de contraseñas, antivirus o seguridad de Windows o UAC, más correo web y pagos, y los diálogos de ManoSegura.
- `Alt+Tab`, `Alt+Esc` y `Ctrl+Esc` bloqueados. `Alt+F4` se bloquea con cualquier modificador extra.
- `type` escribe en trozos y comprueba entre trozos que la ventana objetivo sigue al frente y que no se ha pulsado pánico. `wait` también se corta con el pánico.
- `enable` ya no borra la marca de desactivado antes de que confirmes.
- `TrustMaxMinutes` con tope duro de 240. Se ignoran ficheros `trust.txt` con caducidad imposible.
- `batch` valida todos los pasos (teclas y URLs) antes de pedir permiso. `screenshot` solo guarda `.png`.

### Robustez
- DPI por monitor (Per-Monitor v2, con alternativas) y diálogo escalado al DPI del monitor.
- Monitores con coordenadas negativas: `TargetMonitor` acepta `left`/`right`, `x=-1920`, un punto `-1920,0` y `DISPLAY2`.
- Errores con id estable y texto en español e inglés (`Language`, `--en`, `--es`).
- `--json` (o `MANOSEGURA_JSON=1`): un objeto JSON por llamada, solo ASCII y válido con cualquier página de códigos.
- `config.json` validado, con mensajes claros (tipos, rangos, opciones).
- Nuevos comandos: `config`, `check-url`, `check-key`, `verify-log`.

### Calidad
- PSScriptAnalyzer limpio (`PSScriptAnalyzerSettings.psd1`).
- Tests Pester en `tests/`.
- GitHub Actions en `windows-latest` con Windows PowerShell 5.1 y PowerShell 7.
- Dot-sourcing con `MANOSEGURA_LIBRARY=1` para tests.

### Cambios incompatibles
- En navegadores, `key ctrl+l` + `paste url` ya no funciona: usa `navigate <url>` y pon `Navigation` en `allowlist` o `ask`.
- Si el vigilante de pánico no puede arrancar, las acciones se rechazan (`E_GUARD`) en lugar de seguir sin pánico.

## [1.0.0] - 2026-10-16
- Primera versión.
