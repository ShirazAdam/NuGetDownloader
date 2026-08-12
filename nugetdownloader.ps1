param(
    [Parameter(Mandatory = $true)]
    [string]$Publisher,

    [string]$Source = "https://api.nuget.org/v3/index.json",

    [string]$OutputDirectory = ".\Packages",

    [switch]$IncludePrerelease,

    [switch]$AllVersions,

    [int]$Limit = 0
)

# Ensure output directory exists
if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

# Helper: Get the V3 resource URLs from the index
function Get-V3Resources {
    param([string]$IndexUrl)
    try {
        $index = Invoke-RestMethod -Uri $IndexUrl -UseBasicParsing
        $resources = $index.resources
        $searchService = ($resources | Where-Object { $_.'@type' -like '*SearchQueryService*' } | Select-Object -First 1).'@id'
        $packageBase = ($resources | Where-Object { $_.'@type' -like '*PackageBaseAddress*' } | Select-Object -First 1).'@id'
        if (-not $searchService -or -not $packageBase) {
            throw "Could not find SearchQueryService or PackageBaseAddress in the V3 index."
        }
        return @{
            SearchService = $searchService
            PackageBase   = $packageBase
        }
    } catch {
        Write-Error "Failed to parse V3 index from '$IndexUrl': $_"
        exit 1
    }
}

# Helper: Download a single .nupkg file
function Download-Package {
    param(
        [string]$PackageId,
        [string]$Version,
        [string]$BaseUrl,
        [string]$DestinationFolder
    )
    $fileName = "$PackageId.$Version.nupkg"
    $filePath = Join-Path -Path $DestinationFolder -ChildPath $fileName
    if (Test-Path -Path $filePath) {
        Write-Host "Skipping $fileName (already exists)" -ForegroundColor Gray
        return $false
    }
    $downloadUrl = "$BaseUrl$($PackageId.ToLowerInvariant())/$Version/$($PackageId.ToLowerInvariant()).$Version.nupkg"
    try {
        Write-Host "Downloading $fileName ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -UseBasicParsing
        Write-Host "  -> Saved to $filePath" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "Failed to download $downloadUrl : $_"
        return $false
    }
}

# Main script
Write-Host "Fetching NuGet V3 resources from '$Source' ..." -ForegroundColor Yellow
$resources = Get-V3Resources -IndexUrl $Source
$searchUrl = $resources.SearchService
$packageBase = $resources.PackageBase

# Ensure search URL ends with '?'
if (-not ($searchUrl -match '\?')) {
    $searchUrl += '?'
} else {
    $searchUrl += '&'
}

Write-Host "Searching for packages by publisher: '$Publisher' ..." -ForegroundColor Yellow

$skip = 0
$take = 100
$totalDownloaded = 0
$processedCount = 0
$allPackages = @()

do {
    $query = "$($searchUrl)q=author:`"$Publisher`"&prerelease=$($IncludePrerelease.IsPresent)&skip=$skip&take=$take"
    try {
        $response = Invoke-RestMethod -Uri $query -UseBasicParsing
    } catch {
        Write-Error "Search API call failed: $_"
        exit 1
    }

    $packages = $response.data
    if (-not $packages -or $packages.Count -eq 0) {
        break
    }

    foreach ($pkg in $packages) {
        $id = $pkg.id
        $versions = $pkg.versions | ForEach-Object { $_.version }
        if ($versions.Count -eq 0) {
            # Fallback: use the top-level version
            $versions = @($pkg.version)
        }
        # If not AllVersions, only download the latest version
        # The "version" property is the latest (stable or prerelease depending on search)
        if (-not $AllVersions) {
            $latest = $pkg.version
            if ($versions -contains $latest) {
                $versions = @($latest)
            } else {
                # If not in the versions list, just use the latest from the list
                $versions = @($versions[-1])
            }
        }

        foreach ($ver in $versions) {
            if ($Limit -gt 0 -and $processedCount -ge $Limit) {
                Write-Host "Limit of $Limit reached. Stopping." -ForegroundColor Yellow
                break
            }
            $downloaded = Download-Package -PackageId $id -Version $ver -BaseUrl $packageBase -DestinationFolder $OutputDirectory
            if ($downloaded) { $totalDownloaded++ }
            $processedCount++
        }
        if ($Limit -gt 0 -and $processedCount -ge $Limit) {
            break
        }
    }

    $skip += $take
    # Break if we have fewer than 'take' results (last page)
    if ($packages.Count -lt $take) {
        break
    }
} while ($true)

Write-Host "Completed. Processed $processedCount package entries, downloaded $totalDownloaded new packages to '$OutputDirectory'." -ForegroundColor Green