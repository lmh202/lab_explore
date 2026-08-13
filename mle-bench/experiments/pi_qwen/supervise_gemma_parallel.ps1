[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SuiteId,

    [ValidateRange(0.01, 24.0)]
    [double]$TimeLimitHours = 6,

    [int]$Seed = 42,

    [ValidateRange(1, 16)]
    [int]$MaxCpuThreads = 4,

    [ValidateRange(0, 62)]
    [int]$FirstCpuOffset = 4,

    [ValidateRange(60, 1800)]
    [int]$StatusIntervalSeconds = 300,

    [string]$RepoRoot,
    [string]$RunsDir,
    [string]$PiExe,
    [string]$Provider = "lum-llm",
    [string]$Model = "nvidia/Gemma-4-26B-A4B-NVFP4"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if (-not $RunsDir) {
    $RunsDir = Join-Path $RepoRoot "runs\pi-gemma-original"
}
if (-not $PiExe) {
    $PiExe = (Resolve-Path (Join-Path $RepoRoot "..\pi_backup_0.84.1_original\pi.exe")).Path
}
if (-not (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -or
    [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
    throw "ANTHROPIC_AUTH_TOKEN is required by the supervisor process."
}

$manifestPath = Join-Path $PSScriptRoot "candidates.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$competitionIds = @($manifest.candidates.competition_id | ForEach-Object { [string]$_ })
$logicalProcessors = [Environment]::ProcessorCount
$requiredExclusiveEnd = $FirstCpuOffset + ($competitionIds.Count * $MaxCpuThreads)
if ($requiredExclusiveEnd -gt $logicalProcessors) {
    throw "The requested affinity layout needs cores 0-$($requiredExclusiveEnd - 1), but only $logicalProcessors logical processors are available."
}

$suiteRoot = Join-Path $RunsDir "supervisor\$SuiteId"
$workerLogRoot = Join-Path $suiteRoot "workers"
New-Item -ItemType Directory -Path $workerLogRoot -Force | Out-Null
$suitePath = Join-Path $suiteRoot "suite.json"
$historyPath = Join-Path $suiteRoot "status.jsonl"
$activePath = Join-Path $RunsDir "gemma-active.json"
$runCasePath = Join-Path $PSScriptRoot "run_case.ps1"
$powershellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$startedAt = [DateTime]::UtcNow

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-LatestCaseRun {
    param([string]$CompetitionId)
    $caseRoot = Join-Path $RunsDir "$CompetitionId\baseline"
    if (-not (Test-Path -LiteralPath $caseRoot -PathType Container)) {
        return $null
    }
    return Get-ChildItem -LiteralPath $caseRoot -Filter "run.json" -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $startedAt.AddMinutes(-1) } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

$workers = @()
for ($index = 0; $index -lt $competitionIds.Count; $index++) {
    $competitionId = $competitionIds[$index]
    $cpuOffset = $FirstCpuOffset + ($index * $MaxCpuThreads)
    $stdoutPath = Join-Path $workerLogRoot "$competitionId.stdout.log"
    $stderrPath = Join-Path $workerLogRoot "$competitionId.stderr.log"
    $workerArgs = @(
        $powershellExe,
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $runCasePath,
        "-CompetitionId", $competitionId,
        "-Variant", "baseline",
        "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
        "-Seed", [string]$Seed,
        "-MaxCpuThreads", [string]$MaxCpuThreads,
        "-CpuAffinityOffset", [string]$cpuOffset,
        "-RepoRoot", $RepoRoot,
        "-RunsDir", $RunsDir,
        "-PiExe", $PiExe,
        "-Provider", $Provider,
        "-Model", $Model
    )
    foreach ($value in $workerArgs) {
        if ([string]$value -match '[\r\n"%]') {
            throw "Worker executable and arguments may not contain quotes, percent signs, or newlines."
        }
    }
    $command = (@($workerArgs | ForEach-Object { '"' + [string]$_ + '"' }) -join " ")
    $command += ' 1>"' + $stdoutPath + '" 2>"' + $stderrPath + '"'
    $shellCommand = '"' + $command + '"'
    $process = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList @("/D", "/S", "/C", $shellCommand) `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden `
        -PassThru
    $workers += [pscustomobject]@{
        competition_id = $competitionId
        cpu_affinity_offset = $cpuOffset
        process = $process
        stdout = $stdoutPath
        stderr = $stderrPath
    }
}

# The six workers already inherited the credential; the long-lived supervisor does not need it.
Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue

function New-SuiteSnapshot {
    $caseRecords = @()
    foreach ($worker in $workers) {
        $worker.process.Refresh()
        $running = -not $worker.process.HasExited
        $processExitCode = if ($running) { $null } else { $worker.process.ExitCode }
        $latestRun = Get-LatestCaseRun -CompetitionId $worker.competition_id
        $runStatus = if ($running) { "starting" } else { "runner_failed" }
        $score = $null
        $validSubmission = $null
        $integrityClean = $null
        $runPath = $null
        if ($latestRun) {
            $runPath = $latestRun.FullName
            try {
                $run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json
                $runStatus = [string]$run.status
                if ($run.PSObject.Properties.Name -contains "grade") {
                    $score = $run.grade.score
                    $validSubmission = $run.grade.valid_submission
                }
                if ($run.PSObject.Properties.Name -contains "integrity") {
                    $integrityClean = $run.integrity.clean
                }
            }
            catch {
                $runStatus = if ($running) { "run_json_updating" } else { "run_json_invalid" }
            }
        }
        $caseRecords += [ordered]@{
            competition_id = $worker.competition_id
            worker_pid = $worker.process.Id
            process_running = $running
            process_exit_code = $processExitCode
            cpu_affinity_offset = $worker.cpu_affinity_offset
            run_status = $runStatus
            score = $score
            valid_submission = $validSubmission
            integrity_clean = $integrityClean
            run_json = $runPath
            stdout = $worker.stdout
            stderr = $worker.stderr
        }
    }

    $runningCount = @($caseRecords | Where-Object { $_.process_running }).Count
    $finishedCount = $caseRecords.Count - $runningCount
    $failedCount = @($caseRecords | Where-Object {
        -not $_.process_running -and
        ($_.process_exit_code -ne 0 -or $_.run_status -notin @("completed", "timed_out"))
    }).Count
    $suiteStatus = if ($runningCount -gt 0) {
        "running"
    }
    elseif ($failedCount -gt 0) {
        "completed_with_failures"
    }
    else {
        "completed"
    }
    $os = Get-CimInstance Win32_OperatingSystem
    return [ordered]@{
        schema_version = 1
        suite_id = $SuiteId
        status = $suiteStatus
        provider = $Provider
        model = $Model
        pi_executable = $PiExe
        started_at_utc = $startedAt.ToString("o")
        checked_at_utc = [DateTime]::UtcNow.ToString("o")
        status_interval_seconds = $StatusIntervalSeconds
        time_limit_hours_per_case = $TimeLimitHours
        seed = $Seed
        parallel = $true
        competition_count = $caseRecords.Count
        running_count = $runningCount
        finished_count = $finishedCount
        failed_count = $failedCount
        free_ram_gb = [Math]::Round($os.FreePhysicalMemory / 1MB, 2)
        cases = $caseRecords
    }
}

$nextSnapshotAt = [DateTime]::MinValue
do {
    $now = [DateTime]::UtcNow
    if ($now -ge $nextSnapshotAt) {
        $snapshot = New-SuiteSnapshot
        Write-JsonFile -Value $snapshot -Path $suitePath
        [IO.File]::AppendAllText(
            $historyPath,
            (($snapshot | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
        Write-JsonFile -Value ([ordered]@{
            suite_id = $SuiteId
            supervisor_pid = $PID
            status = $snapshot.status
            checked_at_utc = $snapshot.checked_at_utc
            suite_json = $suitePath
        }) -Path $activePath
        $nextSnapshotAt = $now.AddSeconds($StatusIntervalSeconds)
    }
    if ($snapshot.running_count -eq 0) {
        break
    }
    Start-Sleep -Seconds 30
} while ($true)

# Always persist a final snapshot immediately after the last worker exits.
$finalSnapshot = New-SuiteSnapshot
Write-JsonFile -Value $finalSnapshot -Path $suitePath
[IO.File]::AppendAllText(
    $historyPath,
    (($finalSnapshot | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
Write-JsonFile -Value ([ordered]@{
    suite_id = $SuiteId
    supervisor_pid = $PID
    status = $finalSnapshot.status
    checked_at_utc = $finalSnapshot.checked_at_utc
    suite_json = $suitePath
}) -Path $activePath
$finalSnapshot | ConvertTo-Json -Depth 12

if ($finalSnapshot.failed_count -gt 0) {
    exit 2
}
