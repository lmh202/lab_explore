# Bad-case direction review against public reference kernels

This is a post-run host-side audit. The public Kaggle kernels were downloaded only after the baseline runs and were never copied into a Pi workspace.

## TPS May 2022

### Verdict

The agent chose the right broad model family and partially correct feature engineering, but missed the dataset's most important discovered structure. More importantly, the submitted predictions were corrupted by an aggregation bug. The official failure is therefore mostly execution and selection failure, not evidence that LightGBM/XGBoost was the wrong direction.

### What aligns with good references

- Both the agent and references split the ten-character `f_27` string into per-position features.
- Both use nonlinear boosted trees and AUC-based validation.
- The agent constructed interactions, which is directionally appropriate for this synthetic dataset.

### What the references do better

- The EDA reference checks string cardinality and train/test overlap, then adds the count of unique characters.
- It identifies three specific sharp-boundary interactions: `f_02 + f_21`, `f_05 + f_22`, and `f_00 + f_01 + f_26`, with ternary threshold features.
- The GBDT reference follows validation AUC across iterations, selects the AUC peak, retrains on all data, and correctly averages full test predictions over seeds.

### What went bad in the agent run

- It used many largely arbitrary products and ratios rather than discovering or testing the three high-value interactions.
- It averaged weak configurations even after observing that the blend reduced OOF AUC.
- For each model family it accumulated predictions over five folds but divided only by the number of configurations, omitting division by five. Clipping then forced a large fraction of predictions to exactly `1.0`, destroying AUC rank information.
- It printed only basic prediction statistics and did not detect that the submission median was `1.0`.

### Main policy opportunity

Require an explicit prediction-accounting invariant (`number of accumulated predictions == averaging denominator`), submission quantile/tie checks, validation-based model selection, and error/interaction analysis before launching a large ensemble.

## Ventilator Pressure Prediction

### Verdict

The agent correctly recognized the physics/time-series nature and chose sensible lag/cumulative features. A flat LightGBM is a reasonable cheap baseline, but the final implementation did not preserve the fundamental sample unit: one complete 80-step breath. Compared with strong references, the feature direction is right but the representation, validation, loss alignment, and model family progression are wrong or incomplete.

### What aligns with good references

- Both use `R`, `C`, `u_in`, `u_out`, cumulative input, lags, differences, rolling statistics, and interactions.
- Both recognize that only `u_out == 0` is scored with MAE.
- A cheap tree baseline before sequence models is sensible under a six-hour RTX 4060 budget.

### What the references do better

- The simple LSTM groups rows by `breath_id`, builds a tensor per complete breath, and directly optimizes masked inspiratory MAE.
- Its validation keeps breaths intact with GroupKFold.
- The stronger Transformer reshapes data to `(n_breaths, 80, features)`, masks loss to the scored phase, saves the best validation checkpoint, uses auxiliary pressure-difference/integral targets, and tests pressure-grid rounding on OOF predictions.
- The Transformer reports CV 0.131 and LB 0.112, but its 11/32-fold resource budget is far beyond this experiment; it is a conceptual direction reference, not a fair six-hour target.

### What went bad in the agent run

- To reduce cost, it sampled 5% of individual rows instead of complete breaths. Lag, cumulative, rolling, and step features were then computed over mutilated sequences, while test features were computed on complete sequences.
- It used ordinary row-level KFold, allowing rows from the same breath on both sides and validating a different unit from deployment.
- It trained the final model and wrote a submission before running CV.
- Early stopping monitored the training set itself.
- It trained equally on scored inspiratory and unscored expiratory rows instead of aligning the objective with the official mask.
- It repeatedly reduced scale without first repairing the sampling unit and validation contract.

### Main policy opportunity

Require the agent to state the independent sample/group unit before sampling or splitting; preserve whole groups during feature computation; align loss and validation exactly with the official metric; establish a trustworthy cheap baseline first; then move to a small one-fold LSTM/GRU only if time permits.

## Paths

Agent traces and generated code:

- `runs/pi-qwen/tabular-playground-series-may-2022/baseline/20260812T043946430Z/host-logs/pi-events.jsonl`
- `runs/pi-qwen/tabular-playground-series-may-2022/baseline/20260812T043946430Z/workspace/code/solution_v2.py`
- `runs/pi-qwen/ventilator-pressure-prediction/baseline/20260812T062451744Z/host-logs/pi-events.jsonl`
- `runs/pi-qwen/ventilator-pressure-prediction/baseline/20260812T062451744Z/workspace/code/train_model.py`

Public references:

- `analysis/reference_kernels/tps_may_2022/ambrosm_eda/tpsmay22-eda-which-makes-sense.py`
- `analysis/reference_kernels/tps_may_2022/ambrosm_gbdt/tpsmay22-gradient-boosting-quickstart.py`
- `analysis/reference_kernels/tps_may_2022/pourchot_features/tps-2022-05-important-features-updated.py`
- `analysis/reference_kernels/ventilator/theoviel_lstm/deep-learning-starter-simple-lstm.py`
- `analysis/reference_kernels/ventilator/cdeotte_transformer/tensorflow-transformer-0-112.py`
- `analysis/reference_kernels/ventilator/l0glikelihood_01093/0-1093-single-public-lb.ipynb`
