"""Public-only submission shape validator used inside Pi workspaces."""

from __future__ import annotations

import argparse
import csv
import json
import re
from itertools import zip_longest
from pathlib import Path


def validate_submission(submission: Path, sample: Path) -> dict:
    result = {
        "valid": False,
        "submission": str(submission),
        "sample": str(sample),
        "rows": 0,
        "errors": [],
    }
    if not submission.is_file():
        result["errors"].append("submission file does not exist")
        return result
    if not sample.is_file():
        result["errors"].append("sample submission does not exist")
        return result

    with sample.open("r", encoding="utf-8-sig", newline="") as sample_file, submission.open(
        "r", encoding="utf-8-sig", newline=""
    ) as submission_file:
        sample_reader = csv.reader(sample_file)
        submission_reader = csv.reader(submission_file)
        sample_header = next(sample_reader, None)
        submission_header = next(submission_reader, None)

        if not sample_header or not submission_header:
            result["errors"].append("sample or submission is empty")
            return result
        if submission_header != sample_header:
            result["errors"].append(
                f"header mismatch: expected {sample_header!r}, got {submission_header!r}"
            )
            return result

        for row_number, pair in enumerate(
            zip_longest(sample_reader, submission_reader), start=2
        ):
            sample_row, submission_row = pair
            if sample_row is None or submission_row is None:
                result["errors"].append(f"row count differs at CSV row {row_number}")
                break
            if len(submission_row) != len(submission_header):
                result["errors"].append(
                    f"CSV row {row_number} has {len(submission_row)} columns; "
                    f"expected {len(submission_header)}"
                )
                break
            if submission_row[0] != sample_row[0]:
                result["errors"].append(
                    f"ID/order mismatch at CSV row {row_number}: "
                    f"expected {sample_row[0]!r}, got {submission_row[0]!r}"
                )
                break
            natural_questions_row = (
                submission_header == ["example_id", "PredictionString"]
                and sample_row[0].endswith(("_long", "_short"))
            )
            prediction = submission_row[1].strip() if len(submission_row) > 1 else ""
            if natural_questions_row:
                if prediction and not re.fullmatch(r"(?:\d+:\d+|YES|NO)", prediction):
                    result["errors"].append(
                        f"invalid Natural Questions prediction at CSV row {row_number}: "
                        "expected start_token:end_token, YES, NO, or blank"
                    )
                    break
            elif any(value.strip() == "" for value in submission_row[1:]):
                result["errors"].append(f"blank prediction at CSV row {row_number}")
                break
            result["rows"] += 1

    result["valid"] = not result["errors"]
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("submission", type=Path)
    parser.add_argument(
        "--sample", type=Path, default=Path("data/sample_submission.csv")
    )
    args = parser.parse_args()
    result = validate_submission(args.submission, args.sample)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
