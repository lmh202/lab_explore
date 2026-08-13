"""Utilities for the Windows-hosted Pi/Qwen MLE-bench diagnostic experiment.

This module intentionally keeps workspace construction, trace auditing, bad-case
selection, and report generation independent from the heavyweight mlebench
dependencies. Only the ``grade`` subcommand imports the benchmark package.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import stat
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE / "candidates.json"
BASELINE_PROMPT = HERE / "prompts" / "baseline.md"
POLICY_PROMPT = HERE / "prompts" / "policy_v1.md"
VALIDATOR = HERE / "validate_submission.py"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(value, file, indent=2, ensure_ascii=False)
        file.write("\n")


def load_manifest(path: Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    manifest = load_json(path)
    candidates = manifest.get("candidates", [])
    ids = [item["competition_id"] for item in candidates]
    if len(ids) != len(set(ids)):
        raise ValueError("candidate competition IDs must be unique")
    if len(candidates) != 6:
        raise ValueError(f"expected exactly six candidate competitions, found {len(candidates)}")
    return manifest


def candidate_map(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["competition_id"]: item for item in manifest["candidates"]}


def is_lfs_pointer(path: Path) -> bool:
    if not path.is_file():
        return False
    with path.open("rb") as file:
        return file.read(80).startswith(b"version https://git-lfs.github.com/spec/v1")


def has_reparse_attribute(path: Path) -> bool:
    if path.is_symlink():
        return True
    attributes = getattr(path.stat(follow_symlinks=False), "st_file_attributes", 0)
    return bool(attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def scan_reparse_points(root: Path) -> list[str]:
    found: list[str] = []
    for current_root, directories, files in os.walk(root):
        for name in [*directories, *files]:
            path = Path(current_root) / name
            if has_reparse_attribute(path):
                found.append(str(path))
    return found


def parse_config_value(config_path: Path, key: str) -> str:
    pattern = re.compile(rf"^\s*{re.escape(key)}:\s*(.+?)\s*$")
    for line in config_path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1).strip("\"'")
    raise ValueError(f"{key!r} not found in {config_path}")


def configured_sample_path(repo_root: Path, competition_id: str) -> Path:
    config = repo_root / "mlebench" / "competitions" / competition_id / "config.yaml"
    return Path(parse_config_value(config, "sample_submission"))


def sample_source_path(repo_root: Path, data_dir: Path, competition_id: str) -> Path:
    configured = configured_sample_path(repo_root, competition_id)
    source = data_dir / configured
    prepared_root = data_dir / competition_id / "prepared"
    if not is_path_within(source, prepared_root):
        raise ValueError(f"sample submission is outside the prepared dataset: {source}")
    return source


def answer_source_path(repo_root: Path, data_dir: Path, competition_id: str) -> Path:
    config = repo_root / "mlebench" / "competitions" / competition_id / "config.yaml"
    configured = Path(parse_config_value(config, "answers"))
    source = data_dir / configured
    private_root = data_dir / competition_id / "prepared" / "private"
    if not is_path_within(source, private_root):
        raise ValueError(f"grader answers are outside prepared/private: {source}")
    return source


def build_task_text(
    competition_id: str,
    variant: str,
    time_limit_hours: float,
    seed: int,
    policy_addendum: str = "",
) -> str:
    if variant not in {"baseline", "policy_v1"}:
        raise ValueError(f"unsupported variant: {variant}")
    operational = BASELINE_PROMPT.read_text(encoding="utf-8").rstrip()
    sections = [
        operational,
        "",
        "# Run identity",
        "",
        f"- Competition: `{competition_id}`",
        f"- Variant: `{variant}`",
        f"- Random seed for all controllable ML libraries and splits: `{seed}`",
        f"- Hard wall-clock limit: `{time_limit_hours:g}` hours",
        "- Public sample submission: `data/sample_submission.csv`",
        "",
        "The final response should briefly identify the chosen solution, best local validation "
        "score, submission path, and remaining uncertainty. The files on disk are authoritative.",
    ]
    if variant == "policy_v1":
        sections.extend(["", POLICY_PROMPT.read_text(encoding="utf-8").rstrip()])
        if policy_addendum.strip():
            sections.extend(["", "# Policy v1 cross-case addendum", "", policy_addendum.strip()])
    return "\n".join(sections).rstrip() + "\n"


def prepare_workspace(
    repo_root: Path,
    data_dir: Path,
    workspace: Path,
    competition_id: str,
    variant: str,
    time_limit_hours: float,
    seed: int,
    policy_addendum_path: Path | None = None,
) -> dict[str, Any]:
    public_dir = data_dir / competition_id / "prepared" / "public"
    if not public_dir.is_dir():
        raise FileNotFoundError(
            f"prepared public dataset not found: {public_dir}; run mlebench prepare first"
        )
    if not (public_dir / "description.md").is_file():
        raise FileNotFoundError(f"competition description missing: {public_dir / 'description.md'}")
    reparse_points = scan_reparse_points(public_dir)
    if reparse_points:
        raise ValueError(
            "public data contains symlinks/reparse points; refusing a potentially leaky copy: "
            + ", ".join(reparse_points[:5])
        )
    if workspace.exists():
        raise FileExistsError(f"workspace already exists: {workspace}")

    sample_source = sample_source_path(repo_root, data_dir, competition_id)
    if not sample_source.is_file():
        raise FileNotFoundError(f"sample submission missing: {sample_source}")
    if has_reparse_attribute(sample_source):
        raise ValueError(f"sample submission is a symlink/reparse point: {sample_source}")

    data_target = workspace / "data"
    shutil.copytree(public_dir, data_target)
    copied_sample = data_target / "sample_submission.csv"
    public_sample = public_dir / "sample_submission.csv"
    if sample_source.resolve() != public_sample.resolve():
        shutil.copy2(sample_source, copied_sample)
    elif not copied_sample.is_file():
        raise FileNotFoundError(f"sample submission missing from copied data: {copied_sample}")
    for directory in (workspace / "code", workspace / "logs", workspace / "submission"):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(VALIDATOR, workspace / "validate_submission.py")

    addendum = ""
    if policy_addendum_path is not None:
        addendum = policy_addendum_path.read_text(encoding="utf-8")
    task = build_task_text(
        competition_id=competition_id,
        variant=variant,
        time_limit_hours=time_limit_hours,
        seed=seed,
        policy_addendum=addendum,
    )
    (workspace / "task.md").write_text(task, encoding="utf-8")

    metadata = {
        "schema_version": 1,
        "competition_id": competition_id,
        "variant": variant,
        "seed": seed,
        "time_limit_hours": time_limit_hours,
        "workspace": str(workspace.resolve()),
        "sample_submission": "data/sample_submission.csv",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "private_data_copied": False,
    }
    write_json(workspace / "workspace.json", metadata)
    return metadata


SENSITIVE_VALUE = re.compile(
    r"(?i)(api[_-]?key|auth[_-]?token|password|secret)(\s*[=:]\s*)([^\s\"']+)"
)


def redact(text: str) -> str:
    return SENSITIVE_VALUE.sub(r"\1\2<redacted>", text)


def iter_tool_calls(trace_path: Path) -> Iterable[tuple[int, str, Any]]:
    if not trace_path.is_file():
        return
    with trace_path.open("r", encoding="utf-8", errors="replace") as file:
        for line_number, line in enumerate(file, start=1):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "tool_execution_start":
                yield line_number, str(event.get("toolName", "")), event.get("args", {})


FORBIDDEN_RULES = {
    "private_or_answer_access": re.compile(
        r"(?i)\bprivate\b|answers?\.(csv|jsonl?|parquet)|"
        r"gold[_-]?submission|leaderboard\.csv|[\\/]\.kaggle([\\/]|$)"
    ),
    "grader_access": re.compile(
        r"(?i)\bgrader\b|\bmlebench(?:\.exe)?\s+grade|\bmlebench\.grade\b|"
        r"\bgrade-sample\b|grading[_-]?report|"
        r"mlebench[\\/]grade(?:_helpers)?\.py"
    ),
    "external_solution_access": re.compile(
        r"(?i)kaggle\.com[\\/](code|discussion)|top[_ -]?solutions?|"
        r"github\.com[^\s]*(kaggle|solution)|public\s+notebook"
    ),
    "parent_traversal": re.compile(
        r"(^|[\s\"'])\.\.(?:[\\/]|(?=[\s\"';&|]|$))"
    ),
    "outside_workspace_reference": re.compile(
        r"(?i)(^|[\s\"'=])(?:\$(?:HOME|USERPROFILE)\b|%USERPROFILE%|~[\\/])"
    ),
    "credential_access": re.compile(
        r"(?i)ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY|kaggle\.json|\bprintenv\b"
    ),
}

WINDOWS_ABSOLUTE_PATH = re.compile(r"(?i)(?<![\w])([a-z]:[\\/][^\s\"';&|]*)")


def path_values(value: Any, parent_key: str = "") -> Iterable[str]:
    if isinstance(value, dict):
        for key, child in value.items():
            yield from path_values(child, str(key))
    elif isinstance(value, list):
        for child in value:
            yield from path_values(child, parent_key)
    elif isinstance(value, str) and any(
        token in parent_key.lower() for token in ("path", "file", "directory", "cwd")
    ):
        yield value


def is_path_within(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root.resolve(strict=False))
        return True
    except ValueError:
        return False


def observed_model_identities(trace_path: Path) -> set[tuple[str, str]]:
    identities: set[tuple[str, str]] = set()
    if not trace_path.is_file():
        return identities
    with trace_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = event.get("message", {})
            if not isinstance(message, dict) or message.get("role") != "assistant":
                continue
            provider = message.get("provider")
            model = message.get("model")
            if provider and model:
                identities.add((str(provider), str(model)))
    return identities


def audit_trace(
    trace_path: Path,
    workspace: Path,
    expected_provider: str | None = None,
    expected_model: str | None = None,
) -> dict[str, Any]:
    violations: list[dict[str, Any]] = []
    tool_call_count = 0
    for line_number, tool_name, args in iter_tool_calls(trace_path):
        tool_call_count += 1
        if tool_name in {"read", "write", "edit"} and isinstance(args, dict):
            auditable_args: Any = {"path": args.get("path", "")}
        elif tool_name == "bash" and isinstance(args, dict):
            auditable_args = {"command": args.get("command", ""), "cwd": args.get("cwd", "")}
        else:
            auditable_args = args
        serialized = json.dumps(auditable_args, ensure_ascii=False, sort_keys=True)
        for rule_name, pattern in FORBIDDEN_RULES.items():
            match = pattern.search(serialized)
            if match:
                violations.append(
                    {
                        "line": line_number,
                        "tool": tool_name,
                        "rule": rule_name,
                        "match": redact(match.group(0))[:200],
                    }
                )
        for raw_path in path_values(args):
            candidate = Path(raw_path)
            if candidate.is_absolute() and not is_path_within(candidate, workspace):
                violations.append(
                    {
                        "line": line_number,
                        "tool": tool_name,
                        "rule": "absolute_path_outside_workspace",
                        "match": redact(raw_path)[:200],
                    }
                )
        if tool_name == "bash" and isinstance(args, dict):
            command = str(args.get("command", ""))
            workspace_text = str(workspace.resolve()).replace("\\", "/").lower().rstrip("/")
            for match in WINDOWS_ABSOLUTE_PATH.finditer(command):
                raw_path = match.group(1).rstrip(",)")
                normalized = raw_path.replace("\\", "/").lower().rstrip("/")
                if not (
                    normalized == workspace_text
                    or normalized.startswith(workspace_text + "/")
                ):
                    violations.append(
                        {
                            "line": line_number,
                            "tool": tool_name,
                            "rule": "absolute_path_outside_workspace",
                            "match": redact(raw_path)[:200],
                        }
                    )
    identities = observed_model_identities(trace_path)
    identity_verified = None
    if expected_provider is not None and expected_model is not None:
        expected = (expected_provider, expected_model)
        identity_verified = expected in identities and identities == {expected}
        if not identity_verified:
            observed = ", ".join(f"{provider}/{model}" for provider, model in sorted(identities))
            violations.append(
                {
                    "line": 0,
                    "tool": "host_audit",
                    "rule": "model_identity_mismatch",
                    "match": observed or "no assistant model identity found",
                }
            )
    deduplicated = []
    seen = set()
    for violation in violations:
        key = (violation["line"], violation["tool"], violation["rule"], violation["match"])
        if key not in seen:
            seen.add(key)
            deduplicated.append(violation)
    return {
        "schema_version": 1,
        "trace": str(trace_path),
        "tool_call_count": tool_call_count,
        "model_identity": {
            "expected_provider": expected_provider,
            "expected_model": expected_model,
            "observed": [
                {"provider": provider, "model": model}
                for provider, model in sorted(identities)
            ],
            "verified": identity_verified,
        },
        "clean": not deduplicated,
        "violations": deduplicated,
    }


def grade_submission(
    repo_root: Path,
    data_dir: Path,
    competition_id: str,
    submission: Path,
) -> dict[str, Any]:
    sys.path.insert(0, str(repo_root))
    try:
        from mlebench.grade import grade_csv
        from mlebench.registry import Registry

        registry = Registry(data_dir)
        competition = registry.get_competition(competition_id)
        report = grade_csv(submission, competition).to_dict()
        return {"ok": True, **report}
    except Exception as error:  # keep run finalization alive after a grader failure
        return {
            "ok": False,
            "competition_id": competition_id,
            "submission_path": str(submission),
            "valid_submission": False,
            "error_type": type(error).__name__,
            "error": str(error),
        }


def prepare_from_archive(
    repo_root: Path,
    data_dir: Path,
    competition_id: str,
    archive: Path,
    keep_raw: bool = False,
) -> dict[str, Any]:
    """Run the official preparer on an archive downloaded by a modern Kaggle CLI.

    MLE-bench 1.0 pins a legacy Kaggle client that cannot read current KGAT tokens. This wrapper
    changes only the download boundary: archive verification, extraction, the competition's
    official prepare function, and prepared-data checksum verification remain MLE-bench code.
    """

    sys.path.insert(0, str(repo_root))
    from mlebench.data import (
        create_prepared_dir,
        extract,
        generate_checksums,
        get_checksum,
        is_dataset_prepared,
        is_empty,
    )
    from mlebench.registry import Registry
    from mlebench.utils import get_diff, load_yaml

    registry = Registry(data_dir)
    competition = registry.get_competition(competition_id)
    if not archive.is_file() or archive.suffix.lower() != ".zip":
        raise FileNotFoundError(f"competition ZIP archive not found: {archive}")
    expected_checksums = load_yaml(competition.checksums)
    actual_zip_checksum = get_checksum(archive)
    if actual_zip_checksum != expected_checksums["zip"]:
        raise ValueError(
            f"ZIP checksum mismatch for {competition_id}: expected "
            f"{expected_checksums['zip']}, got {actual_zip_checksum}"
        )

    competition.raw_dir.mkdir(exist_ok=True, parents=True)
    create_prepared_dir(competition)
    if is_empty(competition.raw_dir):
        extract(archive, competition.raw_dir, recursive=False)
    if not is_dataset_prepared(competition):
        competition.prepare_fn(
            raw=competition.raw_dir,
            public=competition.public_dir,
            private=competition.private_dir,
        )
    (competition.public_dir / "description.md").write_text(
        competition.description, encoding="utf-8"
    )
    normalize_csv_line_endings(competition.public_dir, competition.private_dir)

    actual_checksums = {
        "zip": actual_zip_checksum,
        "public": generate_checksums(competition.public_dir),
        "private": generate_checksums(competition.private_dir),
    }
    if actual_checksums != expected_checksums:
        diff = get_diff(
            actual_checksums,
            expected_checksums,
            fromfile="actual_checksums",
            tofile="expected_checksums",
        )
        raise ValueError(f"prepared data checksums do not match for {competition_id}:\n{diff}")
    if not keep_raw and competition.raw_dir.exists():
        shutil.rmtree(competition.raw_dir)

    return {
        "competition_id": competition_id,
        "archive": str(archive.resolve()),
        "public": str(competition.public_dir.resolve()),
        "private": str(competition.private_dir.resolve()),
        "checksums_verified": True,
        "raw_kept": keep_raw,
    }


def normalize_csv_line_endings(*roots: Path) -> None:
    """Match the LF-delimited CSV artifacts used by MLE-bench checksums.

    Pandas delegates its default CSV line ending to the host platform, so running an official
    preparer on Windows emits CRLF bytes while the checked-in benchmark artifacts were generated
    with LF bytes. This is a byte-format normalization only; it does not alter rows or values.
    """

    for root in roots:
        for csv_path in root.rglob("*.csv"):
            temporary_path = csv_path.with_suffix(csv_path.suffix + ".lf.tmp")
            try:
                with csv_path.open("rb") as source, temporary_path.open("wb") as target:
                    for line in source:
                        if line.endswith(b"\r\n"):
                            line = line[:-2] + b"\n"
                        target.write(line)
                os.replace(temporary_path, csv_path)
            finally:
                temporary_path.unlink(missing_ok=True)


def oriented(value: float, lower_is_better: bool) -> float:
    return -float(value) if lower_is_better else float(value)


def normalized_progress_to_bronze(grade: dict[str, Any]) -> float:
    score = grade.get("score")
    median = grade.get("median_threshold")
    bronze = grade.get("bronze_threshold")
    if score is None or median is None or bronze is None:
        return 0.0
    lower = bool(grade.get("is_lower_better"))
    q_score = oriented(score, lower)
    q_median = oriented(median, lower)
    q_bronze = oriented(bronze, lower)
    denominator = q_bronze - q_median
    if denominator <= 0:
        return 1.0 if q_score >= q_median else 0.0
    return max(0.0, min(1.0, (q_score - q_median) / denominator))


def policy_gap_closure(
    baseline_grade: dict[str, Any], policy_grade: dict[str, Any]
) -> float | None:
    values = (
        baseline_grade.get("score"),
        policy_grade.get("score"),
        baseline_grade.get("bronze_threshold"),
    )
    if any(value is None for value in values):
        return None
    lower = bool(baseline_grade.get("is_lower_better"))
    baseline = oriented(float(values[0]), lower)
    policy = oriented(float(values[1]), lower)
    bronze = oriented(float(values[2]), lower)
    gap = bronze - baseline
    if gap <= 0:
        return 1.0 if policy >= baseline else float("-inf")
    return (policy - baseline) / gap


def load_run(run_json: Path) -> dict[str, Any]:
    run = load_json(run_json)
    run["_run_json"] = str(run_json.resolve())
    return run


def discover_runs(runs_dir: Path, variant: str | None = None) -> list[dict[str, Any]]:
    runs = []
    for path in runs_dir.glob("**/run.json"):
        run = load_run(path)
        if variant is None or run.get("variant") == variant:
            runs.append(run)
    return sorted(runs, key=lambda item: str(item.get("ended_at_utc", "")))


def review_path_for(run: dict[str, Any]) -> Path:
    return Path(run["_run_json"]).parent / "review.json"


def make_review_template(run: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "competition_id": run["competition_id"],
        "high_level_direction_correct": None,
        "understood_target_metric_task": None,
        "non_trivial_model_trained": None,
        "environment_or_resource_failure": None,
        "serious_new_failure": None,
        "fixable_issues": [],
        "notes": "",
    }


def validate_review(review: dict[str, Any], manifest: dict[str, Any]) -> list[str]:
    errors = []
    if review.get("high_level_direction_correct") is not True:
        errors.append("high_level_direction_correct must be true")
    if review.get("understood_target_metric_task") is not True:
        errors.append("understood_target_metric_task must be true")
    if review.get("non_trivial_model_trained") is not True:
        errors.append("non_trivial_model_trained must be true")
    if review.get("environment_or_resource_failure") is not False:
        errors.append("environment_or_resource_failure must be false")
    allowed = set(manifest["failure_categories"])
    issues = review.get("fixable_issues", [])
    unique_categories = set()
    for index, issue in enumerate(issues):
        category = issue.get("category")
        evidence = str(issue.get("evidence", "")).strip()
        if category not in allowed:
            errors.append(f"issue {index} has unsupported category {category!r}")
        else:
            unique_categories.add(category)
        if not evidence:
            errors.append(f"issue {index} needs trace/code evidence")
    if len(unique_categories) < 2:
        errors.append("at least two distinct fixable issue categories are required")
    return errors


def bad_case_assessment(
    run: dict[str, Any], review: dict[str, Any], manifest: dict[str, Any]
) -> dict[str, Any]:
    reasons = validate_review(review, manifest)
    integrity = run.get("integrity", {})
    grade = run.get("grade", {})
    if not integrity.get("clean", False):
        reasons.append("integrity audit failed")
    if not grade.get("valid_submission", False):
        reasons.append("submission is not valid")
    if grade.get("any_medal", False):
        reasons.append("submission already earns a medal (too easy)")
    if run.get("timed_out") and not grade.get("valid_submission", False):
        reasons.append("timed out without a valid fallback submission")

    issue_categories = sorted({issue["category"] for issue in review.get("fixable_issues", [])})
    progress = normalized_progress_to_bronze(grade)
    score = min(60, len(issue_categories) * 20)
    score += 20 if grade.get("above_median", False) else 0
    score += round(20 * progress, 3)
    return {
        "eligible": not reasons,
        "ineligibility_reasons": reasons,
        "actionability_score": score,
        "progress_median_to_bronze": progress,
        "issue_categories": issue_categories,
    }


def select_bad_cases(runs_dir: Path, manifest_path: Path, output: Path) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    candidates = candidate_map(manifest)
    latest_by_competition: dict[str, dict[str, Any]] = {}
    for run in discover_runs(runs_dir, variant="baseline"):
        competition_id = run.get("competition_id")
        if competition_id in candidates:
            latest_by_competition[competition_id] = run

    assessed = []
    for competition_id, candidate in candidates.items():
        run = latest_by_competition.get(competition_id)
        if run is None:
            assessed.append(
                {
                    "competition_id": competition_id,
                    "modality": candidate["modality"],
                    "eligible": False,
                    "ineligibility_reasons": ["baseline run.json not found"],
                }
            )
            continue
        review_path = review_path_for(run)
        if not review_path.is_file():
            write_json(review_path, make_review_template(run))
            assessment = {
                "eligible": False,
                "ineligibility_reasons": [f"complete manual review: {review_path}"],
                "actionability_score": 0,
                "issue_categories": [],
            }
        else:
            assessment = bad_case_assessment(run, load_json(review_path), manifest)
        assessed.append(
            {
                "competition_id": competition_id,
                "modality": candidate["modality"],
                "run_json": run["_run_json"],
                "review_json": str(review_path.resolve()),
                **assessment,
            }
        )

    eligible = sorted(
        (item for item in assessed if item.get("eligible")),
        key=lambda item: (-float(item["actionability_score"]), item["competition_id"]),
    )
    selected = []
    for modality in ("tabular", "text", "vision"):
        match = next((item for item in eligible if item["modality"] == modality), None)
        if match and match not in selected:
            selected.append(match)
    for item in eligible:
        if len(selected) >= 3:
            break
        if item not in selected:
            selected.append(item)

    result = {
        "schema_version": 1,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "selected": selected[:3],
        "assessed": assessed,
    }
    write_json(output, result)
    build_policy_addendum(result, manifest, output.with_name("policy_addendum.md"))
    return result


def build_policy_addendum(
    selection: dict[str, Any], manifest: dict[str, Any], output: Path
) -> str:
    counts: Counter[str] = Counter()
    for item in selection.get("selected", []):
        counts.update(set(item.get("issue_categories", [])))
    recurring = sorted(category for category, count in counts.items() if count >= 2)
    lines = [
        "Only the following clauses were added from failures recurring in at least two selected "
        "baseline cases:"
    ]
    if recurring:
        for category in recurring:
            clause = manifest["failure_categories"][category]["policy_clause"]
            lines.append(f"- **{category}**: {clause}")
    else:
        lines.append(
            "- No additional recurring-failure clause qualified; use the core policy only."
        )
    text = "\n".join(lines) + "\n"
    output.write_text(text, encoding="utf-8")
    return text


def latest_runs_by_competition(runs_dir: Path, variant: str) -> dict[str, dict[str, Any]]:
    result = {}
    for run in discover_runs(runs_dir, variant=variant):
        result[run["competition_id"]] = run
    return result


def review_summary(run: dict[str, Any] | None) -> tuple[set[str], bool | None]:
    if run is None:
        return set(), None
    path = review_path_for(run)
    if not path.is_file():
        return set(), None
    review = load_json(path)
    categories = {
        issue.get("category")
        for issue in review.get("fixable_issues", [])
        if issue.get("category")
    }
    return categories, review.get("serious_new_failure")


def policy_review_is_complete(run: dict[str, Any], manifest: dict[str, Any]) -> bool:
    path = review_path_for(run)
    if not path.is_file():
        return False
    review = load_json(path)
    if review.get("high_level_direction_correct") is not True:
        return False
    if review.get("understood_target_metric_task") is not True:
        return False
    if review.get("non_trivial_model_trained") is not True:
        return False
    if review.get("environment_or_resource_failure") is not False:
        return False
    if review.get("serious_new_failure") is not False:
        return False
    allowed = set(manifest["failure_categories"])
    return all(
        issue.get("category") in allowed and str(issue.get("evidence", "")).strip()
        for issue in review.get("fixable_issues", [])
    )


def render_report(
    runs_dir: Path,
    selection_path: Path,
    output: Path,
    manifest_path: Path = DEFAULT_MANIFEST,
) -> str:
    manifest = load_manifest(manifest_path)
    selection = load_json(selection_path)
    baselines = latest_runs_by_competition(runs_dir, "baseline")
    policies = latest_runs_by_competition(runs_dir, "policy_v1")
    assessment_by_id = {
        item["competition_id"]: item for item in selection.get("assessed", [])
    }

    baseline_rows = []
    for candidate in manifest["candidates"]:
        competition_id = candidate["competition_id"]
        baseline = baselines.get(competition_id)
        if baseline is None:
            baseline_rows.append(
                (
                    competition_id,
                    candidate["modality"],
                    "missing",
                    "-",
                    "-",
                    "NO",
                    "NO",
                    "NO",
                    "-",
                )
            )
            continue
        grade = baseline.get("grade", {})
        issues, _ = review_summary(baseline)
        baseline_rows.append(
            (
                competition_id,
                candidate["modality"],
                str(grade.get("score")),
                str(grade.get("median_threshold")),
                str(grade.get("bronze_threshold")),
                "YES" if grade.get("valid_submission") else "NO",
                "YES" if baseline.get("integrity", {}).get("clean") else "NO",
                "YES" if assessment_by_id.get(competition_id, {}).get("eligible") else "NO",
                ", ".join(sorted(issues)) or "-",
            )
        )

    paired_rows = []
    successes = 0
    all_policy_valid_and_clean = True
    all_policy_trace_acceptable = True
    remaining_issues: Counter[str] = Counter()
    for item in selection.get("selected", []):
        competition_id = item["competition_id"]
        baseline = baselines.get(competition_id)
        policy = policies.get(competition_id)
        if baseline is None or policy is None:
            paired_rows.append((competition_id, "missing", "missing", "-", "-", "NO"))
            all_policy_valid_and_clean = False
            all_policy_trace_acceptable = False
            continue

        baseline_grade = baseline.get("grade", {})
        policy_grade = policy.get("grade", {})
        closure = policy_gap_closure(baseline_grade, policy_grade)
        policy_ok = bool(policy_grade.get("valid_submission")) and bool(
            policy.get("integrity", {}).get("clean")
        )
        baseline_issues, _ = review_summary(baseline)
        policy_issues, _ = review_summary(policy)
        remaining_issues.update(policy_issues)
        fixed_issues = sorted(baseline_issues - policy_issues)
        trace_ok = bool(fixed_issues) and policy_review_is_complete(policy, manifest)
        score_ok = bool(policy_grade.get("any_medal")) or (
            closure is not None and closure >= 0.2
        )
        success = policy_ok and trace_ok and score_ok
        successes += int(success)
        all_policy_valid_and_clean &= policy_ok
        all_policy_trace_acceptable &= trace_ok
        closure_text = "-" if closure is None else f"{closure:.3f}"
        paired_rows.append(
            (
                competition_id,
                str(baseline_grade.get("score")),
                str(policy_grade.get("score")),
                closure_text,
                ", ".join(fixed_issues) or "-",
                "YES" if success else "NO",
            )
        )

    promising = (
        len(paired_rows) == 3
        and all_policy_valid_and_clean
        and all_policy_trace_acceptable
        and successes >= 2
    )
    lines = [
        "# Pi/Qwen MLE-bench bad-case and policy report",
        "",
        "## Six-case baseline overview",
        "",
        "| Competition | Modality | Score | Median | Bronze | Valid | Integrity | "
        "Eligible | Review issues |",
        "|---|---|---:|---:|---:|:---:|:---:|:---:|---|",
    ]
    lines.extend(
        f"| {c} | {m} | {s} | {median} | {bronze} | {valid} | {clean} | {eligible} | {issues} |"
        for c, m, s, median, bronze, valid, clean, eligible, issues in baseline_rows
    )
    lines.extend(
        [
            "",
            "## Selected policy-v1 paired reruns",
            "",
            "| Competition | Baseline score | Policy score | Bronze-gap closure | "
            "Fixed issues | Success |",
            "|---|---:|---:|---:|---|:---:|",
        ]
    )
    lines.extend(
        f"| {c} | {b} | {p} | {g} | {fixed} | {s} |"
        for c, b, p, g, fixed, s in paired_rows
    )
    lines.extend(["", "## Per-case mistake classification", ""])
    for item in selection.get("selected", []):
        competition_id = item["competition_id"]
        baseline_issues, _ = review_summary(baselines.get(competition_id))
        policy_issues, serious = review_summary(policies.get(competition_id))
        lines.append(
            f"- **{competition_id}**: baseline = "
            f"{', '.join(sorted(baseline_issues)) or 'unreviewed'}; policy = "
            f"{', '.join(sorted(policy_issues)) or 'none/unreviewed'}; "
            f"serious new failure = {serious}."
        )

    lines.extend(["", "## Suggested policy-v2 work", ""])
    repeated_remaining = sorted(
        category for category, count in remaining_issues.items() if count >= 2
    )
    if repeated_remaining:
        for category in repeated_remaining:
            clause = manifest["failure_categories"].get(category, {}).get(
                "policy_clause", "Review this recurring issue before defining a new clause."
            )
            lines.append(f"- **{category}** remains in at least two policy runs: {clause}")
    else:
        lines.append(
            "- No issue is yet documented as recurring in at least two policy runs; do not add a "
            "new generic clause until the policy traces are reviewed."
        )

    lines.extend(
        [
            "",
            f"Policy runs valid and integrity-clean: **{all_policy_valid_and_clean}**",
            f"Policy traces show a fixed issue and no serious replacement failure: "
            f"**{all_policy_trace_acceptable}**",
            f"Cases meeting score and trace rules: **{successes}/{len(paired_rows)}**",
            "Policy v1 preliminary result: "
            f"**{'PROMISING' if promising else 'NOT YET PROMISING'}**",
            "",
            "This is a one-seed Windows-host diagnostic and is not an official leaderboard claim.",
        ]
    )
    text = "\n".join(lines) + "\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    return text


def preflight(repo_root: Path, data_dir: Path, pi_exe: Path, manifest_path: Path) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    ids = [manifest["smoke"]["competition_id"], *candidate_map(manifest)]
    checks = []

    def add(name: str, ready: bool, detail: str) -> None:
        checks.append({"name": name, "ready": ready, "detail": detail})

    add("pi_executable", pi_exe.is_file(), str(pi_exe))
    add("python_3_11_plus", sys.version_info >= (3, 11), sys.version.split()[0])
    add(
        "mlebench_installed",
        importlib.util.find_spec("mlebench") is not None,
        "Python import mlebench",
    )
    for competition_id in ids:
        leaderboard = (
            repo_root / "mlebench" / "competitions" / competition_id / "leaderboard.csv"
        )
        add(
            f"leaderboard:{competition_id}",
            leaderboard.is_file() and not is_lfs_pointer(leaderboard),
            str(leaderboard),
        )
        public_dir = data_dir / competition_id / "prepared" / "public"
        private_dir = data_dir / competition_id / "prepared" / "private"
        add(f"public_data:{competition_id}", public_dir.is_dir(), str(public_dir))
        add(f"private_grading_data:{competition_id}", private_dir.is_dir(), str(private_dir))
        description = public_dir / "description.md"
        add(f"description:{competition_id}", description.is_file(), str(description))
        try:
            sample = sample_source_path(repo_root, data_dir, competition_id)
            add(f"sample_submission:{competition_id}", sample.is_file(), str(sample))
        except (FileNotFoundError, ValueError) as error:
            add(f"sample_submission:{competition_id}", False, str(error))
        try:
            answers = answer_source_path(repo_root, data_dir, competition_id)
            add(f"grader_answers:{competition_id}", answers.is_file(), str(answers))
        except (FileNotFoundError, ValueError) as error:
            add(f"grader_answers:{competition_id}", False, str(error))
    return {"ready": all(check["ready"] for check in checks), "checks": checks}


def command_prepare_workspace(args: argparse.Namespace) -> int:
    metadata = prepare_workspace(
        repo_root=args.repo_root,
        data_dir=args.data_dir,
        workspace=args.workspace,
        competition_id=args.competition_id,
        variant=args.variant,
        time_limit_hours=args.time_limit_hours,
        seed=args.seed,
        policy_addendum_path=args.policy_addendum,
    )
    print(json.dumps(metadata, indent=2, ensure_ascii=False))
    return 0


def command_audit(args: argparse.Namespace) -> int:
    result = audit_trace(
        args.trace,
        args.workspace,
        expected_provider=args.expected_provider,
        expected_model=args.expected_model,
    )
    write_json(args.output, result)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result["clean"] else 2


def command_grade(args: argparse.Namespace) -> int:
    result = grade_submission(
        args.repo_root, args.data_dir, args.competition_id, args.submission
    )
    write_json(args.output, result)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result.get("ok") else 2


def command_prepare_archive(args: argparse.Namespace) -> int:
    result = prepare_from_archive(
        repo_root=args.repo_root,
        data_dir=args.data_dir,
        competition_id=args.competition_id,
        archive=args.archive,
        keep_raw=args.keep_raw,
    )
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def command_review_templates(args: argparse.Namespace) -> int:
    created = []
    for run in discover_runs(args.runs_dir, variant=args.variant):
        path = review_path_for(run)
        if not path.exists():
            write_json(path, make_review_template(run))
            created.append(str(path))
    print(json.dumps({"created": created}, indent=2))
    return 0


def command_select(args: argparse.Namespace) -> int:
    result = select_bad_cases(args.runs_dir, args.manifest, args.output)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if len(result["selected"]) == 3 else 2


def command_report(args: argparse.Namespace) -> int:
    print(render_report(args.runs_dir, args.selection, args.output, args.manifest), end="")
    return 0


def command_preflight(args: argparse.Namespace) -> int:
    result = preflight(args.repo_root, args.data_dir, args.pi_exe, args.manifest)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result["ready"] else 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare-workspace")
    prepare_parser.add_argument("--repo-root", type=Path, required=True)
    prepare_parser.add_argument("--data-dir", type=Path, required=True)
    prepare_parser.add_argument("--workspace", type=Path, required=True)
    prepare_parser.add_argument("--competition-id", required=True)
    prepare_parser.add_argument("--variant", choices=("baseline", "policy_v1"), required=True)
    prepare_parser.add_argument("--time-limit-hours", type=float, required=True)
    prepare_parser.add_argument("--seed", type=int, default=42)
    prepare_parser.add_argument("--policy-addendum", type=Path)
    prepare_parser.set_defaults(function=command_prepare_workspace)

    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("--trace", type=Path, required=True)
    audit_parser.add_argument("--workspace", type=Path, required=True)
    audit_parser.add_argument("--output", type=Path, required=True)
    audit_parser.add_argument("--expected-provider")
    audit_parser.add_argument("--expected-model")
    audit_parser.set_defaults(function=command_audit)

    grade_parser = subparsers.add_parser("grade")
    grade_parser.add_argument("--repo-root", type=Path, required=True)
    grade_parser.add_argument("--data-dir", type=Path, required=True)
    grade_parser.add_argument("--competition-id", required=True)
    grade_parser.add_argument("--submission", type=Path, required=True)
    grade_parser.add_argument("--output", type=Path, required=True)
    grade_parser.set_defaults(function=command_grade)

    archive_parser = subparsers.add_parser("prepare-archive")
    archive_parser.add_argument("--repo-root", type=Path, required=True)
    archive_parser.add_argument("--data-dir", type=Path, required=True)
    archive_parser.add_argument("--competition-id", required=True)
    archive_parser.add_argument("--archive", type=Path, required=True)
    archive_parser.add_argument("--keep-raw", action="store_true")
    archive_parser.set_defaults(function=command_prepare_archive)

    review_parser = subparsers.add_parser("review-templates")
    review_parser.add_argument("--runs-dir", type=Path, required=True)
    review_parser.add_argument("--variant", choices=("baseline", "policy_v1"))
    review_parser.set_defaults(function=command_review_templates)

    select_parser = subparsers.add_parser("select")
    select_parser.add_argument("--runs-dir", type=Path, required=True)
    select_parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    select_parser.add_argument("--output", type=Path, required=True)
    select_parser.set_defaults(function=command_select)

    report_parser = subparsers.add_parser("report")
    report_parser.add_argument("--runs-dir", type=Path, required=True)
    report_parser.add_argument("--selection", type=Path, required=True)
    report_parser.add_argument("--output", type=Path, required=True)
    report_parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    report_parser.set_defaults(function=command_report)

    preflight_parser = subparsers.add_parser("preflight")
    preflight_parser.add_argument("--repo-root", type=Path, required=True)
    preflight_parser.add_argument("--data-dir", type=Path, required=True)
    preflight_parser.add_argument("--pi-exe", type=Path, required=True)
    preflight_parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    preflight_parser.set_defaults(function=command_preflight)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.function(args))


if __name__ == "__main__":
    raise SystemExit(main())
