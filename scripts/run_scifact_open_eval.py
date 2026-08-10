"""Run the pinned SciFact-Open evaluator on a modern NumPy environment.

The upstream evaluator uses the removed ``numpy.int`` alias. Restoring that
alias at process startup keeps the author evaluator itself unchanged.
"""

import argparse
import contextlib
import io
import os
from pathlib import Path
import runpy

import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional path to save the evaluator's stdout.",
    )
    args = parser.parse_args()

    workspace = Path(__file__).resolve().parents[1]
    repository = workspace / "external" / "scifact-open"
    evaluator = repository / "script" / "run_eval.py"

    if not evaluator.is_file():
        raise FileNotFoundError(f"SciFact-Open evaluator not found: {evaluator}")

    # Compatibility only: do not edit or replace any evaluator logic.
    if not hasattr(np, "int"):
        np.int = int  # type: ignore[attr-defined]

    previous_directory = Path.cwd()
    captured = io.StringIO()
    try:
        os.chdir(repository)
        with contextlib.redirect_stdout(captured):
            runpy.run_path(str(evaluator), run_name="__main__")
    finally:
        os.chdir(previous_directory)

    output = captured.getvalue()
    print(output, end="")

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()

