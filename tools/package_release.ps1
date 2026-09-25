# package_release.ps1 -- build the Nexus archive for the ciallo mod.
#
#   powershell -NoProfile -File tools\package_release.ps1 -Version 1.1.1
#   powershell -NoProfile -File tools\package_release.ps1 -Version 1.1.1 -OutDir D:\
#
# The archive holds a single top-level `ciallo/` folder (extract it into the game's `mods`),
# with the mod descriptor, the README, the native DLL, the bundled sounds and the Lua. The
# C source and the tests are never shipped. Entry names use forward slashes, as the ZIP
# spec asks; Compress-Archive writes backslashes on Windows, which some tools dislike.
#
# Pure ASCII (Windows PowerShell 5.1 reads a BOM-less non-ASCII .ps1 as ANSI).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir = 'D:\'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$zipPath = Join-Path $OutDir ("Ciallo_Push_Sound_v{0}.zip" -f $Version)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# exactly what a player needs: descriptor + README + DLL + sounds + Lua
$files = @()
foreach ($rel in @('ciallo.mod', 'README.md')) {
    $path = Join-Path $repo $rel
    if (-not (Test-Path -LiteralPath $path)) { throw "missing $rel" }
    $files += Get-Item -LiteralPath $path
}
foreach ($dir in @('bin', 'assets', 'scripts')) {
    $path = Join-Path $repo $dir
    if (-not (Test-Path -LiteralPath $path)) { throw "missing $dir" }
    $files += Get-ChildItem -LiteralPath $path -Recurse -File
}
if ($files.Count -eq 0) { throw 'nothing to package' }

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $rel = 'ciallo/' + $file.FullName.Substring($repo.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $target = $entry.Open()
        $source = [System.IO.File]::OpenRead($file.FullName)
        try {
            $source.CopyTo($target)
        } finally {
            $source.Close()
            $target.Close()
        }
    }
} finally {
    $archive.Dispose()
}

$zip = Get-Item -LiteralPath $zipPath
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
Write-Host ("packaged {0} file(s) into {1}" -f $files.Count, $zipPath)
Write-Host ("size   : {0:N2} MB" -f ($zip.Length / 1MB))
Write-Host ("sha256 : {0}" -f $hash)
Write-Host 'contents:'
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    foreach ($entry in ($check.Entries | Sort-Object FullName)) {
        Write-Host ("  {0,9:N0} B  {1}" -f $entry.Length, $entry.FullName)
    }
} finally {
    $check.Dispose()
}
