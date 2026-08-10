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

## SFO-C3 - SciFact-Open full-corpus BM25 index

- Timestamp: 2026-08-10T15:06:00+08:00.
- Status: PASS.
- Environment: existing `base`; Python 3.9.19; NumPy 2.0.2; SciPy 1.13.1; scikit-learn 1.6.1.
- Device: CPU only.
- Input: `external/scifact-open/data/corpus.jsonl` (500,000 documents; title + abstract). Not the 12K `corpus_candidates.jsonl` debug subset.
- Runtime: 138.3 seconds (3.9s corpus load, 99.9s tokenize/vectorize, remainder save).
- Command:

```powershell
conda run -n base python scripts/build_scifact_open_bm25_index.py
```

- Method: standard Okapi BM25 (`k1=1.5`, `b=0.75`) built from a scikit-learn `CountVectorizer` (English stopword list, `(?u)\b\w\w+\b` token pattern, lowercased) over `title + " " + abstract`, stored as a scipy sparse term-document matrix. idf uses the Lucene/Elasticsearch `log((N-df+0.5)/(df+0.5)+1)` variant, which stays non-negative for all terms including very common ones.
- Output: `outputs/scifact_open/bm25/index/` (642,043-term vocabulary; 42,707,913 nonzero term-document pairs; ~119MB on disk: sparse matrix, doc IDs, doc lengths, idf vector, fitted vectorizer, stats.json).
- Validation: smoke-tested the same script on a 2,000-document prefix and 5 sample claims before the full run to confirm the pipeline was correct.
- Conclusion: BM25 index built over the full formal 500K corpus.

## SFO-C4 - SciFact-Open BM25 top-100 retrieval

- Timestamp: 2026-08-10T15:09:00+08:00.
- Status: PASS.
- Environment: existing `base`.
- Input: `external/scifact-open/data/claims.jsonl` (279 claims); index from SFO-C3.
- Runtime: 3.9 seconds for all 279 claims (plus 2.0s index load).
- Command:

```powershell
conda run -n base python scripts/retrieve_scifact_open_bm25.py
```

- Output: `outputs/scifact_open/bm25/rankings.jsonl` - one record per claim with up to 100 ranked `{doc_id, rank, score}` entries, retrieved against the full 500K corpus (never `corpus_candidates.jsonl`). 0 of 279 claims had zero matching query terms.
- Conclusion: full-corpus top-100 retrieval completed for every claim.

## SFO-C5 - SciFact-Open BM25 retrieval evaluation

- Timestamp: 2026-08-10T15:11:00+08:00.
- Status: PASS.
- Environment: existing `base`.
- Runtime: under 1 second.
- Command:

```powershell
conda run -n base python scripts/evaluate_scifact_open_retrieval.py
```

- Method: the pinned `external/scifact-open/script/run_eval.py` scores verification predictions (predicted label + confidence from `model_predictions.parqet`) and cannot compute retrieval-only Recall@K, so metrics are computed directly and unambiguously from each claim's gold evidence document IDs in `claims.jsonl` against the BM25 ranking, without editing the author evaluator.
- Metrics (206/279 claims have at least one gold evidence document; 73 NEI claims excluded from the average):
  - Recall@1: 0.3575
  - Recall@5: 0.5772
  - Recall@10: 0.6495
  - Recall@50: 0.7886
  - Recall@100: 0.8552
- Output: `outputs/scifact_open/bm25/metrics.txt`.
- Conclusion: full-corpus BM25 retrieval is reproducible and recovers the large majority of gold evidence documents by rank 100.

## SFO-C6 - Sanity sample

- Timestamp: 2026-08-10T15:11:00+08:00 (same run as SFO-C5).
- Status: PASS.
- Method: 5 claims sampled with fixed seed 42 from the 206 gold-evidence claims (reproducible via `--sanity-seed`).
- Result: all 5 sampled claims' retrieved doc_ids and gold doc_ids exist in the 500K corpus; 4 of 5 claims found their gold document within the top-100, consistent with the aggregate Recall@100 = 0.8552.
- Conclusion: no data-integrity issue found. Detail embedded in `outputs/scifact_open/bm25/metrics.txt`.

## SFO-D1 - BM25 -> MultiVerS adapter (OPTIONAL)

- Timestamp: 2026-08-10T15:20:00+08:00.
- Status: PASS.
- Note: `external/multivers/multivers/data.py` (`MultiVerSReader`) expects claims as `{"id", "claim", "doc_ids"}` and a corpus of `{"doc_id", "title", "abstract"}`; SciFact-Open's `corpus.jsonl` already matches the corpus schema exactly, so only the claims side needed converting.
- Command:

```powershell
conda run -n base python scripts/adapt_retrieval_to_multivers.py --output outputs/scifact_open/multivers_topk/input.jsonl --top-k 10
```

- Output: `outputs/scifact_open/multivers_topk/input.jsonl` - 279 claims, each with its BM25 top-10 doc_ids from SFO-C4.
- Conclusion: thin adapter, no changes to either pinned author repository.

## SFO-D2 - Small smoke run (OPTIONAL)

- Timestamp: 2026-08-10T15:21:00+08:00.
- Status: PASS.
- Environment: `akb-multivers` (same as SF-B3); RTX 4060 Laptop GPU, batch size 1, workers 0.
- Input: 15 claims, top-10 BM25 doc_ids each (150 claim-document pairs).
- Runtime: approximately 32 seconds inference (plus model load).
- Command (from `cache/`, same relative-path pattern as SF-B3):

```powershell
conda run -n akb-multivers python ../external/multivers/multivers/predict.py --checkpoint_path ../external/multivers/checkpoints/scifact.ckpt --input_file ../outputs/scifact_open/multivers_topk/smoke_input.jsonl --corpus_file ../external/scifact-open/data/corpus.jsonl --output_file ../outputs/scifact_open/multivers_topk/smoke_predictions.jsonl --batch_size 1 --num_workers 0 --device 0
```

- Output: `outputs/scifact_open/multivers_topk/smoke_predictions.jsonl` - 15 records, predictions serialize correctly, GPU memory/runtime stable, and predicted SUPPORT labels line up with claims whose gold evidence document was successfully retrieved by BM25.
- Conclusion: safe to proceed to the full 279-claim run.

## SFO-D3 - Full end-to-end run (OPTIONAL)

- Timestamp: 2026-08-10T15:23:00+08:00.
- Status: PASS.
- Environment: `akb-multivers`; RTX 4060 Laptop GPU, batch size 1, workers 0.
- Input: all 279 SciFact-Open claims, top-10 BM25 doc_ids each (2,790 claim-document pairs); corpus is the full 500K `scifact-open/data/corpus.jsonl` (only the 2,790 referenced doc_ids are tensorized; the corpus dict load itself takes a few seconds).
- Runtime: 14 minutes 21 seconds (861 seconds), approximately 4.3 pairs/sec after warmup - judged cheap enough per the SFO-D3 "full run only if cheap" rule given the smoke run was stable.
- Command: same as SFO-D2 with `input_file`/`output_file` pointed at the full 279-claim `outputs/scifact_open/multivers_topk/input.jsonl` / `predictions.jsonl`.
- Output: `outputs/scifact_open/multivers_topk/predictions.jsonl` - 279 records.
- Conclusion: full end-to-end BM25(top-10) -> MultiVerS run completed without errors.

## SFO-D4 - Document-level verification metrics (OPTIONAL, do-not-overclaim)

- Timestamp: 2026-08-10T15:38:00+08:00.
- Status: PASS.
- Method: the official evaluator needs a parquet file with SUPPORT/CONTRADICT confidence scores that this predict-only pipeline does not produce, so this computes the same label-match P/R/F1 definition directly from predicted vs. gold evidence (no evaluator edits). Sentence-level rationale is not scored, per SFO-D4's own instruction to treat document-level evidence/label as primary.
- Command:

```powershell
conda run -n base python scripts/evaluate_multivers_topk.py
```

- Metrics (279 claims; 460 gold claim-document pairs, 223 of which fell inside the retrieved top-10 pool):
  - Precision (of predicted pairs): 0.7803
  - Recall (of gold pairs that made it into top-K): 0.6054
  - Recall (of ALL gold pairs, retrieval-capped): 0.2935
  - F1 (retrieval-capped recall): 0.4265
- Output: `outputs/scifact_open/multivers_topk/metrics.txt`.
- Conclusion: consistent with the pure-retrieval Recall@10 = 0.6495 in SFO-C5 (the "recall of pool" figure here, 0.6054, is a stricter per-claim-document-pair version of the same quantity); the verifier itself is reasonably precise (0.78) once a relevant document is actually retrieved. This is not directly comparable to SF-B4's SciFact dev numbers, which used gold cited documents rather than open retrieval.
