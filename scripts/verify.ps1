[CmdletBinding()]
param(
    [ValidateSet('msvc', 'clang-cl')]
    [string] $Toolchain = 'msvc',
    [ValidateSet('debug', 'releasedbg')]
    [string[]] $Mode = @('debug', 'releasedbg'),
    [switch] $Full
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$XmakeFile = Join-Path $RepositoryRoot 'xmake.lua'
$PluginName = [regex]::Match(
    (Get-Content -LiteralPath $XmakeFile -Raw),
    '(?m)^\s*local\s+plugin_name\s*=\s*"([^"]+)"\s*$').Groups[1].Value
$Version = & (Join-Path $PSScriptRoot 'release.ps1') -Action Current -RepositoryRoot $RepositoryRoot
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) "$PluginName-verify-$([guid]::NewGuid())"
$FixtureName = "verify-$([guid]::NewGuid().ToString('N')).txt"
$FixturePath = Join-Path $RepositoryRoot "package\$FixtureName"

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-FilesEqual {
    param([string] $Expected, [string] $Actual, [string] $Message)
    Assert-True (Test-Path -LiteralPath $Expected -PathType Leaf) "Missing expected file: $Expected"
    Assert-True (Test-Path -LiteralPath $Actual -PathType Leaf) "Missing actual file: $Actual"
    $expectedHash = (Get-FileHash -LiteralPath $Expected -Algorithm SHA256).Hash
    $actualHash = (Get-FileHash -LiteralPath $Actual -Algorithm SHA256).Hash
    Assert-True ($expectedHash -ceq $actualHash) "$Message ($expectedHash != $actualHash)"
}

function Clear-FalloutEnvironment {
    $env:FO4_DEV_MODS = $null
    $env:XSE_FO4_MODS_PATH = $null
    $env:XSE_FO4_GAME_PATH = $null
}

function Invoke-Xmake {
    param(
        [Parameter(Mandatory)][string] $Task,
        [string[]] $Arguments = @(),
        [switch] $ExpectFailure
    )

    & xmake $Task -P $RepositoryRoot @Arguments
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        Assert-True ($exitCode -ne 0) "Expected 'xmake $Task $Arguments' to fail."
    } else {
        Assert-True ($exitCode -eq 0) "'xmake $Task $Arguments' failed with exit code $exitCode."
    }
}

function Set-BuildConfiguration {
    param(
        [Parameter(Mandatory)][string] $BuildMode,
        [AllowEmptyString()][string] $DeployDirectory = ''
    )

    Invoke-Xmake -Task 'f' -Arguments @(
        '-m', $BuildMode,
        '-a', 'x64',
        "--toolchain=$Toolchain",
        "--deploy_dir=$DeployDirectory",
        '-y')
}

function Get-BuildFile {
    param([string] $BuildMode, [string] $Extension)
    return Join-Path $RepositoryRoot "build\windows\x64\$BuildMode\$PluginName.$Extension"
}

function Get-PackageFile {
    param([string] $Extension)
    return Join-Path $RepositoryRoot "package\F4SE\Plugins\$PluginName.$Extension"
}

function Test-StagedBinaries {
    param([string] $BuildMode, [string] $Root = (Join-Path $RepositoryRoot 'package'))
    Assert-FilesEqual (Get-BuildFile $BuildMode 'dll') (Join-Path $Root "F4SE\Plugins\$PluginName.dll") 'DLL hash mismatch'
    Assert-FilesEqual (Get-BuildFile $BuildMode 'pdb') (Join-Path $Root "F4SE\Plugins\$PluginName.pdb") 'PDB hash mismatch'
}

function Get-Dumpbin {
    $command = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' |
            Select-Object -Last 1
        if ($found) {
            return $found
        }
    }
    throw 'dumpbin.exe was not found.'
}

function Test-BinaryMetadata {
    param([string] $Dll)

    $exports = & (Get-Dumpbin) /nologo /exports $Dll
    Assert-True ($LASTEXITCODE -eq 0) 'dumpbin failed.'
    foreach ($name in @('F4SEPlugin_Query', 'F4SEPlugin_Load', 'F4SEPlugin_Preload', 'F4SEPlugin_Version')) {
        Assert-True ([bool]($exports -match "\b$([regex]::Escape($name))\b")) "Missing DLL export $name."
    }

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Dll)
    Assert-True ($versionInfo.FileVersion -like "$Version.*") "Unexpected file version '$($versionInfo.FileVersion)'."
    Assert-True ($versionInfo.ProductVersion -like "$Version.*") "Unexpected product version '$($versionInfo.ProductVersion)'."
}

function Test-Archive {
    $archive = Join-Path $RepositoryRoot "build\xpack\$PluginName\$PluginName-$Version.zip"
    Assert-True (Test-Path -LiteralPath $archive -PathType Leaf) "Missing archive: $archive"

    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entries = @($zip.Entries | Where-Object { $_.Name })
        $actualNames = @($entries.FullName.Replace('\', '/') | Sort-Object)
        $packageRoot = Join-Path $RepositoryRoot 'package'
        $expectedFiles = Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
            Where-Object Name -ne '.gitkeep'
        $expectedNames = @($expectedFiles | ForEach-Object {
                [IO.Path]::GetRelativePath($packageRoot, $_.FullName).Replace('\', '/')
            } | Sort-Object)
        Assert-True (($actualNames -join "`n") -ceq ($expectedNames -join "`n")) "Archive file set differs from package payload.`nExpected: $expectedNames`nActual: $actualNames"
        Assert-True (-not ($actualNames -match '^(package|build|nexus|lib)/')) 'Archive contains a wrapper or non-payload content.'
        Assert-True (-not ($actualNames -match '\.(lib|exp|obj)$')) 'Archive contains build intermediates.'

        foreach ($entry in $entries) {
            $packageFile = Join-Path $packageRoot $entry.FullName
            $stream = $entry.Open()
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    $entryHash = [Convert]::ToHexString($sha.ComputeHash($stream))
                } finally {
                    $sha.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
            $packageHash = (Get-FileHash -LiteralPath $packageFile -Algorithm SHA256).Hash
            Assert-True ($entryHash -ceq $packageHash) "Archive hash mismatch for $($entry.FullName)."
        }
    } finally {
        $zip.Dispose()
    }
}

function Test-ReleaseDecisions {
    $script = Join-Path $PSScriptRoot 'release.ps1'
    $unchanged = & $script -Action Compare -PreviousVersion $Version -CurrentVersion $Version |
        ConvertFrom-Json
    Assert-True (-not $unchanged.publish -and $unchanged.reason -eq 'unchanged') 'Unchanged version would publish.'

    $feature = & $script -Action Compare -PreviousVersion '1.2.3' -CurrentVersion '1.2.4' -Ref 'refs/heads/feature' |
        ConvertFrom-Json
    Assert-True (-not $feature.publish -and $feature.reason -eq 'not-main') 'Feature branch would publish.'

    $pullRequest = & $script -Action Compare -PreviousVersion '1.2.3' -CurrentVersion '1.2.4' -EventName 'pull_request' |
        ConvertFrom-Json
    Assert-True (-not $pullRequest.publish -and $pullRequest.reason -eq 'not-a-push') 'Pull request would publish.'

    $initial = & $script -Action Compare -PreviousVersion '' -CurrentVersion $Version |
        ConvertFrom-Json
    Assert-True (-not $initial.publish -and $initial.reason -eq 'no-previous-version') 'Initial template creation would publish.'

    $increased = & $script -Action Compare -PreviousVersion '1.2.3' -CurrentVersion '1.2.4' |
        ConvertFrom-Json
    Assert-True ($increased.publish -and $increased.tag -eq 'v1.2.4') 'Increasing version would not publish.'

    $decreaseRejected = $false
    try {
        & $script -Action Compare -PreviousVersion '1.2.4' -CurrentVersion '1.2.3' 2>$null | Out-Null
    } catch {
        $decreaseRejected = $true
    }
    Assert-True $decreaseRejected 'Decreasing version was accepted.'
}

try {
    New-Item -ItemType Directory -Path $TempRoot | Out-Null
    Push-Location $RepositoryRoot
    Clear-FalloutEnvironment

    $formatFiles = Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'src') -Recurse -File |
        Where-Object Extension -in @('.cpp', '.h', '.hpp')
    & clang-format --dry-run --Werror @($formatFiles.FullName)
    Assert-True ($LASTEXITCODE -eq 0) 'Owned C++ formatting check failed.'

    foreach ($buildMode in $Mode) {
        Set-BuildConfiguration $buildMode
        if ($Full) {
            Invoke-Xmake -Task 'clean'
        }
        Invoke-Xmake -Task 'build' -Arguments @('-y')
        Test-StagedBinaries $buildMode
        Test-BinaryMetadata (Get-BuildFile $buildMode 'dll')
    }

    if ($Full) {
        $poisonMods = Join-Path $TempRoot 'poison-mods'
        $poisonGame = Join-Path $TempRoot 'poison-game'
        $poisonDev = Join-Path $TempRoot 'poison-dev'
        $env:FO4_DEV_MODS = $poisonDev
        $env:XSE_FO4_MODS_PATH = $poisonMods
        $env:XSE_FO4_GAME_PATH = $poisonGame
        Set-BuildConfiguration 'releasedbg'
        Invoke-Xmake -Task 'build'
        Assert-True (-not (Test-Path -LiteralPath $poisonMods)) 'Inherited XSE_FO4_MODS_PATH received files.'
        Assert-True (-not (Test-Path -LiteralPath $poisonGame)) 'Inherited XSE_FO4_GAME_PATH received files.'
        Assert-True (-not (Test-Path -LiteralPath $poisonDev)) 'Inherited FO4_DEV_MODS received files.'
        Clear-FalloutEnvironment

        $deploy = Join-Path $TempRoot 'deploy'
        New-Item -ItemType Directory -Path $deploy | Out-Null
        Set-Content -LiteralPath (Join-Path $deploy 'user-extra.txt') -Value 'preserve'
        Set-BuildConfiguration 'releasedbg' $deploy
        Invoke-Xmake -Task 'build'
        Test-StagedBinaries 'releasedbg' $deploy
        Assert-True (Test-Path -LiteralPath (Join-Path $deploy 'user-extra.txt')) 'Deployment deleted an unrelated destination file.'

        $releaseDll = Get-BuildFile 'releasedbg' 'dll'
        $releaseWriteTime = (Get-Item -LiteralPath $releaseDll).LastWriteTimeUtc
        Set-Content -LiteralPath $FixturePath -Value 'asset-v1'
        Invoke-Xmake -Task 'build'
        Assert-True ((Get-Item -LiteralPath $releaseDll).LastWriteTimeUtc -eq $releaseWriteTime) 'Asset-only build relinked the plugin.'
        Assert-FilesEqual $FixturePath (Join-Path $deploy $FixtureName) 'Asset-only deployment hash mismatch'
        Set-Content -LiteralPath $FixturePath -Value 'asset-v2'
        Invoke-Xmake -Task 'build'
        Assert-FilesEqual $FixturePath (Join-Path $deploy $FixtureName) 'Edited asset was not redeployed'
        Assert-True (Test-Path -LiteralPath (Join-Path $deploy 'user-extra.txt')) 'A later deployment deleted an unrelated destination file.'

        Set-BuildConfiguration 'releasedbg'
        Remove-Item -LiteralPath $FixturePath
        $clearedProbe = Join-Path $RepositoryRoot "package\cleared-$FixtureName"
        try {
            Set-Content -LiteralPath $clearedProbe -Value 'must-not-deploy'
            Invoke-Xmake -Task 'build'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $deploy ([IO.Path]::GetFileName($clearedProbe))))) 'Cleared deployment destination still received files.'
        } finally {
            Remove-Item -LiteralPath $clearedProbe -Force -ErrorAction SilentlyContinue
        }

        $unsafeFile = Join-Path $TempRoot 'not-a-directory'
        Set-Content -LiteralPath $unsafeFile -Value 'fixture'
        Invoke-Xmake -Task 'f' -Arguments @('-m', 'releasedbg', '-a', 'x64', "--toolchain=$Toolchain", "--deploy_dir=$unsafeFile", '-y') -ExpectFailure
        Invoke-Xmake -Task 'f' -Arguments @('-m', 'releasedbg', '-a', 'x64', "--toolchain=$Toolchain", "--deploy_dir=$RepositoryRoot", '-y') -ExpectFailure
        Invoke-Xmake -Task 'f' -Arguments @('-m', 'releasedbg', '-a', 'x64', "--toolchain=$Toolchain", "--deploy_dir=$([IO.Path]::GetPathRoot($TempRoot))", '-y') -ExpectFailure
        Invoke-Xmake -Task 'f' -Arguments @('-m', 'releasedbg', '-a', 'x64', "--toolchain=$Toolchain", '--deploy_dir=relative', '-y') -ExpectFailure

        $copyFailure = Join-Path $TempRoot 'copy-failure'
        New-Item -ItemType Directory -Path $copyFailure | Out-Null
        Set-Content -LiteralPath (Join-Path $copyFailure 'F4SE') -Value 'blocks directory creation'
        Set-BuildConfiguration 'releasedbg' $copyFailure
        Set-Content -LiteralPath $FixturePath -Value 'force-install'
        try {
            Invoke-Xmake -Task 'build' -ExpectFailure
        } finally {
            Remove-Item -LiteralPath $FixturePath -Force -ErrorAction SilentlyContinue
        }

        Set-BuildConfiguration 'debug'
        Invoke-Xmake -Task 'build'
        $debugWriteTime = (Get-Item -LiteralPath (Get-BuildFile 'debug' 'dll')).LastWriteTimeUtc
        Remove-Item -LiteralPath (Get-PackageFile 'dll'), (Get-PackageFile 'pdb') -Force
        Invoke-Xmake -Task 'build'
        Assert-True ((Get-Item -LiteralPath (Get-BuildFile 'debug' 'dll')).LastWriteTimeUtc -eq $debugWriteTime) 'Cached debug restage relinked the plugin.'
        Test-StagedBinaries 'debug'
        Invoke-Xmake -Task 'pack' -Arguments @('-f', 'zip', '--autobuild=n') -ExpectFailure

        Set-BuildConfiguration 'releasedbg'
        Invoke-Xmake -Task 'build'
        Test-StagedBinaries 'releasedbg'
        Invoke-Xmake -Task 'pack' -Arguments @('-f', 'zip')
        Test-Archive
        Test-ReleaseDecisions
    }

    $commonLibPin = (& git -C (Join-Path $RepositoryRoot 'lib/commonlibf4') rev-parse HEAD).Trim()
    Assert-True ($commonLibPin -ceq 'a1d08a520579aa90f386a5109b28d9a22ef898d6') "Unexpected CommonLibF4 pin $commonLibPin."
    $sharedPin = (& git -C (Join-Path $RepositoryRoot 'lib/commonlibf4') rev-parse 'HEAD:lib/commonlib-shared').Trim()
    Assert-True ($sharedPin -ceq 'ca0e527c5af60d48497f02197c3c4c436d683387') "Unexpected commonlib-shared pin $sharedPin."

    Write-Host "Verification passed for ${Toolchain}: $($Mode -join ', ')."
} finally {
    Clear-FalloutEnvironment
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $FixturePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
