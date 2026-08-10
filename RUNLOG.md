# Phase 1 Run Log

## A1 - Clone and pin author repositories

- Timestamp: 2026-08-08T22:03:00+08:00.
- Status: PASS.
- Device: CPU / network only.
- Runtime: approximately 6 seconds.
- Commands:

```powershell
git clone https://github.com/allenai/scifact.git external/scifact
git clone https://github.com/dwadden/multivers.git external/multivers
git clone https://github.com/dwadden/scifact-open.git external/scifact-open
git -C external/<repo> rev-parse HEAD
```

- Output: `external/scifact`, `external/multivers`, `external/scifact-open`.
- Conclusion: all three author repositories were cloned and pinned; see `env/environment_notes.md`.

## A3-SF-ATTEMPT - SciFact author download script

- Timestamp: 2026-08-08T22:04:42+08:00.
- Status: FAIL.
- Runtime: approximately 5 seconds, shared with the MultiVerS attempt below.
- Exact command:

```powershell
bash -lc "cd /mnt/d/Downloads/Content/NUS/lab/akb_baseline_phase1/external/scifact && bash script/download-data.sh"
```

- First actionable root cause: the Windows checkout converted the shell script to CRLF; WSL failed on `$'\r'` before a valid download could complete.

## A3-MV-ATTEMPT - MultiVerS author data script

- Timestamp: 2026-08-08T22:04:42+08:00.
- Status: FAIL.
- Exact command:

```powershell
bash -lc "cd /mnt/d/Downloads/Content/NUS/lab/akb_baseline_phase1/external/multivers && bash script/get_data.sh"
```

- First actionable root cause: CRLF appended `%0D` to the official S3 URL, producing HTTP 403.

## A3-SF-MV-FALLBACK - SciFact and MultiVerS official data

- Timestamp: 2026-08-08T22:04:55+08:00.
- Status: PASS.
- Runtime: approximately 6 seconds.
- Commands: download the exact two URLs embedded in the author scripts with `curl.exe -fL --retry 3`, extract each with `tar -xzf`, then remove only the downloaded archive.
- Inputs:
  - `https://scifact.s3-us-west-2.amazonaws.com/release/latest/data.tar.gz`
  - `https://scifact.s3.us-west-2.amazonaws.com/longchecker/latest/data.tar.gz`
- Outputs: `external/scifact/data` and `external/multivers/data`.
- Conclusion: official datasets extracted successfully without editing either author repository.

## A3-SFO-ATTEMPT - SciFact-Open author data script

- Timestamp: 2026-08-08T22:05:19+08:00.
- Status: FAIL.
- Runtime: 14.5 seconds.
- Exact command:

```powershell
bash -lc "cd /mnt/d/Downloads/Content/NUS/lab/akb_baseline_phase1/external/scifact-open && bash script/get_data.sh"
```

- First actionable root cause: the upstream script contains `wget wget URL`; CRLF also appended `%0D` to the S3 URL.

## A3-SFO-FALLBACK - SciFact-Open official data

- Timestamp: 2026-08-08T22:05:40+08:00.
- Status: PASS.
- Runtime: 44.3 seconds.
- Command: download the exact upstream URL with `curl.exe -fL --retry 3`, extract with `tar -xzf`, and remove only the downloaded archive.
- Input: `https://scifact.s3.us-west-2.amazonaws.com/scifact-open/latest/scifact_open.tar.gz`.
- Output: `external/scifact-open/data` and `external/scifact-open/prediction`.
- Conclusion: the complete 500K corpus, 279 claims, author predictions, and author retrievals are present.

## SF-B2-PREP - MultiVerS public SciFact checkpoint

- Timestamp: 2026-08-08T22:06:37+08:00.
- Status: PASS.
- Runtime: 587.1 seconds.
- Environment: WSL2 system Python used only to invoke the dependency-free downloader; no inference environment installed.
- Exact command:

```powershell
bash -lc "cd /mnt/d/Downloads/Content/NUS/lab/akb_baseline_phase1/external/multivers && python3 script/get_checkpoint.py scifact"
```

- Input: author S3 checkpoint URL selected by `get_checkpoint.py`.
- Output: `external/multivers/checkpoints/scifact.ckpt`.
- Validation: 5,253,770,098 bytes; SHA-256 `630739EC906BC5AD959A59BCEE479329F97AEEE4EB373230C79595B076C46690`.
- Conclusion: the required public MultiVerS checkpoint is fully downloaded; no training occurred.

## A2-ENV-AUDIT - Existing environment compatibility

- Timestamp: 2026-08-08T22:18:00+08:00.
- Status: PASS with one required new environment.
- Existing environments inspected: `base`, `car`, `job`, `lab`, `screw-video-yolo-lock`.
- Results:
  - SciFact evaluator CLI in `base`: PASS.
  - SciFact-Open author evaluator in `base`: initially FAIL on removed `numpy.int`; PASS with a runtime compatibility wrapper and no evaluator edit.
  - MultiVerS CLI in `base`: FAIL because `pytorch_lightning` is absent and the repository needs the legacy 1.2.1 API.
- Conclusion: reuse `base` for evaluators; create only `akb-multivers` for model inference.

## A2-MV-ENV - Configure MultiVerS environment

- Timestamp: 2026-08-08T22:44:51+08:00.
- Status: PASS.
- Environment: `D:\automata\envs\akb-multivers`.
- Commands:

```powershell
conda create -n akb-multivers python=3.8.20 pip=24.2 -y
conda install -n akb-multivers pytorch=1.7.1 torchvision=0.8.2 cudatoolkit=11.0 -c pytorch -y
conda run -n akb-multivers python -m pip install pip==24.0
conda run -n akb-multivers python -m pip install --timeout 300 --retries 5 -r external/multivers/requirements.txt
conda run -n akb-multivers python -m pip install --force-reinstall pillow==8.2.0
```

- Resolved attempts:
  - pip 24.2 rejected scispaCy 0.3.0 metadata; pip 24.0 accepted the historical package.
  - The first long requirements download timed out on SciPy; the retry completed.
  - Conda Pillow 9.3.0 produced a torchvision `_imaging` DLL error; Pillow 8.2.0 fixed it.
- Validation:
  - `pip check`: PASS.
  - MultiVerS prediction CLI import chain: PASS.
  - RTX 4060 / CUDA tensor operation: PASS.
  - `scifact.ckpt` deserialization: PASS (epoch 20, global step 58,560).
- Reproduction file: `env/multivers_environment.yml`.

## SFO-C2 - Author prediction evaluator sanity

- Timestamp: 2026-08-08T22:43:00+08:00.
- Status: PASS.
- Environment: existing `base` (Python 3.9.19).
- Runtime: 3.53 seconds.
- Command:

```powershell
conda run -n base python scripts/run_scifact_open_eval.py --output outputs/scifact_open/official_eval/metrics.txt
```

- Output: `outputs/scifact_open/official_eval/metrics.txt`.
- Conclusion: the pinned author predictions, data, and evaluator execute end-to-end without changing evaluator logic.

## SF-B3-SMOKE-1 - MultiVerS first dev smoke

- Timestamp: 2026-08-08T23:01:00+08:00.
- Status: FAIL.
- Input: one SciFact dev claim and cited document.
- Runtime: 6.25 seconds.
- First actionable root cause: Transformers 4.2.2 could not follow Hugging Face's current relative redirect while resolving `allenai/longformer-large-4096/config.json`.
- Resolution: cache the exact official foundation model locally and launch the unmodified author script from the cache directory.

## SF-B3-PREP - MultiVerS runtime model assets

- Timestamp: 2026-08-08T23:15:44+08:00.
- Status: PASS.
- Assets:
  - Hugging Face `allenai/longformer-large-4096` config, tokenizer, and `pytorch_model.bin` cached under `cache/allenai/longformer-large-4096`.
  - Author `longformer_large_science.ckpt` downloaded with `python script/get_checkpoint.py longformer_large_science`.
- Validation:
  - Hugging Face model size 1,742,910,431 bytes; SHA-256 `FEC3D7C012CB20E9269AF88A8AC53EAB4F5E0D490C4F276A60F0DF0D2EEAB5BE`.
  - Science checkpoint size 1,646,843,693 bytes; SHA-256 `D1B2CAE78FCACD6DCA2C5543E1048F3D588EBC129DA92F2551564C7867A30535`.

## SF-B3-SMOKE-2 - MultiVerS second dev smoke

- Status: FAIL.
- Runtime: 12.60 seconds.
- First actionable root cause: `checkpoints/longformer_large_science.ckpt` was not yet present; the author model constructor requires it in addition to `scifact.ckpt`.
- Resolution: download the public checkpoint with the author script.

## SF-B3-SMOKE-3 - MultiVerS GPU smoke

- Status: PASS.
- Runtime: 20.91 seconds including model load.
- Device: NVIDIA GeForce RTX 4060 Laptop GPU; batch size 1; workers 0.
- Input: `outputs/scifact/multivers/smoke_input.jsonl` (one claim-document pair).
- Output: `outputs/scifact/multivers/smoke_predictions.jsonl`.
- Conclusion: checkpoint construction, local model resolution, CUDA inference, and prediction serialization all pass.

## SF-B3 - MultiVerS full SciFact dev inference

- Timestamp: 2026-08-08T23:19:00+08:00.
- Status: PASS.
- Environment: `akb-multivers`; Python 3.8.20; PyTorch 1.7.1+CUDA 11.0; Lightning 1.2.1; Transformers 4.2.2.
- Device: NVIDIA GeForce RTX 4060 Laptop GPU; batch size 1; workers 0.
- Input: 300 claims from `external/multivers/data/scifact/claims_dev_cited.jsonl`; 5,183-document corpus.
- Work units: 340 claim-document pairs.
- Runtime: 83.11 seconds.
- Command:

```powershell
cd cache
conda run -n akb-multivers python ..\external\multivers\multivers\predict.py --checkpoint_path ..\external\multivers\checkpoints\scifact.ckpt --input_file ..\external\multivers\data\scifact\claims_dev_cited.jsonl --corpus_file ..\external\multivers\data\scifact\corpus.jsonl --output_file ..\outputs\scifact\multivers\predictions.jsonl --batch_size 1 --num_workers 0 --device 0
```

- Output: 300 valid JSONL records, 188 non-empty claim predictions, 209 predicted documents.
- Prediction SHA-256: `4D517919E73917825DA67281C3B8D77373A69E7A4C8805B91C024B65E4A7ACB7`.

## SF-B4 - Official SciFact evaluation

- Timestamp: 2026-08-08T23:21:00+08:00.
- Status: PASS.
- Evaluator: `allenai/scifact-evaluator` commit `66feffc5b2cc9e28e3ce3b8c9e824c3c642981eb`.
- Environment: existing `base`.
- Runtime: 1.45 seconds.
- Command:

```powershell
conda run -n base python external/scifact-evaluator/evaluator/eval.py --labels_file external/scifact/data/claims_dev.jsonl --preds_file outputs/scifact/multivers/predictions.jsonl --metrics_output_file outputs/scifact/multivers/metrics_scifact_evaluator.json --verbose
```

- Metrics:
  - Abstract label only P/R/F1: 1.000000 / 1.000000 / 1.000000.
  - Abstract rationalized P/R/F1: 1.000000 / 1.000000 / 1.000000.
  - Sentence selection P/R/F1: 0.997275 / 1.000000 / 0.998636.
  - Sentence label P/R/F1: 0.997275 / 1.000000 / 0.998636.
- Metrics SHA-256: `ABD00193131A0F54D7E333A7A250DA33E30BF63947881FCA00B1C7919DDEF924`.
- Qualification: this proves reproducible inference and evaluation, not clean dev generalization. The public checkpoint targets hidden-test leaderboard prediction, names a `combined_split` experiment in its metadata, and exactly recovers all 209 dev gold claim-document labels.
