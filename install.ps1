#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot installer for MochaGlass on Windows 10/11.

.DESCRIPTION
    Installs every external tool MochaGlass needs (Komorebi, whkd, YASB, Cava,
    Flow Launcher, Windows Terminal and the JetBrainsMono Nerd Font), deploys
    the YASB, Cava, Komorebi, whkd and Flow Launcher configurations, installs
    device_status.exe into %USERPROFILE%\scripts, merges the Catppuccin Mocha
    theme into the Windows Terminal settings, enables autostart and starts
    Komorebi + YASB.

    Existing YASB/Cava/Komorebi/whkd/Flow Launcher/Windows Terminal
    configurations are backed up before they are touched. Re-running the
    script is safe.

    Run it from the repository root:
        powershell -ExecutionPolicy Bypass -File .\install.ps1
    or from PowerShell 7:
        pwsh -ExecutionPolicy Bypass -File .\install.ps1

.PARAMETER SkipApps
    Do not install or check Komorebi, whkd, YASB, Cava, Flow Launcher or
    Windows Terminal.

.PARAMETER SkipFont
    Do not install the JetBrainsMono Nerd Font.

.PARAMETER SkipConfigs
    Do not deploy the YASB, Cava, Komorebi, whkd or Flow Launcher
    configuration files.

.PARAMETER SkipWidget
    Do not install device_status.exe.

.PARAMETER SkipTerminal
    Do not merge the theme into the Windows Terminal settings.

.PARAMETER NoStart
    Install and configure everything, but do not start Komorebi or YASB.

.PARAMETER NoAutostart
    Do not add Komorebi/YASB to the Windows startup folder.

.PARAMETER NoElevate
    Do not relaunch the script as administrator. Some package installs may fail
    without elevation; the script will keep going and report what failed.

.PARAMETER BuildWidget
    Build device_status.exe from source instead of downloading the release
    binary. Requires the Rust toolchain (cargo).

.PARAMETER DeviceStatusSource
    Path to a custom device_status.exe to install instead of downloading or
    building one.

.PARAMETER WeatherApiKey
    OpenWeatherMap API key. If omitted, the weather widget is removed from the
    bar layout (it is optional in MochaGlass).

.PARAMETER WeatherCity
    City name or "lat,lon" coordinates for the weather widget. Required
    together with WeatherApiKey.

.PARAMETER WallpaperPath
    Folder that the YASB wallpapers widget should use. Defaults to
    %USERPROFILE%\Pictures\Wallpapers and is populated from the repository's
    Wallpapers folder when it is empty.

.PARAMETER ConfigRoot
    Root folder that receives the yasb/ and cava/ configuration directories.
    Defaults to %USERPROFILE%\.config.

.PARAMETER DryRun
    Print every action without changing anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    .\install.ps1 -WeatherApiKey 0123456789abcdef -WeatherCity "Paris,fr" -WallpaperPath "D:\Wallpapers"

.EXAMPLE
    .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$SkipApps,
    [switch]$SkipFont,
    [switch]$SkipConfigs,
    [switch]$SkipWidget,
    [switch]$SkipTerminal,
    [switch]$NoStart,
    [switch]$NoAutostart,
    [switch]$NoElevate,
    [switch]$BuildWidget,
    [string]$DeviceStatusSource = '',
    [string]$WeatherApiKey = '',
    [string]$WeatherCity = '',
    [string]$WallpaperPath = '',
    [string]$ConfigRoot = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:RepoRoot = Split-Path -Parent $PSCommandPath
$script:DryRun = [bool]$DryRun
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:WingetAvailable = $false
$script:LogPath = Join-Path $env:TEMP ('mochaglass-install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:YasbExePath = ''
$script:KomorebiExePath = ''

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    Write-Host ''
    Write-Host '  MochaGlass installer' -ForegroundColor Magenta
    Write-Host '  Catppuccin Mocha ricing setup for Windows' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('-' * 72) -ForegroundColor DarkGray
}

function Write-Info {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Gray
}

function Write-Good {
    param([string]$Text)
    Write-Host "    [ok] $Text" -ForegroundColor Green
}

function Write-Note {
    param([string]$Text)
    Write-Host "    [..] $Text" -ForegroundColor Yellow
}

function Write-Bad {
    param([string]$Text)
    Write-Host "    [!!] $Text" -ForegroundColor Red
}

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Component = $Name
        Status    = $Status
        Detail    = $Detail
    })
}

function Add-Failure {
    param([string]$Text)
    $script:Failures.Add($Text)
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    $parts = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $sources = @(
        ($env:Path -split ';'),
        ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'),
        ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
    )

    foreach ($source in $sources) {
        foreach ($part in $source) {
            $trimmed = "$part".Trim()
            if (-not $trimmed) { continue }
            $key = $trimmed.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $parts.Add($trimmed)
        }
    }

    $env:Path = ($parts -join ';')
}

function Find-Tool {
    param(
        [string]$Name,
        [string[]]$Candidates = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in $Candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded) {
            $dir = Split-Path -Parent $expanded
            if ($env:Path -notlike "*$dir*") {
                $env:Path = "$dir;$env:Path"
            }
            return $expanded
        }
    }

    return $null
}

function Test-WingetPackageInstalled {
    param([string]$Id)

    if (-not $script:WingetAvailable) {
        return $false
    }

    $output = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return $false
    }

    return (($output | Out-String) -match [regex]::Escape($Id))
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Label,
        [string]$Component
    )

    if (-not $script:WingetAvailable) {
        Write-Bad "WinGet is not available, cannot install $Label."
        Add-Result $Component 'failed' 'WinGet is not available'
        Add-Failure "$Label could not be installed because WinGet is missing."
        return $false
    }

    if (Test-WingetPackageInstalled -Id $Id) {
        Write-Good "$Label is already installed."
        Add-Result $Component 'present' $Id
        return $true
    }

    if ($script:DryRun) {
        Write-Note "[dry-run] winget install --id $Id --exact"
        Add-Result $Component 'dry-run' "would install $Id"
        return $true
    }

    Write-Info "Installing $Label ($Id)..."
    & winget install --id $Id --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity

    $code = $LASTEXITCODE
    Update-SessionPath

    if ($code -ne 0 -and -not (Test-WingetPackageInstalled -Id $Id)) {
        Write-Bad "$Label installation failed (WinGet exit code $code)."
        Add-Result $Component 'failed' "winget exit code $code"
        Add-Failure "$Label could not be installed. Install it manually from $Id."
        return $false
    }

    Write-Good "$Label installed."
    Add-Result $Component 'installed' $Id
    return $true
}

function Backup-Path {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destination = "$Path.mochaglass-backup-$stamp"
    $counter = 1
    while (Test-Path -LiteralPath $destination) {
        $destination = "$Path.mochaglass-backup-$stamp-$counter"
        $counter++
    }

    Copy-Item -LiteralPath $Path -Destination $destination -Recurse -Force
    return $destination
}

function Invoke-Download {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    if ($script:DryRun) {
        Write-Note "[dry-run] download $Uri -> $OutFile"
        return
    }

    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

# ---------------------------------------------------------------------------
# JSON / JSONC helpers (Windows Terminal settings are JSON with comments)
# ---------------------------------------------------------------------------

function Remove-JsonComments {
    param([string]$Text)

    if (-not $Text) { return '' }

    $text = $Text.TrimStart([char]0xFEFF)
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $i = 0

    while ($i -lt $text.Length) {
        $char = $text[$i]

        if ($inString) {
            [void]$builder.Append($char)
            if ($escaped) {
                $escaped = $false
            } elseif ($char -eq '\') {
                $escaped = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            [void]$builder.Append($char)
            $i++
            continue
        }

        if ($char -eq '/' -and ($i + 1) -lt $text.Length) {
            $next = $text[$i + 1]

            if ($next -eq '/') {
                while ($i -lt $text.Length -and $text[$i] -ne "`n" -and $text[$i] -ne "`r") {
                    $i++
                }
                if ($i -lt $text.Length) {
                    [void]$builder.Append($text[$i])
                    $i++
                }
                continue
            }

            if ($next -eq '*') {
                $i += 2
                while (($i + 1) -lt $text.Length -and -not ($text[$i] -eq '*' -and $text[$i + 1] -eq '/')) {
                    $i++
                }
                $i += 2
                continue
            }
        }

        if ($char -eq ',') {
            $lookahead = $i + 1
            while ($lookahead -lt $text.Length -and [char]::IsWhiteSpace($text[$lookahead])) {
                $lookahead++
            }
            if ($lookahead -lt $text.Length -and ($text[$lookahead] -eq '}' -or $text[$lookahead] -eq ']')) {
                $i++
                continue
            }
        }

        [void]$builder.Append($char)
        $i++
    }

    return $builder.ToString()
}

function ConvertTo-HashtableDeep {
    param($Object)

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Object.Keys) {
            $result[$key] = ConvertTo-HashtableDeep $Object[$key]
        }
        return $result
    }

    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Object.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HashtableDeep $property.Value
        }
        return $result
    }

    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Object) {
            [void]$list.Add((ConvertTo-HashtableDeep $item))
        }
        return ,$list.ToArray()
    }

    return $Object
}

function Merge-HashtableDeep {
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )

    foreach ($key in $Overlay.Keys) {
        if ($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
            Merge-HashtableDeep -Base $Base[$key] -Overlay $Overlay[$key]
        } else {
            $Base[$key] = $Overlay[$key]
        }
    }
}

function Merge-KeyedArray {
    param(
        [object[]]$Base,
        [object[]]$Additions,
        [string]$Key
    )

    $result = @($Base)

    foreach ($item in @($Additions)) {
        if ($null -eq $item -or $item -isnot [hashtable]) { continue }

        $foundIndex = -1
        for ($i = 0; $i -lt $result.Count; $i++) {
            $candidate = $result[$i]
            if ($candidate -is [hashtable] -and $candidate.ContainsKey($Key) -and
                $item.ContainsKey($Key) -and $candidate[$Key] -eq $item[$Key]) {
                $foundIndex = $i
                break
            }
        }

        if ($foundIndex -ge 0) {
            $result[$foundIndex] = $item
        } else {
            $result += $item
        }
    }

    return ,$result
}

function Get-TerminalSettingsPath {
    $storePackage = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe'
    $previewPackage = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe'
    $unpackaged = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal'

    $existing = @(
        (Join-Path $storePackage 'LocalState\settings.json'),
        (Join-Path $previewPackage 'LocalState\settings.json'),
        (Join-Path $unpackaged 'settings.json')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if ($existing.Count -gt 0) {
        return ($existing | Select-Object -First 1)
    }

    if (Test-Path -LiteralPath $storePackage) {
        $stateDir = Join-Path $storePackage 'LocalState'
        if (-not (Test-Path -LiteralPath $stateDir)) {
            if (-not $script:DryRun) {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            }
        }
        return (Join-Path $stateDir 'settings.json')
    }

    if (Test-Path -LiteralPath $previewPackage) {
        $stateDir = Join-Path $previewPackage 'LocalState'
        if (-not (Test-Path -LiteralPath $stateDir)) {
            if (-not $script:DryRun) {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            }
        }
        return (Join-Path $stateDir 'settings.json')
    }

    if (Test-Path -LiteralPath $unpackaged) {
        return (Join-Path $unpackaged 'settings.json')
    }

    return $null
}

# ---------------------------------------------------------------------------
# Font helpers
# ---------------------------------------------------------------------------

function Test-FontFamilyInstalled {
    param([string]$Family)

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )

    foreach ($key in $keys) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }

        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -like "$Family *") {
                return $true
            }
        }
    }

    return $false
}

function Install-NerdFontFallback {
    $workDir = Join-Path $env:TEMP ('MochaGlass-JetBrainsMono-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $registryKey = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    $archivePath = ''

    try {
        if ($tar) {
            $archivePath = Join-Path $env:TEMP 'MochaGlass-JetBrainsMono.tar.xz'
            Write-Info 'Downloading the official JetBrainsMono Nerd Font archive (~7 MB)...'
            Invoke-Download -Uri 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz' -OutFile $archivePath

            if ($script:DryRun) {
                return $true
            }

            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            & $tar.Source -xf $archivePath -C $workDir
            if ($LASTEXITCODE -ne 0) {
                throw "tar exited with code $LASTEXITCODE while extracting the font archive."
            }
        } else {
            $archivePath = Join-Path $env:TEMP 'MochaGlass-JetBrainsMono.zip'
            Write-Info 'Downloading the official JetBrainsMono Nerd Font archive (~134 MB)...'
            Invoke-Download -Uri 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip' -OutFile $archivePath

            if ($script:DryRun) {
                return $true
            }

            Expand-Archive -LiteralPath $archivePath -DestinationPath $workDir -Force
        }

        New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
        New-Item -Path $registryKey -Force | Out-Null

        if (-not ('Win32.Gdi32' -as [type])) {
            Add-Type -Name Gdi32 -Namespace Win32 -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern int AddFontResource(string lpFileName);
'@
        }

        if (-not ('Win32.User32' -as [type])) {
            Add-Type -Name User32 -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
'@
        }

        # Install the two families the setup needs:
        #   JetBrainsMonoNerdFont-*      -> "JetBrainsMono NF"  (Windows Terminal)
        #   JetBrainsMonoNerdFontPropo-* -> "JetBrainsMono NFP" (YASB / Flow Launcher)
        # The Nerd Font Mono (NFM) and no-ligature (NL) variants are not needed.
        $fonts = @(Get-ChildItem -Path $workDir -Filter '*.ttf' -Recurse |
            Where-Object { $_.Name -match '^JetBrainsMonoNerdFont(-Propo)?-' })

        if ($fonts.Count -eq 0) {
            throw 'No JetBrainsMono NF/NFP font files were found in the downloaded archive.'
        }

        foreach ($font in $fonts) {
            if ($font.Name -like 'JetBrainsMonoNerdFontPropo-*') {
                $family = 'JetBrainsMono NFP'
            } else {
                $family = 'JetBrainsMono NF'
            }

            $style = $font.BaseName -replace '^JetBrainsMonoNerdFont(-Propo)?-', ''
            if (-not $style) { $style = 'Regular' }

            $target = Join-Path $fontDir $font.Name
            Copy-Item -LiteralPath $font.FullName -Destination $target -Force

            $registryName = "$family $style (TrueType)"
            New-ItemProperty -Path $registryKey -Name $registryName -Value $target `
                -PropertyType String -Force | Out-Null
            [void][Win32.Gdi32]::AddFontResource($target)
        }

        [void][Win32.User32]::SendMessage([IntPtr]0xFFFF, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero)

        return ((Test-FontFamilyInstalled -Family 'JetBrainsMono NFP') -and
                (Test-FontFamilyInstalled -Family 'JetBrainsMono NF'))
    } finally {
        if (-not $script:DryRun) {
            if ($archivePath -and (Test-Path -LiteralPath $archivePath)) {
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $workDir) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# device_status helpers
# ---------------------------------------------------------------------------

function Build-DeviceStatus {
    $projectDir = Join-Path $script:RepoRoot 'device_status'
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        throw 'cargo was not found. Install the Rust toolchain to build device_status.'
    }

    Write-Info 'Building device_status.exe from source...'
    Push-Location $projectDir
    try {
        & cargo build --release --locked
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    $exe = Join-Path $projectDir 'target\release\device_status.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw 'cargo reported success but device_status.exe was not produced.'
    }
    return $exe
}

function Resolve-DeviceStatusBinary {
    if ($DeviceStatusSource) {
        $expanded = [Environment]::ExpandEnvironmentVariables($DeviceStatusSource)
        if (-not (Test-Path -LiteralPath $expanded)) {
            throw "DeviceStatusSource does not exist: $expanded"
        }
        Write-Info "Using custom binary: $expanded"
        return (Resolve-Path -LiteralPath $expanded).Path
    }

    if ($BuildWidget) {
        return Build-DeviceStatus
    }

    $built = Join-Path $script:RepoRoot 'device_status\target\release\device_status.exe'
    $buildInputs = @(
        (Join-Path $script:RepoRoot 'device_status\src\main.rs'),
        (Join-Path $script:RepoRoot 'device_status\Cargo.toml'),
        (Join-Path $script:RepoRoot 'device_status\Cargo.lock'),
        (Join-Path $script:RepoRoot 'device_status\build.rs')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if ((Test-Path -LiteralPath $built) -and $buildInputs.Count -gt 0) {
        $newestInput = ($buildInputs | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
            Sort-Object -Descending | Select-Object -First 1)
        if ((Get-Item -LiteralPath $built).LastWriteTime -ge $newestInput) {
            Write-Info 'Using the existing release build in device_status\target\release.'
            return $built
        }
    }

    $downloadPath = Join-Path $env:TEMP 'MochaGlass-device_status.exe'
    $latestUrl = 'https://github.com/Hyacinthe-primus/MochaGlass/releases/latest/download/device_status.exe'
    $sumsUrl = 'https://github.com/Hyacinthe-primus/MochaGlass/releases/latest/download/SHA256SUMS.txt'

    if ($script:DryRun) {
        Write-Note "[dry-run] download $latestUrl"
        return $downloadPath
    }

    try {
        Write-Info 'Downloading the latest device_status.exe release...'
        Invoke-WebRequest -Uri $latestUrl -OutFile $downloadPath -UseBasicParsing

        try {
            $sums = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
            $expectedLine = ($sums -split "`r?`n" | Where-Object { $_ -match 'device_status\.exe' } | Select-Object -First 1)
            if ($expectedLine) {
                $expected = ($expectedLine -split '\s+')[0]
                $actual = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
                if ($actual -ne $expected) {
                    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                    throw "Checksum mismatch for device_status.exe (expected $expected, got $actual)."
                }
                Write-Good 'Checksum verified against SHA256SUMS.txt.'
            }
        } catch {
            if ($_.Exception.Message -like '*Checksum mismatch*') { throw }
            Write-Info 'No published checksum found, skipping verification.'
        }

        if ((Get-Item -LiteralPath $downloadPath).Length -lt 100000) {
            throw 'The downloaded device_status.exe looks too small to be valid.'
        }

        return $downloadPath
    } catch {
        Write-Note "Release download failed: $($_.Exception.Message)"
    }

    $rootBinary = Join-Path $script:RepoRoot 'device_status.exe'
    if (Test-Path -LiteralPath $rootBinary) {
        Write-Info 'Falling back to device_status.exe from the repository root.'
        return $rootBinary
    }

    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        Write-Info 'Falling back to building device_status.exe from source.'
        return Build-DeviceStatus
    }

    throw 'Could not obtain device_status.exe. Pass -DeviceStatusSource <path> or install Rust and use -BuildWidget.'
}

# ---------------------------------------------------------------------------
# YASB config helpers
# ---------------------------------------------------------------------------

function Get-YasbConfigDirectory {
    if ($ConfigRoot) {
        return (Join-Path ([IO.Path]::GetFullPath($ConfigRoot)) 'yasb')
    }

    if ($script:YasbExePath) {
        $yasbc = Join-Path (Split-Path -Parent $script:YasbExePath) 'yasbc.exe'
        if (Test-Path -LiteralPath $yasbc) {
            $output = & $yasbc -c 2>$null
            $candidate = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[A-Za-z]:\\' }) |
                Select-Object -Last 1
            if ($candidate) {
                return $candidate
            }
        }
    }

    return (Join-Path $env:USERPROFILE '.config\yasb')
}

function Set-YamlScalarLine {
    param(
        [string]$Content,
        [string]$Key,
        [string]$Value
    )

    $pattern = '(?m)^(?<prefix>\s*' + [regex]::Escape($Key) + ':\s*).*$'
    return [regex]::Replace($Content, $pattern, {
        param($match)
        $match.Groups['prefix'].Value + $Value
    })
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Banner

try {
    Start-Transcript -Path $script:LogPath -Force | Out-Null
} catch {
    $script:LogPath = ''
}

$isAdmin = Test-IsAdmin
$currentExe = (Get-Process -Id $PID).Path

Write-Info "Repository: $script:RepoRoot"
Write-Info "PowerShell: $($PSVersionTable.PSVersion) ($currentExe)"
Write-Info "Administrator: $isAdmin"

if (-not $script:DryRun -and -not $isAdmin -and -not $NoElevate) {
    Write-Note 'Administrator rights are needed to install Komorebi, YASB and the Nerd Font.'
    Write-Note 'Relaunching this installer elevated in a new window...'

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $arguments += "-$key" }
        } elseif ($null -ne $value -and "$value" -ne '') {
            $escaped = "$value".Replace('"', '\"')
            $arguments += "-$key"
            $arguments += ('"{0}"' -f $escaped)
        }
    }

    try {
        Start-Process -FilePath $currentExe -Verb RunAs -ArgumentList $arguments
        Write-Good 'The elevated installer is running in a new window.'
        exit 0
    } catch {
        Write-Bad "Elevation was cancelled or failed: $($_.Exception.Message)"
        Write-Bad 'Re-run this script from an elevated PowerShell window, or pass -NoElevate.'
        exit 1
    }
}

$requiredPaths = @(
    (Join-Path $script:RepoRoot 'MochaGlass_YASB\config.yaml'),
    (Join-Path $script:RepoRoot 'MochaGlass_YASB\styles.css'),
    (Join-Path $script:RepoRoot 'MochaGlass_Cava\config'),
    (Join-Path $script:RepoRoot 'MochaGlass_Komorebi\komorebi.json'),
    (Join-Path $script:RepoRoot 'MochaGlass_Komorebi\whkdrc'),
    (Join-Path $script:RepoRoot 'MochaGlass_FlowLauncher\TranslucentFlow.xaml'),
    (Join-Path $script:RepoRoot 'MochaGlass_Terminal\settings.json')
)

$missing = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    Write-Bad 'This script must be run from the MochaGlass repository root.'
    foreach ($path in $missing) {
        Write-Bad "Missing: $path"
    }
    exit 1
}

Update-SessionPath
$script:WingetAvailable = [bool](Get-Command winget -ErrorAction SilentlyContinue)

# --- Step 1: applications ---------------------------------------------------
Write-Section '1/9  Applications'

if ($SkipApps) {
    Write-Info 'Skipped (-SkipApps).'
    Add-Result 'Applications' 'skipped' '-SkipApps'
} elseif (-not $script:WingetAvailable) {
    Write-Bad 'WinGet was not found.'
    Write-Info 'Install "App Installer" from the Microsoft Store, then re-run this script:'
    Write-Info 'https://apps.microsoft.com/detail/9nblggh4nns1'
    Add-Result 'Applications' 'failed' 'WinGet is missing'
    Add-Failure 'WinGet is missing; install App Installer from the Microsoft Store.'
} else {
    $komorebi = Find-Tool -Name 'komorebic' -Candidates @(
        '%ProgramFiles%\komorebi\bin\komorebic.exe',
        '%LOCALAPPDATA%\Programs\komorebi\bin\komorebic.exe'
    )
    if ($komorebi) {
        Write-Good 'Komorebi is already installed.'
        Add-Result 'Komorebi' 'present' $komorebi
    } else {
        [void](Install-WingetPackage -Id 'LGUG2Z.komorebi' -Label 'Komorebi' -Component 'Komorebi')
    }

    $whkd = Find-Tool -Name 'whkd' -Candidates @(
        '%ProgramFiles%\whkd\bin\whkd.exe',
        '%LOCALAPPDATA%\Programs\whkd\bin\whkd.exe'
    )
    if ($whkd) {
        Write-Good 'whkd is already installed.'
        Add-Result 'whkd' 'present' $whkd
    } else {
        [void](Install-WingetPackage -Id 'LGUG2Z.whkd' -Label 'whkd' -Component 'whkd')
    }

    $yasbc = Find-Tool -Name 'yasbc' -Candidates @(
        '%ProgramFiles%\YASB\yasbc.exe',
        '%LOCALAPPDATA%\Programs\YASB\yasbc.exe'
    )
    if ($yasbc) {
        Write-Good 'YASB is already installed.'
        Add-Result 'YASB' 'present' $yasbc
    } else {
        [void](Install-WingetPackage -Id 'AmN.yasb' -Label 'YASB' -Component 'YASB')
    }

    $cava = Find-Tool -Name 'cava' -Candidates @(
        '%LOCALAPPDATA%\cava\cava.exe',
        '%ProgramFiles%\cava\cava.exe'
    )
    if ($cava) {
        Write-Good 'Cava is already installed.'
        Add-Result 'Cava' 'present' $cava
    } else {
        [void](Install-WingetPackage -Id 'karlstav.cava' -Label 'Cava' -Component 'Cava')
    }

    $flow = Find-Tool -Name 'flow.launcher' -Candidates @(
        '%LOCALAPPDATA%\FlowLauncher\Flow.Launcher.exe',
        '%ProgramFiles%\Flow Launcher\Flow.Launcher.exe'
    )
    if ($flow) {
        Write-Good 'Flow Launcher is already installed.'
        Add-Result 'Flow Launcher' 'present' $flow
    } else {
        [void](Install-WingetPackage -Id 'Flow-Launcher.Flow-Launcher' -Label 'Flow Launcher' -Component 'Flow Launcher')
    }

    $wt = Find-Tool -Name 'wt' -Candidates @(
        '%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe'
    )
    if ($wt) {
        Write-Good 'Windows Terminal is already installed.'
        Add-Result 'Windows Terminal' 'present' $wt
    } else {
        [void](Install-WingetPackage -Id 'Microsoft.WindowsTerminal' -Label 'Windows Terminal' -Component 'Windows Terminal')
    }

    Update-SessionPath

    $script:YasbExePath = Find-Tool -Name 'yasbc' -Candidates @(
        '%ProgramFiles%\YASB\yasbc.exe',
        '%LOCALAPPDATA%\Programs\YASB\yasbc.exe'
    )
    $script:KomorebiExePath = Find-Tool -Name 'komorebic' -Candidates @(
        '%ProgramFiles%\komorebi\bin\komorebic.exe',
        '%LOCALAPPDATA%\Programs\komorebi\bin\komorebic.exe'
    )
}

# --- Step 2: font -----------------------------------------------------------
Write-Section '2/9  JetBrainsMono Nerd Font'

if ($SkipFont) {
    Write-Info 'Skipped (-SkipFont).'
    Add-Result 'Nerd Font' 'skipped' '-SkipFont'
} elseif ((Test-FontFamilyInstalled -Family 'JetBrainsMono NFP') -and
          (Test-FontFamilyInstalled -Family 'JetBrainsMono NF')) {
    Write-Good 'JetBrainsMono Nerd Font (NF + NFP) is already installed.'
    Add-Result 'Nerd Font' 'present' 'JetBrainsMono NF / NFP'
} elseif ($script:DryRun) {
    Write-Note '[dry-run] install the JetBrainsMono Nerd Font.'
    Add-Result 'Nerd Font' 'dry-run' 'would install'
} else {
    $fontOk = $false
    if ($script:WingetAvailable) {
        Write-Info 'Installing the font with WinGet...'
        & winget install --id DEVCOM.JetBrainsMonoNerdFont --exact --source winget --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity
        $fontOk = ((Test-FontFamilyInstalled -Family 'JetBrainsMono NFP') -and
                   (Test-FontFamilyInstalled -Family 'JetBrainsMono NF'))
    }

    if (-not $fontOk) {
        Write-Note 'WinGet font install did not provide the needed families; using the official archive.'
        try {
            $fontOk = Install-NerdFontFallback
        } catch {
            Write-Bad "Font installation failed: $($_.Exception.Message)"
        }
    }

    if ($fontOk) {
        Write-Good 'JetBrainsMono Nerd Font installed.'
        Add-Result 'Nerd Font' 'installed' 'JetBrainsMono NF / NFP'
    } else {
        Add-Result 'Nerd Font' 'failed' 'JetBrainsMono NF / NFP not found'
        Add-Failure 'The JetBrainsMono Nerd Font could not be installed.'
    }
}

# --- Step 3: YASB and Cava configs -----------------------------------------
Write-Section '3/9  YASB and Cava configuration'

if ($SkipConfigs) {
    Write-Info 'Skipped (-SkipConfigs).'
    Add-Result 'Configuration' 'skipped' '-SkipConfigs'
} else {
    $yasbDir = Get-YasbConfigDirectory
    $cavaDir = if ($ConfigRoot) {
        Join-Path ([IO.Path]::GetFullPath($ConfigRoot)) 'cava'
    } else {
        Join-Path $env:USERPROFILE '.config\cava'
    }

    $yasbSource = Join-Path $script:RepoRoot 'MochaGlass_YASB'
    $cavaSource = Join-Path $script:RepoRoot 'MochaGlass_Cava\config'

    if ($script:DryRun) {
        Write-Note "[dry-run] deploy YASB config to $yasbDir"
        Write-Note "[dry-run] deploy Cava config to $cavaDir\config"
        Add-Result 'Configuration' 'dry-run' 'would deploy YASB and Cava configs'
    } else {
        try {
            $yasbBackup = Backup-Path -Path $yasbDir
            if ($yasbBackup) { Write-Info "Backed up YASB config to $yasbBackup" }

            New-Item -ItemType Directory -Path $yasbDir -Force | Out-Null
            Copy-Item -Path (Join-Path $yasbSource '*') -Destination $yasbDir -Recurse -Force

            $configPath = Join-Path $yasbDir 'config.yaml'
            $configText = [IO.File]::ReadAllText($configPath)

            $exePath = Join-Path $env:USERPROFILE 'scripts\device_status.exe'
            $yamlExePath = $exePath.Replace('\', '\\')
            # YASB runs run_cmd through cmd.exe, so quote the path for usernames
            # and folders that contain spaces.
            $yamlRunCmd = ('"{0}"' -f $exePath).Replace('\', '\\').Replace('"', '\"')
            $configText = Set-YamlScalarLine -Content $configText -Key 'run_cmd' -Value ('"{0}"' -f $yamlRunCmd)

            # device_status.exe writes UTF-8 JSON; make sure YASB decodes it as
            # UTF-8 instead of the system ANSI code page.
            $encodingRegex = [regex]'(?m)^(?<indent>[ \t]*)use_shell:[ \t]*true[ \t]*(?:#.*)?\r?$'
            $configText = $encodingRegex.Replace($configText, {
                param($match)
                $line = $match.Value.Replace("`r", '')
                $line + "`r`n" + $match.Groups['indent'].Value + 'encoding: "utf-8"'
            }, 1)

            $wallpapers = if ($WallpaperPath) {
                [IO.Path]::GetFullPath(([Environment]::ExpandEnvironmentVariables($WallpaperPath)))
            } else {
                Join-Path $env:USERPROFILE 'Pictures\Wallpapers'
            }

            New-Item -ItemType Directory -Path $wallpapers -Force | Out-Null
            $existingWallpapers = @(Get-ChildItem -Path $wallpapers -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp|webp)$' })

            if ($existingWallpapers.Count -eq 0) {
                $repoWallpapers = Join-Path $script:RepoRoot 'Wallpapers'
                if (Test-Path -LiteralPath $repoWallpapers) {
                    Copy-Item -Path (Join-Path $repoWallpapers '*') -Destination $wallpapers -Force
                    Write-Info 'Copied the repository wallpapers into the wallpaper folder.'
                }
            }

            $yamlWallpapers = $wallpapers.Replace('\', '/')
            $configText = Set-YamlScalarLine -Content $configText -Key 'image_path' -Value ('"{0}"' -f $yamlWallpapers)

            if ($WeatherApiKey -and $WeatherCity) {
                $configText = Set-YamlScalarLine -Content $configText -Key 'api_key' -Value ('"{0}"' -f $WeatherApiKey)
                $configText = Set-YamlScalarLine -Content $configText -Key 'location' -Value ('"{0}"' -f $WeatherCity)
                Write-Good 'Weather widget configured.'
            } else {
                $configText = [regex]::Replace($configText, '(?m)^[ \t]*"weather",[ \t]*(?:#.*)?\r?\n', '')
                Write-Info 'Weather widget disabled (pass -WeatherApiKey and -WeatherCity to enable it).'
            }

            if (-not $configText.Contains($yamlExePath)) {
                throw 'Failed to patch the board_status run_cmd path in config.yaml.'
            }
            if (-not $configText.Contains($yamlWallpapers)) {
                throw 'Failed to patch the wallpapers image_path in config.yaml.'
            }

            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($configPath, $configText, $utf8NoBom)

            $cavaBackup = Backup-Path -Path $cavaDir
            if ($cavaBackup) { Write-Info "Backed up Cava config to $cavaBackup" }

            New-Item -ItemType Directory -Path $cavaDir -Force | Out-Null
            Copy-Item -LiteralPath $cavaSource -Destination (Join-Path $cavaDir 'config') -Force

            Write-Good "YASB config deployed to $yasbDir"
            Write-Good "Cava config deployed to $cavaDir"
            Write-Good 'device_status path, wallpaper path and weather settings patched.'
            Add-Result 'Configuration' 'installed' $yasbDir
        } catch {
            Write-Bad "Configuration deployment failed: $($_.Exception.Message)"
            Add-Result 'Configuration' 'failed' $_.Exception.Message
            Add-Failure "YASB/Cava configuration deployment failed: $($_.Exception.Message)"
        }
    }
}

# --- Step 4: Komorebi and whkd configuration --------------------------------
Write-Section '4/9  Komorebi and whkd configuration'

if ($SkipConfigs) {
    Write-Info 'Skipped (-SkipConfigs).'
    Add-Result 'Komorebi config' 'skipped' '-SkipConfigs'
} else {
    $komorebic = Find-Tool -Name 'komorebic' -Candidates @(
        '%ProgramFiles%\komorebi\bin\komorebic.exe',
        '%LOCALAPPDATA%\Programs\komorebi\bin\komorebic.exe'
    )

    $komorebiDir = if ($env:KOMOREBI_CONFIG_HOME) {
        [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:KOMOREBI_CONFIG_HOME))
    } else {
        $env:USERPROFILE
    }
    $komorebiJson = Join-Path $komorebiDir 'komorebi.json'
    $applicationsJson = Join-Path $env:USERPROFILE 'applications.json'

    $whkdrcPath = Join-Path $env:USERPROFILE '.config\whkdrc'
    if ($komorebic) {
        try {
            $reportedWhkdrc = @(& $komorebic whkdrc 2>$null |
                ForEach-Object { "$_".Trim() } |
                Where-Object { $_ -match '^[A-Za-z]:\\' }) | Select-Object -Last 1
            if ($reportedWhkdrc) { $whkdrcPath = $reportedWhkdrc }
        } catch {
        }
    }

    $komorebiSource = Join-Path $script:RepoRoot 'MochaGlass_Komorebi\komorebi.json'
    $whkdSource = Join-Path $script:RepoRoot 'MochaGlass_Komorebi\whkdrc'

    if ($script:DryRun) {
        Write-Note "[dry-run] deploy Komorebi config to $komorebiJson"
        Write-Note "[dry-run] deploy whkd keybindings to $whkdrcPath"
        if (-not (Test-Path -LiteralPath $applicationsJson)) {
            Write-Note '[dry-run] fetch applications.json from the upstream Komorebi rules.'
        }
        Add-Result 'Komorebi config' 'dry-run' 'would deploy komorebi.json and whkdrc'
    } else {
        try {
            foreach ($target in @($komorebiJson, $whkdrcPath)) {
                $backup = Backup-Path -Path $target
                if ($backup) { Write-Info "Backed up $target to $backup" }
            }

            New-Item -ItemType Directory -Path $komorebiDir -Force | Out-Null
            New-Item -ItemType Directory -Path (Split-Path -Parent $whkdrcPath) -Force | Out-Null

            Copy-Item -LiteralPath $komorebiSource -Destination $komorebiJson -Force
            Copy-Item -LiteralPath $whkdSource -Destination $whkdrcPath -Force

            # applications.json is maintained upstream and is large; fetch it
            # instead of shipping a stale copy in the repository.
            if (-not (Test-Path -LiteralPath $applicationsJson)) {
                $fetched = $false
                if ($komorebic) {
                    try {
                        Push-Location $env:USERPROFILE
                        try {
                            & $komorebic fetch-app-specific-configuration 2>&1 |
                                ForEach-Object { Write-Info "$_" }
                        } finally {
                            Pop-Location
                        }
                        $fetched = Test-Path -LiteralPath $applicationsJson
                    } catch {
                        Write-Note "komorebic could not fetch applications.json: $($_.Exception.Message)"
                    }
                }

                if (-not $fetched) {
                    $rulesUrl = 'https://raw.githubusercontent.com/LGUG2Z/komorebi-application-specific-configuration/master/applications.json'
                    try {
                        Invoke-WebRequest -Uri $rulesUrl -OutFile $applicationsJson -UseBasicParsing
                        $fetched = Test-Path -LiteralPath $applicationsJson
                    } catch {
                        Write-Note "Could not download applications.json: $($_.Exception.Message)"
                    }
                }

                if ($fetched) {
                    Write-Good 'Komorebi application rules (applications.json) installed.'
                } else {
                    Write-Note 'applications.json is missing; Komorebi will run without app-specific rules.'
                }
            } else {
                Write-Info 'Existing applications.json kept.'
            }

            Write-Good "Komorebi config deployed to $komorebiJson"
            Write-Good "whkd keybindings deployed to $whkdrcPath"
            Add-Result 'Komorebi config' 'installed' $komorebiJson
        } catch {
            Write-Bad "Komorebi configuration failed: $($_.Exception.Message)"
            Add-Result 'Komorebi config' 'failed' $_.Exception.Message
            Add-Failure "Komorebi/whkd configuration failed: $($_.Exception.Message)"
        }
    }
}

# --- Step 5: Flow Launcher theme --------------------------------------------
Write-Section '5/9  Flow Launcher theme'

if ($SkipConfigs) {
    Write-Info 'Skipped (-SkipConfigs).'
    Add-Result 'Flow Launcher theme' 'skipped' '-SkipConfigs'
} else {
    $flowRoot = Join-Path $env:APPDATA 'FlowLauncher'
    $flowThemeSource = Join-Path $script:RepoRoot 'MochaGlass_FlowLauncher\TranslucentFlow.xaml'
    $flowThemesDir = Join-Path $flowRoot 'Themes'
    $flowThemeTarget = Join-Path $flowThemesDir 'TranslucentFlow.xaml'
    $flowSettingsPath = Join-Path $flowRoot 'Settings\Settings.json'

    if (-not (Test-Path -LiteralPath $flowRoot)) {
        Write-Note 'Flow Launcher has not been launched yet; start it once, then re-run this script to apply the theme.'
        Add-Result 'Flow Launcher theme' 'skipped' 'Flow Launcher settings not found'
    } elseif ($script:DryRun) {
        Write-Note "[dry-run] install TranslucentFlow.xaml in $flowThemesDir"
        Write-Note "[dry-run] set Flow Launcher theme to TranslucentFlow and language to English"
        Add-Result 'Flow Launcher theme' 'dry-run' 'would install TranslucentFlow and set English'
    } else {
        try {
            $themeBackup = Backup-Path -Path $flowThemeTarget
            if ($themeBackup) { Write-Info "Backed up the existing theme to $themeBackup" }

            New-Item -ItemType Directory -Path $flowThemesDir -Force | Out-Null
            Copy-Item -LiteralPath $flowThemeSource -Destination $flowThemeTarget -Force
            Write-Good 'TranslucentFlow theme installed.'

            if (Test-Path -LiteralPath $flowSettingsPath) {
                $flowRaw = [IO.File]::ReadAllText($flowSettingsPath)
                $flowSettings = ConvertTo-HashtableDeep (Remove-JsonComments $flowRaw | ConvertFrom-Json)

                $flowSettings['Theme'] = 'TranslucentFlow'
                $flowSettings['Language'] = 'en'
                $flowSettings['ColorScheme'] = 'System'
                $flowSettings['UseDropShadowEffect'] = $true
                $flowSettings['BackdropType'] = 0

                $settingsBackup = Backup-Path -Path $flowSettingsPath
                if ($settingsBackup) { Write-Info "Backed up Flow Launcher settings to $settingsBackup" }

                $flowJson = $flowSettings | ConvertTo-Json -Depth 100
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [IO.File]::WriteAllText($flowSettingsPath, $flowJson, $utf8NoBom)
                Write-Good 'Flow Launcher set to TranslucentFlow with English labels.'
            } else {
                Write-Note 'Flow Launcher settings not found; select TranslucentFlow manually in Settings > Theme.'
            }

            Add-Result 'Flow Launcher theme' 'installed' 'TranslucentFlow + English'
        } catch {
            Write-Bad "Flow Launcher configuration failed: $($_.Exception.Message)"
            Add-Result 'Flow Launcher theme' 'failed' $_.Exception.Message
            Add-Failure "Flow Launcher configuration failed: $($_.Exception.Message)"
        }
    }
}

# --- Step 6: device_status.exe ---------------------------------------------
Write-Section '6/9  device_status.exe'

if ($SkipWidget) {
    Write-Info 'Skipped (-SkipWidget).'
    Add-Result 'device_status.exe' 'skipped' '-SkipWidget'
} else {
    try {
        $sourceBinary = Resolve-DeviceStatusBinary
        $scriptsDir = Join-Path $env:USERPROFILE 'scripts'
        $destination = Join-Path $scriptsDir 'device_status.exe'

        if ($script:DryRun) {
            Write-Note "[dry-run] install $sourceBinary -> $destination"
            Add-Result 'device_status.exe' 'dry-run' 'would install'
        } else {
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

            $copied = $false
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Copy-Item -LiteralPath $sourceBinary -Destination $destination -Force
                    $copied = $true
                    break
                } catch {
                    if ($attempt -eq 5) { throw }
                    Start-Sleep -Milliseconds 750
                }
            }

            if (-not $copied) {
                throw 'Could not replace device_status.exe; it may still be in use.'
            }

            Unblock-File -LiteralPath $destination -ErrorAction SilentlyContinue

            Write-Good "Installed to $destination"

            $count = $null
            try {
                $raw = & $destination 2>$null
                $json = ($raw | Out-String) | ConvertFrom-Json
                if ($null -ne $json.count) {
                    $count = $json.count
                    Write-Good "Smoke test passed: $count connected device(s) reported."
                }
            } catch {
                Write-Note 'The binary was installed but the smoke test did not return valid JSON yet.'
            }

            Add-Result 'device_status.exe' 'installed' $(if ($null -ne $count) { "$count device(s) detected" } else { $destination })
        }
    } catch {
        Write-Bad "device_status.exe installation failed: $($_.Exception.Message)"
        Add-Result 'device_status.exe' 'failed' $_.Exception.Message
        Add-Failure "device_status.exe installation failed: $($_.Exception.Message)"
    }
}

# --- Step 7: Windows Terminal ----------------------------------------------
Write-Section '7/9  Windows Terminal theme'

if ($SkipTerminal) {
    Write-Info 'Skipped (-SkipTerminal).'
    Add-Result 'Terminal theme' 'skipped' '-SkipTerminal'
} else {
    try {
        $settingsPath = Get-TerminalSettingsPath
        if (-not $settingsPath) {
            Write-Note 'Windows Terminal settings were not found. Launch Windows Terminal once, then re-run this script.'
            Add-Result 'Terminal theme' 'skipped' 'settings.json not found'
        } else {
            $themePath = Join-Path $script:RepoRoot 'MochaGlass_Terminal\settings.json'
            $themeRaw = [IO.File]::ReadAllText($themePath)
            $theme = ConvertTo-HashtableDeep (Remove-JsonComments $themeRaw | ConvertFrom-Json)

            $fresh = -not (Test-Path -LiteralPath $settingsPath)
            if ($fresh) {
                Write-Info 'No existing Windows Terminal settings found; creating one from the MochaGlass theme.'
                # Deep copy so that the merge below never enumerates a hashtable
                # while it is also being modified.
                $user = ConvertTo-HashtableDeep $theme
            } else {
                $userRaw = [IO.File]::ReadAllText($settingsPath)
                try {
                    $userObject = Remove-JsonComments $userRaw | ConvertFrom-Json
                } catch {
                    throw "Could not parse $settingsPath. Back it up and merge MochaGlass_Terminal\settings.json manually."
                }
                $user = ConvertTo-HashtableDeep $userObject
            }

            if (-not $user.ContainsKey('profiles') -or $user['profiles'] -isnot [hashtable]) {
                $user['profiles'] = @{}
            }
            if (-not $user['profiles'].ContainsKey('defaults') -or $user['profiles']['defaults'] -isnot [hashtable]) {
                $user['profiles']['defaults'] = @{}
            }

            if (-not $fresh) {
                Merge-HashtableDeep -Base $user['profiles']['defaults'] -Overlay $theme['profiles']['defaults']

                $user['schemes'] = Merge-KeyedArray -Base $user['schemes'] -Additions $theme['schemes'] -Key 'name'
                $user['actions'] = Merge-KeyedArray -Base $user['actions'] -Additions $theme['actions'] -Key 'id'
                $user['keybindings'] = Merge-KeyedArray -Base $user['keybindings'] -Additions $theme['keybindings'] -Key 'keys'

                if (-not $user.ContainsKey('$schema') -and $theme.ContainsKey('$schema')) {
                    $user['$schema'] = $theme['$schema']
                }
            }

            if (-not $user['profiles']['defaults'].ContainsKey('font') -or
                $user['profiles']['defaults']['font'] -isnot [hashtable]) {
                $user['profiles']['defaults']['font'] = @{}
            }
            # Keep the installed family explicit; older copies of the theme
            # used the non-existent "JetBrainsMono Nerd Font" name.
            $user['profiles']['defaults']['font']['face'] = 'JetBrainsMono NF'

            if ($fresh) {
                $pwshGuid = '{177cb554-0efc-4492-843b-38142db0411b}'
                $windowsPowerShellGuid = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
                $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
                if (-not $pwshCommand) {
                    if ($user['profiles'].ContainsKey('list')) {
                        $user['profiles']['list'] = @($user['profiles']['list'] | Where-Object {
                            -not ($_ -is [hashtable] -and $_['guid'] -eq $pwshGuid)
                        })
                    }
                    $user['defaultProfile'] = $windowsPowerShellGuid
                } elseif ($user['profiles'].ContainsKey('list')) {
                    foreach ($profileEntry in @($user['profiles']['list'])) {
                        if ($profileEntry -is [hashtable] -and $profileEntry['guid'] -eq $pwshGuid) {
                            $profileEntry['commandline'] = $pwshCommand.Source
                        }
                    }
                }
            }

            if ($script:DryRun) {
                Write-Note "[dry-run] apply the Catppuccin Mocha theme to $settingsPath"
                Add-Result 'Terminal theme' 'dry-run' 'would apply theme'
            } else {
                $backup = Backup-Path -Path $settingsPath
                if ($backup) { Write-Info "Backed up Terminal settings to $backup" }

                $json = $user | ConvertTo-Json -Depth 100
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [IO.File]::WriteAllText($settingsPath, $json, $utf8NoBom)

                Write-Good "Catppuccin Mocha theme applied to $settingsPath"
                Add-Result 'Terminal theme' 'installed' $settingsPath
            }
        }
    } catch {
        Write-Bad "Windows Terminal configuration failed: $($_.Exception.Message)"
        Add-Result 'Terminal theme' 'failed' $_.Exception.Message
        Add-Failure "Windows Terminal configuration failed: $($_.Exception.Message)"
    }
}

# --- Step 8: autostart ------------------------------------------------------
Write-Section '8/9  Autostart'

if ($NoAutostart) {
    Write-Info 'Skipped (-NoAutostart).'
    Add-Result 'Autostart' 'skipped' '-NoAutostart'
} elseif ($script:DryRun) {
    Write-Note '[dry-run] enable Komorebi and YASB autostart.'
    Add-Result 'Autostart' 'dry-run' 'would enable Komorebi and YASB'
} else {
    $komorebic = Find-Tool -Name 'komorebic' -Candidates @(
        '%ProgramFiles%\komorebi\bin\komorebic.exe',
        '%LOCALAPPDATA%\Programs\komorebi\bin\komorebic.exe'
    )
    if ($komorebic) {
        & $komorebic enable-autostart --whkd 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Good 'Komorebi autostart enabled (with whkd).'
        } else {
            Write-Note 'Komorebi autostart could not be enabled.'
        }
    } else {
        Write-Note 'komorebic was not found; skipping Komorebi autostart.'
    }

    $yasbc = Find-Tool -Name 'yasbc' -Candidates @(
        '%ProgramFiles%\YASB\yasbc.exe',
        '%LOCALAPPDATA%\Programs\YASB\yasbc.exe'
    )
    if ($yasbc) {
        & $yasbc enable-autostart 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Good 'YASB autostart enabled.'
        } else {
            Write-Note 'YASB autostart could not be enabled.'
        }
    } else {
        Write-Note 'yasbc was not found; skipping YASB autostart.'
    }

    Add-Result 'Autostart' 'installed' 'Komorebi + YASB'
}

# --- Step 9: start ----------------------------------------------------------
Write-Section '9/9  Start'

if ($NoStart) {
    Write-Info 'Skipped (-NoStart).'
    Add-Result 'Start' 'skipped' '-NoStart'
} elseif ($script:DryRun) {
    Write-Note '[dry-run] start Komorebi and YASB.'
    Add-Result 'Start' 'dry-run' 'would start Komorebi and YASB'
} else {
    $komorebic = Find-Tool -Name 'komorebic' -Candidates @(
        '%ProgramFiles%\komorebi\bin\komorebic.exe',
        '%LOCALAPPDATA%\Programs\komorebi\bin\komorebic.exe'
    )
    if ($komorebic) {
        if (Get-Process -Name 'komorebi' -ErrorAction SilentlyContinue) {
            Write-Good 'Komorebi is already running.'
        } else {
            try {
                Start-Process -FilePath $komorebic -ArgumentList @('start', '--whkd') -WindowStyle Hidden
                Start-Sleep -Seconds 2
                if (Get-Process -Name 'komorebi' -ErrorAction SilentlyContinue) {
                    Write-Good 'Komorebi started with whkd.'
                } else {
                    Write-Note 'Komorebi did not stay running. Run "komorebic start --whkd" manually to see the error.'
                }
            } catch {
                Write-Note "Komorebi could not be started: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Note 'komorebic was not found; Komorebi was not started.'
    }

    $yasbc = Find-Tool -Name 'yasbc' -Candidates @(
        '%ProgramFiles%\YASB\yasbc.exe',
        '%LOCALAPPDATA%\Programs\YASB\yasbc.exe'
    )
    if ($yasbc) {
        try {
            if (Get-Process -Name 'yasb' -ErrorAction SilentlyContinue) {
                & $yasbc reload 2>&1 | Out-Null
                Write-Good 'YASB reloaded.'
            } else {
                Start-Process -FilePath $yasbc -ArgumentList @('start') -WindowStyle Hidden
                Start-Sleep -Seconds 2
                if (Get-Process -Name 'yasb' -ErrorAction SilentlyContinue) {
                    Write-Good 'YASB started.'
                } else {
                    Write-Note 'YASB did not start. Run "yasbc start" manually to see the error.'
                }
            }
        } catch {
            Write-Note "YASB could not be started: $($_.Exception.Message)"
        }
    } else {
        Write-Note 'yasbc was not found; YASB was not started.'
    }

    Add-Result 'Start' 'installed' 'Komorebi + YASB'
}

# --- Summary ----------------------------------------------------------------
Write-Section 'Summary'

$script:Results | Format-Table -Property Component, Status, Detail -AutoSize

if (-not $NoAutostart -and -not $script:DryRun) {
    Write-Info 'Komorebi and YASB will start automatically at the next sign-in.'
} elseif ($NoAutostart) {
    Write-Info 'Autostart was skipped. Start the bar with "yasbc start".'
}

$whkdrc = Join-Path $env:USERPROFILE '.config\whkdrc'
if (-not (Test-Path -LiteralPath $whkdrc) -and -not $script:DryRun) {
    Write-Note "No whkdrc found at $whkdrc."
    Write-Note 'Re-run this installer without -SkipConfigs to deploy the MochaGlass keybindings.'
}

if ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Version -like '10.0.1*') {
    Write-Note 'Windows 10 detected: the power menu and some icons need Segoe Fluent Icons.'
}

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host '  Completed with issues:' -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "    - $failure" -ForegroundColor Red
    }
}

if ($script:LogPath) {
    Write-Info "Log: $script:LogPath"
}

if ($script:DryRun) {
    Write-Host ''
    Write-Host '  Dry run complete. Nothing was changed.' -ForegroundColor Yellow
}

try {
    Stop-Transcript | Out-Null
} catch {
}

if ($script:Failures.Count -gt 0) {
    exit 1
}

exit 0
