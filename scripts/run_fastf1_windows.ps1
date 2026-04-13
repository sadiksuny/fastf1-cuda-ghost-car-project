param(
    [Parameter(Mandatory = $true)]
    [int]$Year,

    [Parameter(Mandatory = $true)]
    [string]$Event,

    [Parameter(Mandatory = $true)]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [string]$ReferenceDriver,

    [Parameter(Mandatory = $true)]
    [string]$CompareDriver,

    [int]$ReferenceLap,
    [int]$CompareLap,
    [string]$BuildConfig = "Release",
    [string]$CacheDir = ".fastf1_cache"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$refCsv = Join-Path $repoRoot "data\fastf1_ref.csv"
$cmpCsv = Join-Path $repoRoot "data\fastf1_cmp.csv"
$exportScript = Join-Path $repoRoot "scripts\export_fastf1_laps.py"
$exePath = Join-Path $repoRoot "build\$BuildConfig\f1_ghost_app.exe"
$pythonCmd = Get-Command py -ErrorAction SilentlyContinue

if (-not $pythonCmd) {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
}

if (-not $pythonCmd) {
    throw "Neither 'py' nor 'python' was found on PATH. Activate your Anaconda environment first, then rerun this script."
}

$exportArgs = @(
    $exportScript,
    "--year", $Year,
    "--event", $Event,
    "--session", $Session,
    "--cache-dir", $CacheDir,
    "--reference-driver", $ReferenceDriver,
    "--compare-driver", $CompareDriver,
    "--reference-output", $refCsv,
    "--compare-output", $cmpCsv
)

if ($PSBoundParameters.ContainsKey("ReferenceLap")) {
    $exportArgs += @("--reference-lap", $ReferenceLap)
}

if ($PSBoundParameters.ContainsKey("CompareLap")) {
    $exportArgs += @("--compare-lap", $CompareLap)
}

& $pythonCmd.Source @exportArgs

if (-not (Test-Path $exePath)) {
    throw "App executable not found at $exePath. Build the project first."
}

& $exePath $refCsv $cmpCsv $ReferenceDriver $CompareDriver
