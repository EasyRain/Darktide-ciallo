# run_tests.ps1 -- volume tests for ciallo_sfx.c (no game needed) + optional DLL rebuild.
#
#   powershell -NoProfile -File tests\run_tests.ps1                 # guard + compile + run tests
#   powershell -NoProfile -File tests\run_tests.ps1 -RebuildDll     # ... and rebuild bin\ciallo_sfx.dll
#   powershell -NoProfile -File tests\run_tests.ps1 -KeepArtifacts  # keep the .exe/.obj
#
# Checks:
#   1. src\ciallo_sfx.c must not call waveOutSetVolume (that would move the whole audio
#      session, i.e. the game's own volume and the Windows mixer slider, not just ours).
#   2. The compiled tests: the volume a play uses, and the software scaling maths.
#
# Pure ASCII (Windows PowerShell 5.1 reads a BOM-less non-ASCII .ps1 as ANSI).

[CmdletBinding()]
param(
    [string]$VcVars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
    [string]$LuaJit = 'D:\Tools\Lua\luajit\src\luajit.exe',
    [switch]$RebuildDll,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'src\ciallo_sfx.c'
$testC = Join-Path $PSScriptRoot 'test_audio_volume.c'
$testExe = Join-Path $PSScriptRoot 'test_audio_volume.exe'
$failed = 0

function Step([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:failed++ }
    Write-Host ("[{0}] {1,-42} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
}

# --- 1. the guard: no device/session volume calls in the C source --------------------
$code = Get-Content -LiteralPath $source | Where-Object { $_ -notmatch '^\s*(\*|/\*|//)' }
$device = @($code | Select-String -Pattern 'waveOutSetVolume')
Step 'no waveOutSetVolume in the C source' ($device.Count -eq 0) $(if ($device.Count) { "$($device.Count) line(s)" } else { 'volume is scaled in software' })

# --- 2. compile and run the tests ---------------------------------------------------
if (-not (Test-Path -LiteralPath $VcVars)) {
    Write-Host "[FAIL] vcvars64.bat not found at $VcVars (pass -VcVars <path>)"
    exit 1
}
if (-not (Test-Path -LiteralPath $testC)) {
    Write-Host "[FAIL] missing $testC"
    exit 1
}

Write-Host ''
Write-Host '--- compiling tests'
$compile = cmd /c "`"$VcVars`" >nul 2>&1 && cd /d `"$repo`" && cl /nologo /O2 /utf-8 `"$testC`" /Fe:`"$testExe`"" 2>&1
if (-not (Test-Path -LiteralPath $testExe)) {
    Write-Host ($compile | Out-String)
    Write-Host '[FAIL] compilation did not produce the test executable'
    exit 1
}

Write-Host '--- running tests'
& $testExe
$testExit = $LASTEXITCODE
Step 'test_audio_volume.exe' ($testExit -eq 0) "exit $testExit"

# --- 2b. Lua tests (sound pool + folder scan) --------------------------------------
Write-Host ''
Write-Host '--- lua tests'
$lua = $LuaJit
if (-not (Test-Path -LiteralPath $lua)) {
    $found = Get-Command luajit -ErrorAction SilentlyContinue
    if ($found) { $lua = $found.Source } else { $lua = $null }
}
if (-not $lua) {
    Step 'lua tests skipped' $false 'luajit not found (pass -LuaJit <path>)'
} else {
    Push-Location $repo
    try {
        foreach ($test in @('tests\test_sound_pool.lua', 'tests\test_audio_files.lua')) {
            if (-not (Test-Path -LiteralPath $test)) { Step (Split-Path -Leaf $test) $false 'missing'; continue }
            & $lua $test
            Step (Split-Path -Leaf $test) ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

# --- 3. optional: rebuild the DLL --------------------------------------------------
if ($RebuildDll) {
    Write-Host ''
    Write-Host '--- rebuilding bin\ciallo_sfx.dll'
    $bin = Join-Path $repo 'bin'
    if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin | Out-Null }
    $dll = Join-Path $bin 'ciallo_sfx.dll'
    $build = cmd /c "`"$VcVars`" >nul 2>&1 && cd /d `"$repo`" && cl /nologo /O2 /LD /utf-8 src\ciallo_sfx.c /Fo:bin\ /Fe:bin\ciallo_sfx.dll /link winmm.lib" 2>&1
    if (Test-Path -LiteralPath $dll) {
        $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.Substring(0, 16)
        Step 'bin\ciallo_sfx.dll rebuilt' $true ("{0:N0} B  sha256 {1}..." -f (Get-Item $dll).Length, $hash)
    } else {
        Write-Host ($build | Out-String)
        Step 'bin\ciallo_sfx.dll rebuilt' $false 'link failed'
    }
    Remove-Item (Join-Path $bin 'ciallo_sfx.obj'), (Join-Path $bin 'ciallo_sfx.exp'), (Join-Path $bin 'ciallo_sfx.lib') -Force -ErrorAction SilentlyContinue
}

# --- 4. tidy up ---------------------------------------------------------------------
if (-not $KeepArtifacts) {
    Remove-Item $testExe, (Join-Path $PSScriptRoot 'test_audio_volume.obj'), (Join-Path $repo 'test_audio_volume.obj'), (Join-Path $PSScriptRoot 'test_audio_volume.lib'), (Join-Path $PSScriptRoot 'test_audio_volume.exp') -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) { Write-Host 'ALL CHECKS PASSED'; exit 0 }
Write-Host ("{0} CHECK(S) FAILED" -f $failed)
exit 1
