param(
  [string]$Executable = (Join-Path $PSScriptRoot '..\native\build\Release\image_optimizer.exe'),
  [string]$Report = (Join-Path $PSScriptRoot '..\benchmark-results\native.json'),
  [ValidateRange(1, 100)][int]$Iterations = 3
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/images.ps1')
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory $work | Out-Null
try {
  New-ImageCorpus $work
  $records = @()
  foreach ($inputFormat in @('png', 'jpeg', 'bmp', 'tiff')) {
    $inputPath = Join-Path $work "landscape.$inputFormat"
    foreach ($outputFormat in @('png', 'jpeg', 'bmp', 'tiff')) {
      foreach ($quality in @(1, 82, 100)) {
        $samples = @()
        for ($i = 0; $i -le $Iterations; $i++) {
          $outputPath = Join-Path $work "out-$i.$outputFormat"
          $watch = [System.Diagnostics.Stopwatch]::StartNew()
          $result = Invoke-Optimizer $Executable @('--input', $inputPath, '--output', $outputPath, '--format', $outputFormat, '--max-width', '1800', '--max-height', '1800', '--quality', "$quality")
          $watch.Stop()
          if ($result.Code -ne 0) { throw $result.Stderr }
          if ($i -gt 0) { $samples += $watch.Elapsed.TotalMilliseconds }
          Assert-Image $outputPath $outputFormat 1800 900
          $outputBytes = (Get-Item -LiteralPath $outputPath).Length
          Remove-Item -LiteralPath $outputPath -Force
        }
        $sorted = @($samples | Sort-Object)
        $median = if ($sorted.Count % 2) { $sorted[[int][Math]::Floor($sorted.Count / 2)] } else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
        $inputBytes = (Get-Item -LiteralPath $inputPath).Length
        $records += [ordered]@{
          input_format = $inputFormat; output_format = $outputFormat; quality = $quality
          input_dimensions = @(2400, 1200); output_dimensions = @(1800, 900)
          input_sha256 = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
          input_bytes = $inputBytes; output_bytes = $outputBytes
          savings_percent = [Math]::Round((1 - $outputBytes / $inputBytes) * 100, 3)
          median_ms = [Math]::Round($median, 3); samples_ms = $samples
        }
      }
    }
  }
  $reportData = [ordered]@{
    schema_version = 1
    source_commit = (git -C (Split-Path $PSScriptRoot -Parent) rev-parse HEAD)
    source_dirty = (@(git -C (Split-Path $PSScriptRoot -Parent) status --porcelain).Count -gt 0)
    measured_at_utc = [DateTime]::UtcNow.ToString('o')
    os = [Environment]::OSVersion.VersionString
    cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    powershell = $PSVersionTable.PSVersion.ToString()
    binary_sha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
    corpus = 'seed-1701-4000-rectangles-v1'
    warmup_runs_per_case = 1; measured_runs_per_case = $Iterations
    timing_scope = 'Wall time including native process launch and PowerShell invocation wrapper; excludes independent decoding and fixture generation.'
    cases = $records
  }
  $reportPath = [System.IO.Path]::GetFullPath($Report)
  New-Item -ItemType Directory -Force (Split-Path -Parent $reportPath) | Out-Null
  [System.IO.File]::WriteAllText($reportPath, ($reportData | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding))
  Write-Host "Saved 48 benchmark cases to $reportPath"
} finally { Remove-Item -LiteralPath $work -Recurse -Force }
