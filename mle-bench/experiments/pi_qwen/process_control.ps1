function Wait-ExperimentProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [string]$KillLogPath
    )

    $timedOut = $false
    try {
        Wait-Process -Id $Process.Id -Timeout $TimeoutSeconds -ErrorAction Stop
    } catch {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $timedOut = $true
            $killStderrPath = "$KillLogPath.stderr.log"
            $killProcess = Start-Process `
                -FilePath "$env:SystemRoot\System32\taskkill.exe" `
                -ArgumentList @("/PID", [string]$Process.Id, "/T", "/F") `
                -RedirectStandardOutput $KillLogPath `
                -RedirectStandardError $killStderrPath `
                -NoNewWindow `
                -Wait `
                -PassThru
            if ($killProcess.ExitCode -ne 0) {
                $Process.Refresh()
                if (-not $Process.HasExited) {
                    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                }
            }
            Wait-Process -Id $Process.Id -Timeout 30 -ErrorAction SilentlyContinue
        }
    }

    $Process.Refresh()
    $exitCode = if ($Process.HasExited) { $Process.ExitCode } else { $null }
    return [pscustomobject]@{
        timed_out = $timedOut
        exit_code = $exitCode
    }
}

function Set-ExperimentResourceLimits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 63)]
        [int]$MaxCpuThreads,

        [ValidateRange(0, 62)]
        [int]$CpuAffinityOffset = 0
    )

    $processorCount = [Environment]::ProcessorCount
    if ($CpuAffinityOffset -ge $processorCount) {
        throw "CPU affinity offset $CpuAffinityOffset exceeds the available $processorCount logical processors."
    }
    $effectiveThreads = [Math]::Min($MaxCpuThreads, $processorCount - $CpuAffinityOffset)
    $threadValue = [string]$effectiveThreads
    foreach ($name in @(
        "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
        "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "BLIS_NUM_THREADS",
        "LOKY_MAX_CPU_COUNT"
    )) {
        [Environment]::SetEnvironmentVariable($name, $threadValue, "Process")
    }
    [Environment]::SetEnvironmentVariable("TOKENIZERS_PARALLELISM", "false", "Process")

    $mask = (([int64]1 -shl $effectiveThreads) - 1) -shl $CpuAffinityOffset
    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    $currentProcess.ProcessorAffinity = [IntPtr]$mask
    $currentProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal

    return [pscustomobject]@{
        max_cpu_threads = $effectiveThreads
        cpu_affinity_offset = $CpuAffinityOffset
        affinity_mask = ("0x{0:X}" -f $mask)
        priority = [string]$currentProcess.PriorityClass
        child_windows_hidden = $true
    }
}
