[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# The 6 real candidates only (smoke already verified manually: completed,
# score 0.80805, clean). Gemma (262144 context) + original unpatched pi.exe.

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

foreach ($competitionId in $CompetitionIds) {
    Write-Output "=== starting (gemma): $competitionId ==="
    $p = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $PSScriptRoot "run_case_gemma.ps1"),
            "-CompetitionId", $competitionId,
            "-Variant", "baseline",
            "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir
        ) `
        -NoNewWindow -Wait -PassThru
    Write-Output "=== finished (gemma): $competitionId exit=$($p.ExitCode) ==="
}

Write-Output "ALL_GEMMA_CANDIDATES_DONE"
