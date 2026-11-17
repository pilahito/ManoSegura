#Requires -Version 5.1
<#
.SYNOPSIS
    Compila ManoSegura.ps1 en un .exe (requiere el modulo ps2exe).

.EXAMPLE
    .\build.ps1
    .\build.ps1 -OutputDir .\dist

.NOTES
    El .exe sigue necesitando Windows PowerShell 5.1 (incluido en Windows 10/11).
    No esta firmado: algunos antivirus pueden avisar; es normal en ejecutables
    generados a partir de scripts.
#>
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = '2.0.0.0'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'ManoSegura.ps1'
$icon = Join-Path $root 'assets\manosegura.ico'
if (-not (Test-Path -LiteralPath $OutputDir)) { [void](New-Item -ItemType Directory -Path $OutputDir -Force) }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $icon))) { [void](New-Item -ItemType Directory -Path (Split-Path -Parent $icon) -Force) }

function New-ManoIcon {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $size = 64
    $bitmap = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.Clear([System.Drawing.Color]::FromArgb(11, 15, 20))
    $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(61, 220, 151))
    $graphics.FillRectangle($accent, 2, 2, 60, 60)
    $font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $dark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(5, 32, 22))
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = 'Center'
    $format.LineAlignment = 'Center'
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $graphics.DrawString('M', $font, $dark, $rect, $format)
    $graphics.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $png = $stream.ToArray()
    $stream.Dispose()

    $ico = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($ico)
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]1)
    $writer.Write([byte]$size)
    $writer.Write([byte]$size)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]32)
    $writer.Write([UInt32]$png.Length)
    $writer.Write([UInt32]22)
    $writer.Write($png)
    $writer.Flush()
    [IO.File]::WriteAllBytes($Path, $ico.ToArray())
    $writer.Dispose()
    $ico.Dispose()
}

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Output 'Instalando ps2exe...'
    Install-Module ps2exe -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module ps2exe -Force

New-ManoIcon -Path $icon
$exe = Join-Path $OutputDir 'ManoSegura.exe'
Write-Output "Compilando $source -> $exe"
Invoke-ps2exe -InputFile $source -OutputFile $exe -STA -DPIAware -iconFile $icon `
    -title 'ManoSegura' `
    -description 'Mano remota segura para asistentes de IA en Windows' `
    -company 'pilahito' -product 'ManoSegura' `
    -copyright 'Copyright (c) 2026 pilahito' -version $Version -noOutput

$item = Get-Item -LiteralPath $exe
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
Write-Output ("OK: {0} ({1:N0} bytes)  SHA256 {2}" -f $item.FullName, $item.Length, $hash)
