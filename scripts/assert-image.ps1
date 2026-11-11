param(
  [Parameter(Mandatory = $true)][string]$Path,
  [Parameter(Mandatory = $true)][string]$Format,
  [Parameter(Mandatory = $true)][int]$Width,
  [Parameter(Mandatory = $true)][int]$Height
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/images.ps1')
Assert-Image $Path $Format $Width $Height
