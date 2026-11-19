# SPDX-License-Identifier: MPL-2.0
"""Failure-path tests; never access credentials or submit an app to Apple."""
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "notarize_release", Path(__file__).resolve().parents[1] / "notarize_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
SUBMISSION_ID = "51e3b8bf-9c8c-43ac-997b-b97c3f53af32"


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = {
            "schema": release.SCHEMA, "bundle_id": release.BUNDLE_ID,
            "phase": "prepared", "submission_id": None,
            "submission_sha256": "a" * 64,
            "metadata": {"version": "0.9.0", "build": "58", "notes": "RELEASE-NOTES-0.9.0.md"},
        }
        release.write_manifest(self.root, self.manifest)

    def archive(self, members):
        path = self.root / "source.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in members:
                archive.writestr(name, data)
        return path

    def submitted(self):
        self.manifest.update(phase="submitted", submission_id=SUBMISSION_ID)
        release.write_manifest(self.root, self.manifest)

    def result(self, data, returncode=0):
        return subprocess.CompletedProcess([], returncode, json.dumps(data), "")

    def test_archive_traversal_and_symlink_parent_are_rejected(self):
        for name in ("../outside", "/outside", "EmberPDF.app/../../outside", "..\\outside"):
            with self.subTest(name=name):
                with self.assertRaises(release.ReleaseError):
                    release.validate_archive(self.archive([(name, "payload")]))
        link = zipfile.ZipInfo("EmberPDF.app/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for members in (
            [(link, "../../outside")],
            [(link, "inside"), ("EmberPDF.app/link/payload", "payload")],
        ):
            with self.assertRaises(release.ReleaseError):
                release.validate_archive(self.archive(members))

    def test_payload_detects_file_mode_content_and_link_changes(self):
        stage = self.root / "stage"
        stage.mkdir()
        file = stage / "binary"
        file.write_bytes(b"original")
        original = release.payload_digest(stage)
        file.chmod(0o755)
        executable = release.payload_digest(stage)
        self.assertNotEqual(original, executable)
        file.write_bytes(b"changed")
        self.assertNotEqual(executable, release.payload_digest(stage))
        (stage / "link").symlink_to("../manifest.json")
        with self.assertRaises(release.ReleaseError):
            release.payload_digest(stage)

    def test_macos_path_aliases_cannot_overwrite_or_bypass_link_check(self):
        for first, second in (("File", "file"), ("caf\u00e9", "cafe\u0301")):
            with self.assertRaises(release.ReleaseError):
                release.validate_archive(self.archive([(first, "one"), (second, "two")]))
        link = zipfile.ZipInfo("EmberPDF.app/Link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(release.ReleaseError):
            release.validate_archive(self.archive([(link, "."), ("EmberPDF.app/link/file", "payload")]))

    def test_only_valid_developer_id_application_identity_is_selected(self):
        sha = "A" * 40
        name = "Developer ID Application: Test Person (ABC1234567)"
        output = f'  1) {sha} "{name}"\n  1 valid identities found\n'
        self.assertEqual(release.select_identity(output, sha.lower())["team"], "ABC1234567")
        for invalid in ("0 valid identities found", output.replace("Developer ID Application", "Apple Development"), output + output):
            with self.assertRaises(release.ReleaseError):
                release.select_identity(invalid, sha)

    def test_missing_identity_does_not_create_output_or_modify_archive(self):
        archive = self.archive([("EmberPDF.app/test", "payload")])
        original = archive.read_bytes()
        output = self.root / "new-release"
        with patch.object(release, "run_command", return_value=subprocess.CompletedProcess([], 0, "0 valid identities found", "")):
            with self.assertRaises(release.ReleaseError):
                release.prepare(archive, "A" * 40, output)
        self.assertFalse(output.exists())
        self.assertEqual(archive.read_bytes(), original)

    def test_submit_records_id_and_refuses_duplicate_upload(self):
        with patch.object(release, "verify_prepared"), patch.object(release, "run_command", return_value=self.result({"id": SUBMISSION_ID})) as command:
            self.assertEqual(release.submit(self.root, "test-profile"), 0)
            saved = release.load_manifest(self.root)
            self.assertEqual(saved["submission_id"], SUBMISSION_ID)
            with self.assertRaises(release.ReleaseError):
                release.submit(self.root, "test-profile")
            self.assertEqual(command.call_count, 1)
            args = command.call_args.args[0]
            self.assertIn("--no-wait", args)
            self.assertNotIn("--password", args)

    def test_timeout_preserves_partial_id_or_blocks_uncertain_retry(self):
        for output, expected in ((f'{{"id":"{SUBMISSION_ID}",', SUBMISSION_ID), (b"", None)):
            with self.subTest(output=output):
                release.write_manifest(self.root, self.manifest)
                timeout = subprocess.TimeoutExpired(["notarytool"], 55, output=output)
                with patch.object(release, "verify_prepared"), patch.object(release, "run_command", side_effect=timeout) as command:
                    with self.assertRaises(release.ReleaseError):
                        release.submit(self.root, "test-profile")
                    self.assertEqual(release.load_manifest(self.root)["submission_id"], expected)
                    with self.assertRaises(release.ReleaseError):
                        release.submit(self.root, "test-profile")
                    self.assertEqual(command.call_count, 1)

    def test_modified_payload_prevents_submission(self):
        with patch.object(release, "verify_prepared", side_effect=release.ReleaseError("changed")), patch.object(release, "run_command") as command:
            with self.assertRaises(release.ReleaseError):
                release.submit(self.root, "test-profile")
            command.assert_not_called()
        self.assertEqual(release.load_manifest(self.root)["phase"], "prepared")

    def test_pending_never_fetches_log_or_staples(self):
        self.submitted()
        with patch.object(release, "verify_prepared"), patch.object(release, "run_command", return_value=self.result({"id": SUBMISSION_ID, "status": "In Progress"})) as command, patch.object(release, "fetch_notary_log") as log:
            self.assertEqual(release.finish(self.root, "test-profile"), 3)
            self.assertEqual(command.call_count, 1)
            log.assert_not_called()
        self.assertFalse((self.root / "final").exists())

    def test_rejected_or_mismatched_log_never_creates_distribution(self):
        for status, log_status in (("Invalid", "Invalid"), ("Accepted", "Invalid")):
            self.submitted()
            with patch.object(release, "verify_prepared"), patch.object(release, "run_command", return_value=self.result({"id": SUBMISSION_ID, "status": status})) as command, patch.object(release, "fetch_notary_log", return_value={"status": log_status, "sha256": "a" * 64}):
                with self.assertRaises(release.ReleaseError):
                    release.finish(self.root, "test-profile")
                self.assertEqual(command.call_count, 1)
            self.assertEqual(release.load_manifest(self.root)["phase"], "rejected")
            self.assertFalse((self.root / "final").exists())

    def test_staple_failure_keeps_original_and_can_retry_without_resubmit(self):
        self.submitted()
        signed = self.root / "signed"
        (signed / release.APP_NAME).mkdir(parents=True)
        (signed / release.APP_NAME / "payload").write_text("original")
        original = release.payload_digest(signed)
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                with patch.object(release, "verify_prepared"), patch.object(release, "fetch_notary_log", return_value={"status": "Accepted", "sha256": "a" * 64}), patch.object(release, "run_command", side_effect=[self.result({"id": SUBMISSION_ID, "status": "Accepted"}), release.ReleaseError("staple failed")]):
                    with self.assertRaisesRegex(release.ReleaseError, "staple failed"):
                        release.finish(self.root, "test-profile")
                self.assertEqual(release.payload_digest(signed), original)
                self.assertFalse((self.root / "final").exists())
                self.assertEqual(list(self.root.glob("*.zip")), [])


if __name__ == "__main__":
    unittest.main()
