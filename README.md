# NuGet Downloader
Windows PowerShell script to download NuGet packages.

## Usage

.\NuGetDownloader.ps1 -Publisher "Microsoft"

.\NuGetDownloader.ps1 -Publisher "YourCompany" -Source "https://pkgs.dev.azure.com/yourorg/_packaging/yourfeed/nuget/v3/index.json" -OutputDirectory "C:\MyPackages"

### How It Works

Fetches the NuGet V3 service index to locate the search and package download endpoints.
Queries the search endpoint with author:"PublisherName" to retrieve all packages.
For each package, it downloads the latest version (or all versions if -AllVersions).
Uses the package base address to construct the exact .nupkg URL.
Skips any file that already exists to avoid re-downloading.

### Limitations & Considerations

Public NuGet.org has a query limit; the script paginates through the results (100 per page).
Authentication is not handled; for private feeds, you might need to pass an API key or use Invoke-WebRequest -Credential.
Large downloads: If a publisher has hundreds of packages, this may take time and bandwidth.
The search API may not return all packages if the author name is not exact; you can adjust the q parameter if needed.
