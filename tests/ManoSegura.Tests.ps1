#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $script:RepoRoot = Split-Path -Parent $base
    $env:MANOSEGURA_LIBRARY = '1'
    . (Join-Path $script:RepoRoot 'ManoSegura.ps1')
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('manosegura-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    Initialize-ManoEnvironment -RootPath $script:TestRoot
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\MANOSEGURA_LIBRARY -ErrorAction SilentlyContinue
}

Describe 'Configuracion' {
    It 'la configuracion por defecto tiene las claves esperadas' {
        $cfg = Get-ManoDefaultConfig
        $cfg.Keys | Should -Contain 'TargetMonitor'
        $cfg.Keys | Should -Contain 'ConfirmMode'
        $cfg.Keys | Should -Contain 'PanicHotkey'
        $cfg.Keys | Should -Contain 'AiName'
        $cfg.Keys | Should -Contain 'ShowAiLabel'
        $cfg.Keys | Should -HaveCount 15
        $cfg.ConfirmMode | Should -Be 'ask'
        $cfg.PanicHotkey | Should -Be 'Ctrl+Alt+P'
    }

    It 'importa valores validos de config.json' {
        $path = Join-Path $script:TestRoot 'config-valid.json'
        '{"TargetMonitor":"left","ConfirmMode":"auto","TrustMaxMinutes":30,"ShotFormat":"jpg","BlockedTitles":["Ventas"]}' |
            Set-Content -LiteralPath $path -Encoding UTF8
        $loaded = Import-ManoConfig -Path $path
        $loaded.Config.TargetMonitor | Should -Be 'left'
        $loaded.Config.ConfirmMode | Should -Be 'auto'
        $loaded.Config.TrustMaxMinutes | Should -Be 30
        $loaded.Config.ShotFormat | Should -Be 'jpg'
        @($loaded.Config.BlockedTitles) | Should -HaveCount 1
        $loaded.Warnings | Should -HaveCount 0
    }

    It 'corrige valores invalidos y avisa' {
        $path = Join-Path $script:TestRoot 'config-invalid.json'
        '{"ConfirmMode":"loco","ConfirmTimeoutSec":99999,"TrustMaxMinutes":0,"ShotFormat":"bmp","PanicHotkey":"ctrl+win+x"}' |
            Set-Content -LiteralPath $path -Encoding UTF8
        $loaded = Import-ManoConfig -Path $path
        $loaded.Config.ConfirmMode | Should -Be 'ask'
        $loaded.Config.ConfirmTimeoutSec | Should -Be 300
        $loaded.Config.TrustMaxMinutes | Should -Be 1
        $loaded.Config.ShotFormat | Should -Be 'png'
        $loaded.Config.PanicHotkey | Should -Be 'Ctrl+Alt+P'
        $loaded.Warnings.Count | Should -BeGreaterThan 0
    }

    It 'config.json ilegible usa valores por defecto con aviso' {
        $path = Join-Path $script:TestRoot 'config-broken.json'
        '{ esto no es json' | Set-Content -LiteralPath $path -Encoding UTF8
        $loaded = Import-ManoConfig -Path $path
        $loaded.Config.ConfirmMode | Should -Be 'ask'
        $loaded.Warnings.Count | Should -BeGreaterThan 0
    }

    It 'permite cambiar un ajuste y lo guarda' {
        Set-ManoConfigValue -Key 'ClickDelayMs' -Value '55' | Out-Null
        $script:Cfg.ClickDelayMs | Should -Be 55
        (Import-ManoConfig -Path $script:ConfigFile).Config.ClickDelayMs | Should -Be 55
        { Set-ManoConfigValue -Key 'NoExiste' -Value '1' } | Should -Throw
    }
}

Describe 'Reglas de seguridad' {
    It 'bloquea titulos de login, correo y pagos' {
        Test-ManoTitleBlocked -Title 'Iniciar sesion - Gmail' | Should -BeTrue
        Test-ManoTitleBlocked -Title 'Sign in to PayPal' | Should -BeTrue
        Test-ManoTitleBlocked -Title 'Escribe tu contrasena' | Should -BeTrue
        Test-ManoTitleBlocked -Title 'Banco Santander - Banca online' | Should -BeTrue
    }

    It 'permite titulos normales' {
        Test-ManoTitleBlocked -Title 'Bloc de notas' | Should -BeFalse
        Test-ManoTitleBlocked -Title 'Documento1 - Word' | Should -BeFalse
        Test-ManoTitleBlocked -Title '' | Should -BeFalse
    }

    It 'aplica la lista extra de titulos bloqueados' {
        Test-ManoTitleBlocked -Title 'Tienda Ventas privadas' -Extra @('Ventas') | Should -BeTrue
        Test-ManoTitleBlocked -Title 'Calculadora' -Extra @('Ventas') | Should -BeFalse
    }

    It 'la regex incluye la lista extra' {
        Get-ManoBlockRegex -Extra @('Hipoteca') | Should -Match 'Hipoteca'
    }
}

Describe 'Teclas y combinaciones' {
    It 'convierte combinaciones validas a SendKeys' {
        (Convert-ManoKeyCombo 'ctrl+s').SendKeys | Should -Be '^s'
        (Convert-ManoKeyCombo 'enter').SendKeys | Should -Be '{ENTER}'
        (Convert-ManoKeyCombo 'alt+f1').SendKeys | Should -Be '%{F1}'
        (Convert-ManoKeyCombo 'ctrl+shift+t').SendKeys | Should -Be '^+t'
        (Convert-ManoKeyCombo 'intro').Normalized | Should -Be 'enter'
    }

    It 'rechaza combinaciones peligrosas o invalidas' {
        { Convert-ManoKeyCombo 'win+r' } | Should -Throw '*Windows*'
        { Convert-ManoKeyCombo 'alt+f4' } | Should -Throw '*bloqueada*'
        { Convert-ManoKeyCombo 'ctrl+alt+delete' } | Should -Throw '*bloqueada*'
        { Convert-ManoKeyCombo 'ctrl+ab' } | Should -Throw '*desconocida*'
        { Convert-ManoKeyCombo '' } | Should -Throw '*vacia*'
    }

    It 'convierte el atajo de panico a codigo nativo' {
        $hotkey = Convert-ManoHotkey 'Ctrl+Alt+P'
        $hotkey.Modifiers | Should -Be 3
        $hotkey.VirtualKey | Should -Be 80
        { Convert-ManoHotkey 'ctrl+alt+@' } | Should -Throw
    }
}

Describe 'Batch' {
    It 'convierte un array de pasos' {
        $steps = Convert-ManoBatch -Json '[{"cmd":"click","args":[10,20]},{"cmd":"key","args":["ctrl+s"]}]'
        $steps | Should -HaveCount 2
        $steps[0].Cmd | Should -Be 'click'
        $steps[1].Cmd | Should -Be 'key'
        $steps[1].Args[0] | Should -Be 'ctrl+s'
    }

    It 'acepta un objeto con steps' {
        $steps = Convert-ManoBatch -Json '{"steps":[{"cmd":"wait","args":[100]}]}'
        $steps | Should -HaveCount 1
        $steps[0].Cmd | Should -Be 'wait'
    }

    It 'rechaza comandos no permitidos' {
        { Convert-ManoBatch -Json '[{"cmd":"powershell","args":["x"]}]' } | Should -Throw '*no permitido*'
    }

    It 'rechaza JSON invalido, vacio y demasiados pasos' {
        { Convert-ManoBatch -Json 'no json' } | Should -Throw '*JSON*'
        { Convert-ManoBatch -Json '[]' } | Should -Throw '*no hay pasos*'
        { Convert-ManoBatch -Json '[{"cmd":"wait"},{"cmd":"wait"}]' -MaxSteps 1 } | Should -Throw '*maximo*'
    }

    It 'rechaza argumentos que no son primitivos' {
        { Convert-ManoBatch -Json '[{"cmd":"click","args":[{"x":1}]}]' } | Should -Throw '*argumentos*'
    }
}

Describe 'Monitores' {
    BeforeAll {
        Add-Type -AssemblyName System.Drawing
        $script:MonitorA = [pscustomobject]@{ DeviceName = '\\.\DISPLAY1'; Bounds = [System.Drawing.Rectangle]::new(0, 0, 1920, 1080); Primary = $true; MonitorId = 'AOC 24' }
        $script:MonitorB = [pscustomobject]@{ DeviceName = '\\.\DISPLAY2'; Bounds = [System.Drawing.Rectangle]::new(-1920, 0, 1920, 1080); Primary = $false; MonitorId = 'DELL P2419H' }
        $script:Monitors = @($script:MonitorA, $script:MonitorB)
    }

    It 'elige el primario por defecto' {
        (Select-ManoMonitor -Monitors $script:Monitors -Spec 'primary').DeviceName | Should -Be '\\.\DISPLAY1'
        (Select-ManoMonitor -Monitors $script:Monitors -Spec '').DeviceName | Should -Be '\\.\DISPLAY1'
    }

    It 'elige por indice, izquierda y derecha' {
        (Select-ManoMonitor -Monitors $script:Monitors -Spec '1').DeviceName | Should -Be '\\.\DISPLAY2'
        (Select-ManoMonitor -Monitors $script:Monitors -Spec 'left').DeviceName | Should -Be '\\.\DISPLAY2'
        (Select-ManoMonitor -Monitors $script:Monitors -Spec 'right').DeviceName | Should -Be '\\.\DISPLAY1'
    }

    It 'elige por coordenada, punto o identificador' {
        (Select-ManoMonitor -Monitors $script:Monitors -Spec 'x=-1920').DeviceName | Should -Be '\\.\DISPLAY2'
        (Select-ManoMonitor -Monitors $script:Monitors -Spec '-100,100').DeviceName | Should -Be '\\.\DISPLAY2'
        (Select-ManoMonitor -Monitors $script:Monitors -Spec 'DELL').MonitorId | Should -Be 'DELL P2419H'
    }

    It 'devuelve null si no encuentra el monitor' {
        Select-ManoMonitor -Monitors $script:Monitors -Spec '9' | Should -BeNullOrEmpty
        Select-ManoMonitor -Monitors $script:Monitors -Spec 'no-existe' | Should -BeNullOrEmpty
        Select-ManoMonitor -Monitors @() -Spec 'primary' | Should -BeNullOrEmpty
    }
}

Describe 'Geometria' {
    It 'comprueba puntos y rectangulos' {
        $inner = [System.Drawing.Rectangle]::new(10, 10, 100, 50)
        $outer = [System.Drawing.Rectangle]::new(0, 0, 200, 100)
        Test-ManoPointInRect 20 20 $inner | Should -BeTrue
        Test-ManoPointInRect 5 5 $inner | Should -BeFalse
        Test-ManoPointInRect 110 60 $inner | Should -BeFalse
        Test-ManoRectInside $inner $outer | Should -BeTrue
        Test-ManoRectInside $inner ([System.Drawing.Rectangle]::new(50, 0, 200, 100)) | Should -BeFalse
        Format-ManoRect $inner | Should -Be '10,10 100x50'
    }
}

Describe 'Estado y confianza' {
    It 'activa y desactiva ManoSegura' {
        Set-ManoDisabled -Disabled $true
        Test-ManoDisabled | Should -BeTrue
        Set-ManoDisabled -Disabled $false
        Test-ManoDisabled | Should -BeFalse
    }

    It 'el modo confianza caduca con la fecha guardada' {
        Set-ManoTrustMinutes 5 | Out-Null
        Test-ManoTrustActive | Should -BeTrue
        Clear-ManoTrust
        Test-ManoTrustActive | Should -BeFalse
    }

    It 'valida la fecha de confianza' {
        $now = Get-Date
        Test-ManoTrustValue ($now.AddMinutes(5).ToString('o')) $now 120 | Should -BeTrue
        Test-ManoTrustValue ($now.AddMinutes(-5).ToString('o')) $now 120 | Should -BeFalse
        Test-ManoTrustValue ($now.AddMinutes(200).ToString('o')) $now 120 | Should -BeFalse
        Test-ManoTrustValue 'no es una fecha' $now 120 | Should -BeFalse
    }
}

Describe 'Utilidades' {
    It 'recorta texto largo' {
        Get-ManoClipped 'abcdef' 3 | Should -Be 'abc...'
        Get-ManoClipped 'abc' 10 | Should -Be 'abc'
        Get-ManoClipped $null 10 | Should -Be ''
    }

    It 'la ayuda menciona los comandos principales' {
        $help = Get-ManoHelpText
        foreach ($token in @('ui', 'list', 'use', 'shot', 'click', 'type', 'key', 'drag', 'batch', 'trust', 'panic', 'config')) {
            $help | Should -Match ([regex]::Escape($token))
        }
    }
}

Describe 'Nombre de la IA' {
    It 'usa IA por defecto' {
        Remove-Item -LiteralPath $script:AiFile -Force -ErrorAction SilentlyContinue
        $script:Cfg.AiName = 'IA'
        Get-ManoAiName | Should -Be 'IA'
    }

    It 'guarda y devuelve el nombre de la IA' {
        Set-ManoAiName 'Claude' | Should -Be 'Claude'
        Get-ManoAiName | Should -Be 'Claude'
        (Get-Content -LiteralPath $script:AiFile -Raw).Trim() | Should -Be 'Claude'
    }

    It 'usa el nombre configurado si no hay estado guardado' {
        Remove-Item -LiteralPath $script:AiFile -Force -ErrorAction SilentlyContinue
        $script:Cfg.AiName = 'Copilot'
        Get-ManoAiName | Should -Be 'Copilot'
    }

    It 'la variable de entorno tiene prioridad' {
        $env:MANOSEGURA_AI_NAME = 'Gemini'
        Get-ManoAiName | Should -Be 'Gemini'
        Remove-Item Env:\MANOSEGURA_AI_NAME -ErrorAction SilentlyContinue
    }

    It 'limpia y valida el nombre' {
        { Set-ManoAiName '' } | Should -Throw
        $long = ('x' * 50)
        Set-ManoAiName $long | Should -Be ('x' * 32)
    }
}

Describe 'Tiempo de confianza' {
    It 'entiende presets y formatos de tiempo' {
        Convert-ManoTrustSpec '10m' | Should -Be 10
        Convert-ManoTrustSpec '30' | Should -Be 30
        Convert-ManoTrustSpec '1h' | Should -Be 60
        Convert-ManoTrustSpec '2h' | Should -Be 120
        Convert-ManoTrustSpec '3h' | Should -Be 180
        Convert-ManoTrustSpec '90m' | Should -Be 90
        Convert-ManoTrustSpec '1h30m' | Should -Be 90
        Convert-ManoTrustSpec '1.5h' | Should -Be 90
        Convert-ManoTrustSpec '45 min' | Should -Be 45
        { Convert-ManoTrustSpec 'luego' } | Should -Throw
        { Convert-ManoTrustSpec '0m' } | Should -Throw
        { Convert-ManoTrustSpec '' } | Should -Throw
    }

    It 'anade tiempo sobre la confianza activa' {
        Clear-ManoTrust
        [void](Set-ManoTrustMinutes 10)
        $result = Add-ManoTrustMinutes 20
        $result.Extended | Should -BeTrue
        $result.TotalMinutes | Should -BeGreaterThan 25
        $result.TotalMinutes | Should -BeLessOrEqual 31
        Get-ManoTrustRemainingMinutes | Should -BeGreaterThan 25
    }

    It 'respeta TrustMaxMinutes al ampliar' {
        Clear-ManoTrust
        $script:Cfg.TrustMaxMinutes = 60
        [void](Set-ManoTrustMinutes 30)
        $result = Add-ManoTrustMinutes 120
        $result.Capped | Should -BeTrue
        $result.TotalMinutes | Should -BeLessOrEqual 61
        $script:Cfg.TrustMaxMinutes = 120
    }

    It 'si la confianza caduco empieza desde ahora' {
        Clear-ManoTrust
        (Get-Date).AddMinutes(-5).ToString('o') | Set-Content -LiteralPath $script:TrustFile
        $result = Add-ManoTrustMinutes 10
        $result.Extended | Should -BeFalse
        $result.TotalMinutes | Should -BeLessOrEqual 11
    }

    It 'sin confianza no hay minutos restantes' {
        Clear-ManoTrust
        Get-ManoTrustRemainingMinutes | Should -Be 0
    }
}
