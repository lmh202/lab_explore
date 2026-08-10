# Environment and Public Asset Record

Prepared: 2026-08-08T22:17:02+08:00 (Asia/Singapore)

## Host

- OS execution context: Windows with WSL2 available.
- Git: 2.51.2.windows.1.
- Conda: 25.3.0.
- Existing default Python observed: 3.9.19; Python launcher also exposes 3.11 and 3.13.
- GPU: NVIDIA GeForce RTX 4060 Laptop GPU, 8,188 MiB VRAM; driver 560.94.
- Existing `base` environment is reused for SciFact and SciFact-Open evaluation.
- One new environment, `akb-multivers`, was created because no existing environment provided the legacy Lightning API required by MultiVerS.

Environment guidance from the author READMEs:

- SciFact: Python 3.7 in its own Conda environment.
- MultiVerS: Python 3.8 in its own Conda environment.
- SciFact-Open: Python 3.8.5 in its own Conda environment.

The audit avoided merging the MultiVerS legacy stack into the shared modern environment.

## Final environment selection

### Existing `base`: SciFact and SciFact-Open evaluators

- Python 3.9.19.
- NumPy 2.0.2, Pandas 2.2.3, Scikit-learn 1.6.1, PyArrow 21.0.0.
- SciFact `verisci/evaluate/pipeline.py --help`: PASS.
- SciFact-Open author evaluator: PASS using `scripts/run_scifact_open_eval.py`.

The SciFact-Open evaluator uses the removed `np.int` alias. The wrapper restores only that alias at process startup and then executes the pinned author script unchanged. The shared `base` packages were not downgraded or otherwise modified.

### New `akb-multivers`: MultiVerS inference

- Location: `D:\automata\envs\akb-multivers`.
- Reproduction recipe: `env/multivers_environment.yml`.
- Python 3.8.20; pip 24.0.
- PyTorch 1.7.1, torchvision 0.8.2, CUDA toolkit 11.0.
- PyTorch Lightning 1.2.1; Transformers 4.2.2; tokenizers 0.9.4.
- NumPy 1.19.4; Pandas 1.1.5; Scikit-learn 0.23.2; SciPy 1.6.0.
- spaCy 2.3.5; scispaCy 0.3.0; Pillow 8.2.0.
- `pip check`: PASS, no broken requirements.
- `multivers/predict.py --help`: PASS.
- RTX 4060 detection and a CUDA matrix operation: PASS.
- Public `scifact.ckpt` CPU deserialization: PASS; epoch 20, global step 58,560.

Keep pip below 24.1 in this environment because scispaCy 0.3.0 contains historical non-standard package metadata. Pillow is fixed at 8.2.0 because the newer Conda Pillow build initially failed to load torchvision's `_imaging` DLL.

## Pinned author repositories

| Repository | Local path | Branch | Commit | Commit date |
|---|---|---|---|---|
| allenai/scifact | `external/scifact` | `master` | `68b98a56d93e0f9da0d2aab4e6c3294699a0f72e` | 2023-10-15 |
| dwadden/multivers | `external/multivers` | `main` | `a6ce033f0e17ae38c1f102eae1ee4ca213fbbe2e` | 2023-08-15 |
| dwadden/scifact-open | `external/scifact-open` | `main` | `6fc2e2f2f97001f2fadb882600beb3e984d77aad` | 2023-11-24 |
| allenai/scifact-evaluator | `external/scifact-evaluator` | `master` | `66feffc5b2cc9e28e3ce3b8c9e824c3c642981eb` | pinned during SciFact evaluation |

The author worktrees were not edited. SciFact reports one untracked `._data` metadata file shipped by its official tarball; MultiVerS and SciFact-Open remain clean because their downloaded assets are ignored upstream.

## Prepared datasets and baselines

### SciFact official data

Source: `https://scifact.s3-us-west-2.amazonaws.com/release/latest/data.tar.gz`

| File | Records | Bytes |
|---|---:|---:|
| `external/scifact/data/corpus.jsonl` | 5,183 | 8,307,875 |
| `external/scifact/data/claims_train.jsonl` | 809 | 175,616 |
| `external/scifact/data/claims_dev.jsonl` | 300 | 65,007 |
| `external/scifact/data/claims_test.jsonl` | 300 | 33,769 |

The local evaluable split is `dev`; test labels are not public.

### MultiVerS processed data and SciFact checkpoint

Processed-data source: `https://scifact.s3.us-west-2.amazonaws.com/longchecker/latest/data.tar.gz`

The archive populated `external/multivers/data/{scifact,covidfact,healthver}`. The Phase 1 SciFact inputs include `claims_dev_cited.jsonl`, `claims_test_retrieved.jsonl`, and `corpus.jsonl`.

Checkpoint source: `https://scifact.s3.us-west-2.amazonaws.com/longchecker/latest/checkpoints/scifact.ckpt`

- Local path: `external/multivers/checkpoints/scifact.ckpt`
- Size: 5,253,770,098 bytes.
- SHA-256: `630739EC906BC5AD959A59BCEE479329F97AEEE4EB373230C79595B076C46690`.
- S3 `Content-Length`: 5,253,770,098 bytes (matches local file).
- Downloaded by the author-provided `script/get_checkpoint.py scifact` command.

Additional runtime assets required by the author implementation:

- `external/multivers/checkpoints/longformer_large_science.ckpt`: 1,646,843,693 bytes; SHA-256 `D1B2CAE78FCACD6DCA2C5543E1048F3D588EBC129DA92F2551564C7867A30535`.
- `cache/allenai/longformer-large-4096/pytorch_model.bin`: 1,742,910,431 bytes; SHA-256 `FEC3D7C012CB20E9269AF88A8AC53EAB4F5E0D490C4F276A60F0DF0D2EEAB5BE`.

Transformers 4.2.2 cannot follow Hugging Face's current relative cache redirect. The foundation model was therefore downloaded with a modern client/direct official URL and resolved as a local relative path by launching inference from the workspace `cache` directory. The author source code remains unchanged.

### SciFact-Open official data and author predictions

Source: `https://scifact.s3.us-west-2.amazonaws.com/scifact-open/latest/scifact_open.tar.gz`

| File | Records | Bytes | Role |
|---|---:|---:|---|
| `external/scifact-open/data/claims.jsonl` | 279 | 101,404 | Formal claims |
| `external/scifact-open/data/claims_metadata.jsonl` | 279 | 105,777 | Claim metadata |
| `external/scifact-open/data/corpus.jsonl` | 500,000 | 889,005,055 | Formal full corpus |
| `external/scifact-open/data/corpus_candidates.jsonl` | 12,236 | 24,850,554 | Debug-only subset |
| `external/scifact-open/prediction/retrievals.jsonl` | 279 | 143,679 | Author retrievals |
| `external/scifact-open/prediction/model_predictions.parqet` | Parquet | 1,312,667 | Author predictions for evaluator sanity |

The upstream filename is spelled `model_predictions.parqet`; it is preserved exactly. Formal retrieval must use the 500K `corpus.jsonl`, never only the 12K candidate subset.

## Download-script compatibility note

On this Windows checkout, Git converted shell scripts to CRLF. WSL therefore interpreted a trailing carriage return as part of filenames and URLs. In addition, the upstream SciFact-Open script contains `wget wget URL`. Each official script was attempted once and the failure was logged. The repositories were left unchanged; fallback downloads used the exact official S3 URLs embedded in those scripts.
