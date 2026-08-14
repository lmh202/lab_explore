# pi Agent + MLE-bench (Gemma) Reproduction Protocol

Reproducible setup notes for standing up the full experiment stack — the [pi coding agent
CLI](https://github.com/earendil-works/pi) talking to a self-hosted model fleet through a personal
gateway (`lum.id`), plus [MLE-bench](https://github.com/openai/mle-bench) and the 19-competition
harness under `mle-bench/experiments/pi_qwen/` — on a **fresh machine/server**, in one pass.

**Scope decision, read first:** use pi's **official prebuilt binary** (Section 1). Earlier in this
project a from-source patched build of pi existed (`pi_patched/`, built from a checkout at
`pi-mono-src/`) to work around a compaction bug. That investigation is **closed and not part of
this protocol** — the actual experiment runs use the official binary plus a repository-owned runtime
guard loaded explicitly by the Gemma runner. The guard addresses oversized tool observations,
malformed textual tool calls, and transient provider failures without patching pi itself. Do not
rebuild pi from source; do not carry over `pi_patched/`, `pi_backup_0.84.1_original/`, or
`pi-mono-src/` to a new machine — none of it is referenced by any run script.

Target platform: Windows 10/11 Server, PowerShell 5.1, Git for Windows installed somewhere (any
path), Python 3.11+ available as `py.exe`.

---

## Part A — pi CLI

### A1. Install pi

pi ships precompiled standalone binaries on GitHub Releases — no Node/npm build needed.

```powershell
$release = Invoke-RestMethod "https://api.github.com/repos/earendil-works/pi/releases/latest"
$zipAsset = $release.assets | Where-Object { $_.name -eq "pi-windows-x64.zip" }
$sumAsset = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" }

$dest = "D:\Downloads\Content\NUS\lab"   # repo root's parent -- adjust to your layout
Invoke-WebRequest $zipAsset.browser_download_url -OutFile "$dest\pi-windows-x64.zip"
Invoke-WebRequest $sumAsset.browser_download_url -OutFile "$dest\SHA256SUMS"

$expected = (Select-String -Path "$dest\SHA256SUMS" -Pattern "pi-windows-x64.zip").Line.Split(' ')[0]
$actual = (Get-FileHash "$dest\pi-windows-x64.zip" -Algorithm SHA256).Hash
if ($actual.ToLower() -ne $expected.ToLower()) { throw "Checksum mismatch!" }

Expand-Archive "$dest\pi-windows-x64.zip" -DestinationPath "$dest\pi" -Force
Remove-Item "$dest\pi-windows-x64.zip", "$dest\SHA256SUMS"
```

This produces `<dest>\pi\pi.exe` — every run script in this repo resolves pi as
`(parent of repo root)\pi\pi.exe` by default, so keep it at this exact location relative to
wherever you clone the repo. Verify:

```powershell
D:\Downloads\Content\NUS\lab\pi\pi.exe --version
# expect: 0.84.1
```

### A2. Set the gateway auth token

Both providers below authenticate against the `lum.id` gateway using one token. **Never commit
this token or paste it into a chat/log** — set it as an environment variable only.

```powershell
$env:ANTHROPIC_AUTH_TOKEN = "<your lum.id token>"                      # session-scoped
[Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "<your lum.id token>", "User")  # persistent, new terminals only
```

`ANTHROPIC_BASE_URL` is **not** needed by pi — base URLs are hardcoded in `models.json` below.

### A3. Configure providers and models

Edit `~/.pi/agent/models.json` (create if missing) — this is the exact, currently-verified content,
including the Gemma model used for the actual experiment runs:

```json
{
  "providers": {
    "lum": {
      "name": "lum.id gateway",
      "baseUrl": "https://lum.id/claude",
      "api": "anthropic-messages",
      "apiKey": "$ANTHROPIC_AUTH_TOKEN",
      "models": [
        {
          "id": "claude-sonnet-5",
          "name": "Claude Sonnet 5 (via lum.id)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 1000000,
          "maxTokens": 128000,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "compat": { "forceAdaptiveThinking": true }
        }
      ]
    },
    "lum-llm": {
      "name": "lum.id LLM gateway (llama.cpp/vLLM)",
      "baseUrl": "https://lum.id/llm/v1",
      "api": "openai-completions",
      "apiKey": "$ANTHROPIC_AUTH_TOKEN",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "qwen3.6-27b",
          "name": "Qwen3.6 27B (lum.id llama.cpp)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 32768,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "compat": { "thinkingFormat": "qwen-chat-template" }
        },
        {
          "id": "qwen3.6-35b-a3b",
          "name": "Qwen3.6 35B A3B (lum.id llama.cpp)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 32768,
          "maxTokens": 16384,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "compat": { "thinkingFormat": "qwen-chat-template" }
        },
        {
          "id": "nvidia/Gemma-4-26B-A4B-NVFP4",
          "name": "NVIDIA Gemma 4 26B A4B NVFP4 (via lum.id)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 262144,
          "maxTokens": 32768,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

Notes on non-obvious fields:

- **`contextWindow`** values are not guesses — confirmed per-model via `GET <base>/v1/models`
  (field `meta.n_ctx` on the serving instance, not the model's trained-up-to context). Re-check
  this on a new deployment before reusing these numbers; the actual served context can be smaller
  than what the model was trained on.
- **`compat.forceAdaptiveThinking: true`** (Claude) — `GET .../v1/models` on `/claude` reports
  `thinking.types.adaptive.supported: true`, `enabled.supported: false`, i.e. it needs Anthropic's
  newer adaptive-thinking request shape. Without this pi sends the wrong thinking payload.
- **`compat.thinkingFormat: "qwen-chat-template"`** (Qwen only, not Gemma) — these llama.cpp-served
  Qwen models return a separate `reasoning_content` field; without this the thinking content can
  leak into the visible response, or (observed during the experiment sweep) very rarely a literal
  `<tool_call>...</tool_call>` XML block leaks into `thinking` instead of firing a real tool call.
  This is a known, unresolved quirk of Qwen's template on this serving stack, not something to
  "fix" by further compat flags — just be aware a small fraction of Qwen runs can hit it.

Verify (needs the token from A2 in the *same* shell):

```powershell
D:\Downloads\Content\NUS\lab\pi\pi.exe --list-models
```

### A4. `~/.pi/agent/settings.json`

```json
{
  "lastChangelogVersion": "0.84.1",
  "defaultProvider": "lum-llm",
  "defaultModel": "qwen3.6-35b-a3b",
  "shellPath": "D:\\Git\\bin\\bash.exe",
  "retry": {
    "maxRetries": 10
  }
}
```

- `shellPath` **must** point at a real `bash.exe` on this machine (see A5) — this is the single
  most common silent-hang cause.
- `retry.maxRetries: 10` (raised from pi's default of 3) — cheap insurance against transient
  gateway/stream errors on long unattended runs; no observed downside.
- The experiment run scripts pass `--no-extensions --no-skills --no-prompt-templates
  --no-context-files --no-approve`, so nothing under `~/.pi/agent/extensions/` is discovered. The
  reliable Gemma runner also passes one explicit `--extension` path pointing to the checked-in
  `experiments/pi_qwen/extensions/gemma_runtime_guard.ts`; explicit paths still load when discovery
  is disabled.

### A5. Fix: Windows shell path (prevents a silent hang)

pi's `bash` tool looks for a shell in this order: `settings.json` → `C:\Program Files\Git\bin\bash.exe`
→ `bash.exe` on `PATH`. If Git for Windows is installed anywhere else, the second check silently
fails and **the agent hangs indefinitely on its first bash tool call** — no error, no crash.

```powershell
Get-Command bash.exe -All | Select-Object Source
```

Pin the result in `settings.json`'s `shellPath` (A4).

### A6. Install ripgrep (defensive, recommended)

pi's `grep` tool shells out to ripgrep rather than implementing search itself. If `rg` isn't a real
installed binary, tool calls that use it can fail or behave unpredictably.

```powershell
winget install --id BurntSushi.ripgrep.MSVC -e --accept-package-agreements --accept-source-agreements
```

Updates the persistent user `PATH` (registry) — **restart your terminal** for `rg` to resolve.

### A7. Verify pi end to end

```powershell
$env:ANTHROPIC_AUTH_TOKEN = "<your lum.id token>"
cd D:\Downloads\Content\NUS\lab

.\pi\pi.exe --print --no-session --provider lum-llm --model nvidia/Gemma-4-26B-A4B-NVFP4 "Reply with exactly: connect ok"
.\pi\pi.exe --print --no-session --provider lum-llm --model nvidia/Gemma-4-26B-A4B-NVFP4 "Use your bash tool to run: echo hello-from-bash-tool"
```

Both should return within seconds to low tens-of-seconds, not minutes. For any multi-step agentic
task, write the instruction to a file and pass it as `@filename` rather than inline — see
[Troubleshooting](#troubleshooting), a long inline argument with nested quotes can make pi.exe hang
before it ever makes a network request.

---

## Part B — MLE-bench + the experiment harness

### B1. Clone/copy the repo and install the Python environment

```powershell
cd D:\Downloads\Content\NUS\lab
py.exe -3.11 -m venv mle-bench\.venv
.\mle-bench\.venv\Scripts\python.exe -m pip install --upgrade pip
.\mle-bench\.venv\Scripts\python.exe -m pip install -e .\mle-bench
.\mle-bench\.venv\Scripts\python.exe -m pip install pandas==2.2.3
```

`pandas==2.2.3` is a hard requirement, not a nice-to-have: MLE-bench 1.0's official
preparer/grader code still calls `DataFrame.applymap`, which was removed in pandas 3. Installing
mlebench itself may pull a newer pandas; the explicit pin after must run last.

### B2. Patch mlebench itself (3 small fixes, required)

The vendored mlebench package has bugs that only surface on a Windows host whose system locale
isn't UTF-8 (this one is Chinese/GBK) and against the modern Kaggle API. All three were hit and
fixed live against this exact `.venv`; apply them before touching any real data:

**`mlebench/registry.py`**, in `Registry.get_competition()` — reading a competition's
`description.md` defaults to the OS locale encoding (GBK here) instead of UTF-8, and crashes with
`UnicodeDecodeError` on any description containing a non-ASCII character (smart quotes, non-breaking
spaces, etc. — most competitions have at least one):

```diff
         description_path = get_repo_dir() / config["description"]
-        description = description_path.read_text()
+        description = description_path.read_text(encoding="utf-8")
```

**`mlebench/data.py`**, in `download_and_prepare_dataset()` — same class of bug on the *write*
side, once the read above is fixed the description text correctly contains non-ASCII characters
that the default-encoding write can no longer represent:

```diff
-    with open(competition.public_dir / "description.md", "w") as f:
+    with open(competition.public_dir / "description.md", "w", encoding="utf-8") as f:
         f.write(competition.description)
```

```diff
-            with open(competition.checksums, "w") as file:
+            with open(competition.checksums, "w", encoding="utf-8") as file:
                 yaml.dump(actual_checksums, file, default_flow_style=False)
```

**`mlebench/utils.py`** — same fix applied to the two other shared text-file readers used on every
competition (`read_jsonl`, `load_yaml`), for consistency/robustness even though a crash wasn't
observed here specifically:

```diff
     result = []
-    with open(file_path, "r") as f:
+    with open(file_path, "r", encoding="utf-8") as f:
```
```diff
-    with open(fpath, "r") as file:
+    with open(fpath, "r", encoding="utf-8") as file:
         contents = yaml.safe_load(file)
```

**`mlebench/data.py`**, in `download_dataset()` — kaggle's Python package rewrote its internals in
v2 (see B3): the custom `ApiException` class at `kaggle.rest.ApiException` no longer exists, and
the "you must accept this competition's rules" signal moved from the exception's `str()` into the
HTTP response body:

```diff
 def is_api_exception(exception: Exception) -> bool:
-    # only import when necessary; otherwise kaggle asks for API key on import
-    from kaggle.rest import ApiException
+    # kaggle>=2 dropped its custom ApiException wrapper and lets the
+    # underlying `requests` call raise directly.
+    from requests.exceptions import HTTPError as ApiException

     return isinstance(exception, ApiException)
```
```diff
     api = authenticate_kaggle_api()
-    from kaggle.rest import ApiException
+    from requests.exceptions import HTTPError as ApiException

     try:
         api.competition_download_files(...)
     except ApiException as e:
-        if _need_to_accept_rules(str(e)):
+        response = getattr(e, "response", None)
+        detail = response.text if response is not None else str(e)
+        if _need_to_accept_rules(detail):
```

And in `_prompt_user_to_accept_rules()`, make the interactive prompt fail fast with the exact URL
instead of hanging when there's no real terminal attached (batch/automated runs):

```diff
 def _prompt_user_to_accept_rules(competition_id: str) -> None:
-    response = input("Would you like to open the competition page in your browser now? (y/n): ")
+    rules_url = f"https://www.kaggle.com/c/{competition_id}/rules"
+    try:
+        response = input("Would you like to open the competition page in your browser now? (y/n): ")
+    except EOFError:
+        raise RuntimeError(
+            f"You must accept the competition rules before downloading the dataset. "
+            f"Visit {rules_url}, log in, and click 'I Accept', then re-run prepare for `{competition_id}`."
+        )
```

None of this touches grading/scoring logic — only file I/O encoding and the download-error path.

### B3. Kaggle credentials

Put a **current** Kaggle API token at `$HOME\.kaggle\access_token` (the newer `KGAT_...`-prefixed
bearer token, generated from the Kaggle account's Settings page — *not* the legacy
`kaggle.json` username+key pair, though that also still works if it's what you have). Never commit
either file.

The `.venv` from B1 gets mlebench's declared `kaggle<1.7` dependency by default, which cannot
authenticate with a `KGAT_...` token at all (it only knows the legacy `kaggle.json` format). Fix by
upgrading in place — verified this does not affect prepare/grade correctness (checksumming and the
official per-competition `prepare.py` scripts never call into the `kaggle` package, only the
download step does):

```powershell
.\mle-bench\.venv\Scripts\python.exe -m pip install --upgrade kaggle==2.2.4
```

(This repo also has a `.venv-kaggle` left over from an earlier, more elaborate two-environment
design — download via a separate modern-kaggle venv, then hand the zip to `.venv` through a custom
`experiment.py prepare-archive` wrapper. That still works and is what prepared the original 6
competitions, but is no longer necessary: with B2 + this single-`.venv` upgrade, plain
`mlebench prepare -c <id>` works directly. Use whichever you prefer; this protocol documents the
simpler one.)

### B4. Accept competition rules

Kaggle requires accepting each competition's rules **in a logged-in browser** before its API will
allow downloads — this cannot be automated or done on someone else's behalf. If the server reuses
the same Kaggle account as before, the original 6 + smoke are already accepted; only the 13 new
ones below need it. Visit each and click "I Accept":

```
https://www.kaggle.com/c/spaceship-titanic/rules
https://www.kaggle.com/c/tabular-playground-series-may-2022/rules
https://www.kaggle.com/c/ventilator-pressure-prediction/rules
https://www.kaggle.com/c/chaii-hindi-and-tamil-question-answering/rules
https://www.kaggle.com/c/text-normalization-challenge-english-language/rules
https://www.kaggle.com/c/statoil-iceberg-classifier-challenge/rules
https://www.kaggle.com/c/tgs-salt-identification-challenge/rules
https://www.kaggle.com/c/lmsys-chatbot-arena/rules
https://www.kaggle.com/c/tensorflow2-question-answering/rules
https://www.kaggle.com/c/champs-scalar-coupling/rules
https://www.kaggle.com/c/uw-madison-gi-tract-image-segmentation/rules
https://www.kaggle.com/c/tweet-sentiment-extraction/rules
https://www.kaggle.com/c/google-quest-challenge/rules
https://www.kaggle.com/c/jigsaw-unintended-bias-in-toxicity-classification/rules
https://www.kaggle.com/c/AI4Code/rules
https://www.kaggle.com/c/learning-agency-lab-automated-essay-scoring-2/rules
https://www.kaggle.com/c/stanford-covid-vaccine/rules
```

`h-and-m-personalized-fashion-recommendations`, `hubmap-kidney-segmentation`,
`siim-covid19-detection`, and `freesound-audio-tagging-2019` were in earlier drafts of the expanded
candidate list and were all **dropped** for disk size — see B6. The final expanded set is 16
competitions (6 original + 10 new), not the originally-targeted 20; all four drops were media-heavy
(3 vision, 1 audio) and each was individually too large for this host's disk budget. If closer to
20 is wanted, the gap should be filled with a *small* (sub-1GB) competition, not another
image/audio pick, given the 4/4 track record above.

### B5. Prepare the datasets

The candidate manifest is `mle-bench\experiments\pi_qwen\candidates_gemma.json` — already updated
to the full 19-competition set (the original 6 + 13 new ones), with the dropped h-and-m entry kept
in `dropped_candidates` for the record. Prepare each with `--data-dir` pointed explicitly at the
repo's own `data\` folder — **do not omit `--data-dir`**, see B6 — and `--skip-verification`:

```powershell
cd D:\Downloads\Content\NUS\lab\mle-bench
.\.venv\Scripts\Activate.ps1
$DataDir = "D:\Downloads\Content\NUS\lab\mle-bench\data"

Get-Content .\experiments\pi_qwen\candidates_expansion_14.txt, .\experiments\pi_qwen\candidate_ids.txt |
  Where-Object { $_.Trim() } |
  ForEach-Object {
    mlebench prepare -c $_ --data-dir $DataDir --skip-verification
  }
```

(`candidate_ids.txt` is the original 6; `candidates_expansion_14.txt` is the 13 new ones —
`h-and-m-personalized-fashion-recommendations` has already been removed from that file, see B6.)

`--skip-verification` is deliberate, not a shortcut past a real problem: several competitions'
official `prepare.py` do a `train_test_split(..., random_state=<fixed>)`, and scikit-learn/numpy's
exact "random-but-seeded" shuffle algorithm changed between the numpy 1.x this repo's reference
`checksums.yaml` was generated under and the numpy 2.4.6 installed here — same seed, different
(but equally valid) split, so the *checksum* of the resulting file differs even though the split
itself is correct. Verified directly on `lmsys-chatbot-arena`: train/test/answers shapes, the exact
90/10 ratio, and test-vs-answers ID correspondence all check out — this is not data corruption.
`--skip-verification` only skips this checksum comparison (and the raw-zip-download checksum check
alongside it); extraction still runs and would fail loudly on genuine corruption (`BadZipFile`).

### B6. Disk space — read before running B5 unattended

**Four competitions are dropped from the candidate list for disk size, all media-heavy:**
`h-and-m-personalized-fashion-recommendations` (raw ~32GB, images copied into `prepared/public/`
roughly doubling footprint), `hubmap-kidney-segmentation` (high-res whole-slide images, ~85GB+
before exhausting disk), `siim-covid19-detection` (DICOM images, exhausted disk during the raw zip
download itself), and `freesound-audio-tagging-2019` (dropped preemptively without attempting —
~27GB of uncompressed audio by direct calculation from its published curated+noisy hour counts, and
by that point every media-heavy pick tried had needed close to 2x that). Do not re-add any of the
four without first confirming free disk headroom well above 100GB just for that one competition —
plain unzipped size is not a safe estimate, mlebench's prepare step commonly duplicates the raw
data into `prepared/`.

More generally: `mlebench prepare` has **no default `--data-dir`** — it silently falls back to
`%LOCALAPPDATA%\mle-bench\data` (the OS user-cache directory, likely on the system drive) if you
forget the flag, which is *not* where any run script looks for data and can quietly fill up a
small system drive. Always pass `--data-dir` explicitly (B5's command already does).

If preparing several large candidates in one unattended batch, guard each iteration with a
free-space check and skip rather than crash-cascade — this genuinely works (verified: it turned a
second potential h-and-m-style cascade into 8 clean one-line skips instead of 8 cryptic crashes):

```powershell
$minFreeGB = 15
$freeGB = [math]::Floor((Get-PSDrive D).Free / 1GB)
if ($freeGB -lt $minFreeGB) { Write-Output "SKIP $_ ($freeGB GB free)"; return }
```

Note this guard only checks free space *before* a competition starts — it does not stop a single
competition from consuming everything by itself mid-run (that's exactly what happened with hubmap
and siim-covid19-detection). Of the 16 final candidates, `AI4Code` is the one remaining
moderately-large pick (~8GB by community estimate, unverified against this host as of writing —
many small JSON files, high file count rather than high per-file size); prepare it on its own
first rather than unattended in a batch with others queued behind it.

**Shortcut for a new server**: if it's reachable from the machine that already has data prepared,
just copy `mle-bench\data\` over (rsync/robocopy) instead of re-downloading — it's a plain
`raw/` + `prepared/{public,private}` tree per competition, no machine-specific state inside it.

### B7. Run the experiment sweep

The reliability launcher is `mle-bench\experiments\pi_qwen\run_case_gemma_parallel.ps1` — it reads
`candidates_gemma.json`, uses the **original, unpatched** `pi.exe` from Part A by default, disables
extension discovery/skills/prompt-templates/context-files/session, explicitly loads only the
checked-in Gemma runtime guard, and writes to `runs\pi-qwen-gemma\`. Despite its historical name it
also supports a single case; `-CoreOffset 0` is the serial/default placement.

Single case:

```powershell
cd D:\Downloads\Content\NUS\lab\mle-bench
$env:ANTHROPIC_AUTH_TOKEN = "<token>"
.\experiments\pi_qwen\run_case_gemma_parallel.ps1 `
  -CompetitionId tabular-playground-series-may-2022 `
  -Variant baseline `
  -TimeLimitHours 6 `
  -Seed 42 `
  -MaxCpuThreads 4 `
  -CoreOffset 0 `
  -MaxPiAttempts 3
```

All candidates, sequentially (safe default — see the note on parallel runs below):

```powershell
foreach ($id in (Get-Content .\experiments\pi_qwen\candidate_ids.txt)) {
  .\experiments\pi_qwen\run_case_gemma_parallel.ps1 -CompetitionId $id -Variant baseline -TimeLimitHours 6 -Seed 42 -CoreOffset 0
}
```

(Swap in the 13 new IDs from B4/B5 the same way, or read them straight out of
`candidates_gemma.json`'s `candidates[].competition_id`.)

**On running competitions in parallel**: `process_control.ps1`'s `Set-ExperimentResourceLimits`
supports a `-CpuAffinityOffset` for non-overlapping CPU slices (see `run_case_gemma_parallel.ps1`
for the pattern), and this machine had 32 logical cores to split across. It genuinely works and
saves wall-clock time — but **check the sequential launcher isn't already queued to reach the same
competition** before starting a parallel batch for it. This project hit exactly that: a sequential
sweep was still working through its list when a parallel batch was started for "the remaining"
competitions, without confirming the sequential one wasn't about to reach them on its own —
2 competitions ended up launched twice concurrently, wasting CPU-hours on a fully redundant run
that produced no new information. If parallelizing, either parallelize the *entire* candidate list
from a cold start, or explicitly track which IDs are claimed by which launcher before adding more.

Each run writes `run.json` (status, score, medal thresholds, integrity audit) and
`host-logs\pi-events.jsonl` (the full trace) under a fresh timestamped directory. A completed run
with `status: "invalid_submission"` or similar is still worth keeping — it's a real result, not a
crash — only a `status: "running"` entry with no `ended_at_utc` after the process has actually
exited represents dead/orphaned state worth deleting.

### B8. Optional: browse results

A read-only, no-auth viewer for run results (case picker, input/output/description, prompt +
transcript) lives at `waypoint\frontend\src\app\mlebench\` — a small addition to an unrelated
internal tool checked out at `waypoint\`, reading `mle-bench\runs\**` directly off disk via Next.js
route handlers. Not required to run experiments, only to browse them:

```powershell
cd D:\Downloads\Content\NUS\lab\waypoint\frontend
npm install
npm run dev
# open http://localhost:3000/mlebench
```

---

## Troubleshooting

### pi

| Symptom | How to confirm | Root cause | Fix |
|---|---|---|---|
| `pi` hangs indefinitely (10-30+ min) on any task using the `bash` tool; process alive, doing nothing | `Get-Process pi \| Select CPU` barely increases; `Get-NetTCPConnection -OwningProcess <pid>` shows no connection at all | Default shell-path probing doesn't find `bash.exe` when Git for Windows is on a non-default drive/path | Set `shellPath` explicitly in `settings.json` (A5) |
| Still hangs after fixing `shellPath`, only on complex/open-ended tasks — trivial single-tool tasks complete in seconds | Same CPU/network check shows the same "doing nothing" signature | Instruction passed as an inline CLI argument with nested/escaped double quotes (e.g. a JSON schema description) — something in the argument-passing chain mishandles it before pi.exe ever makes a network request | Write the instruction to a file, pass as `@filename` instead of an inline string |
| `--list-models` shows a model but requests return `403 permission_error: requires admin access` | Try an obviously fake model name — if the error text is identical, it's the gateway's generic "not in this token's catalog" response, not a real permissions problem | The model isn't served on the path you're calling (e.g. Qwen lived on `/llm`, not `/claude`) | `GET <base>/v1/models` on each candidate path before concluding it's a permissions issue |
| A model's final `thinking` content contains literal tool-call markup, no real tool call fires, `stopReason: "stop"` not `"toolUse"` | Run `experiment.py trace-health` on `pi-events.jsonl` | Serving/template output was not decoded into a structured Pi tool call | Use the guarded Gemma runner; it queues up to two in-session recovery turns and the host can restart Pi in the same workspace within the original time budget |
| A long run ends with `EngineCore encountered an issue` and OS exit code 0 | `trace-health.json` reports `provider_error: true`; `pi-stderr.log` may still be empty | Transient serving failure, often observed after oversized tool output grew request context past 100k tokens | The guarded runner caps tool observations, compacts at 70k tokens, retries in-session, then restarts Pi from workspace files if needed; `run.json` records every attempt |
| A run's transcript looks truncated to a fraction of its real length with no error shown | The trace has multiple `agent_start`/`agent_end` episodes (compaction or a stream-retry occurred); naively reading only the *last* `agent_end`'s message list drops every earlier episode | — (this is a viewer bug, not a pi bug — see B8's viewer, already fixed there) | Build any transcript view from `turn_end` events across the whole file, not `agent_end.messages` |

### MLE-bench / Kaggle

| Symptom | Root cause | Fix |
|---|---|---|
| `UnicodeDecodeError: 'gbk' codec can't decode...` loading a competition | `registry.py` reads `description.md` without `encoding="utf-8"`, defaults to system locale | B2 patch |
| `UnicodeEncodeError: 'gbk' codec can't encode...` after the above is fixed, now on write | `data.py` writes `description.md`/`checksums.yaml` without `encoding="utf-8"` | B2 patch |
| `ModuleNotFoundError: No module named 'kaggle.rest'` | `kaggle>=2` dropped the `kaggle.rest.ApiException` class `data.py` imports | B2 patch |
| `PermissionError: Kaggle authentication failed` despite a valid `access_token` file | `.venv`'s pinned `kaggle<1.7` package can't read the newer `KGAT_...` token format | B3 |
| `RuntimeError: You must accept the competition rules...` | Expected, not a bug — Kaggle requires browser-side rule acceptance per competition per account | B4 |
| `ValueError: Checksums do not match for <competition>!` after a clean download (zip checksum matched) | numpy 2.x vs 1.x `train_test_split` shuffle drift on competitions with a random public/private split — see B5 | `--skip-verification`, after confirming (once) the resulting data shape/ratio is sane |
| `OSError: [Errno 28] No space left on device` / `sqlite3.OperationalError: database or disk is full`, possibly cascading into instant failures on every subsequent competition in a batch | A large image-heavy competition (h-and-m, hubmap-kidney-segmentation — both ~2x raw size on copy into `prepared/`) exhausted free disk mid-run | B6 — drop the oversized competition, add a pre-flight free-space guard to batch scripts (prevents the cascade but not the triggering competition's own failure) |
| Downloaded/prepared data ends up under `%LOCALAPPDATA%\mle-bench\data` instead of the repo | `mlebench prepare` has no default `--data-dir`; omitting the flag silently uses the OS cache dir | Always pass `--data-dir` explicitly (B5); if it already happened, that directory is safe to delete — nothing reads from it |

### General debugging recipe for a suspected pi hang

```powershell
Get-Process pi | Select-Object Id, CPU, StartTime          # CPU barely moving over minutes = suspicious
Get-NetTCPConnection -OwningProcess <pid>                  # no connection at all = stuck before ever calling the model
Get-CimInstance Win32_Process -Filter "ParentProcessId=<pid>"  # no child process = stuck before spawning any tool subprocess
```

If all three are empty/flat for more than a minute or two on what should be a simple task, kill it
(`Stop-Process -Id <pid> -Force`) and re-test with the task rewritten as an `@file` attachment
rather than an inline argument.
