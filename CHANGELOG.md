# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versiones [SemVer](https://semver.org/lang/es/).

## [2.0.0] - 2026-11-17

### Añadido
- **Interfaz gráfica** (`ui`, o sin argumentos): pestañas de Ventanas, Acciones, Ajustes y Registro; lista de ventanas con hwnd/proceso/título/monitor/bloqueada; botones de pánico, activar y confiar; borde visible sobre la ventana objetivo y atajo global de pánico.
- Comandos `drag`, `focus` (también dentro de batch), `config set`, `monitors`.
- Opciones globales `--yes`, `--dry-run` y `--format png|jpg`.
- Ajustes nuevos: `ConfirmMode` (`ask`/`auto`), `ClickDelayMs`, `MaxBatchSteps`, `BlockedTitles`, `ShotFormat`, `LogLines`, `PanicHotkey`.
- **Tiempo de confianza ampliable**: presets 10 min / 30 min / 1 h / 2 h / 3 h o personalizado en la interfaz, con boton **Ampliar tiempo** y **Quitar**; por CLI `trust 1h`, `trust add 30m` o `trust +30m`.
- Ejemplo de batch actualizado y `config.example.json` nuevo.
- Tests Pester 5 reescritos y CI para PowerShell 5.1 y 7.

### Cambiado
- La seguridad pasa a ser **más simple**: una ventana y un monitor, permiso (o confianza), bloqueo de contraseñas/correo/pagos, pánico y registro. Se mantiene el bloqueo de campos de contraseña por UI Automation.
- El modo confianza tiene tope (`TrustMaxMinutes`) y caducidad real; ya no hay proceso vigilante obligatorio: el atajo de pánico se registra mientras la interfaz está abierta.
- Los errores son textos claros; códigos de salida 0/1/2.

### Eliminado
- Cadena de hashes de auditoría con SHA-256 y `verify-log` (queda un registro de texto simple).
- Proceso vigilante separado, banner/consola minimizada y modo `-ExecutionPolicy Bypass`.
- Reglas especiales de navegadores (barra de direcciones, pestañas nuevas), listas de URLs, `navigate`, JSON de salida y sistema bilingüe de mensajes de la 1.1.
- Límite de acciones por minuto y cadena de auditoría: menos protocolo, menos fricción.

### Seguridad
- La ventana debe estar entera en el monitor objetivo.
- `type`/`paste` comprueban el campo enfocado y se niegan a escribir en contraseñas.
- Títulos de login, correo, pagos y banca bloqueados por defecto (ampliable).
- `panic` desactiva ManoSegura, revoca la confianza y detiene los batch en el siguiente paso.

### Notas
- Probado en Windows 11 con PowerShell 5.1; la CI cubre PowerShell 5.1 y 7.
- La 1.0.0 sigue disponible en el historial de git.

## [1.0.0] - 2026-10-16
- Primera versión: una ventana, un monitor, permiso por acción, modo confianza, pánico, capturas y CLI.
