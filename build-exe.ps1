[CmdletBinding()]
param(
  [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'ManoSegura.ps1'
if (-not (Test-Path -LiteralPath $source)) {
  throw "No se encuentra ManoSegura.ps1 en $PSScriptRoot"
}

if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
  Install-Module -Name ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Confirm:$false
  Import-Module ps2exe -ErrorAction Stop
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory 'ManoSegura.exe'
Invoke-PS2EXE -InputFile $source -OutputFile $output -x64 -STA
if (-not (Test-Path -LiteralPath $output)) {
  throw 'La compilacion termino sin generar ManoSegura.exe.'
}

Write-Host "Generado: $output"
Write-Host 'El EXE conserva los comandos de consola y los permisos por accion.'
