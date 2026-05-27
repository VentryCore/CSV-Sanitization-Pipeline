# =============================================================================
#  CsvViewer.ps1
#
# Renders a formatted terminal preview of CSV files in a target directory.
# Designed as a diagnostic companion to  CsvSanitizer — point it at
# .\Chaotic Data to inspect raw fault-injected files, or .\Clean_CSVs to
# verify sanitizer output.
#
# Usage:
#   .\CsvViewer.ps1                          # defaults to .\Clean_CSVs
#   .\CsvViewer.ps1 -Folder ".\Chaotic Data" # inspect dirty files
#   .\CsvViewer.ps1 -Folder ".\Clean_CSVs" -PreviewRows 10
# =============================================================================

param(
    [string]$Folder      = ".\Chaotic Data",   # Target directory (overridable at runtime)
    [int]$PreviewRows    = 5                   # Number of rows to display per file
)

Write-Host "   ----- CSV Viewer ----- " -ForegroundColor Yellow
Write-Host "Target : $Folder" -ForegroundColor DarkGray
Write-Host "Preview: $PreviewRows rows per file`n" -ForegroundColor DarkGray

if (-not (Test-Path $Folder)) {
    Write-Host "Directory '$Folder' does not exist." -ForegroundColor Red
    exit 1
}

$csvfiles = Get-ChildItem $Folder -Filter "*.csv"

if ($csvfiles.Count -eq 0) {
    Write-Host "No CSV files found in '$Folder'." -ForegroundColor Yellow
    exit 0
}

Write-Host "$($csvfiles.Count) CSV files found in $Folder`n" -ForegroundColor Cyan

$file_index = 0


foreach ($file in $csvfiles[0..10]) {
    $file_index++

    $data      = Import-Csv $file.FullName
    $row_count = $data.Count

    # File header banner — makes it easy to visually separate files
    # in a long terminal dump
    Write-Host "[$file_index / $($csvfiles.Count)]  $($file.Name)  ($row_count rows)" -ForegroundColor Green
    Write-Host ("-" * 60) -ForegroundColor DarkGray

    # Render only the first $PreviewRows rows — avoids flooding the terminal
    # when inspecting large files or the full 50-file set
    $data | Select-Object -First $PreviewRows | Format-Table -AutoSize
}

Write-Host "Viewer complete. $file_index files rendered." -ForegroundColor Cyan
