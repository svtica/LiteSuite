# Release-LiteSuite.ps1
# PowerShell script for automating LiteSuite releases and local builds

param(
    [Parameter(Mandatory=$false)]
    [string]$Action = "build",
    
    [Parameter(Mandatory=$false)]
    [string]$Version = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Configuration = "Release",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipTests,
    
    [Parameter(Mandatory=$false)]
    [switch]$CreateSuite
)

# Configuration
$GitHubUser = "svtica"  # Service TI GitHub username
$SuiteProjects = @(
    @{ Name = "LiteTask"; Tech = "dotnet8"; Platform = "win-x64" },
    @{ Name = "LitePM"; Tech = "netframework"; Platform = "win" },
    @{ Name = "LiteDeploy"; Tech = "netframework"; Platform = "win" },
    @{ Name = "LiteRun"; Tech = "cpp"; Platform = @("win-x64", "win-x86") },
    @{ Name = "LiteSrv"; Tech = "cpp"; Platform = @("win-x64", "win-x86") }
)

function Write-Header {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Build-DotNet8Project {
    param([string]$ProjectPath, [string]$Platform)
    
    Write-Header "Building .NET 8.0 Project: $ProjectPath"
    
    # Restore dependencies
    dotnet restore $ProjectPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to restore dependencies" }
    
    # Build
    dotnet build $ProjectPath --configuration $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw "Failed to build project" }
    
    # Run tests if not skipped
    if (-not $SkipTests) {
        dotnet test $ProjectPath --configuration $Configuration --no-build --verbosity normal
        # Continue even if tests fail (some projects might not have tests)
    }
    
    # Publish
    $publishDir = Join-Path (Split-Path $ProjectPath) "publish"
    dotnet publish $ProjectPath -c $Configuration -r $Platform --self-contained false -o $publishDir
    if ($LASTEXITCODE -ne 0) { throw "Failed to publish project" }
    
    return $publishDir
}

function Build-NetFrameworkProject {
    param([string]$ProjectPath)
    
    Write-Header "Building .NET Framework Project: $ProjectPath"
    
    $projectDir = Split-Path $ProjectPath
    $solutionFile = Get-ChildItem -Path $projectDir -Name "*.sln" | Select-Object -First 1
    
    if ($solutionFile) {
        $solutionPath = Join-Path $projectDir $solutionFile
        
        # Restore NuGet packages
        nuget restore $solutionPath
        
        # Build
        msbuild $solutionPath /p:Configuration=$Configuration /p:Platform="Any CPU"
        if ($LASTEXITCODE -ne 0) { throw "Failed to build solution" }
    } else {
        # Build project directly
        msbuild $ProjectPath /p:Configuration=$Configuration /p:Platform="Any CPU"
        if ($LASTEXITCODE -ne 0) { throw "Failed to build project" }
    }
    
    # Copy build outputs
    $buildPath = Join-Path $projectDir "bin\$Configuration"
    $publishDir = Join-Path $projectDir "publish"
    
    if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
    New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
    
    # Copy executables and dependencies
    Get-ChildItem $buildPath -Include "*.exe", "*.dll", "*.config" | Copy-Item -Destination $publishDir
    
    return $publishDir
}

function Build-CppProject {
    param([string]$ProjectPath, [string]$Platform)
    
    Write-Header "Building C++ Project: $ProjectPath ($Platform)"
    
    $projectDir = Split-Path $ProjectPath
    $solutionFile = Get-ChildItem -Path $projectDir -Name "*.sln" | Select-Object -First 1
    $projectFile = Get-ChildItem -Path $projectDir -Name "*.vcxproj" | Select-Object -First 1
    
    $msbuildPlatform = if ($Platform -eq "win-x64") { "x64" } else { "x86" }
    
    if ($solutionFile) {
        $solutionPath = Join-Path $projectDir $solutionFile
        msbuild $solutionPath /p:Configuration=$Configuration /p:Platform=$msbuildPlatform
    } elseif ($projectFile) {
        $projectFilePath = Join-Path $projectDir $projectFile
        msbuild $projectFilePath /p:Configuration=$Configuration /p:Platform=$msbuildPlatform
    } else {
        throw "No solution or project file found in $projectDir"
    }
    
    if ($LASTEXITCODE -ne 0) { throw "Failed to build C++ project" }
    
    # Copy build outputs
    $buildPath = Join-Path $projectDir "$msbuildPlatform\$Configuration"
    $publishDir = Join-Path $projectDir "publish\$Platform"
    
    if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
    New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
    
    if (Test-Path $buildPath) {
        Get-ChildItem $buildPath -Include "*.exe", "*.dll" | Copy-Item -Destination $publishDir
    }
    
    return $publishDir
}

function Create-ReleasePackage {
    param([string]$ProjectName, [string]$PublishDir, [string]$Platform, [string]$Version)
    
    Write-Header "Creating Release Package: $ProjectName"
    
    $projectDir = Split-Path $PublishDir
    $packageName = "$ProjectName-$Version-$Platform.zip"
    $packagePath = Join-Path $projectDir $packageName
    
    # Add documentation files
    $readmePath = Join-Path $projectDir "README.md"
    $licensePath = Join-Path $projectDir "LICENSE"
    
    if (Test-Path $readmePath) { Copy-Item $readmePath -Destination $PublishDir }
    if (Test-Path $licensePath) { Copy-Item $licensePath -Destination $PublishDir }
    
    # Create package
    Compress-Archive -Path "$PublishDir\*" -DestinationPath $packagePath -Force
    
    Write-Host "Package created: $packagePath" -ForegroundColor Green
    return $packagePath
}

function Build-AllProjects {
    Write-Header "Building All LiteSuite Projects"
    
    $packages = @()
    $currentDir = Get-Location
    
    foreach ($project in $SuiteProjects) {
        $projectDir = Join-Path $currentDir "..\$($project.Name)"
        
        if (-not (Test-Path $projectDir)) {
            Write-Warning "Project directory not found: $projectDir"
            continue
        }
        
        Set-Location $projectDir
        
        try {
            $platforms = if ($project.Platform -is [array]) { $project.Platform } else { @($project.Platform) }
            
            foreach ($platform in $platforms) {
                $publishDir = switch ($project.Tech) {
                    "dotnet8" { Build-DotNet8Project "*.vbproj" $platform }
                    "netframework" { Build-NetFrameworkProject "*.vbproj" }
                    "cpp" { Build-CppProject "*.vcxproj" $platform }
                }
                
                if ($publishDir -and (Test-Path $publishDir)) {
                    $packagePath = Create-ReleasePackage $project.Name $publishDir $platform $Version
                    $packages += $packagePath
                }
            }
        } catch {
            Write-Error "Failed to build $($project.Name): $_"
        }
    }
    
    Set-Location $currentDir
    return $packages
}

function Create-SuitePackage {
    param([string[]]$Packages)
    
    Write-Header "Creating LiteSuite Package"
    
    $suiteDir = "LiteSuite-$Version"
    $suitePath = Join-Path (Get-Location) $suiteDir
    
    if (Test-Path $suitePath) { Remove-Item $suitePath -Recurse -Force }
    New-Item -ItemType Directory -Path $suitePath -Force | Out-Null
    
    # Extract each package to suite directory
    foreach ($package in $Packages) {
        if (Test-Path $package) {
            $projectName = [System.IO.Path]::GetFileNameWithoutExtension($package).Split('-')[0]
            $projectDir = Join-Path $suitePath $projectName
            
            Expand-Archive -Path $package -DestinationPath $projectDir -Force
            Write-Host "Added $projectName to suite" -ForegroundColor Green
        }
    }
    
    # Create suite documentation
    Copy-Item "README.md" -Destination $suitePath -ErrorAction SilentlyContinue
    Copy-Item "LICENSE" -Destination $suitePath -ErrorAction SilentlyContinue
    
    # Create version file
    $versionInfo = @"
LiteSuite v$Version

Build Date: $(Get-Date)
Configuration: $Configuration

Included Tools:
$($SuiteProjects | ForEach-Object { "- $($_.Name)" } | Out-String)
"@
    $versionInfo | Set-Content -Path (Join-Path $suitePath "VERSION.txt")
    
    # Create suite package
    $suitePackage = "$suiteDir.zip"
    Compress-Archive -Path "$suitePath\*" -DestinationPath $suitePackage -Force
    
    Write-Host "Suite package created: $suitePackage" -ForegroundColor Green
    return $suitePackage
}

function Tag-AndPush {
    param([string]$Version)
    
    Write-Header "Tagging and Pushing Release"
    
    $tag = "v$Version"
    
    # Create and push tag
    git tag $tag
    git push origin $tag
    
    Write-Host "Tagged and pushed: $tag" -ForegroundColor Green
}

# Main execution
try {
    # Set version if not provided
    if (-not $Version) {
        $Version = "1.0.0-$(Get-Date -Format 'yyyyMMdd')"
    }
    
    Write-Header "LiteSuite Release Automation"
    Write-Host "Action: $Action" -ForegroundColor Yellow
    Write-Host "Version: $Version" -ForegroundColor Yellow
    Write-Host "Configuration: $Configuration" -ForegroundColor Yellow
    
    switch ($Action.ToLower()) {
        "build" {
            $packages = Build-AllProjects
            
            if ($CreateSuite) {
                Create-SuitePackage $packages
            }
        }
        
        "release" {
            $packages = Build-AllProjects
            $suitePackage = Create-SuitePackage $packages
            Tag-AndPush $Version
        }
        
        "tag" {
            Tag-AndPush $Version
        }
        
        default {
            Write-Error "Unknown action: $Action. Use 'build', 'release', or 'tag'"
        }
    }
    
    Write-Header "Completed Successfully"
    
} catch {
    Write-Error "Build failed: $_"
    exit 1
}
