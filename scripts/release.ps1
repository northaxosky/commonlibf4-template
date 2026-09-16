[CmdletBinding()]
param(
    [ValidateSet('Current', 'Compare', 'Evaluate')]
    [string] $Action = 'Current',
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $PreviousVersion,
    [string] $CurrentVersion,
    [string] $Before,
    [string] $After = 'HEAD',
    [string] $EventName = 'push',
    [string] $Ref = 'refs/heads/main'
)

$ErrorActionPreference = 'Stop'

function ConvertTo-StrictSemanticVersion {
    param([Parameter(Mandatory)][string] $Value)

    $pattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    if ($Value -cnotmatch $pattern) {
        throw "Invalid semantic version '$Value'."
    }
    return [System.Management.Automation.SemanticVersion]::new($Value)
}

function Get-VersionFromText {
    param([Parameter(Mandatory)][string] $Text)

    $matches = [regex]::Matches(
        $Text,
        '(?m)^\s*local\s+plugin_version\s*=\s*"([^"]+)"\s*$')
    if ($matches.Count -ne 1) {
        throw "Expected exactly one plugin_version declaration in xmake.lua; found $($matches.Count)."
    }

    $value = $matches[0].Groups[1].Value
    [void](ConvertTo-StrictSemanticVersion $value)
    return $value
}

function Get-VersionAtRevision {
    param([Parameter(Mandatory)][string] $Revision)

    $spec = "${Revision}:xmake.lua"
    $text = & git -C $RepositoryRoot show $spec 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return Get-VersionFromText ($text -join "`n")
}

function Get-ReleaseDecision {
    param(
        [AllowEmptyString()][string] $OldVersion,
        [Parameter(Mandatory)][string] $NewVersion,
        [Parameter(Mandatory)][string] $Trigger,
        [Parameter(Mandatory)][string] $GitRef
    )

    [void](ConvertTo-StrictSemanticVersion $NewVersion)
    if ($Trigger -ne 'push') {
        return [ordered]@{ publish = $false; reason = 'not-a-push'; version = $NewVersion; tag = "v$NewVersion" }
    }
    if ($GitRef -ne 'refs/heads/main') {
        return [ordered]@{ publish = $false; reason = 'not-main'; version = $NewVersion; tag = "v$NewVersion" }
    }
    if ([string]::IsNullOrWhiteSpace($OldVersion)) {
        return [ordered]@{ publish = $false; reason = 'no-previous-version'; version = $NewVersion; tag = "v$NewVersion" }
    }

    $old = ConvertTo-StrictSemanticVersion $OldVersion
    $new = ConvertTo-StrictSemanticVersion $NewVersion
    if ($OldVersion -ceq $NewVersion) {
        return [ordered]@{ publish = $false; reason = 'unchanged'; version = $NewVersion; tag = "v$NewVersion" }
    }
    if ($new.CompareTo($old) -le 0) {
        throw "Version must increase on main: $OldVersion -> $NewVersion."
    }
    return [ordered]@{ publish = $true; reason = 'increased'; version = $NewVersion; tag = "v$NewVersion" }
}

switch ($Action) {
    'Current' {
        $text = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'xmake.lua') -Raw
        Get-VersionFromText $text
    }
    'Compare' {
        if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
            throw 'CurrentVersion is required for Compare.'
        }
        Get-ReleaseDecision -OldVersion $PreviousVersion -NewVersion $CurrentVersion -Trigger $EventName -GitRef $Ref |
            ConvertTo-Json -Compress
    }
    'Evaluate' {
        if ([string]::IsNullOrWhiteSpace($Before) -or [string]::IsNullOrWhiteSpace($After)) {
            throw 'Before and After are required for Evaluate.'
        }

        $newVersion = Get-VersionAtRevision $After
        if (-not $newVersion) {
            throw "xmake.lua is missing at revision $After."
        }

        $oldVersion = $null
        if ($Before -notmatch '^0+$') {
            $oldVersion = Get-VersionAtRevision $Before
        }
        Get-ReleaseDecision -OldVersion $oldVersion -NewVersion $newVersion -Trigger $EventName -GitRef $Ref |
            ConvertTo-Json -Compress
    }
}
