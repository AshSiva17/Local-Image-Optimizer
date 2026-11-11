param([Parameter(Mandatory = $true)][string]$Directory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/images.ps1')
New-ImageCorpus $Directory
