<#
.SYNOPSIS
    Build and package SPT_LoadBundleEvenFaster plugin for distribution

.DESCRIPTION
    This script builds the C# plugin (and optionally a native CRC32 DLL if
    present), packages them into a BepInEx-compatible structure, and creates
    a 7z archive.

.PREREQUISITES
    Before running this script, you MUST copy required reference DLLs:

    1. Run CopyReferences.ps1 with your SPTarkov path:
       .\CopyReferences.ps1 -SptPath "C:\Path\To\SPTarkov"

    2. This will copy all necessary DLLs to References\Client folder

    3. Ensure 7z (7-Zip) is installed and available in PATH
#>

param(
    [switch]$SkipBuild,
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot

# Read version from csproj
$csprojPath = Join-Path $ScriptRoot "SPT_LoadBundleEvenFaster.Plugin\SPT_LoadBundleEvenFaster.Plugin.csproj"
[xml]$csproj = Get-Content $csprojPath
$Version = ($csproj.Project.PropertyGroup | Where-Object { $_.AssemblyVersion } | Select-Object -ExpandProperty AssemblyVersion)
if (-not $Version) {
    $Version = "1.0.0"
}

# Logging functions
function Write-Log {
    param([string]$Message, [string]$ForegroundColor = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $ForegroundColor
}

function Write-Success { param([string]$Message) Write-Log $Message "Green" }
function Write-Error { param([string]$Message) Write-Log $Message "Red" }
function Write-Warning { param([string]$Message) Write-Log $Message "Yellow" }
function Write-Info { param([string]$Message) Write-Log $Message "Cyan" }

# Check prerequisites
function Test-Prerequisites {
    Write-Info "Checking prerequisites..."

    # Check if References\Client exists and has DLLs
    $referencesDir = Join-Path $ScriptRoot "References\Client"
    if (-not (Test-Path $referencesDir)) {
        Write-Error "References\Client folder not found!"
        Write-Error "Please run: .\CopyReferences.ps1 -SptPath `"C:\Path\To\SPTarkov`""
        return $false
    }

    $dllFiles = Get-ChildItem -Path $referencesDir -Filter "*.dll"
    if ($dllFiles.Count -eq 0) {
        Write-Error "No DLLs found in References\Client folder!"
        Write-Error "Please run: .\CopyReferences.ps1 -SptPath `"C:\Path\To\SPTarkov`""
        return $false
    }
    Write-Success "Found $($dllFiles.Count) DLLs in References\Client"

    # Check if dotnet is available
    try {
        $dotnetVersion = dotnet --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "dotnet found: $dotnetVersion"
        } else {
            Write-Error "dotnet not found or not working properly"
            return $false
        }
    } catch {
        Write-Error "dotnet not found. Please install .NET SDK"
        return $false
    }

    # Check if 7z is available
    try {
        $sevenZipVersion = 7z 2>&1 | Select-Object -First 1
        Write-Success "7z found"
    } catch {
        Write-Error "7z (7-Zip) not found. Please install 7-Zip and add to PATH"
        return $false
    }

    return $true
}

# Build C# plugin
function Build-CSharpPlugin {
    Write-Info "Building C# plugin..."

    $csprojPath = Join-Path $ScriptRoot "SPT_LoadBundleEvenFaster.Plugin\SPT_LoadBundleEvenFaster.Plugin.csproj"

    if (-not (Test-Path $csprojPath)) {
        Write-Error "C# project not found: $csprojPath"
        return $false
    }

    $buildArgs = @(
        "build",
        $csprojPath,
        "--configuration", "Release",
        "--no-restore"
    )

    Write-Info "Running: dotnet $($buildArgs -join ' ')"
    $result = & dotnet @buildArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "C# build failed!"
        Write-Error $result
        return $false
    }

    Write-Success "C# plugin built successfully"
    return $true
}





# Package everything
function New-Package {
    Write-Info "Creating package..."

    $packageDir = Join-Path $ScriptRoot "Package\s8_SPT_LoadBundleEvenFaster"
    $targetDir = Join-Path $ScriptRoot "Package\BepInEx\plugins\s8_SPT_LoadBundleEvenFaster"

    # Clean previous package
    if (-not $SkipClean) {
        Write-Info "Cleaning previous package..."
        if (Test-Path (Join-Path $ScriptRoot "Package")) {
            try {
                Remove-Item -Path (Join-Path $ScriptRoot "Package") -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Error "Failed to remove previous package directory: $($_.Exception.Message)"
                return $false
            }
        }
    }

    # Create directories
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    # Copy C# plugin files from artifact — only DLLs to avoid nested plugin dir
    $artifactDir = Join-Path $ScriptRoot "SPT_LoadBundleEvenFaster.Plugin\artifact"
    if (-not (Test-Path $artifactDir)) {
        Write-Warning "Artifact folder not found, trying bin/Release..."
        $artifactDir = Join-Path $ScriptRoot "SPT_LoadBundleEvenFaster.Plugin\bin\Release\netstandard2.1"
    }

    if (Test-Path $artifactDir) {
        Write-Info "Copying C# plugin DLL(s) into $targetDir (flatten)"
        # Fail-fast: require at least one DLL to be present
        $dlls = Get-ChildItem -Path $artifactDir -Filter "*.dll" -File -Recurse -ErrorAction SilentlyContinue
        if (-not $dlls -or $dlls.Count -eq 0) {
            Write-Error "No DLLs found in artifact directory ($artifactDir). Aborting."
            return $false
        }

        foreach ($d in $dlls) {
            Write-Info "  - Copying $($d.Name)"
            Copy-Item -Path $d.FullName -Destination (Join-Path $targetDir $d.Name) -Force
        }

        Write-Success "C# plugin DLL(s) copied"
    } else {
        Write-Error "C# plugin output not found at expected path: $artifactDir. Aborting."
        return $false
    }


    # Verify package contents
    Write-Info "Package contents:"
    Get-ChildItem -Path $targetDir -Recurse | ForEach-Object {
        Write-Host "  - $($_.FullName.Replace($targetDir, ''))" -ForegroundColor Gray
    }

    # Create 7z archive
    Write-Info "Creating 7z archive..."
    $archiveName = "s8_SPT_LoadBundleEvenFaster-v$Version-win-x86_64.7z"
    $archivePath = Join-Path $ScriptRoot $archiveName

    if (Test-Path $archivePath) {
        Remove-Item -Path $archivePath -Force
    }

    $packageRoot = Join-Path $ScriptRoot "Package"
    $7zArgs = @(
        "a",
        "-t7z",
        "-mx9",
        "-m0=LZMA2",
        $archiveName,
        "BepInEx\*"
    )

    Push-Location $packageRoot
    $result = & 7z @7zArgs 2>&1
    Pop-Location

    if ($LASTEXITCODE -ne 0) {
        Write-Error "7z archive creation failed!"
        Write-Error $result
        return $false
    }

    Write-Success "Package created: $archivePath"
    return $true
}

# Main execution
function Main {
    Write-Log "=== SPT_LoadBundleEvenFaster Package Script ===" "Cyan"
    Write-Log "Version: $Version"
    Write-Log ""

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        Write-Error "Prerequisites check failed. Please fix the issues above and try again."
        exit 1
    }

    Write-Log ""

    # Build projects
    if (-not $SkipBuild) {
        if (-not (Build-CSharpPlugin)) {
            Write-Error "C# build failed. Aborting."
            exit 1
        }
    } else {
        Write-Warning "Skipping build (using existing artifacts)"
    }


    Write-Log ""

    # Create package
    if (-not (New-Package)) {
        Write-Error "Package creation failed. Aborting."
        exit 1
    }

    Write-Log ""
    Write-Success "=== Build and package completed successfully! ==="
    Write-Log "Package location: $(Join-Path $ScriptRoot `"s8_SPT_LoadBundleEvenFaster-v$Version-win-x86_64.7z`")"
    Write-Log ""
    Write-Log "To install, extract the archive to your SPTarkov root directory."
}

# Run main function
Main
