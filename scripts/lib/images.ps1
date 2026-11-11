# Windows-only helpers. GDI+ supplies an independent decoder for WIC test outputs.
Add-Type -AssemblyName System.Drawing
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
$OutputEncoding = [Console]::OutputEncoding

function New-ImageCorpus([string]$Directory) {
  New-Item -ItemType Directory -Force $Directory | Out-Null
  $formats = [ordered]@{
    png = [System.Drawing.Imaging.ImageFormat]::Png
    jpeg = [System.Drawing.Imaging.ImageFormat]::Jpeg
    bmp = [System.Drawing.Imaging.ImageFormat]::Bmp
    tiff = [System.Drawing.Imaging.ImageFormat]::Tiff
  }
  # Fixed seed and drawing operations make the source reproducible; hashes record encoder differences.
  $bitmap = New-Object System.Drawing.Bitmap 2400, 1200
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.Clear([System.Drawing.Color]::White)
    $random = New-Object System.Random 1701
    for ($i = 0; $i -lt 4000; $i++) {
      $color = [System.Drawing.Color]::FromArgb(255, $random.Next(256), $random.Next(256), $random.Next(256))
      $brush = New-Object System.Drawing.SolidBrush $color
      try { $graphics.FillRectangle($brush, $random.Next(2400), $random.Next(1200), $random.Next(1, 80), $random.Next(1, 80)) }
      finally { $brush.Dispose() }
    }
    foreach ($format in $formats.Keys) { $bitmap.Save((Join-Path $Directory "landscape.$format"), $formats[$format]) }
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  foreach ($shape in @(@('portrait', 1200, 2400), @('small', 320, 160))) {
    $image = New-Object System.Drawing.Bitmap $shape[1], $shape[2]
    try { $image.Save((Join-Path $Directory "$($shape[0]).png"), $formats.png) }
    finally { $image.Dispose() }
  }
  [System.IO.File]::WriteAllText((Join-Path $Directory 'corrupt.png'), 'This is not an image.')
  # GIF is decodable by WIC but outside this application's four-format contract.
  $gif = New-Object System.Drawing.Bitmap 16, 16
  try { $gif.Save((Join-Path $Directory 'unsupported.gif'), [System.Drawing.Imaging.ImageFormat]::Gif) }
  finally { $gif.Dispose() }
}

function Assert-Image([string]$Path, [string]$Format, [int]$Width, [int]$Height) {
  if (!(Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -le 0) { throw "Missing or empty image: $Path" }
  $expected = switch ($Format) {
    'png' { [System.Drawing.Imaging.ImageFormat]::Png.Guid }
    'jpeg' { [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid }
    'bmp' { [System.Drawing.Imaging.ImageFormat]::Bmp.Guid }
    'tiff' { [System.Drawing.Imaging.ImageFormat]::Tiff.Guid }
    default { throw "Unknown expected format: $Format" }
  }
  $image = [System.Drawing.Image]::FromFile($Path)
  try {
    if ($image.Width -ne $Width -or $image.Height -ne $Height) { throw "Wrong dimensions in $Path : $($image.Width)x$($image.Height), expected ${Width}x${Height}" }
    if ($image.RawFormat.Guid -ne $expected) { throw "Wrong encoded format in $Path (expected $Format)" }
    # Force pixel decoding too; opening a header alone is insufficient.
    $decoded = New-Object System.Drawing.Bitmap $image
    try { $null = $decoded.GetPixel(0, 0); $null = $decoded.GetPixel(($Width - 1), ($Height - 1)) }
    finally { $decoded.Dispose() }
  } finally { $image.Dispose() }
}

function Invoke-Optimizer([string]$Executable, [string[]]$Arguments) {
  $stderrPath = [System.IO.Path]::GetTempFileName()
  # Native commands update this global automatic variable even inside a function.
  # GitHub Actions propagates it as the step exit code after the script returns.
  $previousExitCode = $global:LASTEXITCODE
  try {
    # Windows PowerShell turns native stderr into ErrorRecords, even for expected failures.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $stdout = & $Executable @Arguments 2> $stderrPath; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previousPreference }
    return [pscustomobject]@{ Code = $code; Stdout = ($stdout -join "`n"); Stderr = (Get-Content -LiteralPath $stderrPath -Raw) }
  } finally {
    $global:LASTEXITCODE = $previousExitCode
    Remove-Item -LiteralPath $stderrPath -Force
  }
}
