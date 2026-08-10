# pi Agent + Self-Hosted Qwen3.6 Setup Protocol

Reproducible setup notes for installing the [pi coding agent CLI](https://github.com/earendil-works/pi)
on Windows and wiring it up to a self-hosted Qwen3.6 backend reached through a personal gateway
(`lum.id`). Written after a live debugging session where the agent hung for 10-30+ minutes on
what looked like simple tasks; the real causes and fixes are captured in
[Troubleshooting](#troubleshooting) below.

Target platform: Windows 10/11, PowerShell 5.1, Git for Windows installed somewhere (any path).

## 1. Install pi

pi ships precompiled standalone binaries on GitHub Releases — no Node/npm build needed.

```powershell
# Find the latest release and its Windows asset + checksum URLs
$release = Invoke-RestMethod "https://api.github.com/repos/earendil-works/pi/releases/latest"
$zipAsset = $release.assets | Where-Object { $_.name -eq "pi-windows-x64.zip" }
$sumAsset = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" }

# Download both into the target directory (adjust the destination as needed)
$dest = "D:\Downloads\Content\NUS\lab"
Invoke-WebRequest $zipAsset.browser_download_url -OutFile "$dest\pi-windows-x64.zip"
Invoke-WebRequest $sumAsset.browser_download_url -OutFile "$dest\SHA256SUMS"

# Verify checksum before extracting
$expected = (Select-String -Path "$dest\SHA256SUMS" -Pattern "pi-windows-x64.zip").Line.Split(' ')[0]
$actual = (Get-FileHash "$dest\pi-windows-x64.zip" -Algorithm SHA256).Hash
if ($actual.ToLower() -ne $expected.ToLower()) { throw "Checksum mismatch!" }

Expand-Archive "$dest\pi-windows-x64.zip" -DestinationPath "$dest\pi" -Force
Remove-Item "$dest\pi-windows-x64.zip", "$dest\SHA256SUMS"
```

This produces `<dest>\pi\pi.exe` plus its bundled native dependencies (clipboard, Windows console
mode addon) and reference docs/examples. Verify:

```powershell
D:\Downloads\Content\NUS\lab\pi\pi.exe --version
```

## 2. Set the gateway auth token

Both providers below authenticate against the `lum.id` gateway using one token. **Never commit
this token or paste it into a chat/log** — set it as an environment variable only.

Session-scoped (must be re-run in every new terminal window):

```powershell
$env:ANTHROPIC_AUTH_TOKEN = "<your lum.id token>"
```

Persistent (writes to the registry; takes effect in *new* terminal windows only, not the current one):

```powershell
[Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "<your lum.id token>", "User")
```

`ANTHROPIC_BASE_URL` is **not** needed by pi — the base URLs are hardcoded in `models.json` below.
That variable only matters if you're also pointing an Anthropic-SDK-based tool (e.g. Claude Code
itself) at the same gateway.

## 3. Configure the custom providers

The gateway exposes two independent paths with two different wire protocols. This was **not**
documented anywhere — it was discovered by probing `GET <base>/v1/models` on each path:

| Path | Protocol | Serves |
|---|---|---|
| `https://lum.id/claude` | Anthropic Messages API | Claude models (`claude-sonnet-5`, etc.) |
| `https://lum.id/llm` | OpenAI Chat Completions | Self-hosted Qwen3.6 models via llama.cpp/vLLM |

Edit `~/.pi/agent/models.json` (create the file if it doesn't exist):

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
        "supportsReasoningEffort": false,
        "thinkingFormat": "qwen-chat-template"
      },
      "models": [
        {
          "id": "qwen3.6-27b",
          "name": "Qwen3.6 27B (lum.id llama.cpp)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 32768,
          "maxTokens": 8192,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "qwen3.6-35b-a3b",
          "name": "Qwen3.6 35B A3B (lum.id llama.cpp)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 32768,
          "maxTokens": 8192,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

Notes on the non-obvious fields:

- **`contextWindow: 32768`** — the model was trained up to 262144 tokens, but the *running*
  llama.cpp server instance on this deployment only allocates 32768. Confirmed via
  `GET https://lum.id/llm/v1/models`, field `meta.n_ctx`. Sending a request that would exceed
  this will fail or behave badly at the server; re-check `n_ctx` on a new deployment before
  reusing this value.
- **`compat.forceAdaptiveThinking: true`** (Claude entry) — `GET .../v1/models` on the `/claude`
  path reports `thinking.types.adaptive.supported: true` and `enabled.supported: false` for these
  models, i.e. they need Anthropic's newer adaptive-thinking request shape, not the legacy
  budget-token one. Without this flag pi sends the wrong thinking payload.
- **`compat.thinkingFormat: "qwen-chat-template"`** (Qwen entries) — these llama.cpp-served Qwen
  models return a separate `reasoning_content` field. Without this compat flag the thinking
  content can leak into the final visible response.

Verify the providers loaded and see which models are marked available (needs the token from step 2
to be set in the *same* shell):

```powershell
D:\Downloads\Content\NUS\lab\pi\pi.exe --list-models
```

## 4. Set a default provider/model (optional)

So a bare `pi` invocation (no `--provider`/`--model` flags) uses Qwen by default. Edit
`~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "lum-llm",
  "defaultModel": "qwen3.6-35b-a3b"
}
```

## 5. Fix: Windows shell path (prevents a silent hang)

pi's `bash` tool looks for a shell in this order: `settings.json` → `C:\Program Files\Git\bin\bash.exe`
→ `bash.exe` on `PATH`. If Git for Windows is installed anywhere else (e.g. `D:\Git`), the second
check silently fails to resolve correctly and **the agent hangs indefinitely on its first bash tool
call** — no error, no crash, just an idle process. See [Troubleshooting](#troubleshooting) for how
this was diagnosed.

Find your actual `bash.exe`:

```powershell
Get-Command bash.exe -All | Select-Object Source
```

Then pin it explicitly in `~/.pi/agent/settings.json`:

```json
{
  "shellPath": "D:\\Git\\bin\\bash.exe"
}
```

(Adjust the path to whatever `Get-Command` reported. Combine this with the `defaultProvider`/
`defaultModel` keys from step 4 — it's the same file.)

## 6. Install ripgrep (defensive, recommended)

pi's built-in `grep` tool shells out to ripgrep (`rg`) rather than implementing search itself
(source: [`grep.ts`](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/src/core/tools/grep.ts)).
If `rg` isn't a real installed binary, tool calls that use it can fail or behave unpredictably.
Note: in this debugging session, missing `rg` turned out **not** to be the cause of the hang
described below (see Troubleshooting) — but it's still a real dependency worth installing properly
rather than relying on a shell alias/function from another tool.

```powershell
winget install --id BurntSushi.ripgrep.MSVC -e --accept-package-agreements --accept-source-agreements
```

This updates the persistent user `PATH` (registry). **Restart your terminal** for `rg` to resolve;
an already-open shell (or a long-lived agent session that inherited the old environment) won't see it.

## 7. Verify everything works end to end

```powershell
$env:ANTHROPIC_AUTH_TOKEN = "<your lum.id token>"
cd D:\Downloads\Content\NUS\lab

# 1. Basic connectivity, no tools
.\pi\pi.exe --print --no-session --provider lum-llm --model qwen3.6-27b "Reply with exactly: connect ok"

# 2. Tool use (bash)
.\pi\pi.exe --print --no-session --provider lum-llm --model qwen3.6-27b "Use your bash tool to run: echo hello-from-bash-tool"

# 3. Multi-step agentic task via a task file (see step below on WHY this must be a file, not an inline argument)
```

For step 3, write the task to a file first, then pass it as `@filename` — do not pass a long or
quote-heavy instruction directly as a CLI argument (see next section for why):

```powershell
@"
Search this directory for a file and summarize what it contains.
When done, output one line of JSON: {"status": "ok"}
"@ | Out-File -Encoding utf8 task_smoke.md

.\pi\pi.exe --print --no-session --provider lum-llm --model qwen3.6-27b "@task_smoke.md"
```

All three should return within seconds to low tens-of-seconds, not minutes.

## Troubleshooting

Symptoms observed and root causes found, in the order they were debugged. Written so a hang can
be recognized quickly next time instead of re-diagnosed from scratch.

| Symptom | How to confirm | Root cause | Fix |
|---|---|---|---|
| `pi` hangs indefinitely (10-30+ min) on any task that uses the `bash` tool; process alive but doing nothing | `Get-Process pi \| Select CPU` barely increases over many minutes; `Get-NetTCPConnection -OwningProcess <pid>` shows no connection at all | pi's default shell-path probing (`C:\Program Files\Git\bin\bash.exe`) doesn't exist on machines where Git for Windows was installed to a non-default drive/path | Set `shellPath` explicitly in `settings.json` (step 5) |
| `pi` hangs the same way even after fixing `shellPath`, only on complex/open-ended tasks — trivial single-tool tasks (`echo`, `grep -c`, read first N lines) all complete in seconds | Same CPU/network check as above shows the same "doing nothing" signature; a real ripgrep install did **not** fix it either | The task instruction was passed as an inline CLI argument containing a long string with nested/escaped double quotes (e.g. a JSON output-schema description like `{\"label\": \"SUPPORT\"\|...}`). Something in the bash → pi.exe argument-passing chain mishandles this, and pi.exe never reaches the point of making its first network request | Write the instruction to a file and pass it as `@filename` instead of an inline quoted string. Confirmed fix: identical task, only difference was `@file` vs inline string, completed in under 150s. |
| `--list-models` shows a model but requests return `403 {"type":"permission_error", "message":"model X requires admin access on this platform"}` | Try the exact same request with an obviously fake model name — if the error text is identical, this message is the gateway's generic "not in this token's catalog" response, not evidence the model exists at all | The model isn't actually served on the path you're calling. On this gateway, `lum.id/claude` only proxies Claude models; Qwen lived on an entirely different path, `lum.id/llm`, using a different wire protocol (OpenAI Chat Completions, not Anthropic Messages) | Confirm the right path/protocol with `GET <base>/v1/models` before concluding it's a permissions problem |
| PowerShell: `表达式或语句中包含意外的标记"print"` / `'--' 运算符仅适用于变量或属性` when running a command that starts with a quoted exe path | — | PowerShell does not execute a bare quoted string at the start of a statement as a command; it tries to parse `--print` as the `--` decrement operator | Either prefix with the call operator (`& "C:\path\pi.exe" ...`) or, if the path has no spaces, drop the quotes entirely (`C:\path\pi.exe ...`) |
| A `--print` run redirected to a file (`> out.txt`) shows an empty file the whole time it's running | — | Not a bug — stdout is fully buffered (not line-buffered) when redirected to a file instead of a TTY, so nothing appears until the process finishes or the buffer fills | Don't use "file still empty" alone as evidence of a hang; check process CPU trend and `Get-NetTCPConnection` instead |

### General debugging recipe for a suspected pi hang

```powershell
Get-Process pi | Select-Object Id, CPU, StartTime          # CPU barely moving over minutes = suspicious
Get-NetTCPConnection -OwningProcess <pid>                  # no connection at all = stuck before ever calling the model
Get-CimInstance Win32_Process -Filter "ParentProcessId=<pid>"  # no child process = stuck before spawning any tool subprocess
```

If all three are empty/flat for more than a minute or two on what should be a simple task, kill it
(`Stop-Process -Id <pid> -Force`) and re-test with the task rewritten as an `@file` attachment
rather than an inline argument.
