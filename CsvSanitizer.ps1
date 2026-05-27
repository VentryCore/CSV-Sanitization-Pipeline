# =============================================================================
# CsvSanitizer.ps1
#
# Scans all CSV files in the .\Chaotic Data directory, applies 5 targeted...
# remediation passes per file, and exports normalized output to .\Clean_CSVs.
# All anomalies encountered are recorded in .\LogFile.txt
#
# Remediation passes (in order):
#   1. Trailing whitespace in string columns
#   2. Corrupted / null price values  (NULL, NaN, N/A, blank)
#   3. Inconsistent date formats      (DD/MM/YYYY  →  YYYY-MM-DD)
#   4. Inconsistent column header names
#   5. Duplicate rows (content-fingerprint match on Product + Price + Date)
# =============================================================================

$dirty_data  = ".\Chaotic Data"
$cleaned_data = ".\Clean_CSVs"
$logfile      = ".\LogFile.txt"
$file_number  = 0

# Generic List outperforms @() for repeated appends at scale.
# @() creates a new array copy on every += operation — O(n) per append.
# List.Add() is O(1) amortized.
$SystemLog = [System.Collections.Generic.List[string]]::new()

Write-Host "   ---- CSV Sanitizer ---- " -ForegroundColor Yellow

# =============================================================================
# FUNCTION: Remove-DuplicateRows
#
# Filters a collection of PSCustomObjects, retaining only the first occurrence
# of each unique row. Uniqueness is determined by a content fingerprint composed
# of Product, Price, and Date — Transaction ID is intentionally excluded because
# duplicate IDs are a symptom of duplication, not a reliable identifier of it.
#
# Uses a HashSet for O(1) average lookup per row. HashSet.Add() returns $true
# if the value was newly inserted (keep the row) and $false if it already
# existed (discard the row). Where-Object uses that boolean directly.
# =============================================================================
function Remove-DuplicateRows {
    param($Rows)

    $seen = [System.Collections.Generic.HashSet[string]]::new()

    $Rows | Where-Object {
        $fingerprint = "$($_.Product)|$($_.Price)|$($_.Date)"
        $seen.Add($fingerprint)
    }
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# Validate input/output paths before entering the processing loop.
# -----------------------------------------------------------------------------

if (-not (Test-Path $cleaned_data)) {
    "Creating output directory: $cleaned_data"
    mkdir $cleaned_data | Out-Null
}

if (Test-Path $dirty_data) {
    $csvfiles = Get-ChildItem $dirty_data -Filter "*.csv"
    "Path is valid. Starting sanitizer ..."
    Write-Host "`nDetected $($csvfiles.count) CSV files for processing" -ForegroundColor Cyan
}
else {
    Write-Warning "Input path '$dirty_data' not found. Exiting."
    exit 1
}

# =============================================================================
# MAIN PROCESSING LOOP
# Each iteration processes one CSV file end-to-end.
# =============================================================================

foreach ($file in $csvfiles) {
    $file_number++
    $row_number = 0

    # Use a Generic List for the per-file accumulator — same O(1) append
    # rationale as $SystemLog above.
    $SingleCleanBucket = [System.Collections.Generic.List[object]]::new()

    # -------------------------------------------------------------------------
    # HEADER DETECTION
    # Reads only the first row to extract column names without loading the
    # entire file. This handles FAULT 4 (header name mutation) by treating
    # headers positionally rather than by name — assumes a stable column order
    # across all source files (validated against sample inspection).
    # -------------------------------------------------------------------------
    $samplerow = Import-Csv $file.FullName | Select-Object -First 1
    $headers = $samplerow.psobject.Properties.Name

    $IdHeader      = $headers[0]
    $ProductHeader = $headers[1]
    $PriceHeader   = $headers[2]
    $DateHeader    = $headers[3]

    # Load the full file now that headers are resolved
    $rawrows = Import-Csv $file.FullName

    # =========================================================================
    # ROW-LEVEL REMEDIATION LOOP
    # =========================================================================
    foreach ($row in $rawrows) {
        $row_number++

        # ---------------------------------------------------------------------
        # PASS 1: Trailing Whitespace (Product column)
        # String.Trim() removes all leading and trailing whitespace characters.
        # Applied in-place on the row object before building the clean record.
        # ---------------------------------------------------------------------
        $row.$ProductHeader = ($row.$ProductHeader).Trim()

        # ---------------------------------------------------------------------
        # PASS 2: Corrupted Price Values
        # Import-Csv deserializes all cell values as [string]. The -as operator
        # attempts a type cast and returns $null on failure — except for "NaN",
        # which casts to [double]::NaN (a valid IEEE 754 value, not $null).
        # Both failure modes are caught explicitly.
        # ---------------------------------------------------------------------
        $raw_price    = $row.$PriceHeader
        $Parsed_Price = $raw_price -as [double]

        if ($null -ne $Parsed_Price -and -not [double]::IsNaN($Parsed_Price)) {
            $row.$PriceHeader = [double]$Parsed_Price
        }
        else {
            $bad_value   = if ([string]::IsNullOrWhiteSpace($raw_price)) { "Blank space" } else { $raw_price }
            $log_message = "[PRICE] '$bad_value' in file $file_number, row $row_number. Defaulted to 0.0"
            $SystemLog.Add($log_message)
            $row.$PriceHeader = 0.0
        }

        # ---------------------------------------------------------------------
        # PASS 3: Date Format Normalization
        # Two formats are present in source data:
        #   - YYYY-MM-DD  (baseline)
        #   - DD/MM/YYYY  (injected by the fault injector)
        #
        # Step 1: Normalize delimiters — replace "/" with "-"
        # Step 2: Detect DD-MM-YYYY via regex and parse with ParseExact +
        #         InvariantCulture to prevent locale-dependent misinterpretation.
        # Step 3: All other formats are passed to the [datetime] cast.
        # Step 4: On any failure, log and apply the fallback date.
        # ---------------------------------------------------------------------
        $rawdate = $row.$DateHeader
        try {
            $cleandate = $rawdate -replace "--|/" , "-"

            if ($cleandate -match '\d{1,2}-\d{1,2}-\d{4}') {
                $real_date_format = [datetime]::ParseExact(
                    $cleandate,
                    "d-M-yyyy",
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            }
            else {
                $real_date_format = [datetime]$cleandate
            }

            $final_format = $real_date_format.ToString("yyyy-MM-dd")
        }
        catch {
            $fall_back_date = "2001-01-01"
            $logfile2       = "[DATE] Unparseable date '$rawdate' in file $file_number, row $row_number. Defaulted to $fall_back_date"
            $SystemLog.Add($logfile2)
            $final_format = $fall_back_date
        }

        # ---------------------------------------------------------------------
        # PASS 4: Header Name Normalization
        # Forces all output records to a canonical schema regardless of what
        # header aliases appeared in the source file. The positional header
        # variables resolved above make this transparent to the row data.
        # ---------------------------------------------------------------------
        $cleanobject = [PSCustomObject]@{
            "Transaction ID" = $row.$IdHeader
            "Product"        = $row.$ProductHeader
            "Price"          = [double]($row.$PriceHeader)
            "Date"           = $final_format
        }

        $SingleCleanBucket.Add($cleanobject)
    }

    # -------------------------------------------------------------------------
    # PASS 5: Duplicate Row Removal
    # Deduplication is performed after all other passes so that the fingerprint
    # operates on normalized data (trimmed strings, resolved dates, clean prices)
    # rather than the raw dirty values.
    # -------------------------------------------------------------------------
    $cleanfile = Remove-DuplicateRows -Rows $SingleCleanBucket

    # -------------------------------------------------------------------------
    # EXPORT
    # -------------------------------------------------------------------------
    $filename   = "CLEAN_" + $file.Name
    $finalpath  = Join-Path $cleaned_data $filename
    $cleanfile | Export-Csv -Path $finalpath -NoTypeInformation
}

Write-Host "`nSanitization complete. $file_number files processed. ✅" -ForegroundColor Green
Write-Host "Output directory: $finalpath" -ForegroundColor Cyan

if ($SystemLog.Count -gt 0) {
    Write-Host "`nATTENTION: $($SystemLog.Count) anomalies logged → $logfile" -ForegroundColor Red
    $SystemLog | Out-File -FilePath $logfile -Encoding utf8
}
