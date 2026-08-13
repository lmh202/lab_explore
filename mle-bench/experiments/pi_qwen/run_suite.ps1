[CmdletBinding()]
param(
    [ValidateSet("baseline", "policy_v1")]
    [string]$Variant = "baseline",
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [ValidateRange(1, 63)]
    [int]$MaxCpuThreads = 4,
    [switch]$Smoke,
    [string]$RepoRoot,
    [string]$DataDir,
    [string]$RunsDir,
    [string]$PythonExe,
    [string]$PiExe
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$LASTEXITCODE = 0
if ($env:PATHEXT -notmatch "(?i)(^|;)\.EXE(;|$)") {
    $env:PATHEXT = ".COM;.EXE;.BAT;.CMD;$env:PATHEXT"
}
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if (-not $RunsDir) {
    $RunsDir = Join-Path $RepoRoot "runs\pi-qwen"
}
$ManifestPath = Join-Path $PSScriptRoot "candidates.json"
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

if ($Smoke) {
    $competitionIds = @([string]$manifest.smoke.competition_id)
    $Variant = "baseline"
    $TimeLimitHours = [double]$manifest.smoke.time_limit_minutes / 60.0
} elseif ($Variant -eq "baseline") {
    $smokeRoot = Join-Path $RunsDir "$($manifest.smoke.competition_id)\baseline"
    $latestSmoke = Get-ChildItem -LiteralPath $smokeRoot -Filter "run.json" -Recurse `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $latestSmoke) {
        throw "A successful spaceship-titanic smoke run is required before the six baselines. Run run_suite.ps1 -Smoke."
    }
    $smokeRun = Get-Content -LiteralPath $latestSmoke.FullName -Raw | ConvertFrom-Json
    if (-not $smokeRun.grade.valid_submission -or -not $smokeRun.integrity.clean -or
        -not $smokeRun.integrity.model_identity.verified) {
        throw "The latest smoke run did not pass submission, integrity, and model-identity checks: $($latestSmoke.FullName)"
    }
    $competitionIds = @($manifest.candidates.competition_id)
} else {
    $selectionPath = Join-Path $RunsDir "selection.json"
    if (-not (Test-Path -LiteralPath $selectionPath -PathType Leaf)) {
        throw "Bad-case selection is missing: $selectionPath"
    }
    $selection = Get-Content -LiteralPath $selectionPath -Raw | ConvertFrom-Json
    $competitionIds = @($selection.selected.competition_id)
    if ($competitionIds.Count -eq 0) {
        throw "No eligible bad case was selected; policy reruns will not be fabricated."
    }
    if ($competitionIds.Count -gt 3 -or
        @($competitionIds | Where-Object { $manifest.candidates.competition_id -notcontains $_ }).Count -gt 0) {
        throw "selection.json must contain at most three IDs from the fixed candidate manifest."
    }
}

$failures = @()
$reviewableTimeouts = @()
foreach ($competitionId in $competitionIds) {
    $arguments = @(
        "-CompetitionId", [string]$competitionId,
        "-Variant", $Variant,
        "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
        "-Seed", [string]$Seed,
        "-MaxCpuThreads", [string]$MaxCpuThreads,
        "-RepoRoot", $RepoRoot,
        "-RunsDir", $RunsDir
    )
    if ($DataDir) { $arguments += @("-DataDir", $DataDir) }
    if ($PythonExe) { $arguments += @("-PythonExe", $PythonExe) }
    if ($PiExe) { $arguments += @("-PiExe", $PiExe) }

    $caseProcess = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList (@(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $PSScriptRoot "run_case.ps1")
        ) + $arguments) `
        -NoNewWindow `
        -Wait `
        -PassThru
    if ($caseProcess.ExitCode -ne 0) {
        $caseRunRoot = Join-Path $RunsDir "$competitionId\$Variant"
        $latestCaseRun = Get-ChildItem -LiteralPath $caseRunRoot -Filter "run.json" -Recurse `
            -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        $isReviewableTimeout = $false
        if ($latestCaseRun) {
            try {
                $caseRun = Get-Content -LiteralPath $latestCaseRun.FullName -Raw |
                    ConvertFrom-Json
                $isReviewableTimeout = (
                    $caseRun.status -eq "timed_out" -and
                    $caseRun.public_submission_validation.valid -and
                    $caseRun.grade.valid_submission -and
                    $caseRun.integrity.clean -and
                    $caseRun.integrity.model_identity.verified
                )
            } catch {
                $isReviewableTimeout = $false
            }
        }
        if ($isReviewableTimeout) {
            $reviewableTimeouts += [string]$competitionId
        } else {
            $failures += [string]$competitionId
        }
    }
}

[pscustomobject]@{
    variant = $Variant
    attempted = @($competitionIds)
    failed = $failures
    reviewable_timeouts = $reviewableTimeouts
    max_cpu_threads = $MaxCpuThreads
    sequential = $true
} | ConvertTo-Json -Depth 4

if ($failures.Count -gt 0) {
    exit 2
}
