[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# Third rerun pass: chaii and tgs-salt, using a locally-patched pi.exe
# (pi_patched/pi.exe, built from pi-mono v0.84.1 with one fix in
# agent-session.ts::_checkCompaction -- the one-shot overflow-recovery flag
# is no longer consumed when prepareCompaction() finds nothing to compact,
# which previously wasted the only recovery attempt on a silent no-op and
# left a session with zero protection against a second truncation shortly
# after. See RUNLOG / conversation history for the full diagnosis. The
# original official pi.exe is untouched at D:\...\lab\pi\pi.exe and backed
# up at D:\...\lab\pi_backup_0.84.1_original\pi.exe.

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen"
$PatchedPiExe = "D:\Downloads\Content\NUS\lab\pi_patched\pi.exe"
$CompetitionIds = @(
    "chaii-hindi-and-tamil-question-answering",
    "tgs-salt-identification-challenge"
)

foreach ($competitionId in $CompetitionIds) {
    Write-Output "=== starting rerun v3 (patched pi): $competitionId ==="
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
            "-RunsDir", $RunsDir,
            "-PiExe", $PatchedPiExe
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    Write-Output "=== finished rerun v3: $competitionId exit=$($caseProcess.ExitCode) ==="
}

Write-Output "ALL_RERUNS_V3_DONE"
