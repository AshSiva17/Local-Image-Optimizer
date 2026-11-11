$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/images.ps1')
$hostExecutable = (Get-Process -Id $PID).Path
$previousExitCode = $global:LASTEXITCODE
try {
  $global:LASTEXITCODE = 0
  $success = Invoke-Optimizer $hostExecutable @('-NoProfile', '-Command', "Write-Output 'runner-ok'; exit 0")
  if ($success.Code -ne 0 -or $success.Stdout.Trim() -ne 'runner-ok') { throw 'Successful command capture failed.' }
  $failure = Invoke-Optimizer $hostExecutable @('-NoProfile', '-Command', "[Console]::Error.WriteLine('expected-failure'); exit 7")
  if ($failure.Code -ne 7 -or $failure.Stderr -notmatch 'expected-failure') { throw 'Expected failure was not captured.' }
  if ($global:LASTEXITCODE -ne 0) { throw 'Expected command failure leaked into the caller exit code.' }

  $global:LASTEXITCODE = 17
  $null = Invoke-Optimizer $hostExecutable @('-NoProfile', '-Command', 'exit 0')
  if ($global:LASTEXITCODE -ne 17) { throw 'Preexisting caller exit code was not preserved.' }
  Write-Host 'Native invocation helper preserves caller exit status and returns expected failures as data.'
} finally { $global:LASTEXITCODE = $previousExitCode }
