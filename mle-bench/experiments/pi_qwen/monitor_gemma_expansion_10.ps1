[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$IntervalMinutes = 5,
    [ValidateRange(5, 180)]
    [int]$StallMinutes = 20,
    [ValidateRange(0, 3)]
    [int]$MaxRestarts = 1,
    [ValidateRange(1, 8)]
    [int]$MaxConcurrent = 2,
    [double]$MinFreeRamGiB = 10,
    [double]$MinFreeDiskGiB = 24
)

# Low-frequency watchdog for the ten Gemma expansion cases. A run counts as
# progressing when its trace grows or any descendant consumes CPU. A run is
# stopped only after StallMinutes without either signal, or after an explicit
# high-frequency repeated command failure. Normal long-running training is not
# interrupted. Watchdog-stopped runs may be retried once after the other batch
# controller has finished.

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RunsDir = Join-Path $RepoRoot "runs\pi-qwen-gemma"
$Runner = Join-Path $PSScriptRoot "run_case_gemma_parallel.ps1"
$CasesPath = Join-Path $PSScriptRoot "candidates_expansion_14.txt"
$LogDir = Join-Path $PSScriptRoot "prep_logs"
$StatePath = Join-Path $LogDir "gemma_expansion_10.watchdog.state.json"
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Cases = @(Get-Content -LiteralPath $CasesPath | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})

if ($Cases.Count -ne 10) {
    throw "Expected exactly ten expansion cases in $CasesPath."
}
if (-not (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -or
    [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
    throw "ANTHROPIC_AUTH_TOKEN is not set in the watchdog process."
}
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$progressState = @{}
$restartCounts = @{}
$restartPending = @{}
$prunedRuns = @{}

function Write-WatchdogLog {
    param([string]$Message)
    Write-Output ("[{0:o}] {1}" -f [DateTime]::UtcNow, $Message)
}

function Get-AllProcesses {
    $result = @{}
    foreach ($process in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) {
        $result[[int]$process.ProcessId] = $process
    }
    return $result
}

function Get-RunnerEntries {
    param([hashtable]$Processes)
    $entries = @()
    foreach ($process in $Processes.Values) {
        if ($process.Name -ne "powershell.exe" -or
            $process.CommandLine -notlike "*run_case_gemma_parallel.ps1*" -or
            $process.CommandLine -notmatch "-CompetitionId\s+([^\s]+)") {
            continue
        }
        $competitionId = $Matches[1].Trim('"')
        if ($Cases -notcontains $competitionId) {
            continue
        }
        $offset = 0
        if ($process.CommandLine -match "-CoreOffset\s+(\d+)") {
            $offset = [int]$Matches[1]
        }
        $entries += [pscustomobject]@{
            CompetitionId = $competitionId
            ProcessId = [int]$process.ProcessId
            ParentProcessId = [int]$process.ParentProcessId
            CreationDate = $process.CreationDate
            CoreOffset = $offset
        }
    }
    return @($entries)
}

function Get-DescendantIds {
    param(
        [int]$RootProcessId,
        [hashtable]$Processes
    )
    $childrenByParent = @{}
    foreach ($process in $Processes.Values) {
        $parentId = [int]$process.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = @()
        }
        $childrenByParent[$parentId] += [int]$process.ProcessId
    }
    $result = @()
    $queue = [Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parentId)) {
            continue
        }
        foreach ($childId in $childrenByParent[$parentId]) {
            $result += $childId
            $queue.Enqueue($childId)
        }
    }
    return @($result)
}

function Get-ProcessCpuSeconds {
    param([int[]]$ProcessIds)
    $total = 0.0
    foreach ($processId in $ProcessIds) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -ne $process -and $null -ne $process.CPU) {
            $total += [double]$process.CPU
        }
    }
    return $total
}

function Get-LatestRunDirectory {
    param([string]$CompetitionId)
    $base = Join-Path $RunsDir "$CompetitionId\baseline"
    if (-not (Test-Path -LiteralPath $base -PathType Container)) {
        return $null
    }
    return Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

function Get-RunStatus {
    param([string]$CompetitionId)
    $latest = Get-LatestRunDirectory -CompetitionId $CompetitionId
    if ($null -eq $latest) {
        return "not_started"
    }
    $runJson = Join-Path $latest.FullName "run.json"
    if (-not (Test-Path -LiteralPath $runJson -PathType Leaf)) {
        return "preparing"
    }
    try {
        return [string]((Get-Content -LiteralPath $runJson -Raw | ConvertFrom-Json).status)
    }
    catch {
        return "invalid_run_json"
    }
}

function Get-TraceSnapshot {
    param([string]$CompetitionId)
    $latest = Get-LatestRunDirectory -CompetitionId $CompetitionId
    if ($null -eq $latest) {
        return [pscustomobject]@{ Path = $null; Size = 0L }
    }
    $trace = Join-Path $latest.FullName "host-logs\pi-events.jsonl"
    if (-not (Test-Path -LiteralPath $trace -PathType Leaf)) {
        return [pscustomobject]@{ Path = $null; Size = 0L }
    }
    $item = Get-Item -LiteralPath $trace
    return [pscustomobject]@{ Path = $trace; Size = [int64]$item.Length }
}

function Get-NewTraceText {
    param(
        [string]$Path,
        [int64]$PreviousSize,
        [int64]$CurrentSize
    )
    if (-not $Path -or $CurrentSize -le $PreviousSize) {
        return ""
    }
    $maxRead = 2MB
    $start = [Math]::Max($PreviousSize, $CurrentSize - $maxRead)
    $count = [int]($CurrentSize - $start)
    $buffer = New-Object byte[] $count
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $read = $stream.Read($buffer, 0, $count)
        return [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    finally {
        $stream.Dispose()
    }
}

function Stop-ProcessTree {
    param(
        [int]$RootProcessId,
        [hashtable]$Processes
    )
    $ids = @(Get-DescendantIds -RootProcessId $RootProcessId -Processes $Processes)
    [array]::Reverse($ids)
    foreach ($processId in @($ids + $RootProcessId)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-StuckRunner {
    param(
        [pscustomobject]$RunnerEntry,
        [hashtable]$Processes,
        [string]$Reason
    )
    $descendantIds = @(Get-DescendantIds -RootProcessId $RunnerEntry.ProcessId -Processes $Processes)
    $piProcess = $null
    foreach ($processId in $descendantIds) {
        if ($Processes.ContainsKey($processId) -and $Processes[$processId].Name -eq "pi.exe") {
            $piProcess = $Processes[$processId]
            break
        }
    }

    if ($null -ne $piProcess) {
        $agentRootId = [int]$piProcess.ProcessId
        $cursor = $piProcess
        while ([int]$cursor.ParentProcessId -ne $RunnerEntry.ProcessId -and
            $Processes.ContainsKey([int]$cursor.ParentProcessId)) {
            $agentRootId = [int]$cursor.ParentProcessId
            $cursor = $Processes[$agentRootId]
        }
        Write-WatchdogLog "$($RunnerEntry.CompetitionId): stopping stuck Pi subtree ($Reason)"
        Stop-ProcessTree -RootProcessId $agentRootId -Processes $Processes
    }
    else {
        Write-WatchdogLog "$($RunnerEntry.CompetitionId): stopping stuck preparation runner ($Reason)"
        Stop-ProcessTree -RootProcessId $RunnerEntry.ProcessId -Processes $Processes
    }
    $restartPending[$RunnerEntry.CompetitionId] = [DateTime]::UtcNow
}

function Test-ExternalBatchCoordinator {
    param([hashtable]$Processes)
    return @($Processes.Values | Where-Object {
        $_.Name -eq "bash.exe" -and $_.CommandLine -like "*MIN_FREE_RAM_GB=8*"
    }).Count -gt 0
}

function Get-FreeRamGiB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [double]$os.FreePhysicalMemory * 1KB / 1GB
}

function Get-FreeDiskGiB {
    return ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($RepoRoot))).AvailableFreeSpace / 1GB
}

function Start-WatchdogCase {
    param(
        [string]$CompetitionId,
        [int]$CoreOffset
    )
    Write-WatchdogLog "${CompetitionId}: launching watchdog retry on CPU offset $CoreOffset"
    Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
            "-CompetitionId", $CompetitionId,
            "-Variant", "baseline",
            "-TimeLimitHours", "6",
            "-Seed", "42",
            "-MaxCpuThreads", "4",
            "-CoreOffset", [string]$CoreOffset,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir
        ) `
        -WindowStyle Hidden |
        Out-Null
}

function Remove-RedundantPublicCopies {
    param([string]$CompetitionId)
    $latest = Get-LatestRunDirectory -CompetitionId $CompetitionId
    if ($null -eq $latest -or $prunedRuns.ContainsKey($latest.FullName)) {
        return
    }
    $status = Get-RunStatus -CompetitionId $CompetitionId
    if ($status -in @("running", "preparing", "not_started")) {
        return
    }
    $source = Join-Path $RepoRoot "data\$CompetitionId\prepared\public"
    $target = Join-Path $latest.FullName "workspace\data"
    if (-not (Test-Path -LiteralPath $source -PathType Container) -or
        -not (Test-Path -LiteralPath $target -PathType Container)) {
        $prunedRuns[$latest.FullName] = $true
        return
    }

    $before = Get-FreeDiskGiB
    foreach ($sourceFile in Get-ChildItem -LiteralPath $source -File -Recurse) {
        $relative = $sourceFile.FullName.Substring($source.Length).TrimStart([char]'\', [char]'/')
        if ($relative -in @("description.md", "sample_submission.csv")) {
            continue
        }
        $copy = Join-Path $target $relative
        if (Test-Path -LiteralPath $copy -PathType Leaf) {
            Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -LiteralPath $target -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object {
            if (@(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    $prunedRuns[$latest.FullName] = $true
    Write-WatchdogLog ("{0}: pruned finalized public-data copy; freed {1:N2} GiB" -f
        $CompetitionId, ((Get-FreeDiskGiB) - $before))
}

Write-WatchdogLog ("watchdog started: interval={0}m stall={1}m max_restarts={2}" -f
    $IntervalMinutes, $StallMinutes, $MaxRestarts)

while ($true) {
    try {
        $now = [DateTime]::UtcNow
        $processes = Get-AllProcesses
        $runners = @(Get-RunnerEntries -Processes $processes)

        # If two controllers launch the same case, retain the oldest runner.
        foreach ($group in $runners | Group-Object CompetitionId | Where-Object { $_.Count -gt 1 }) {
            $ordered = @($group.Group | Sort-Object CreationDate)
            foreach ($duplicate in $ordered[1..($ordered.Count - 1)]) {
                Write-WatchdogLog "$($duplicate.CompetitionId): removing duplicate runner $($duplicate.ProcessId)"
                Stop-ProcessTree -RootProcessId $duplicate.ProcessId -Processes $processes
            }
        }

        $processes = Get-AllProcesses
        $runners = @(Get-RunnerEntries -Processes $processes)
        foreach ($runnerEntry in $runners) {
            $case = $runnerEntry.CompetitionId
            $descendantIds = @(Get-DescendantIds -RootProcessId $runnerEntry.ProcessId -Processes $processes)
            $cpu = Get-ProcessCpuSeconds -ProcessIds @($descendantIds + $runnerEntry.ProcessId)
            $trace = Get-TraceSnapshot -CompetitionId $case
            if (-not $progressState.ContainsKey($case)) {
                $progressState[$case] = [pscustomobject]@{
                    RunnerProcessId = $runnerEntry.ProcessId
                    TracePath = $trace.Path
                    TraceSize = $trace.Size
                    CpuSeconds = $cpu
                    LastProgressUtc = $now
                }
                continue
            }

            $previous = $progressState[$case]
            if ([int]$previous.RunnerProcessId -ne $runnerEntry.ProcessId -or
                [string]$previous.TracePath -ne [string]$trace.Path) {
                $previous.RunnerProcessId = $runnerEntry.ProcessId
                $previous.TracePath = $trace.Path
                $previous.TraceSize = $trace.Size
                $previous.CpuSeconds = $cpu
                $previous.LastProgressUtc = $now
                continue
            }
            $traceGrew = $trace.Size -gt [int64]$previous.TraceSize
            $cpuAdvanced = ($cpu - [double]$previous.CpuSeconds) -ge 1.0
            $newText = Get-NewTraceText -Path $trace.Path `
                -PreviousSize ([int64]$previous.TraceSize) -CurrentSize $trace.Size
            $exit49Count = ([regex]::Matches($newText, "Command exited with code 49")).Count
            $toolStartCount = ([regex]::Matches($newText, '"type":"tool_execution_start"')).Count

            if ($traceGrew -or $cpuAdvanced) {
                $previous.LastProgressUtc = $now
            }
            $previous.TracePath = $trace.Path
            $previous.TraceSize = $trace.Size
            $previous.CpuSeconds = $cpu

            $stallAge = $now - [DateTime]$previous.LastProgressUtc
            if ($exit49Count -ge 20 -and $toolStartCount -ge 20) {
                Stop-StuckRunner -RunnerEntry $runnerEntry -Processes $processes `
                    -Reason "repeated command exit 49 ($exit49Count failures in latest trace window)"
            }
            elseif ($stallAge.TotalMinutes -ge $StallMinutes) {
                Stop-StuckRunner -RunnerEntry $runnerEntry -Processes $processes `
                    -Reason ("no trace or CPU progress for {0:N0} minutes" -f $stallAge.TotalMinutes)
            }
        }

        foreach ($case in $Cases) {
            Remove-RedundantPublicCopies -CompetitionId $case
        }

        # A watchdog-killed run gets at most one retry. Avoid racing the older
        # Claude-managed batch coordinator and respect host resource floors.
        $processes = Get-AllProcesses
        $runners = @(Get-RunnerEntries -Processes $processes)
        $externalCoordinator = Test-ExternalBatchCoordinator -Processes $processes
        if (-not $externalCoordinator -and
            $runners.Count -lt $MaxConcurrent -and
            (Get-FreeRamGiB) -ge $MinFreeRamGiB -and
            (Get-FreeDiskGiB) -ge $MinFreeDiskGiB) {
            foreach ($case in @($restartPending.Keys)) {
                if (@($runners | Where-Object { $_.CompetitionId -eq $case }).Count -gt 0) {
                    continue
                }
                $count = if ($restartCounts.ContainsKey($case)) { [int]$restartCounts[$case] } else { 0 }
                if ($count -ge $MaxRestarts) {
                    $restartPending.Remove($case)
                    Write-WatchdogLog "${case}: retry limit reached; leaving finalized failure for analysis"
                    continue
                }
                $usedOffsets = @($runners.CoreOffset)
                $offset = @(0, 4, 8, 12, 16, 20, 24, 28 | Where-Object { $_ -notin $usedOffsets })[0]
                Start-WatchdogCase -CompetitionId $case -CoreOffset $offset
                $restartCounts[$case] = $count + 1
                $restartPending.Remove($case)
                break
            }
        }

        $summary = @($Cases | ForEach-Object { "$_=$(Get-RunStatus -CompetitionId $_)" }) -join "; "
        Write-WatchdogLog ("snapshot runners={0} ram_free={1:N1}GiB disk_free={2:N1}GiB | {3}" -f
            $runners.Count, (Get-FreeRamGiB), (Get-FreeDiskGiB), $summary)

        $allFinal = $true
        foreach ($case in $Cases) {
            if ((Get-RunStatus -CompetitionId $case) -in @("not_started", "preparing", "running")) {
                $allFinal = $false
                break
            }
        }
        if ($allFinal -and $runners.Count -eq 0 -and $restartPending.Count -eq 0) {
            Write-WatchdogLog "all ten cases reached a final state; watchdog exiting"
            break
        }

        [ordered]@{
            updated_at_utc = $now.ToString("o")
            interval_minutes = $IntervalMinutes
            stall_minutes = $StallMinutes
            active_cases = @($runners.CompetitionId)
            restart_counts = $restartCounts
            restart_pending = @($restartPending.Keys)
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
    catch {
        Write-WatchdogLog "poll error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
