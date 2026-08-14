[CmdletBinding()]
param(
    [ValidateRange(0.01, 24.0)]
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [ValidateRange(1, 63)]
    [int]$MaxCpuThreads = 4,
    [ValidateRange(1, 5)]
    [int]$MaxPiAttempts = 3,
    [double]$MinFreeDiskGiB = 24
)

# Reliability rerun for the four expansion cases that produced no submission.
# The four repaired cases run concurrently on non-overlapping four-core slices.
# This coordinator may run beside other competitions, but refuses to duplicate
# one of its own four cases.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen-gemma"
$Runner = Join-Path $PSScriptRoot "run_case_gemma_parallel.ps1"
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$CompetitionIds = @(
    "lmsys-chatbot-arena",
    "tensorflow2-question-answering",
    "uw-madison-gi-tract-image-segmentation",
    "AI4Code"
)

if (-not (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -or
    [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
    throw "ANTHROPIC_AUTH_TOKEN is not set in this PowerShell session."
}

$activeRunners = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -eq "powershell.exe" -and
        $_.CommandLine -like "*run_case_gemma_parallel.ps1*" -and
        $_.CommandLine -match '-CompetitionId\s+([^\s]+)' -and
        $CompetitionIds -contains $Matches[1].Trim('"')
    })
if ($activeRunners.Count -gt 0) {
    $duplicates = @($activeRunners | ForEach-Object { "PID $($_.ProcessId)" }) -join ", "
    throw "A repaired case runner is already active ($duplicates); refusing to launch a duplicate."
}

function Get-FreeDiskGiB {
    return ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($RepoRoot))).AvailableFreeSpace / 1GB
}

function Get-LatestRunDirectory {
    param([string]$CompetitionId)
    return Get-ChildItem -LiteralPath (Join-Path $RunsDir "$CompetitionId\baseline") -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

function Remove-RedundantPublicCopies {
    param([string]$CompetitionId)
    $latest = Get-LatestRunDirectory -CompetitionId $CompetitionId
    if ($null -eq $latest) { return }
    $source = Join-Path $RepoRoot "data\$CompetitionId\prepared\public"
    $target = Join-Path $latest.FullName "workspace\data"
    if (-not (Test-Path -LiteralPath $source -PathType Container) -or
        -not (Test-Path -LiteralPath $target -PathType Container)) {
        return
    }
    foreach ($sourceFile in Get-ChildItem -LiteralPath $source -File -Recurse) {
        $relative = $sourceFile.FullName.Substring($source.Length).TrimStart([char]'\', [char]'/')
        if ($relative -in @("description.md", "sample_submission.csv")) { continue }
        $copy = Join-Path $target $relative
        if (Test-Path -LiteralPath $copy -PathType Leaf) {
            Remove-Item -LiteralPath $copy -Force
        }
    }
    Get-ChildItem -LiteralPath $target -Directory -Recurse |
        Sort-Object FullName -Descending |
        ForEach-Object {
            if (@(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
}

$jobs = @(
    @{ Id = "lmsys-chatbot-arena"; Offset = 0 },
    @{ Id = "tensorflow2-question-answering"; Offset = 4 },
    @{ Id = "uw-madison-gi-tract-image-segmentation"; Offset = 8 },
    @{ Id = "AI4Code"; Offset = 12 }
)

$copyBytes = 0L
foreach ($job in $jobs) {
    $publicData = Join-Path $RepoRoot "data\$($job.Id)\prepared\public"
    if (-not (Test-Path -LiteralPath $publicData -PathType Container)) {
        throw "Prepared public data is missing for $($job.Id): $publicData"
    }
    $copyBytes += [int64]((Get-ChildItem -LiteralPath $publicData -File -Recurse |
        Measure-Object -Property Length -Sum).Sum)
}
$freeDisk = Get-FreeDiskGiB
$requiredDisk = $MinFreeDiskGiB + ($copyBytes / 1GB)
if ($freeDisk -lt $requiredDisk) {
    throw ("Refusing parallel reruns: {0:N1} GiB free, but copies plus safety floor require {1:N1} GiB." -f
        $freeDisk, $requiredDisk)
}

$processes = @()
foreach ($job in $jobs) {
    Write-Output ("[{0:o}] starting reliability rerun: {1} (CPU offset {2})" -f
        [DateTime]::UtcNow, $job.Id, $job.Offset)
    $process = Start-Process -FilePath $PowerShellExe -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
        "-CompetitionId", $job.Id,
        "-Variant", "baseline",
        "-TimeLimitHours", ([string]::Format(
            [Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
        "-Seed", [string]$Seed,
        "-MaxCpuThreads", [string]$MaxCpuThreads,
        "-CoreOffset", [string]$job.Offset,
        "-MaxPiAttempts", [string]$MaxPiAttempts,
        "-RepoRoot", $RepoRoot,
        "-RunsDir", $RunsDir
    ) -WindowStyle Hidden -PassThru
    $processes += [pscustomobject]@{ CompetitionId = $job.Id; Process = $process }
    Start-Sleep -Seconds 2
}

Write-Output ("[{0:o}] all four reliability reruns launched" -f [DateTime]::UtcNow)
foreach ($entry in $processes) {
    $entry.Process.WaitForExit()
    Write-Output ("[{0:o}] finished {1}: runner exit={2}" -f
        [DateTime]::UtcNow, $entry.CompetitionId, $entry.Process.ExitCode)
    Remove-RedundantPublicCopies -CompetitionId $entry.CompetitionId
}

Write-Output ("[{0:o}] all four reliability reruns finished" -f [DateTime]::UtcNow)
