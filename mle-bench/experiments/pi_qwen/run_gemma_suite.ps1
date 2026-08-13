[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# Full baseline sweep with nvidia/Gemma-4-26B-A4B-NVFP4 (262144 context) and
# the ORIGINAL, unpatched pi.exe (no source patch, no extensions) -- testing
# whether a much larger real context window alone sidesteps the
# truncation/compaction issues found with qwen3.6-27b's 32768 window,
# without needing either of tonight's two targeted fixes.
#
# Step 0: smoke test (spaceship-titanic, <=10min) to catch basic config
# errors cheaply before committing to the full 6-candidate sweep.
# Results land under runs\pi-qwen-gemma\ (separate from the qwen runs).

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen-gemma"
$CompetitionIds = @(
    "tabular-playground-series-may-2022",
    "ventilator-pressure-prediction",
    "chaii-hindi-and-tamil-question-answering",
    "text-normalization-challenge-english-language",
    "statoil-iceberg-classifier-challenge",
    "tgs-salt-identification-challenge"
)

function Invoke-Case {
    param([string]$CompetitionId, [double]$Hours)
    Write-Output "=== starting (gemma): $CompetitionId (limit ${Hours}h) ==="
    $p = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $PSScriptRoot "run_case_gemma.ps1"),
            "-CompetitionId", $CompetitionId,
            "-Variant", "baseline",
            "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $Hours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir
        ) `
        -NoNewWindow -Wait -PassThru
    Write-Output "=== finished (gemma): $CompetitionId exit=$($p.ExitCode) ==="
    return $p.ExitCode
}

$smokeExit = Invoke-Case -CompetitionId "spaceship-titanic" -Hours (10.0 / 60.0)
if ($smokeExit -ne 0) {
    Write-Output "SMOKE_FAILED exit=$smokeExit -- stopping before the real candidates."
    exit 2
}
Write-Output "SMOKE_OK"

foreach ($competitionId in $CompetitionIds) {
    Invoke-Case -CompetitionId $competitionId -Hours $TimeLimitHours | Out-Null
}

Write-Output "ALL_GEMMA_RUNS_DONE"
