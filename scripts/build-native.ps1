$ErrorActionPreference = "Stop"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) {
  throw "Could not find vswhere.exe. Install Visual Studio Build Tools with the C++ workload."
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vsPath) {
  throw "Could not find Visual Studio C++ Build Tools."
}

$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
$cmake = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

if (!(Test-Path $vcvars)) {
  throw "Could not find vcvars64.bat at $vcvars."
}
if (!(Test-Path $cmake)) {
  throw "Could not find Visual Studio CMake at $cmake."
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$native = Join-Path $root "native"
$build = Join-Path $native "build"

cmd.exe /c "call `"$vcvars`" && `"$cmake`" -S `"$native`" -B `"$build`" -G `"NMake Makefiles`" -DCMAKE_BUILD_TYPE=Release -DCMAKE_RUNTIME_OUTPUT_DIRECTORY=`"$build\Release`" && `"$cmake`" --build `"$build`" --config Release"

if ($LASTEXITCODE -ne 0) { throw "Native build failed (exit $LASTEXITCODE)." }
