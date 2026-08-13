import importlib.util
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
EXPERIMENT_DIR = REPO_ROOT / "experiments" / "pi_qwen"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


experiment = load_module("pi_qwen_experiment", EXPERIMENT_DIR / "experiment.py")
submission_validator = load_module(
    "pi_qwen_submission_validator", EXPERIMENT_DIR / "validate_submission.py"
)


class PiQwenExperimentTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_manifest_fixes_six_candidates_and_three_modalities(self):
        manifest = experiment.load_manifest()
        self.assertEqual(len(manifest["candidates"]), 6)
        self.assertEqual(
            {candidate["modality"] for candidate in manifest["candidates"]},
            {"tabular", "text", "vision"},
        )
        self.assertAlmostEqual(
            sum(candidate["dataset_size_gb"] for candidate in manifest["candidates"]),
            2.1141,
        )
        self.assertEqual(manifest["pi"]["expected_version"], "0.84.1")
        self.assertEqual(manifest["pi"]["model"], "qwen3.6-27b")

    def test_task_prompt_keeps_baseline_policy_free_and_uses_at_file_contract(self):
        baseline = experiment.build_task_text("example", "baseline", 6, 42)
        policy = experiment.build_task_text(
            "example", "policy_v1", 6, 42, "- recurring validation clause"
        )
        self.assertNotIn("experiment ledger", baseline.lower())
        self.assertNotIn("policy v1", baseline.lower())
        self.assertIn("data/sample_submission.csv", baseline)
        self.assertIn("experiment ledger", policy.lower())
        self.assertIn("recurring validation clause", policy)

        runner = (EXPERIMENT_DIR / "run_case.ps1").read_text(encoding="utf-8")
        self.assertIn('"@task.md"', runner)
        self.assertIn('"--provider", $provider', runner)
        self.assertIn('"--model", $model', runner)
        self.assertIn('"--no-session"', runner)

    def make_fake_prepared_dataset(self, sample_in_private: bool = True):
        competition_id = "fake-competition"
        config_dir = self.temp / "repo" / "mlebench" / "competitions" / competition_id
        config_dir.mkdir(parents=True)
        location = "private" if sample_in_private else "public"
        config_dir.joinpath("config.yaml").write_text(
            "dataset:\n"
            f"  sample_submission: {competition_id}/prepared/{location}/sample_submission.csv\n",
            encoding="utf-8",
        )
        prepared = self.temp / "data" / competition_id / "prepared"
        public = prepared / "public"
        private = prepared / "private"
        public.mkdir(parents=True)
        private.mkdir(parents=True)
        public.joinpath("description.md").write_text("Task", encoding="utf-8")
        public.joinpath("train.csv").write_text("id,target\n1,0\n", encoding="utf-8")
        sample_dir = private if sample_in_private else public
        sample_dir.joinpath("sample_submission.csv").write_text(
            "id,target\n2,0\n", encoding="utf-8"
        )
        private.joinpath("answers.csv").write_text("id,target\n2,1\n", encoding="utf-8")
        return competition_id

    def test_workspace_copies_public_data_and_only_the_named_sample(self):
        competition_id = self.make_fake_prepared_dataset(sample_in_private=True)
        workspace = self.temp / "workspace"
        metadata = experiment.prepare_workspace(
            repo_root=self.temp / "repo",
            data_dir=self.temp / "data",
            workspace=workspace,
            competition_id=competition_id,
            variant="baseline",
            time_limit_hours=6,
            seed=42,
        )
        self.assertTrue((workspace / "data" / "train.csv").is_file())
        self.assertTrue((workspace / "data" / "sample_submission.csv").is_file())
        self.assertFalse((workspace / "data" / "answers.csv").exists())
        self.assertFalse((workspace / "data" / "private").exists())
        self.assertFalse(metadata["private_data_copied"])
        workspace_metadata = (workspace / "workspace.json").read_text(encoding="utf-8")
        private_source = str(
            (self.temp / "data" / competition_id / "prepared" / "private").resolve()
        )
        self.assertNotIn(private_source, workspace_metadata)

    def test_workspace_rejects_reparse_points(self):
        competition_id = self.make_fake_prepared_dataset(sample_in_private=False)
        public = self.temp / "data" / competition_id / "prepared" / "public"
        try:
            public.joinpath("outside-link").symlink_to(self.temp / "outside")
        except OSError:
            self.skipTest("symlinks are unavailable on this platform")
        with self.assertRaisesRegex(ValueError, "symlinks/reparse"):
            experiment.prepare_workspace(
                self.temp / "repo",
                self.temp / "data",
                self.temp / "workspace",
                competition_id,
                "baseline",
                6,
                42,
            )

    def test_public_submission_schema_validation(self):
        sample = self.temp / "sample.csv"
        valid = self.temp / "valid.csv"
        wrong_order = self.temp / "wrong.csv"
        sample.write_text("id,pred\na,0\nb,0\n", encoding="utf-8")
        valid.write_text("id,pred\na,0.1\nb,0.2\n", encoding="utf-8")
        wrong_order.write_text("id,pred\nb,0.2\na,0.1\n", encoding="utf-8")
        self.assertTrue(submission_validator.validate_submission(valid, sample)["valid"])
        result = submission_validator.validate_submission(wrong_order, sample)
        self.assertFalse(result["valid"])
        self.assertIn("ID/order mismatch", result["errors"][0])

    def test_trace_audit_checks_tool_access_not_message_or_written_prose(self):
        workspace = self.temp / "workspace"
        workspace.mkdir()
        trace = self.temp / "trace.jsonl"
        events = [
            {
                "type": "message_end",
                "message": {
                    "role": "assistant",
                    "provider": "lum-llm",
                    "model": "qwen3.6-27b",
                    "content": "Do not access private data",
                },
            },
            {
                "type": "tool_execution_start",
                "toolName": "write",
                "args": {"path": "code/notes.md", "content": "No private/grader access"},
            },
            {
                "type": "tool_execution_start",
                "toolName": "read",
                "args": {"path": str(workspace / "data.csv")},
            },
            {
                "type": "tool_execution_start",
                "toolName": "bash",
                "args": {"command": "python -m mlebench grade submission.csv"},
            },
            {
                "type": "tool_execution_start",
                "toolName": "read",
                "args": {"path": str(self.temp / "outside" / "answers.csv")},
            },
            {
                "type": "tool_execution_start",
                "toolName": "bash",
                "args": {"command": "curl https://kaggle.com/discussion/123"},
            },
            {
                "type": "tool_execution_start",
                "toolName": "bash",
                "args": {"command": "echo $ANTHROPIC_AUTH_TOKEN"},
            },
        ]
        trace.write_text("\n".join(json.dumps(event) for event in events), encoding="utf-8")
        audit = experiment.audit_trace(trace, workspace, "lum-llm", "qwen3.6-27b")
        self.assertFalse(audit["clean"])
        self.assertTrue(audit["model_identity"]["verified"])
        rules = {violation["rule"] for violation in audit["violations"]}
        self.assertEqual(
            rules,
            {
                "grader_access",
                "private_or_answer_access",
                "absolute_path_outside_workspace",
                "external_solution_access",
                "credential_access",
            },
        )
        self.assertEqual(audit["tool_call_count"], 6)
        wrong_identity = experiment.audit_trace(
            trace, workspace, "lum-llm", "qwen3.6-other"
        )
        self.assertFalse(wrong_identity["model_identity"]["verified"])
        self.assertIn(
            "model_identity_mismatch",
            {violation["rule"] for violation in wrong_identity["violations"]},
        )

    def test_metric_direction_and_bronze_gap_closure(self):
        higher_baseline = {
            "score": 0.6,
            "median_threshold": 0.5,
            "bronze_threshold": 0.8,
            "is_lower_better": False,
        }
        higher_policy = {"score": 0.7}
        lower_baseline = {
            "score": 0.9,
            "median_threshold": 1.0,
            "bronze_threshold": 0.5,
            "is_lower_better": True,
        }
        lower_policy = {"score": 0.7}
        self.assertAlmostEqual(
            experiment.policy_gap_closure(higher_baseline, higher_policy), 0.5
        )
        self.assertAlmostEqual(
            experiment.policy_gap_closure(lower_baseline, lower_policy), 0.5
        )
        self.assertAlmostEqual(experiment.normalized_progress_to_bronze(higher_baseline), 1 / 3)
        self.assertAlmostEqual(experiment.normalized_progress_to_bronze(lower_baseline), 0.2)

    def write_run(self, competition_id, modality, variant, score, issue_categories):
        run_dir = self.temp / "runs" / competition_id / variant / "001"
        run_dir.mkdir(parents=True)
        run = {
            "competition_id": competition_id,
            "variant": variant,
            "ended_at_utc": "2026-01-01T00:00:00Z",
            "timed_out": False,
            "integrity": {"clean": True},
            "grade": {
                "valid_submission": True,
                "score": score,
                "median_threshold": 0.5,
                "bronze_threshold": 0.8,
                "is_lower_better": False,
                "above_median": score > 0.5,
                "any_medal": score >= 0.8,
            },
        }
        experiment.write_json(run_dir / "run.json", run)
        review = {
            "schema_version": 1,
            "competition_id": competition_id,
            "high_level_direction_correct": True,
            "understood_target_metric_task": True,
            "non_trivial_model_trained": True,
            "environment_or_resource_failure": False,
            "serious_new_failure": False if variant == "policy_v1" else None,
            "fixable_issues": [
                {"category": category, "evidence": f"trace evidence for {category}"}
                for category in issue_categories
            ],
            "notes": modality,
        }
        experiment.write_json(run_dir / "review.json", review)

    def test_bad_case_selection_and_paired_report(self):
        manifest = experiment.load_manifest()
        for index, candidate in enumerate(manifest["candidates"]):
            issues = ["validation_design", "experiment_control"]
            if candidate["modality"] == "text":
                issues[1] = "error_analysis"
            if candidate["modality"] == "vision":
                issues[1] = "resource_management"
            self.write_run(
                candidate["competition_id"],
                candidate["modality"],
                "baseline",
                0.60 + index * 0.001,
                issues,
            )

        selection_path = self.temp / "runs" / "selection.json"
        selection = experiment.select_bad_cases(
            self.temp / "runs", experiment.DEFAULT_MANIFEST, selection_path
        )
        self.assertEqual(len(selection["selected"]), 3)
        self.assertEqual(
            {item["modality"] for item in selection["selected"]},
            {"tabular", "text", "vision"},
        )
        addendum = selection_path.with_name("policy_addendum.md").read_text(encoding="utf-8")
        self.assertIn("validation_design", addendum)
        self.assertNotIn("resource_management**", addendum)

        candidate_by_id = {
            candidate["competition_id"]: candidate for candidate in manifest["candidates"]
        }
        for item in selection["selected"]:
            candidate = candidate_by_id[item["competition_id"]]
            self.write_run(
                item["competition_id"],
                candidate["modality"],
                "policy_v1",
                0.70,
                [],
            )
        report_path = self.temp / "runs" / "report.md"
        report = experiment.render_report(
            self.temp / "runs", selection_path, report_path
        )
        self.assertIn("Six-case baseline overview", report)
        self.assertIn("Selected policy-v1 paired reruns", report)
        self.assertIn("Per-case mistake classification", report)
        self.assertIn("Suggested policy-v2 work", report)
        self.assertIn("Policy v1 preliminary result: **PROMISING**", report)

    def test_runner_contains_hard_process_tree_timeout(self):
        runner = (EXPERIMENT_DIR / "run_case.ps1").read_text(encoding="utf-8")
        process_control = (EXPERIMENT_DIR / "process_control.ps1").read_text(encoding="utf-8")
        suite = (EXPERIMENT_DIR / "run_suite.ps1").read_text(encoding="utf-8")
        self.assertIn("$TimeLimitHours * 3600.0", runner)
        self.assertIn("Wait-ExperimentProcess", runner)
        self.assertIn("$piShellCommand", runner)
        self.assertIn("-FilePath $env:ComSpec", runner)
        self.assertIn("1>\"", runner)
        self.assertIn("-WindowStyle Hidden", runner)
        self.assertIn("Set-ExperimentResourceLimits", runner)
        self.assertIn("MaxCpuThreads = 4", runner)
        self.assertIn("Wait-Process", process_control)
        self.assertIn("ProcessorAffinity", process_control)
        self.assertIn("BelowNormal", process_control)
        self.assertIn('"OMP_NUM_THREADS"', process_control)
        self.assertIn("taskkill.exe", process_control)
        self.assertIn('"/T", "/F"', process_control)
        self.assertIn("required before the six baselines", suite)
        self.assertIn("$competitionIds.Count -gt 3", suite)
        self.assertIn("reviewable_timeouts", suite)
        self.assertIn('$caseRun.status -eq "timed_out"', suite)
        self.assertIn("$caseRun.grade.valid_submission", suite)

    def test_setup_splits_modern_download_from_official_prepare_environment(self):
        setup = (EXPERIMENT_DIR / "setup_experiment.ps1").read_text(encoding="utf-8")
        self.assertIn('".venv-kaggle"', setup)
        self.assertIn('"kaggle==2.2.4"', setup)
        self.assertIn('"pandas==2.2.3"', setup)
        self.assertIn('"prepare-archive"', setup)
        self.assertIn("$KaggleExe", setup)
        self.assertIn("$VenvPython", setup)

    def test_preparation_normalizes_windows_csv_line_endings_only(self):
        public = self.temp / "public"
        private = self.temp / "private"
        public.mkdir()
        private.mkdir()
        csv_path = public / "train.csv"
        binary_path = private / "image.png"
        csv_path.write_bytes(b'id,text\r\n1,"two words"\r\n')
        binary_path.write_bytes(b"png\r\nbytes")

        experiment.normalize_csv_line_endings(public, private)

        self.assertEqual(csv_path.read_bytes(), b'id,text\n1,"two words"\n')
        self.assertEqual(binary_path.read_bytes(), b"png\r\nbytes")

    @unittest.skipUnless(os.name == "nt", "Windows process-tree integration test")
    def test_timeout_terminates_process_tree(self):
        child_pid_path = self.temp / "child.pid"
        parent_script = self.temp / "parent.ps1"
        parent_script.write_text(
            "$child = Start-Process powershell.exe -ArgumentList "
            "@('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru\n"
            "[IO.File]::WriteAllText($args[0], [string]$child.Id)\n"
            "Start-Sleep -Seconds 60\n",
            encoding="utf-8",
        )
        parent = subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(parent_script),
                str(child_pid_path),
            ]
        )
        try:
            for _ in range(50):
                if child_pid_path.is_file():
                    break
                time.sleep(0.1)
            self.assertTrue(child_pid_path.is_file())
            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            module_path = EXPERIMENT_DIR / "process_control.ps1"
            kill_log = self.temp / "kill.log"
            command = (
                f". '{module_path}'; "
                f"$p=Get-Process -Id {parent.pid}; "
                f"Wait-ExperimentProcess -Process $p -TimeoutSeconds 1 "
                f"-KillLogPath '{kill_log}' | ConvertTo-Json -Compress"
            )
            result = subprocess.run(
                ["powershell.exe", "-NoProfile", "-Command", command],
                capture_output=True,
                text=True,
                timeout=20,
                check=True,
            )
            wait_result = json.loads(result.stdout.strip())
            self.assertTrue(wait_result["timed_out"])
            child_check = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-Command",
                    f"if (Get-Process -Id {child_pid} -ErrorAction SilentlyContinue) "
                    "{ exit 1 } else { exit 0 }",
                ],
                timeout=10,
            )
            self.assertEqual(child_check.returncode, 0)
        finally:
            if parent.poll() is None:
                subprocess.run(
                    ["taskkill.exe", "/PID", str(parent.pid), "/T", "/F"],
                    capture_output=True,
                    timeout=10,
                )


if __name__ == "__main__":
    unittest.main()
