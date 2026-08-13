[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [int]$MaxCpuThreads = 4
)

# Launch text-normalization, statoil-iceberg, and tgs-salt truly in
# parallel, each pinned to its own non-overlapping 4-core slice (offsets
# 4/8/12 -- chaii is already running on offset 0 via the sequential
# launcher). Waits for all three, then reports exit codes.

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen-gemma"

$jobs = @(
    @{ Id = "text-normalization-challenge-english-language"; Offset = 4 },
    @{ Id = "statoil-iceberg-classifier-challenge"; Offset = 8 },
    @{ Id = "tgs-salt-identification-challenge"; Offset = 12 }
)

$procs = @()
foreach ($job in $jobs) {
    Write-Output "=== launching (parallel, offset $($job.Offset)): $($job.Id) ==="
    $p = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            (Join-Path $PSScriptRoot "run_case_gemma_parallel.ps1"),
            "-CompetitionId", $job.Id,
            "-Variant", "baseline",
            "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-CoreOffset", [string]$job.Offset,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir
        ) `
        -NoNewWindow -PassThru
    $procs += [pscustomobject]@{ Id = $job.Id; Process = $p }
    Start-Sleep -Seconds 3
}

Write-Output "All three launched. Waiting for completion..."
foreach ($entry in $procs) {
    $entry.Process.WaitForExit()
    Write-Output "=== finished (parallel): $($entry.Id) exit=$($entry.Process.ExitCode) ==="
}

Write-Output "ALL_PARALLEL_DONE"
