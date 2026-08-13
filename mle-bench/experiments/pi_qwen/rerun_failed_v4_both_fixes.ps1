[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# Fourth rerun pass: chaii and tgs-salt, with BOTH fixes active together:
#   1. pi_patched/pi.exe -- source patch so the one-shot overflow-recovery
#      flag isn't wasted on a no-op compaction.
#   2. ~/.pi/agent/extensions/oversized-tool-result-guard.ts -- truncates any
#      single tool result over 6000 chars before it enters context, so one
#      giant bash error/output can't survive compaction's "keep most recent"
#      window and blow the budget on retry (the exact cause of both v3
#      failures). Requires extensions enabled, so this uses run_case_ext.ps1
#      (a copy of run_case.ps1 with --no-extensions removed) instead of the
#      real run_case.ps1.

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen"
$PatchedPiExe = "D:\Downloads\Content\NUS\lab\pi_patched\pi.exe"
$CompetitionIds = @(
    "chaii-hindi-and-tamil-question-answering",
    "tgs-salt-identification-challenge"
)

foreach ($competitionId in $CompetitionIds) {
    Write-Output "=== starting rerun v4 (patched pi + tool-result guard): $competitionId ==="
    $caseProcess = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $PSScriptRoot "run_case_ext.ps1"),
            "-CompetitionId", $competitionId,
            "-Variant", "baseline",
            "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir,
            "-PiExe", $PatchedPiExe
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    Write-Output "=== finished rerun v4: $competitionId exit=$($caseProcess.ExitCode) ==="
}

Write-Output "ALL_RERUNS_V4_DONE"
