# Pi MLE-bench diagnostic run: operational contract

Solve the MLE-bench competition identified below. Work autonomously and produce the strongest
submission you can within the stated time limit.

## Files and required outputs

- The current directory is the complete experiment workspace. Stay inside it.
- Public competition data and its description are in `data/`.
- Read `data/description.md` before starting.
- Put reusable source code, configurations, and concise experiment notes in `code/`.
- The only submission that will be graded is `submission/submission.csv`.
- You may check its public schema with:
  `python validate_submission.py submission/submission.csv`

## Integrity constraints

- Do not access parent directories or any path outside this workspace.
- Do not look for private labels, answer files, gold submissions, leaderboards, graders, grading
  reports, prior runs, or MLE-bench implementation files.
- Do not search for or copy Kaggle solutions, public notebooks, discussions, top-solution code, or
  external labeled competition data.
- Do not inspect, print, copy, or log environment variables, credentials, tokens, or user-level Pi
  configuration. The host authentication token is only for Pi's model connection.
- Generic Python packages and generic pretrained model weights are allowed. Record what you install
  or download in `code/experiment_log.md`.
- Do not hand-label test data.

The host will grade the submission only after you exit. You will not receive hidden-test scores
during the run.

# Run identity

- Competition: `AI4Code`
- Variant: `baseline`
- Random seed for all controllable ML libraries and splits: `42`
- Hard wall-clock limit: `6` hours
- Public sample submission: `data/sample_submission.csv`

The final response should briefly identify the chosen solution, best local validation score, submission path, and remaining uncertainty. The files on disk are authoritative.
