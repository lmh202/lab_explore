# Blockers

## Active blockers

None.

## Resolved preparation issue: author shell scripts on Windows

The three author repositories were cloned through Git for Windows, which checked out `.sh` files with CRLF line endings. WSL then treated `\r` as part of commands and S3 URLs. The upstream SciFact-Open script also contains a duplicated `wget` token.

Resolution: each official script was attempted once and logged, the third-party repositories were left unchanged, and the exact official S3 URLs embedded in the scripts were downloaded with Windows `curl.exe` and extracted with `tar`. All expected data files and the required checkpoint passed size/count checks.

For future shell-script execution, use an LF-only copy or clone with `core.autocrlf=input` inside WSL. Do not mass-edit the pinned author worktrees without recording the change.

## Resolved environment issues

- SciFact-Open failed in modern NumPy because the author evaluator calls the removed `np.int` alias. A workspace wrapper restores the alias at runtime and executes the author evaluator unchanged; the sanity run passes.
- No existing environment contained MultiVerS's PyTorch Lightning 1.2.1 API. A single isolated `akb-multivers` environment was created instead of modifying the shared `base` environment.
- pip 24.2 rejected scispaCy 0.3.0 metadata. Pinning pip 24.0, as required by the error guidance, resolved installation.
- One wheel download timed out and succeeded on retry with a longer network timeout.
- torchvision initially failed on a newer Pillow DLL combination. Pillow 8.2.0 restored a clean import.

## Resolved MultiVerS runtime issues

- Transformers 4.2.2 could not follow Hugging Face's current relative redirect for `allenai/longformer-large-4096`. The exact official files were cached locally and the unmodified author script was launched from the cache directory.
- The SciFact checkpoint loader also requires the author-provided `longformer_large_science.ckpt`; this dependency was downloaded with the author script.

## Documented skip: VeriSci (optional baseline)

VeriSci (`external/scifact/script/pipeline.sh`) is a Should/optional baseline per the task specification, not required for the Phase-1 DONE gate. Its `requirements.txt` pins `torch==1.5.0`, `transformers==2.7.0`, `scikit-learn==0.22.2.post1`, and `scispacy==0.2.5` - a legacy stack older than, and disjoint from, the `akb-multivers` environment already built for MultiVerS (which itself required several fix iterations: pip version pinning, a Pillow/torchvision DLL conflict, a timed-out wheel download). Building a second from-scratch legacy environment, downloading two additional roberta-large-scale models via `download-model.sh`, and likely hitting the same CRLF line-ending issue already logged above for this repository's shell scripts, would cost effort comparable to or larger than the MultiVerS environment build for a baseline explicitly marked optional. Per the stop rule ("optimize for useful evidence of feasibility, not for rescuing every legacy repository"), this was skipped without an environment-build attempt rather than risk a multi-hour repair on a non-blocking row. See `reports/baseline_results.md` for the SKIP status.

## Result qualification: SciFact dev contamination

The public `scifact.ckpt` is documented for producing hidden-test leaderboard predictions, while its checkpoint metadata names a `combined_split` experiment. On public dev it exactly recovers all 209 gold claim-document labels and nearly all gold rationale sentences. The official metrics are valid outputs of the evaluator, but they must not be reported as an unbiased dev generalization result. They establish pipeline feasibility only.
