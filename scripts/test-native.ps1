param([string]$Executable = (Join-Path $PSScriptRoot '..\native\build\Release\image_optimizer.exe'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/images.ps1')
if (!(Test-Path -LiteralPath $Executable)) { throw "Build the native executable first: $Executable" }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory $testDir | Out-Null
try {
  New-ImageCorpus $testDir
  foreach ($inputFormat in @('png', 'jpeg', 'bmp', 'tiff')) {
    $inputPath = Join-Path $testDir "landscape.$inputFormat"
    foreach ($outputFormat in @('png', 'jpeg', 'bmp', 'tiff')) {
      foreach ($quality in @(1, 82, 100)) {
        $outputPath = Join-Path $testDir "$inputFormat-$outputFormat-$quality.$outputFormat"
        $result = Invoke-Optimizer $Executable @('--input', $inputPath, '--output', $outputPath, '--format', $outputFormat, '--max-width', '1800', '--max-height', '1800', '--quality', "$quality")
        if ($result.Code -ne 0) { throw "Conversion failed: $($result.Stderr)" }
        $metadata = $result.Stdout | ConvertFrom-Json
        if ($metadata.width -ne 1800 -or $metadata.height -ne 900 -or $metadata.format -ne $outputFormat) { throw "Incorrect metadata: $($result.Stdout)" }
        if ($metadata.output_size -ne (Get-Item -LiteralPath $outputPath).Length) { throw 'Incorrect byte count.' }
        Assert-Image $outputPath $outputFormat 1800 900
      }
    }
    $keptPath = Join-Path $testDir "kept.$inputFormat"
    $result = Invoke-Optimizer $Executable @('--input', $inputPath, '--output', $keptPath, '--format', 'keep')
    if ($result.Code -ne 0) { throw $result.Stderr }
    Assert-Image $keptPath $inputFormat 2400 1200
  }
  # Quality has a measurable effect on a detailed JPEG; do not assume TIFF/PNG/BMP size monotonicity.
  if ((Get-Item (Join-Path $testDir 'png-jpeg-1.jpeg')).Length -ge (Get-Item (Join-Path $testDir 'png-jpeg-100.jpeg')).Length) { throw 'JPEG quality had no expected file-size effect.' }
  foreach ($case in @(
    @('portrait', '--max-height', '1800', 900, 1800),
    @('landscape', '--max-width', '600', 600, 300),
    @('small', '--max-width', '1800', 320, 160)
  )) {
    $path = Join-Path $testDir "$($case[0])-resized.png"
    $result = Invoke-Optimizer $Executable @('--input', (Join-Path $testDir "$($case[0]).png"), '--output', $path, $case[1], $case[2])
    if ($result.Code -ne 0) { throw $result.Stderr }
    Assert-Image $path 'png' $case[3] $case[4]
  }
  $constrained = Join-Path $testDir 'constrained.png'
  $result = Invoke-Optimizer $Executable @('--input', (Join-Path $testDir 'landscape.png'), '--output', $constrained, '--max-width', '1000', '--max-height', '300')
  if ($result.Code -ne 0) { throw $result.Stderr }
  Assert-Image $constrained 'png' 600 300
  $unicodeDir = Join-Path $testDir ("spaces caf" + [char]0xE9 + ' ' + [char]0x56FE)
  New-Item -ItemType Directory $unicodeDir | Out-Null
  $unicodeInput = Join-Path $unicodeDir ([string][char]0x753B + '.png')
  $unicodeOutput = Join-Path $unicodeDir ([string][char]0x7ED3 + '.jpg')
  Copy-Item (Join-Path $testDir 'small.png') $unicodeInput
  $result = Invoke-Optimizer $Executable @('--input', $unicodeInput, '--output', $unicodeOutput, '--format', 'jpeg')
  if ($result.Code -ne 0) { throw $result.Stderr }
  $metadata = $result.Stdout | ConvertFrom-Json
  if ($metadata.input -ne $unicodeInput -or $metadata.output -ne $unicodeOutput) { throw 'Unicode paths did not round-trip through JSON.' }
  Assert-Image $unicodeOutput 'jpeg' 320 160

  $valid = Join-Path $testDir 'small.png'
  $invalidCases = @(
    @('--quality', '0'), @('--quality', '101'), @('--quality', 'abc'),
    @('--max-width', '-1'), @('--max-height', '0'), @('--max-width', '4294967296'),
    @('--format', 'gif'), @('--unknown', 'value'), @('--quality', '82', '--quality', '50'),
    @('--max-width'), @('--input', (Join-Path $testDir 'missing.png')),
    @('--input', (Join-Path $testDir 'corrupt.png')), @('--input', (Join-Path $testDir 'unsupported.gif'))
  )
  foreach ($case in $invalidCases) {
    $output = Join-Path $testDir 'invalid-output.png'
    # Input replacement avoids accidentally only testing duplicate-option rejection.
    $arguments = @('--input', $valid, '--output', $output)
    if ($case[0] -eq '--input') { $arguments = @('--output', $output) }
    $result = Invoke-Optimizer $Executable ($arguments + $case)
    if ($result.Code -eq 0 -or [string]::IsNullOrWhiteSpace($result.Stderr)) { throw "Invalid input was accepted: $case" }
    if (Test-Path -LiteralPath $output) { throw 'Failure left a partial output.' }
  }
  $result = Invoke-Optimizer $Executable @('--output', (Join-Path $testDir 'missing-input.png'))
  if ($result.Code -eq 0) { throw 'Missing input argument was accepted.' }
  $result = Invoke-Optimizer $Executable @('--input', $valid)
  if ($result.Code -eq 0) { throw 'Missing output argument was accepted.' }
  $result = Invoke-Optimizer $Executable @('--input', $valid, '--output', (Join-Path $testDir 'missing-directory/output.png'))
  if ($result.Code -eq 0) { throw 'Invalid output path was accepted.' }
  $hash = (Get-FileHash -LiteralPath $valid -Algorithm SHA256).Hash
  $result = Invoke-Optimizer $Executable @('--input', $valid, '--output', $valid)
  if ($result.Code -eq 0 -or (Get-FileHash -LiteralPath $valid -Algorithm SHA256).Hash -ne $hash) { throw 'Input overwrite protection failed.' }
  Write-Host 'Native integration tests passed (48 conversions, formats, dimensions, quality, Unicode, invalid inputs).'
} finally { Remove-Item -LiteralPath $testDir -Recurse -Force }
