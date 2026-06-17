#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArtifactRoot,
    [string]$ManifestPath,
    [string]$VsCodeSettingsPath,
    [string]$CodeCommand = "code",
    [switch]$SkipVsixInstall,
    [switch]$SkipDockerImageLoad,
    [switch]$SkipWslServerInstall,
    [switch]$VerifyOnly,
    [string]$Distro,
    [string]$WslRepoPath,
    [string]$WslArtifactRoot = "artifacts/wsl",
    [string]$WslServerHome,
    [string]$WslUser,
    [switch]$NoLegacyLayout,
    [switch]$NoVerify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Join-ArtifactPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $localRelativePath = $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    return [System.IO.Path]::GetFullPath((Join-Path $Root $localRelativePath))
}

function ConvertTo-BashQuoted {
    param([Parameter(Mandatory = $true)][string]$Value)

    $singleQuote = [string][char]39
    $escapedQuote = $singleQuote + '"' + $singleQuote + '"' + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $escapedQuote) + $singleQuote
}

function Get-OpenSshPrivateKeys {
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw "Could not resolve the Windows user profile directory."
    }

    $sshDirectory = Join-Path $userProfile ".ssh"
    if (-not (Test-Path -LiteralPath $sshDirectory -PathType Container)) {
        throw "No SSH key directory found at $sshDirectory. Create or copy OpenSSH private keys there before running this script."
    }

    $keys = @(
        Get-ChildItem -LiteralPath $sshDirectory -File -Force |
            Where-Object {
                $includeFile = $true
                if ($_.Name.EndsWith(".pub", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $includeFile = $false
                } else {
                    $firstLine = Get-Content -LiteralPath $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue
                    $includeFile = $firstLine -match "^-----BEGIN (.+ )?PRIVATE KEY-----$"
                }

                $includeFile
            } |
            Sort-Object -Property FullName
    )

    if ($keys.Count -eq 0) {
        throw "No OpenSSH private keys found in $sshDirectory. Expected files such as id_ed25519 or id_rsa, not .pub files."
    }

    return @($keys | ForEach-Object { $_.FullName })
}

function Invoke-WindowsSshAddAll {
    param([string[]]$KeyPath)

    $sshAddCommand = Get-Command "ssh-add" -ErrorAction SilentlyContinue
    if (-not $sshAddCommand) {
        throw "ssh-add was not found. Install the Windows OpenSSH Client before running this script."
    }

    $sshAgentService = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
    if ($null -eq $sshAgentService) {
        throw "The Windows ssh-agent service was not found. Install or enable OpenSSH Authentication Agent before running this script."
    }

    if ($sshAgentService.Status -ne "Running") {
        throw "The Windows ssh-agent service is not running. Start it with: Start-Service ssh-agent"
    }

    Write-Host "Adding OpenSSH private keys to Windows ssh-agent:"
    foreach ($keyPathItem in $KeyPath) {
        Write-Host "  $keyPathItem"
    }

    & $sshAddCommand.Source @KeyPath
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-add failed. If a key requires a passphrase, add it manually with ssh-add and rerun this script."
    }
}

function ConvertTo-JsonLiteral {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [bool]) {
        if ($Value) {
            return "true"
        }
        return "false"
    }

    return '"' + ([string]$Value).Replace("\", "\\").Replace('"', '\"') + '"'
}

function Get-VSCodeUserSettingsPath {
    if (-not [string]::IsNullOrWhiteSpace($VsCodeSettingsPath)) {
        return Resolve-RepoPath $VsCodeSettingsPath
    }

    $appData = [Environment]::GetFolderPath("ApplicationData")
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw "Could not resolve APPDATA for VS Code user settings."
    }

    $codeFolder = "Code"
    if ($CodeCommand -match "insiders") {
        $codeFolder = "Code - Insiders"
    }

    return Join-Path $appData (Join-Path $codeFolder "User\settings.json")
}

function Set-VSCodeUserSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    $settingsPath = Get-VSCodeUserSettingsPath
    $settingsDirectory = Split-Path -Parent $settingsPath
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $settingsPath -Raw
    } else {
        $raw = "{`n}"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = "{`n}"
    }

    $jsonValue = ConvertTo-JsonLiteral $Value
    $escapedName = [regex]::Escape($Name)
    $propertyPattern = '(?m)^(\s*)"' + $escapedName + '"\s*:\s*("([^"\\]|\\.)*"|true|false|null|-?\d+(\.\d+)?)(\s*,?)'
    $propertyRegex = [regex]$propertyPattern

    if ($propertyRegex.IsMatch($raw)) {
        $raw = $propertyRegex.Replace($raw, '$1"' + $Name + '": ' + $jsonValue + '$5', 1)
    } else {
        $lastBrace = $raw.LastIndexOf("}")
        if ($lastBrace -lt 0) {
            throw "VS Code settings file does not look like a JSON object: $settingsPath"
        }

        $before = $raw.Substring(0, $lastBrace).TrimEnd()
        $after = $raw.Substring($lastBrace)
        if ($before.EndsWith("{")) {
            $raw = $before + "`n  `"$Name`": $jsonValue`n" + $after
        } else {
            $raw = $before + ",`n  `"$Name`": $jsonValue`n" + $after
        }
    }

    Set-Content -LiteralPath $settingsPath -Value $raw -NoNewline
    Write-Host "Updated VS Code setting:"
    Write-Host "  $Name = $Value"
    Write-Host "  $settingsPath"
}

function Import-DockerImageArtifacts {
    param([object[]]$DockerImageArtifacts)

    if ($DockerImageArtifacts.Count -eq 0) {
        return
    }

    $dockerCommand = Get-Command "docker" -ErrorAction SilentlyContinue
    if (-not $dockerCommand) {
        throw "docker was not found. Install Docker or use -SkipDockerImageLoad."
    }

    foreach ($dockerImageArtifact in $DockerImageArtifacts) {
        $imageTarPath = Join-ArtifactPath -Root $ArtifactRoot -RelativePath $dockerImageArtifact.path
        Write-Host "Loading Docker image artifact:"
        Write-Host "  $imageTarPath"
        if (-not [string]::IsNullOrWhiteSpace($dockerImageArtifact.bootstrapImageRef)) {
            Write-Host "  bootstrap image: $($dockerImageArtifact.bootstrapImageRef)"
        }
        & $dockerCommand.Source load --input $imageTarPath
        if ($LASTEXITCODE -ne 0) {
            throw "docker load failed for $imageTarPath"
        }
    }
}

function Assert-DockerImageAvailable {
    param([Parameter(Mandatory = $true)][string]$ImageRef)

    $dockerCommand = Get-Command "docker" -ErrorAction SilentlyContinue
    if (-not $dockerCommand) {
        throw "docker was not found. Install Docker or use -SkipDockerImageLoad."
    }

    & $dockerCommand.Source image inspect $ImageRef *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker image was not loaded: $ImageRef"
    }
}

$sshKeys = Get-OpenSshPrivateKeys
Invoke-WindowsSshAddAll -KeyPath $sshKeys

if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $RepoRoot "artifacts/wsl"
} else {
    $ArtifactRoot = Resolve-RepoPath $ArtifactRoot
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $ArtifactRoot "manifest.json"
} else {
    $ManifestPath = Resolve-RepoPath $ManifestPath
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "WSL artifact manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$artifacts = @($manifest.artifacts)

if ($artifacts.Count -eq 0) {
    throw "WSL artifact manifest contains no artifacts: $ManifestPath"
}

if (-not $NoVerify) {
    Write-Host "Verifying WSL artifact hashes:"
    foreach ($artifact in $artifacts) {
        if ([string]::IsNullOrWhiteSpace($artifact.path) -or [string]::IsNullOrWhiteSpace($artifact.sha256)) {
            throw "Manifest artifact is missing path or sha256."
        }

        $artifactPath = Join-ArtifactPath -Root $ArtifactRoot -RelativePath $artifact.path
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Manifest artifact is missing: $artifactPath"
        }

        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = ([string]$artifact.sha256).ToLowerInvariant()

        if ($actualHash -ne $expectedHash) {
            throw "SHA256 mismatch for ${artifactPath}: expected $expectedHash, got $actualHash"
        }

        Write-Host "  OK $($artifact.path)"
    }
}

$serverArtifact = @($artifacts | Where-Object { $_.kind -eq "vscode-server" -and $_.platform -eq "server-linux-x64" } | Select-Object -First 1)
$extensionArtifacts = @($artifacts | Where-Object { $_.kind -eq "vscode-extension" })
$dockerImageArtifacts = @($artifacts | Where-Object { $_.kind -eq "docker-image" })
$bootstrapImageArtifacts = @($dockerImageArtifacts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.bootstrapImageRef) } | Select-Object -First 1)

if ($serverArtifact.Count -eq 0) {
    throw "No server-linux-x64 VS Code Server artifact found in $ManifestPath"
}

if ($extensionArtifacts.Count -eq 0) {
    throw "No VS Code extension VSIX artifacts found in $ManifestPath"
}

Write-Host "Selected VS Code Server artifact:"
Write-Host "  commit:  $($serverArtifact[0].commit)"
Write-Host "  archive: $($serverArtifact[0].path)"

$serverCommit = [string]$serverArtifact[0].commit
$serverQuality = [string]$serverArtifact[0].quality
$serverPath = [string]$serverArtifact[0].path

if ($VerifyOnly) {
    Write-Host "WSL artifact verification completed successfully."
    exit 0
}

if (-not $SkipDockerImageLoad) {
    Import-DockerImageArtifacts -DockerImageArtifacts $dockerImageArtifacts

    if ($bootstrapImageArtifacts.Count -gt 0) {
        $bootstrapImageRef = [string]$bootstrapImageArtifacts[0].bootstrapImageRef
        Assert-DockerImageAvailable -ImageRef $bootstrapImageRef
        Write-Host "Configuring VS Code to use local Dev Containers bootstrap container image:"
        Write-Host "  $bootstrapImageRef"
        Set-VSCodeUserSetting -Name "dev.containers.bootstrapImage" -Value $bootstrapImageRef
        Set-VSCodeUserSetting -Name "dev.containers.bootstrapImagePull" -Value $false
    }
}

if (-not $SkipVsixInstall) {
    if (-not (Get-Command $CodeCommand -ErrorAction SilentlyContinue)) {
        throw "VS Code command not found: $CodeCommand. Pass -CodeCommand or use -SkipVsixInstall."
    }

    foreach ($extensionArtifact in $extensionArtifacts) {
        $vsixPath = Join-ArtifactPath -Root $ArtifactRoot -RelativePath $extensionArtifact.path
        Write-Host "Installing VS Code extension VSIX:"
        Write-Host "  $vsixPath"
        & $CodeCommand --install-extension $vsixPath --force
        if ($LASTEXITCODE -ne 0) {
            throw "VS Code extension install failed for $vsixPath"
        }
    }
}

if ($SkipWslServerInstall) {
    Write-Host "Skipping WSL server install."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($WslRepoPath)) {
    Write-Host "Skipping WSL server install. Pass -WslRepoPath to install the VS Code Server payload inside WSL."
    exit 0
}

if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found. Use -SkipWslServerInstall or run this script from a Windows host with WSL installed."
}

$wslArtifactRootNormalized = $WslArtifactRoot.TrimEnd([char[]]@("/", "\")).Replace("\", "/")
$wslServerArchive = "$wslArtifactRootNormalized/$serverPath"
$wslInstallCommand = "bash src/base-vscode/scripts/install-server.sh --commit $(ConvertTo-BashQuoted $serverCommit) --archive $(ConvertTo-BashQuoted $wslServerArchive) --quality $(ConvertTo-BashQuoted $serverQuality) --user " + '"${remote_user}"' + " --server-home " + '"${server_home}"'

if ($NoLegacyLayout) {
    $wslInstallCommand += " --no-legacy-layout"
}

if (-not [string]::IsNullOrWhiteSpace($WslUser)) {
    $wslRemoteUserCommand = "remote_user=$(ConvertTo-BashQuoted $WslUser)"
} else {
    $wslRemoteUserCommand = 'remote_user="$(id -un)"'
}

if (-not [string]::IsNullOrWhiteSpace($WslServerHome)) {
    $wslServerHomeCommand = "server_home=$(ConvertTo-BashQuoted $WslServerHome)"
} else {
    $wslServerHomeCommand = 'server_home="${HOME}"'
}

$wslCommandParts = @()
$wslCommandParts += "cd $(ConvertTo-BashQuoted $WslRepoPath)"
$wslCommandParts += $wslRemoteUserCommand
$wslCommandParts += $wslServerHomeCommand
$wslCommandParts += $wslInstallCommand

$bashCommand = $wslCommandParts -join " && "
$wslArgs = @()

if (-not [string]::IsNullOrWhiteSpace($Distro)) {
    $wslArgs += @("-d", $Distro)
}

$wslArgs += @("--", "bash", "-lc", $bashCommand)

Write-Host "Installing VS Code Server inside WSL:"
Write-Host "  $bashCommand"
& wsl.exe @wslArgs
if ($LASTEXITCODE -ne 0) {
    throw "WSL server install failed."
}
