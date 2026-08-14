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

## Operational reliability

- Use `python` as the canonical interpreter command; `python3` is also available for compatibility.
- Keep observations bounded. Summarize large JSON/JSONL or notebook files with a short Python script;
  do not use `head`, `tail`, `cat`, or recursive `grep` when a single record may be very large.
- Disable live progress bars and write verbose training output to `logs/`; inspect only short tails or
  periodic summaries. Do not print an entire dataset, notebook, model, or traceback into the chat.
- If the same command or tool validation fails twice, diagnose it and change the command or arguments.
  Use Pi's structured tools directly; never print pseudo tool-call markup as ordinary text.
- Treat `submission/submission.csv` as a durable checkpoint. Validate it whenever a complete candidate
  is available, and preserve a valid existing submission while attempting later improvements.

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
