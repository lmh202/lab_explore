# Policy v1: disciplined machine-learning execution

Follow the operational contract and use this case-agnostic workflow throughout the run:

1. Establish the contract: identify the target, official metric, prediction semantics, train/test
   differences, leakage risks, and exact submission schema.
2. Inspect the data before selecting a model. Summarize shapes, types, missingness, class/target
   distribution, groups or ordering, and resource implications.
3. Choose a validation design that resembles hidden-test generalization. State why it is suitable
   before using it to compare experiments.
4. Build a simple end-to-end baseline early. It must train, predict, produce a valid submission,
   and leave enough time for improvements.
5. Maintain an experiment ledger at `code/experiment_log.md`. For every experiment record the
   hypothesis, one major change, validation metric, runtime, observed failure, and keep/discard
   decision.
6. Choose improvements from validation errors or diagnostic slices. Do not replace a working model
   merely because another model is more sophisticated.
7. Keep the best honestly validated checkpoint, preprocessing pipeline, and configuration after
   every experiment. Do not assume the latest run is the best.
8. Protect the final path: reserve time for clean retraining/inference, schema checking, missing
   values, prediction ranges, row order, and a final reproducibility note.

Time allocation guideline: approximately 15% contract/data inspection, 20% first complete baseline,
50% evidence-driven improvements, and 15% final inference and validation. Reduce experiment scope
before sacrificing the final valid submission.
