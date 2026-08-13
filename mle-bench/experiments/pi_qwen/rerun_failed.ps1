[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# Re-run the three baseline cases that previously ended early because pi's
# agent-level retry budget (default retry.maxRetries=3) was exhausted after
# repeated output-length truncations. ~/.pi/agent/settings.json now sets
# retry.maxRetries=10 and ~/.pi/agent/models.json raises maxTokens to 16384
# for both qwen3.6 entries -- this script assumes those edits are already in
# place; it does not modify pi config itself.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen"
$CompetitionIds = @(
    "chaii-hindi-and-tamil-question-answering",
    "statoil-iceberg-classifier-challenge",
    "tgs-salt-identification-challenge"
)

foreach ($competitionId in $CompetitionIds) {
    Write-Output "=== starting rerun: $competitionId ==="
    $caseProcess = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $PSScriptRoot "run_case.ps1"),
            "-CompetitionId", $competitionId,
            "-Variant", "baseline",
            "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    Write-Output "=== finished rerun: $competitionId exit=$($caseProcess.ExitCode) ==="
}

Write-Output "ALL_RERUNS_DONE"
