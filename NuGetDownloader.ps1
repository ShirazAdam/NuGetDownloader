<#
.SYNOPSIS
    Downloads NuGet packages from a specific publisher (author) from a NuGet feed.

.DESCRIPTION
    Searches a NuGet V3 feed for packages by the specified author and downloads
    their .nupkg files to a local directory. Automatically paginates through all
    results using the API's totalHits count.

.PARAMETER Publisher
    The name of the publisher/author (e.g., "Microsoft").

.PARAMETER Source
    The NuGet V3 index URL. Defaults to the official NuGet gallery.

.PARAMETER OutputDirectory
    The folder where packages will be saved. Defaults to ".\Packages".

.PARAMETER IncludePrerelease
    If specified, prerelease packages are included in the search.

.PARAMETER AllVersions
    If specified, all versions of each package are downloaded; otherwise only the latest.

.PARAMETER Limit
    Maximum number of package versions to process (for testing). Default is 0 (no limit).
#>

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

# Ensure search URL ends with '?' or '&'
if (-not ($searchUrl -match '\?')) {
    $searchUrl += '?'
} else {
    $searchUrl += '&'
}

Write-Host "Searching for packages by publisher: '$Publisher' ..." -ForegroundColor Yellow

$skip = 0
$take = 100
$totalHits = $null
$processedCount = 0
$totalDownloaded = 0

do {
    $query = "$($searchUrl)q=author:`"$Publisher`"&prerelease=$($IncludePrerelease.IsPresent)&skip=$skip&take=$take"
    try {
        $response = Invoke-RestMethod -Uri $query -UseBasicParsing
    } catch {
        Write-Error "Search API call failed: $_"
        exit 1
    }

    # On first request, capture totalHits if available
    if ($null -eq $totalHits) {
        if ($response.PSObject.Properties.Name -contains 'totalHits') {
            $totalHits = $response.totalHits
            if ($totalHits -eq 0) {
                Write-Host "No packages found for publisher '$Publisher'." -ForegroundColor Red
                exit 0
            }
            Write-Host "Total packages found: $totalHits" -ForegroundColor Yellow
        } else {
            # Fallback: totalHits not provided, we'll use page size to determine end
            Write-Host "Total hits not provided by feed; will paginate until an empty page is returned." -ForegroundColor Yellow
        }
    }

    $packages = $response.data
    if (-not $packages -or $packages.Count -eq 0) {
        break
    }

    Write-Host "Processing page $($skip / $take + 1) ..." -ForegroundColor Magenta

    foreach ($pkg in $packages) {
        $id = $pkg.id
        $versions = $pkg.versions | ForEach-Object { $_.version }
        if ($versions.Count -eq 0) {
            $versions = @($pkg.version)
        }
        # If not AllVersions, only download the latest version
        if (-not $AllVersions) {
            $latest = $pkg.version
            if ($versions -contains $latest) {
                $versions = @($latest)
            } else {
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

    # If we have totalHits, use it to decide when to stop; otherwise fallback to page count
    if ($totalHits) {
        # Continue while skip is less than totalHits
    } else {
        # If we got fewer than $take items, we've reached the last page
        if ($packages.Count -lt $take) {
            break
        }
    }
} while (-not $totalHits -or $skip -lt $totalHits)

Write-Host "Completed. Processed $processedCount package entries, downloaded $totalDownloaded new packages to '$OutputDirectory'." -ForegroundColor Green
