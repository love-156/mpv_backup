#Requires -Version 5.1
<#
.SYNOPSIS
    Portable mpv + git-backed portable_config: installer and config syncer.

.DESCRIPTION
    This script lives inside the config repository, but it is also the thing
    that bootstraps a new machine.

    Install mode (new machine, or when run from outside portable_config):
      - installs into a folder named mpv inside the directory the command is
        run from: "cd D:\Tools" then the one-liner gives you D:\Tools\mpv
      - makes sure git is available; if the machine has none, a portable
        MinGit is downloaded into <install-dir>\tools\git
      - downloads the latest Windows mpv build
        (shinchiro / mpv-winbuild-cmake, or SourceForge as fallback)
      - clones the config repository into <install-dir>\portable_config
      - the Windows mpv build automatically uses a folder called
        portable_config that sits next to mpv.exe, so no other setup is needed

    Sync mode (when run from inside the installed portable_config):
      - git add -A, commit, push
      - i.e. local tweaks go back to the repository

    Everything the script downloads stays inside the mpv folder:

      <install-dir>\
        mpv.exe
        portable_config\      <- the git repository (your config)
        tools\7zr.exe         <- extractor
        tools\git\            <- portable MinGit, only if git was missing
        tools\work-*\         <- transient download folder, removed on success

    Nothing is written to %TEMP%, %APPDATA% or PATH.

    Fresh machine, one line (installs into .\mpv of the current directory):
      cd D:\Tools
      irm https://raw.githubusercontent.com/love-156/mpv_backup/main/install.ps1 | iex

    After editing your config:
      cd <install-dir>\portable_config
      .\install.ps1

.PARAMETER Install
    Force install mode.
.PARAMETER Sync
    Force sync mode (commit + push local config changes).
.PARAMETER Update
    Force install mode and download the latest mpv build again.
.PARAMETER ConfigOnly
    Install or update the config folder, but do not download mpv.
.PARAMETER Message
    Custom commit message for sync mode.
.PARAMETER RepoUrl
    Override the config repository URL.
.PARAMETER InstallDir
    Folder that holds mpv.exe. Default: .\mpv under the current directory.
.PARAMETER MpvUrl
    Direct URL to an mpv .7z archive; skips the release lookup.
.PARAMETER Arch
    auto, x64, x86 or arm64. Default: auto.
.PARAMETER NoPush
    Sync mode: commit locally but do not push.

.EXAMPLE
    irm https://raw.githubusercontent.com/you/mpv-config/main/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -Message "subs: bigger font"

.EXAMPLE
    .\install.ps1 -Update

.NOTES
    ASCII only on purpose: this file must survive both "iex" (UTF-8 text from
    the internet) and Windows PowerShell 5.1 reading it from disk (no BOM).
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Sync,
    [switch]$Update,
    [switch]$ConfigOnly,
    [string]$Message,
    [string]$RepoUrl,
    [string]$InstallDir,
    [string]$MpvUrl,
    [ValidateSet('auto', 'x64', 'x86', 'arm64')]
    [string]$Arch = 'auto',
    [switch]$NoPush
)

# ---------------------------------------------------------------------------
# Settings you may want to change
# ---------------------------------------------------------------------------
$DefaultRepoUrl = 'https://github.com/love-156/mpv_backup.git'
$ReleaseApi     = 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest'
$GitReleaseApi  = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
$SevenZipUrl    = 'https://www.7-zip.org/a/7zr.exe'
$UserAgent      = 'mpv-portable-config'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Mpv-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Mpv-Ok {
    param([string]$Text)
    Write-Host "[ok] $Text" -ForegroundColor Green
}

function Mpv-Info {
    param([string]$Text)
    Write-Host "[i]  $Text" -ForegroundColor Gray
}

function Mpv-Warn {
    param([string]$Text)
    Write-Host "[!]  $Text" -ForegroundColor Yellow
}

function Mpv-ShowOutput {
    param($Output)
    foreach ($line in @($Output)) {
        if ($null -ne $line -and "$line" -ne '') {
            Write-Host "     $line" -ForegroundColor DarkGray
        }
    }
}

function Mpv-Run {
    param([string]$Exe, [string[]]$Arguments)

    # Native tools report progress and failures on stderr. With
    # $ErrorActionPreference = 'Stop' (set in Mpv-Main) that stderr would
    # raise a terminating error before we can look at the exit code, so run
    # them with 'Continue' and capture the combined output instead.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Exe @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------
function Mpv-ResolveRepoUrl {
    param([string]$Value, [string]$Fallback)

    if ($Value) { return $Value }
    if ($env:MPV_CONFIG_REPO) { return $env:MPV_CONFIG_REPO }
    if ($Fallback -and $Fallback -notmatch 'OWNER/REPO') { return $Fallback }

    throw 'No repository URL configured. Edit $DefaultRepoUrl in install.ps1, set $env:MPV_CONFIG_REPO, or pass -RepoUrl.'
}

function Mpv-ResolveArch {
    param([string]$Value)

    if ($Value -ne 'auto') { return $Value }

    $cpu = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $cpu = $env:PROCESSOR_ARCHITEW6432 }

    switch ($cpu) {
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
        default { return 'x64' }
    }
}

function Mpv-AssetPattern {
    param([string]$Value)

    switch ($Value) {
        'x86'   { return '^mpv-i686-\d{8}-git-[0-9a-f]+\.7z$' }
        'arm64' { return '^mpv-aarch64-\d{8}-git-[0-9a-f]+\.7z$' }
        default { return '^mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z$' }
    }
}

function Mpv-SourceForgeUrl {
    param([string]$Value)

    $folder = '64bit'
    if ($Value -eq 'x86')   { $folder = '32bit' }
    if ($Value -eq 'arm64') { $folder = 'arm64' }

    $pattern = switch ($Value) {
        'x86'   { 'mpv-i686-\d{8}-git-[0-9a-f]+\.7z' }
        'arm64' { 'mpv-aarch64-\d{8}-git-[0-9a-f]+\.7z' }
        default { 'mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z' }
    }

    try {
        $rss = Invoke-WebRequest -Uri "https://sourceforge.net/projects/mpv-player-windows/rss?path=/$folder" -UseBasicParsing -TimeoutSec 60
        $match = [regex]::Match($rss.Content, "https://sourceforge\.net/projects/mpv-player-windows/files/$folder/$pattern/download")
        if ($match.Success) { return $match.Value }
    } catch {
        # fall through
    }
    return $null
}

# ---------------------------------------------------------------------------
# Portable git (only used when the machine has no git at all)
# ---------------------------------------------------------------------------
function Mpv-InstallPortableGit {
    param([string]$InstallDir)

    $tools = Join-Path $InstallDir 'tools'
    if (-not (Test-Path -LiteralPath $tools)) {
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
    }

    $arch  = Mpv-ResolveArch -Value 'auto'
    $token = switch ($arch) {
        'x86'   { '32-bit' }
        'arm64' { 'arm64' }
        default { '64-bit' }
    }
    $pattern = '^MinGit-\d[\d.]*-' + [regex]::Escape($token) + '\.zip$'

    Mpv-Step 'git not found - downloading portable MinGit'
    Mpv-Info "Download target: $tools\git"

    $release = Invoke-RestMethod -Uri $GitReleaseApi -UseBasicParsing -TimeoutSec 60 -Headers @{
        'User-Agent' = $UserAgent
        'Accept'     = 'application/vnd.github+json'
    }
    $asset = @($release.assets) |
        Where-Object { $_ -and $_.name -match $pattern } |
        Select-Object -First 1

    if (-not $asset) {
        throw "Release $($release.tag_name) has no MinGit $token asset. Install Git manually instead: winget install --id Git.Git -e"
    }

    $work = Join-Path $tools ('work-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $success = $false

    try {
        $zip = Join-Path $work 'mingit.zip'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 900
        Mpv-Ok "Downloaded $($asset.name)"

        $dest = Join-Path $tools 'git'
        if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        }

        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        $unpacked = $false
        if ($tar) {
            $result = Mpv-Run -Exe 'tar.exe' -Arguments @('-xf', $zip, '-C', $dest)
            $unpacked = ($result.ExitCode -eq 0)
        }
        if (-not $unpacked) {
            Mpv-Info 'tar.exe could not unpack it; trying Expand-Archive.'
            Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
        }

        $gitExe = Join-Path $dest 'cmd\git.exe'
        if (-not (Test-Path -LiteralPath $gitExe)) {
            throw "MinGit extraction failed; $gitExe is missing."
        }

        $result = Mpv-Run -Exe $gitExe -Arguments @('--version')
        if ($result.ExitCode -ne 0) {
            throw 'The portable git executable does not run correctly.'
        }
        $success = $true
        Mpv-Ok "Portable git ready: $gitExe"
        Mpv-Warn 'MinGit is minimal: over HTTPS it may ask for a username and a Personal Access Token instead of opening a browser login.'
        return $gitExe
    } finally {
        if ($success) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Mpv-Warn "Partial download kept at $work"
        }
    }
}

function Mpv-EnsureGit {
    param([string]$InstallDir)

    # A "git" from PATH may be an alias or a shim, so prove that it runs.
    $system = Get-Command git -ErrorAction SilentlyContinue
    if ($system) {
        $result = Mpv-Run -Exe 'git' -Arguments @('--version')
        if ($result.ExitCode -eq 0) {
            return 'git'
        }
        Mpv-Warn 'The git found in PATH does not run; using a portable copy instead.'
    }

    $portable = Join-Path $InstallDir 'tools\git\cmd\git.exe'
    if (Test-Path -LiteralPath $portable) {
        return $portable
    }

    return (Mpv-InstallPortableGit -InstallDir $InstallDir)
}

# ---------------------------------------------------------------------------
# mpv download
# ---------------------------------------------------------------------------
function Mpv-ArchiveInfo {
    param([string]$Value)

    $info = [pscustomobject]@{ Url = $null; Name = 'mpv.7z'; Source = $null }

    try {
        $release = Invoke-RestMethod -Uri $ReleaseApi -UseBasicParsing -TimeoutSec 60 -Headers @{
            'User-Agent' = $UserAgent
            'Accept'     = 'application/vnd.github+json'
        }
        $pattern = Mpv-AssetPattern $Value
        $asset = @($release.assets) |
            Where-Object { $_ -and $_.name -match $pattern } |
            Select-Object -First 1

        if ($asset) {
            $info.Url    = $asset.browser_download_url
            $info.Name   = $asset.name
            $info.Source = "GitHub release $($release.tag_name)"
            return $info
        }
        Mpv-Warn "Release $($release.tag_name) contains no $Value build."
    } catch {
        Mpv-Warn "GitHub API lookup failed: $($_.Exception.Message)"
    }

    $fallback = Mpv-SourceForgeUrl -Value $Value
    if ($fallback) {
        $info.Url    = $fallback
        $info.Name   = (($fallback -split '/')[-2])
        $info.Source = 'SourceForge'
    }
    return $info
}

function Mpv-InstallBinary {
    param([string]$InstallDir, [string]$OverrideUrl, [string]$Arch)

    if ($OverrideUrl) {
        $info = [pscustomobject]@{ Url = $OverrideUrl; Name = 'mpv.7z'; Source = '-MpvUrl' }
    } else {
        $info = Mpv-ArchiveInfo -Value $Arch
    }

    if (-not $info.Url) {
        throw 'Could not determine an mpv download URL. Pass -MpvUrl <direct .7z link> to work around it.'
    }

    $tools = Join-Path $InstallDir 'tools'
    if (-not (Test-Path -LiteralPath $tools)) {
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
    }

    Mpv-Step "Downloading mpv from $($info.Source)"
    Mpv-Info $info.Name

    $work = Join-Path $tools ('work-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $success = $false

    try {
        $archive = Join-Path $work 'mpv.7z'
        Invoke-WebRequest -Uri $info.Url -OutFile $archive -UseBasicParsing -TimeoutSec 900
        Mpv-Ok 'Download complete.'

        Mpv-Step 'Extracting'
        $stage = Join-Path $work 'unpack'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        # Unpack into a staging folder first: a failed download or a locked
        # mpv.exe must never leave a half-written binary behind.
        $sevenZip = Join-Path $tools '7zr.exe'
        $extracted = $false
        try {
            if (-not (Test-Path -LiteralPath $sevenZip)) {
                $sevenZipTmp = Join-Path $work '7zr.exe'
                Invoke-WebRequest -Uri $SevenZipUrl -OutFile $sevenZipTmp -UseBasicParsing -TimeoutSec 120
                Move-Item -LiteralPath $sevenZipTmp -Destination $sevenZip
            }
            $result = Mpv-Run -Exe $sevenZip -Arguments @('x', $archive, "-o$stage", '-y')
            $extracted = ($result.ExitCode -eq 0)
            if (-not $extracted) { Mpv-Warn "7zr exited with code $($result.ExitCode)." }
        } catch {
            Mpv-Warn "7zr could not be used: $($_.Exception.Message)"
        }

        if (-not $extracted) {
            $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
            if (-not $tar) {
                throw 'Extraction failed and tar.exe is not available.'
            }
            Mpv-Info 'Trying tar.exe instead.'
            $result = Mpv-Run -Exe 'tar.exe' -Arguments @('-xf', $archive, '-C', $stage)
            if ($result.ExitCode -ne 0) {
                Mpv-ShowOutput $result.Output
                throw 'Extraction failed. The downloaded archive may be corrupt; retry with -Update.'
            }
        }

        if (-not (Test-Path -LiteralPath (Join-Path $stage 'mpv.exe'))) {
            throw "Extraction finished, but mpv.exe is missing in $stage. Retry with -Update."
        }

        try {
            Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
        } catch {
            throw "Could not write into $InstallDir. Close any running mpv instance and retry. ($($_.Exception.Message))"
        }

        $exe = Join-Path $InstallDir 'mpv.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            throw "mpv.exe is still missing in $InstallDir. Close any running mpv instance and retry."
        }

        $success = $true
        Mpv-Ok "mpv installed: $exe"
    } finally {
        if ($success) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Mpv-Warn "Partial download kept at $work"
        }
    }
}

# ---------------------------------------------------------------------------
# Config checkout
# ---------------------------------------------------------------------------
function Mpv-InitConfig {
    param([string]$RepoUrl, [string]$InstallDir, [string]$GitExe)

    $portable = Join-Path $InstallDir 'portable_config'

    if (Test-Path -LiteralPath $portable) {
        if (Test-Path -LiteralPath (Join-Path $portable '.git')) {
            Mpv-Step 'Updating config from git'
            $result = Mpv-Run -Exe $GitExe -Arguments @('-C', $portable, 'pull', '--ff-only', '--quiet')
            if ($result.ExitCode -ne 0) {
                Mpv-Warn 'git pull failed; keeping the config that is already on disk.'
                Mpv-ShowOutput $result.Output
                Mpv-Info 'This usually means there are uncommitted local changes. Run this script from portable_config to sync them first.'
            } else {
                Mpv-Ok 'Config is up to date.'
            }
        } else {
            $existing = @(Get-ChildItem -LiteralPath $portable -Force)
            if ($existing.Count -gt 0) {
                $backup = "$portable.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Move-Item -LiteralPath $portable -Destination $backup
                Mpv-Warn "Existing non-git folder moved to $backup"
            } else {
                Remove-Item -LiteralPath $portable -Force
            }
        }
    }

    if (-not (Test-Path -LiteralPath $portable)) {
        Mpv-Step 'Cloning config repository'
        $result = Mpv-Run -Exe $GitExe -Arguments @('clone', '--quiet', $RepoUrl, $portable)
        if ($result.ExitCode -ne 0) {
            Mpv-ShowOutput $result.Output
            throw "git clone failed: $RepoUrl (for a private repo, check your credentials or run the script from an already authenticated terminal)"
        }
        Mpv-Ok "Cloned into $portable"
    }

    $localConf = Join-Path $portable 'local.conf'
    if (-not (Test-Path -LiteralPath $localConf)) {
        New-Item -ItemType File -Path $localConf | Out-Null
        Mpv-Info 'Created local.conf for machine-specific overrides (git-ignored).'
    }

    return $portable
}

# ---------------------------------------------------------------------------
# Sync local changes back to the repository
# ---------------------------------------------------------------------------
function Mpv-Sync {
    param(
        [string]$Root,
        [string]$GitExe,
        [string]$CommitMessage,
        [switch]$NoPush
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        throw "Not a git repository: $Root"
    }

    Push-Location -LiteralPath $Root
    try {
        $result = Mpv-Run -Exe $GitExe -Arguments @('status', '--porcelain')
        if ($result.ExitCode -ne 0) {
            throw 'git status failed - this folder does not look like a healthy repository.'
        }
        $real = @($result.Output | Where-Object {
            $_ -isnot [System.Management.Automation.ErrorRecord] -and "$_".Trim() -ne ''
        })

        if ($real.Count -eq 0) {
            Mpv-Ok 'No local changes - nothing to commit.'
            return
        }

        Mpv-Step 'Local changes'
        foreach ($line in $real) {
            Write-Host "     $line" -ForegroundColor DarkGray
        }

        $result = Mpv-Run -Exe $GitExe -Arguments @('add', '-A')
        if ($result.ExitCode -ne 0) {
            Mpv-ShowOutput $result.Output
            throw 'git add failed.'
        }

        if (-not $CommitMessage) {
            $CommitMessage = 'config: sync from ' + $env:COMPUTERNAME + ' ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }

        $identity = Mpv-Run -Exe $GitExe -Arguments @('config', 'user.name')
        if ($identity.ExitCode -ne 0 -or -not $identity.Output) {
            $null = Mpv-Run -Exe $GitExe -Arguments @('config', 'user.name', $env:USERNAME)
            Mpv-Info "Set repo-local user.name to $env:USERNAME"
        }

        $identity = Mpv-Run -Exe $GitExe -Arguments @('config', 'user.email')
        if ($identity.ExitCode -ne 0 -or -not $identity.Output) {
            $null = Mpv-Run -Exe $GitExe -Arguments @('config', 'user.email', ($env:USERNAME + '@' + $env:COMPUTERNAME))
            Mpv-Info 'Set repo-local user.email.'
        }

        $result = Mpv-Run -Exe $GitExe -Arguments @('commit', '-m', $CommitMessage)
        if ($result.ExitCode -ne 0) {
            Mpv-ShowOutput $result.Output
            throw 'git commit failed.'
        }

        $result = Mpv-Run -Exe $GitExe -Arguments @('rev-parse', '--short', 'HEAD')
        $hash = @($result.Output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Select-Object -First 1)
        Mpv-Ok "Committed $hash"

        if ($NoPush) {
            Mpv-Info '-NoPush: the commit stays local.'
            return
        }

        $result = Mpv-Run -Exe $GitExe -Arguments @('push', '--quiet')
        if ($result.ExitCode -ne 0) {
            Mpv-ShowOutput $result.Output
            Mpv-Warn 'Push rejected. Trying to rebase onto the remote first...'

            $result = Mpv-Run -Exe $GitExe -Arguments @('pull', '--rebase', '--autostash', '--quiet')
            if ($result.ExitCode -ne 0) {
                Mpv-ShowOutput $result.Output
                $null = Mpv-Run -Exe $GitExe -Arguments @('rebase', '--abort')
                throw 'Automatic rebase failed. Resolve it manually: git pull --rebase, then git push.'
            }

            $result = Mpv-Run -Exe $GitExe -Arguments @('push', '--quiet')
            if ($result.ExitCode -ne 0) {
                Mpv-ShowOutput $result.Output
                throw 'git push failed. Check the remote URL and your credentials.'
            }
        }

        Mpv-Ok 'Pushed to origin.'
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Mpv-Main {
    param(
        [switch]$Install,
        [switch]$Sync,
        [switch]$Update,
        [switch]$ConfigOnly,
        [string]$Message,
        [string]$RepoUrl,
        [string]$InstallDir,
        [string]$MpvUrl,
        [string]$Arch,
        [switch]$NoPush
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # Windows PowerShell 5.1 on old builds; nothing else to do
    }

    $here = $PSScriptRoot
    $localRepo = $null
    if ($here -and (Test-Path -LiteralPath (Join-Path $here '.git'))) {
        $localRepo = $here
    }

    if ($Sync -and ($Install -or $Update -or $ConfigOnly)) {
        throw 'Use -Sync on its own, or -Install / -Update / -ConfigOnly on their own.'
    }

    $mode = 'install'
    if ($Sync) {
        $mode = 'sync'
    } elseif ($Install -or $Update -or $ConfigOnly) {
        $mode = 'install'
    } elseif ($localRepo -and ([IO.Path]::GetFileName($localRepo) -eq 'portable_config')) {
        $mode = 'sync'
    }

    # Split-Path -LiteralPath has no -Leaf parameter set on Windows PowerShell 5.1
    $leafIsPortable = $localRepo -and ([IO.Path]::GetFileName($localRepo) -eq 'portable_config')

    if (-not $InstallDir) {
        if ($leafIsPortable) {
            $InstallDir = [IO.Path]::GetDirectoryName($localRepo)
        } else {
            # "Run it here, install it here": the current directory gets a mpv folder.
            $cwd = (Get-Location).Path
            if ((Test-Path -LiteralPath (Join-Path $cwd 'portable_config\.git')) -or
                (Test-Path -LiteralPath (Join-Path $cwd 'mpv.exe'))) {
                # Already an install root (re-run for an update): do not nest mpv\mpv.
                $InstallDir = $cwd
            } else {
                $InstallDir = Join-Path $cwd 'mpv'
            }
        }
    }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)

    # Fail early with a readable message instead of a raw New-Item/OS error.
    try {
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $InstallDir ('.mpv-write-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType File -Path $probe -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        throw "Cannot write to $InstallDir. Change to a folder you are allowed to write to (for example: cd D:\Tools) and run the command again."
    }

    $portable = Join-Path $InstallDir 'portable_config'

    if ($mode -eq 'sync') {
        $root = $localRepo
        if (-not $root) {
            if (Test-Path -LiteralPath (Join-Path $portable '.git')) { $root = $portable }
        }
        if (-not $root) {
            throw 'Sync mode must run from inside portable_config. Try: cd <install-dir>\portable_config; .\install.ps1'
        }

        Write-Host ''
        Write-Host '  mpv config sync' -ForegroundColor White
        Mpv-Info "repository : $root"

        $gitExe = Mpv-EnsureGit -InstallDir $InstallDir
        Mpv-Sync -Root $root -GitExe $gitExe -CommitMessage $Message -NoPush:$NoPush
        return
    }

    $resolvedRepo = Mpv-ResolveRepoUrl -Value $RepoUrl -Fallback $DefaultRepoUrl
    $resolvedArch = Mpv-ResolveArch -Value $Arch

    Write-Host ''
    Write-Host '  mpv portable setup' -ForegroundColor White
    Mpv-Info "install dir : $InstallDir"
    Mpv-Info "config repo : $resolvedRepo"
    Mpv-Info "architecture: $resolvedArch"
    if ($localRepo -and ($localRepo -ne $portable)) {
        Mpv-Info "this script runs from $localRepo (use -Sync to commit changes from that clone)"
    }

    $gitExe = Mpv-EnsureGit -InstallDir $InstallDir
    if ($gitExe -ne 'git') {
        Mpv-Info "git         : $gitExe"
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $portable = Mpv-InitConfig -RepoUrl $resolvedRepo -InstallDir $InstallDir -GitExe $gitExe

    if ($ConfigOnly) {
        Mpv-Info '-ConfigOnly: skipped the mpv download.'
    } else {
        $exe = Join-Path $InstallDir 'mpv.exe'
        if ((Test-Path -LiteralPath $exe) -and (-not $Update)) {
            Mpv-Ok "mpv is already installed: $exe"
            Mpv-Info 'Pass -Update to download the latest build.'
        } else {
            Mpv-InstallBinary -InstallDir $InstallDir -OverrideUrl $MpvUrl -Arch $resolvedArch
        }
    }

    Write-Host ''
    Mpv-Ok 'Ready.'
    $exePath = Join-Path $InstallDir 'mpv.exe'
    if (Test-Path -LiteralPath $exePath) {
        Write-Host "     mpv    : $exePath"
    } else {
        Write-Host '     mpv    : not downloaded (-ConfigOnly)'
    }
    Write-Host "     config : $portable"
    $toolsDir = Join-Path $InstallDir 'tools'
    if (Test-Path -LiteralPath $toolsDir) {
        Write-Host "     tools  : $toolsDir"
    }
    Write-Host "     repo   : $resolvedRepo"
    Write-Host ''
    Mpv-Info "Sync your changes: cd `"$portable`"; .\install.ps1"
    Mpv-Info 'Update mpv later : .\install.ps1 -Update'
}

try {
    Mpv-Main -Install:$Install -Sync:$Sync -Update:$Update -ConfigOnly:$ConfigOnly `
        -Message $Message -RepoUrl $RepoUrl -InstallDir $InstallDir `
        -MpvUrl $MpvUrl -Arch $Arch -NoPush:$NoPush
} catch {
    Write-Host ''
    Write-Host "[x] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '    Aborted.' -ForegroundColor Red
}
