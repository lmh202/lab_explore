# Pi 0.84.1 + Qwen3.6-27B bad-case experiment

This directory implements the two-stage Windows-host diagnostic described in the experiment plan:
six fixed baseline cases, manual trace-backed bad-case review, selection of at most three cases,
and fresh paired reruns with one case-agnostic policy. It is intentionally a one-seed internal
experiment, not an official isolated MLE-bench leaderboard claim.

## Fixed scope

- Pi: `0.84.1`
- Provider/model: `lum-llm/qwen3.6-27b`
- Seed: `42`
- Per-case Pi wall time: 6 hours
- Per-case CPU cap: 4 logical processors at below-normal priority
- Execution: sequential Windows-host processes
- Smoke: `spaceship-titanic`, at most 10 minutes
- Candidates: the exact six IDs in `candidate_ids.txt` (about 2.114 GB raw in total)

The runner starts Pi and its descendants without visible console windows, caps the process tree to
four logical processors, and disables extension discovery, skills, prompt templates, context files,
sessions, and project trust. This removes accidental prompt additions, but Windows-host execution is not a security
sandbox. The prompt forbids access outside the copied workspace and the trace is audited after the
run. Keep this limitation attached to every result.

Gemma expansion reruns use one explicitly named, repository-owned runtime guard while extension
discovery remains disabled. The guard truncates oversized tool observations before they enter model
context, suppresses live progress bars, triggers compaction at 70k tokens, rejects a fourth identical
failed call, and queues bounded recovery turns for malformed textual tool calls or transient provider
errors. `run_case_gemma_parallel.ps1` additionally ensures `python3.exe` resolves to the experiment
environment and can restart Pi in the same isolated workspace up to three times within the original
wall-clock budget. Every attempt and final trace-health classification is recorded in `run.json`.

After the current expansion batch has stopped, rerun only the four infrastructure failures serially:

```powershell
.\experiments\pi_qwen\rerun_gemma_invalid_4.ps1 -TimeLimitHours 6 -Seed 42
```

## 1. Prepare the host

Run PowerShell from the repository root. The setup script only pulls leaderboard LFS objects for
the smoke task and fixed candidates; it never prepares any other competition.

```powershell
.\experiments\pi_qwen\setup_experiment.ps1 -PullLfs -InstallDependencies
```

The setup intentionally uses two Python environments. `.venv` retains MLE-bench's pinned
`kaggle<1.7` dependency for the unchanged official preparation/grading code, while
`.venv-kaggle` contains the current Kaggle CLI that supports the new `KGAT_...` token format.
The main environment also pins Pandas 2.2.3 because MLE-bench 1.0 preparers and graders use
`DataFrame.applymap`, which was removed in Pandas 3.

Before data preparation:

1. Put a current Kaggle token at `$HOME\.kaggle\access_token` (or a legacy credential at
   `$HOME\.kaggle\kaggle.json`). Never put either file in this repository.
2. In the Kaggle web UI, accept the rules for the six candidates and `spaceship-titanic`.
3. Prepare only this experiment's seven competitions:

```powershell
.\experiments\pi_qwen\setup_experiment.ps1 -PrepareData -RulesAccepted
```

The command can finish its requested setup work and still return exit code 2 until every readiness
check passes. Downloads are performed by `.venv-kaggle`; archives are then extracted, transformed,
and checksum-verified through MLE-bench's official competition preparation functions in `.venv`.
Running the setup script with no switches is a read-only readiness check.

Set the LUM token only in the PowerShell process that launches Pi:

```powershell
$env:ANTHROPIC_AUTH_TOKEN = "<token>"
.\experiments\pi_qwen\setup_experiment.ps1
```

The scripts never serialize the token. Pi must already have `lum-llm/qwen3.6-27b` in
`$HOME\.pi\agent\models.json` with `apiKey` set to the literal `$ANTHROPIC_AUTH_TOKEN`, and
`settings.json` must point `shellPath` at an existing Git Bash executable.

## 2. Smoke and six baselines

First exercise workspace construction, Pi tools, final submission, timeout handling, trace audit,
and the official grader:

```powershell
.\experiments\pi_qwen\run_suite.ps1 -Smoke
```

Then launch the six baselines sequentially. No ML workflow advice is included in the baseline
prompt.

```powershell
.\experiments\pi_qwen\run_suite.ps1 -Variant baseline -TimeLimitHours 6 -Seed 42
```

A single case can be run with the required unified entry point:

```powershell
.\experiments\pi_qwen\run_case.ps1 `
  -CompetitionId tabular-playground-series-may-2022 `
  -Variant baseline `
  -TimeLimitHours 6 `
  -Seed 42 `
  -MaxCpuThreads 4
```

Each run gets a fresh directory under `runs\pi-qwen\<competition>\<variant>\<timestamp>`. The
agent sees only a copy of `prepared/public`, the named public sample submission, the generated
`task.md`, and empty code/log/submission directories. For two official preparers the public sample
CSV happens to live beside private files; the host copies that exact file by name and no other file
from that directory.

`run.json` records the competition and variant, Pi/model versions, seed, wall limit, status, score,
all medal thresholds, metric direction, artifact paths, public schema validation, and integrity
audit. A timed-out run is still available for review if it left a valid submission.

## 3. Review and select bad cases

Generate review templates for the latest baselines:

```powershell
& .\.venv\Scripts\python.exe .\experiments\pi_qwen\experiment.py review-templates `
  --runs-dir .\runs\pi-qwen `
  --variant baseline
```

Open each generated `review.json` together with `host-logs\pi-events.jsonl`, the code, experiment
log, stderr, and `run.json`. A selectable baseline must set:

- `high_level_direction_correct: true`
- `understood_target_metric_task: true`
- `non_trivial_model_trained: true`
- `environment_or_resource_failure: false`
- at least two distinct `fixable_issues`, each with a category from `candidates.json` and concrete
  trace/code evidence

The automated gates additionally require a valid submission, a clean integrity audit, and a score
below bronze. Do not mark an environment-only failure as actionable.

Select up to three cases, preferring one per modality:

```powershell
& .\.venv\Scripts\python.exe .\experiments\pi_qwen\experiment.py select `
  --runs-dir .\runs\pi-qwen `
  --output .\runs\pi-qwen\selection.json
```

The selector writes `policy_addendum.md`. It includes an extra generic clause only when the same
issue category occurs in at least two selected baselines. Exit code 2 means fewer than three valid
bad cases were available; the files are still written and no invalid case is forced into the set.

## 4. Fresh policy reruns and report

The policy suite reads only `selection.json`, starts each selected case from a new workspace, and
does not expose baseline code, traces, or private scores to Pi:

```powershell
.\experiments\pi_qwen\run_suite.ps1 -Variant policy_v1 -TimeLimitHours 6 -Seed 42
```

Create and complete policy review templates. A clean policy review may have no remaining issues,
but it must set `serious_new_failure: false` and the four baseline-direction fields above. Retained
issues still require evidence.

```powershell
& .\.venv\Scripts\python.exe .\experiments\pi_qwen\experiment.py review-templates `
  --runs-dir .\runs\pi-qwen `
  --variant policy_v1
```

Generate the paired report:

```powershell
& .\.venv\Scripts\python.exe .\experiments\pi_qwen\experiment.py report `
  --runs-dir .\runs\pi-qwen `
  --selection .\runs\pi-qwen\selection.json `
  --output .\runs\pi-qwen\report.md
```

The report marks policy v1 promising only when exactly three selected policy runs are valid and
integrity-clean, their reviews show a fixed baseline issue without a serious replacement failure,
and at least two close 20% of their baseline-to-bronze gap or cross bronze. It also lists all six
baselines, paired scores, per-case issue categories, and only evidence-supported policy-v2 ideas.

## Tests

The unit tests use synthetic public/private layouts and do not require Kaggle data or a model token:

```powershell
& .\.venv\Scripts\python.exe -m unittest tests.unit.test_pi_qwen_experiment -v
```

They cover prompt separation and `@task.md`, fixed model invocation, exact public/sample copying,
reparse-point rejection, submission schema/order, metric direction, trace integrity rules,
modality-aware selection, policy reporting, and whole-process-tree timeout wiring.
