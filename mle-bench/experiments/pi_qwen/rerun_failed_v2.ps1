[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# Second rerun pass: only chaii and tgs-salt still failed after the first fix
# (retry.maxRetries 3->10, maxTokens 8192->16384). statoil-iceberg succeeded
# on the first rerun and is not repeated here.
#
# This pass adds contextWindow 32768->20000 in ~/.pi/agent/models.json, based
# on a controlled diagnostic (see diag_compaction/) showing pi's reactive
# overflow-triggered compaction works reliably (20/20 successful recoveries,
# zero output-length truncations in a long forced-context-growth test) but
# never fires proactively at the documented 50% threshold -- only on a true
# overflow. Lowering contextWindow makes a true overflow trigger earlier and
# more reliably, before sessions drift into the "high but not overflowing"
# zone where truncated-thinking turns have no recovery path at all.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen"
$CompetitionIds = @(
    "chaii-hindi-and-tamil-question-answering",
    "tgs-salt-identification-challenge"
)

foreach ($competitionId in $CompetitionIds) {
    Write-Output "=== starting rerun v2: $competitionId ==="
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
    Write-Output "=== finished rerun v2: $competitionId exit=$($caseProcess.ExitCode) ==="
}

Write-Output "ALL_RERUNS_V2_DONE"
