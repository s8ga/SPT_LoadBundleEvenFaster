param(
    [Parameter(Mandatory=$true)]
    [string]$SptPath
)

# Error handling functions
function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor White
}

function Write-ErrorLog {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $Message" -ForegroundColor Red
}

# Function to find DLL in SPTarkov directory
function Find-DllInSPTarkov {
    param(
        [string]$SptPath,
        [string]$DllName
    )
    
    Write-Log "Searching for: $DllName in $SptPath"
    
    # First check if the file exists in the SPTarkov path directly
    $directPath = Join-Path $SptPath $DllName
    if (Test-Path $directPath) {
        Write-Log "Found in direct path: $directPath"
        return $directPath
    }
    
    # Define potential search paths
    $searchPaths = @(
        "EscapeFromTarkov_Data\Managed",
        "BepInEx\core", 
        "BepInEx\plugins\spt"
    )
    
    foreach ($path in $searchPaths) {
        $fullPath = Join-Path $SptPath $path $DllName
        Write-Log "Checking: $fullPath"
        
        if (Test-Path $fullPath) {
            Write-Log "Found in: $fullPath"
            return $fullPath
        }
    }
    
    # If not found in standard paths, do recursive search with better logging
    Write-Log "Doing recursive search for $DllName..."
    try {
        $allDlls = Get-ChildItem -Path $SptPath -Filter $DllName -Recurse -ErrorAction Stop
        if ($allDlls.Count -gt 0) {
            Write-Log "Found $($allDlls.Count) matches:"
            foreach ($dll in $allDlls) {
                Write-Log "  - $($dll.FullName)"
            }
            # Return the first match
            return $allDlls[0].FullName
        }
    }
    catch {
        Write-ErrorLog "Recursive search failed: $($_.Exception.Message)"
    }
    
    Write-ErrorLog "DLL not found: $DllName"
    return $null
}

# Main function
function Copy-References {
    Write-Log "Starting reference file copy..."
    Write-Log "SPTarkov path: $SptPath"
    Write-Log "Project root: $ProjectRoot"
    
    # Set directory paths
    $ClientDir = Join-Path $ProjectRoot "References\Client"
    
    # Create directory
    if (-not (Test-Path $ClientDir)) {
        New-Item -ItemType Directory -Path $ClientDir | Out-Null
        Write-Log "Created directory: $ClientDir"
    } else {
        Write-Log "Directory already exists: $ClientDir"
    }
    
    # Get all csproj files, excluding those in Reference_Repo.do_not_save and Shared project
    $CsprojFiles = Get-ChildItem -Path $ProjectRoot -Filter "*.csproj" -Recurse | 
                   Where-Object { 
                       $_.FullName -notlike "*Reference_Repo.do_not_save*" -and
                       $_.FullName -notlike "*s8_ModSync_Shared*" -and
                       $_.Name -ne "s8_ModSync.Shared.csproj"
                   }
    
    Write-Log "Found $($CsprojFiles.Count) csproj files to process"
    
    $copiedFiles = @{}
    $failedFiles = @{}
    $processedProjects = @{}
    
    foreach ($csproj in $CsprojFiles) {
        Write-Log "`nProcessing: $($csproj.FullName)"
        
        try {
            # Read csproj file as XML
            $csprojContent = [xml](Get-Content $csproj.FullName)
            
            # Only process Client and Updater projects for DLL copying
            $projectName = $csproj.BaseName
            
            if (1) {
                $targetDir = $ClientDir
                Write-Log "  Target directory: $targetDir"
                
                # Parse references
                $references = $csprojContent.SelectNodes("//Reference[@Include]")
                
                Write-Log "  Found $($references.Count) references"
                
                if ($references.Count -eq 0) {
                    Write-Log "  No DLL references found"
                }
                
                foreach ($reference in $references) {
                    $dllName = $reference.Include
                    
                    Write-Log "  Processing reference: $dllName"
                    
                    # Handle versioned DLL names
                    if ($dllName -like "*.dll") {
                        $searchDllName = $dllName
                    } else {
                        # Handle DLLs without .dll extension
                        if ($reference.SpecificVersion -eq "False") {
                            $dllNameWithoutVersion = $dllName -replace ",.*$"
                            $searchDllName = "$dllNameWithoutVersion.dll"
                        } else {
                            $searchDllName = "$dllName.dll"
                        }
                    }
                    
                    Write-Log "  Searching for DLL: $searchDllName"
                    
                    # Find file in SPTarkov directory
                    $sourceFile = Find-DllInSPTarkov -SptPath $SptPath -DllName $searchDllName
                    
                    if ($sourceFile) {
                        $destFile = Join-Path $targetDir $searchDllName
                        
                        # Copy file
                        Copy-Item -Path $sourceFile -Destination $destFile -Force
                        Write-Log "  SUCCESS: Copied $searchDllName -> $targetDir"
                        $copiedFiles[$searchDllName] = $targetDir
                    } else {
                        Write-ErrorLog "  FAILED: Not found - $searchDllName"
                        $failedFiles[$searchDllName] = $csproj.Name
                    }
                }
                
                # Mark this project as processed
                $processedProjects[$csproj.Name] = $targetDir
            } else {
                Write-Log "  Skipping: Only Client and Updater projects need DLL references"
                $processedProjects[$csproj.Name] = "Skipped (No DLLs needed)"
            }
            
        } catch {
            Write-ErrorLog "Failed to process $($csproj.Name): $($_.Exception.Message)"
        }
    }
    
    # Summary report
    Write-Log "`n=== PROCESSING SUMMARY ==="
    Write-Log "Processed $($processedProjects.Count) projects:"
    
    foreach ($project in $processedProjects.Keys) {
        $status = $processedProjects[$project]
        Write-Log "  - $project -> $status"
    }
    
    Write-Log "`n=== COPY SUMMARY ==="
    Write-Log "Successfully copied $($copiedFiles.Count) files"
    Write-Log "Failed to find $($failedFiles.Count) files"
    
    if ($failedFiles.Count -gt 0) {
        Write-Log "`nFailed files:"
        foreach ($file in $failedFiles.Keys) {
            Write-Log "  - $file (in $($failedFiles[$file]))"
        }
    }
    
    Write-Log "`nNote:"
    Write-Log "- Client and Updater projects: DLLs copied from SPTarkov"
    Write-Log "- Server and Shared projects: Use NuGet packages/sdk references (no DLLs needed)"
    Write-Log "- Shared references are build-time dependencies, not runtime references"
    
    Write-Log "Reference copy completed."
}

# Check if SPTarkov path exists
if (-not (Test-Path $SptPath)) {
    Write-ErrorLog "SPTarkov path does not exist: $SptPath"
    exit 1
}

# Set project root
$ProjectRoot = (Get-Location).Path

# Run the main function
try {
    Copy-References
}
catch {
    Write-ErrorLog "Script execution failed: $($_.Exception.Message)"
    exit 1
}
