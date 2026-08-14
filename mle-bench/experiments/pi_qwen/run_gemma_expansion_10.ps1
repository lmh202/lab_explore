[CmdletBinding()]
param(
    [double]$TimeLimitHours = 6,
    [int]$Seed = 42,
    [ValidateRange(1, 63)]
    [int]$MaxCpuThreads = 4,
    [double]$MinFreeDiskGiB = 24
)

# Runs the ten post-baseline Gemma candidates without opening console windows.
# Seven smaller cases use two non-overlapping four-core slots. The three large
# prepared datasets run serially so their isolated workspace copies cannot
# exhaust the host disk. After grading, redundant public-data copies are
# removed from the run workspace; all experiment artifacts are retained.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen-gemma"
$Runner = Join-Path $PSScriptRoot "run_case_gemma_parallel.ps1"
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$smallCases = @(
    "lmsys-chatbot-arena",
    "champs-scalar-coupling",
    "tweet-sentiment-extraction",
    "google-quest-challenge",
    "jigsaw-unintended-bias-in-toxicity-classification",
    "learning-agency-lab-automated-essay-scoring-2",
    "stanford-covid-vaccine"
)
$largeCases = @(
    "tensorflow2-question-answering",
    "uw-madison-gi-tract-image-segmentation",
    "AI4Code"
)
$expectedCases = Get-Content -LiteralPath (Join-Path $PSScriptRoot "candidates_expansion_14.txt") |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if (@($expectedCases).Count -ne 10 -or
    @($expectedCases | Where-Object { $_ -notin @($smallCases + $largeCases) }).Count -ne 0) {
    throw "The expansion list must contain exactly the scheduler's ten fixed competitions."
}
if (-not (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -or
    [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
    throw "ANTHROPIC_AUTH_TOKEN is not set in the scheduler process."
}

function Get-FreeDiskGiB {
    $root = [IO.Path]::GetPathRoot($RepoRoot)
    return ([IO.DriveInfo]::new($root)).AvailableFreeSpace / 1GB
}

function Assert-FreeDisk {
    param([string]$CompetitionId)
    $free = Get-FreeDiskGiB
    if ($free -lt $MinFreeDiskGiB) {
        throw ("Refusing to start {0}: only {1:N2} GiB free; minimum is {2:N2} GiB." -f
            $CompetitionId, $free, $MinFreeDiskGiB)
    }
}

function Get-LatestRunDirectory {
    param([string]$CompetitionId)
    $baseline = Join-Path $RunsDir "$CompetitionId\baseline"
    if (-not (Test-Path -LiteralPath $baseline -PathType Container)) {
        return $null
    }
    return Get-ChildItem -LiteralPath $baseline -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

function Test-AlreadyAttempted {
    param([string]$CompetitionId)
    $latest = Get-LatestRunDirectory -CompetitionId $CompetitionId
    return $null -ne $latest -and (Test-Path -LiteralPath (Join-Path $latest.FullName "run.json"))
}

function Remove-RedundantPublicCopies {
    param([string]$CompetitionId)

    $latest = Get-LatestRunDirectory -CompetitionId $CompetitionId
    if ($null -eq $latest) {
        return
    }
    $source = Join-Path $RepoRoot "data\$CompetitionId\prepared\public"
    $target = Join-Path $latest.FullName "workspace\data"
    if (-not (Test-Path -LiteralPath $source -PathType Container) -or
        -not (Test-Path -LiteralPath $target -PathType Container)) {
        return
    }

    $before = Get-FreeDiskGiB
    foreach ($sourceFile in Get-ChildItem -LiteralPath $source -File -Recurse) {
        $relative = $sourceFile.FullName.Substring($source.Length).TrimStart('\', '/')
        if ($relative -in @("description.md", "sample_submission.csv")) {
            continue
        }
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
    $freed = (Get-FreeDiskGiB) - $before
    Write-Output ("[{0}] pruned redundant workspace public-data copies; freed {1:N2} GiB" -f
        $CompetitionId, $freed)
}

function Start-Case {
    param(
        [string]$CompetitionId,
        [int]$CoreOffset
    )
    Assert-FreeDisk -CompetitionId $CompetitionId
    Write-Host ("[{0}] launching on CPU offset {1}; free disk {2:N2} GiB" -f
        $CompetitionId, $CoreOffset, (Get-FreeDiskGiB))
    return Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
            "-CompetitionId", $CompetitionId,
            "-Variant", "baseline",
            "-TimeLimitHours", ([string]::Format(
                [Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-CoreOffset", [string]$CoreOffset,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir
        ) `
        -WindowStyle Hidden `
        -PassThru
}

function Get-RunningCaseProcess {
    param([string]$CompetitionId)

    $casePattern = "-CompetitionId\s+{0}(?:\s|$)" -f [regex]::Escape($CompetitionId)
    $candidate = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            $_.CommandLine -like "*run_case_gemma_parallel.ps1*" -and
            $_.CommandLine -match $casePattern
        } |
        Sort-Object CreationDate |
        Select-Object -First 1
    if ($null -eq $candidate) {
        return $null
    }

    $coreOffset = 0
    if ($candidate.CommandLine -match "-CoreOffset\s+(\d+)") {
        $coreOffset = [int]$Matches[1]
    }
    return [pscustomobject]@{
        Process = Get-Process -Id $candidate.ProcessId
        CoreOffset = $coreOffset
    }
}

Write-Output ("Expansion scheduler started at {0:o}" -f [DateTime]::UtcNow)
Write-Output ("Pi/Gemma runs: seed={0}, time limit={1}h, threads/case={2}" -f
    $Seed, $TimeLimitHours, $MaxCpuThreads)

$pending = [Collections.Generic.Queue[string]]::new()
$active = @{}
$slots = @(0, 4)
foreach ($competitionId in $smallCases) {
    $running = Get-RunningCaseProcess -CompetitionId $competitionId
    if ($null -ne $running) {
        $slot = $running.CoreOffset
        if ($slot -notin $slots -or $active.ContainsKey($slot)) {
            $slot = @($slots | Where-Object { -not $active.ContainsKey($_) })[0]
        }
        $active[$slot] = [pscustomobject]@{
            CompetitionId = $competitionId
            Process = $running.Process
        }
        Write-Host "[$competitionId] adopted existing runner process $($running.Process.Id)"
    }
    elseif (Test-AlreadyAttempted -CompetitionId $competitionId) {
        Write-Output "[$competitionId] skipped: a run.json already exists"
    }
    else {
        $pending.Enqueue($competitionId)
    }
}

while ($pending.Count -gt 0 -or $active.Count -gt 0) {
    foreach ($slot in $slots) {
        if (-not $active.ContainsKey($slot) -and $pending.Count -gt 0) {
            $competitionId = $pending.Dequeue()
            $active[$slot] = [pscustomobject]@{
                CompetitionId = $competitionId
                Process = (Start-Case -CompetitionId $competitionId -CoreOffset $slot)
            }
            Start-Sleep -Seconds 3
        }
    }

    Start-Sleep -Seconds 15
    foreach ($slot in @($active.Keys)) {
        $entry = $active[$slot]
        $entry.Process.Refresh()
        if ($entry.Process.HasExited) {
            Write-Output ("[{0}] finished with runner exit {1}" -f
                $entry.CompetitionId, $entry.Process.ExitCode)
            Remove-RedundantPublicCopies -CompetitionId $entry.CompetitionId
            $active.Remove($slot)
        }
    }
}

foreach ($competitionId in $largeCases) {
    $running = Get-RunningCaseProcess -CompetitionId $competitionId
    if ($null -ne $running) {
        Write-Host "[$competitionId] adopted existing runner process $($running.Process.Id)"
        $running.Process.WaitForExit()
        Write-Output ("[{0}] finished with runner exit {1}" -f
            $competitionId, $running.Process.ExitCode)
        Remove-RedundantPublicCopies -CompetitionId $competitionId
        continue
    }
    if (Test-AlreadyAttempted -CompetitionId $competitionId) {
        Write-Output "[$competitionId] skipped: a run.json already exists"
        continue
    }
    $process = Start-Case -CompetitionId $competitionId -CoreOffset 0
    $process.WaitForExit()
    Write-Output ("[{0}] finished with runner exit {1}" -f $competitionId, $process.ExitCode)
    Remove-RedundantPublicCopies -CompetitionId $competitionId
}

Write-Output ("ALL_EXPANSION_10_DONE at {0:o}" -f [DateTime]::UtcNow)
