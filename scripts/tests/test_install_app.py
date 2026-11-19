# SPDX-License-Identifier: MPL-2.0
"""Installer tests use synthetic bundles and never launch or replace real apps."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "install_app", Path(__file__).resolve().parents[1] / "install_app.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "build output" / "EmberPDF.app"
        self.target = self.root / "Applications" / "Ember PDF.app"
        self.backup = self.root / "backup.app"
        self.make_bundle(self.source, "52", b"new app")
        self.make_bundle(self.target, "51", b"old app")
        self.ps_output = "    1 /sbin/launchd\n   42 /usr/bin/python3\n"
        self.command_patch = patch.object(installer, "run_command", side_effect=self.command)
        self.mock_command = self.command_patch.start()
        self.addCleanup(self.command_patch.stop)
        self.addCleanup(self.temporary.cleanup)

    def make_bundle(self, path, build, executable):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.emberpdf.app",
            "CFBundleExecutable": "EmberPDF",
            "CFBundleVersion": build,
            "CFBundleShortVersionString": "0.9.0"}))
        binary = path / "Contents/MacOS/EmberPDF"
        binary.write_bytes(executable)
        binary.chmod(0o755)

    def command(self, arguments, timeout=30):
        if arguments[0] == "/bin/ps":
            return self.ps_output
        if arguments[0] == "/usr/bin/ditto":
            shutil.copytree(arguments[1], arguments[2])
        return ""

    def install(self, **kwargs):
        return installer.install(self.source, self.target, self.backup, **kwargs)

    def original_intact(self):
        self.assertEqual((self.target / "Contents/MacOS/EmberPDF").read_bytes(), b"old app")
        self.assertFalse(self.backup.exists())
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_running_app_with_spaces_leaves_every_file_unchanged(self):
        self.ps_output += f"12529 {self.target}/Contents/MacOS/EmberPDF\n"
        with self.assertRaisesRegex(installer.InstallError, "still running"):
            self.install()
        self.original_intact()
        self.assertEqual(self.mock_command.call_count, 1)

    def test_running_helper_inside_bundle_blocks_install(self):
        self.ps_output += f"100 {self.target}/Contents/XPCServices/helper\n"
        with self.assertRaisesRegex(installer.InstallError, "still running"):
            self.install()
        self.original_intact()

    def test_running_via_symlink_is_detected(self):
        alias = self.root / "alias.app"
        alias.symlink_to(self.target, target_is_directory=True)
        self.ps_output += f"100 {alias}/Contents/MacOS/EmberPDF\n"
        with self.assertRaisesRegex(installer.InstallError, "still running"):
            self.install()
        self.original_intact()

    def test_similar_app_name_does_not_block_install(self):
        self.ps_output += f"100 {self.target}.other/Contents/MacOS/EmberPDF\n"
        self.install(check_only=True)
        self.original_intact()

    def test_ps_failure_is_fail_closed(self):
        self.mock_command.side_effect = installer.InstallError("ps unavailable")
        with self.assertRaisesRegex(installer.InstallError, "ps unavailable"):
            self.install()
        self.original_intact()

    def test_empty_malformed_or_short_app_process_is_fail_closed(self):
        for output in ("", "not a process\n", "12 EmberPDF\n"):
            with self.subTest(output=output):
                self.ps_output = output
                with self.assertRaises(installer.InstallError):
                    self.install()
                self.original_intact()

    def test_bundle_identity_mismatch_is_rejected(self):
        plist = self.source / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleIdentifier"] = "another.app"
        plist.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(installer.InstallError, "do not match"):
            self.install()
        self.original_intact()

    def test_missing_version_or_escaping_executable_is_rejected(self):
        plist = self.source / "Contents/Info.plist"
        original = plistlib.loads(plist.read_bytes())
        for value in ({**original, "CFBundleVersion": ""},
                      {**original, "CFBundleShortVersionString": "not a version"},
                      {**original, "CFBundleExecutable": "../elsewhere"}):
            with self.subTest(value=value):
                plist.write_bytes(plistlib.dumps(value))
                with self.assertRaises(installer.InstallError):
                    self.install()
                self.original_intact()

    def test_existing_backup_or_same_bundle_is_rejected(self):
        self.backup.mkdir()
        with self.assertRaisesRegex(installer.InstallError, "Backup already exists"):
            self.install()
        self.backup.rmdir()
        with self.assertRaisesRegex(installer.InstallError, "separate bundles"):
            installer.install(self.target, self.target, self.backup)
        self.original_intact()

    def test_check_only_does_not_copy_or_change_files(self):
        report = self.install(check_only=True)
        self.assertEqual(report["status"], "checked")
        self.original_intact()
        self.assertFalse(any(call.args[0][0] == "/usr/bin/ditto"
                             for call in self.mock_command.call_args_list))

    def test_success_keeps_backup_and_verifies_all_three_copies(self):
        report = self.install()
        self.assertEqual(report["build"], "52")
        self.assertEqual((self.target / "Contents/MacOS/EmberPDF").read_bytes(), b"new app")
        self.assertEqual((self.backup / "Contents/MacOS/EmberPDF").read_bytes(), b"old app")
        signatures = [call for call in self.mock_command.call_args_list
                      if call.args[0][0] == "/usr/bin/codesign"]
        self.assertEqual(len(signatures), 3)
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_app_launched_during_staging_leaves_original_intact(self):
        def launch_during_copy(arguments, timeout=30):
            result = self.command(arguments, timeout)
            if arguments[0] == "/usr/bin/ditto":
                self.ps_output += f"100 {self.target}/Contents/MacOS/EmberPDF\n"
            return result
        self.mock_command.side_effect = launch_during_copy
        with self.assertRaisesRegex(installer.InstallError, "still running"):
            self.install()
        self.original_intact()

    def test_staging_signature_failure_leaves_original_intact(self):
        def fail_staged_signature(arguments, timeout=30):
            if arguments[0] == "/usr/bin/codesign" and Path(arguments[-1]) != self.source:
                raise installer.InstallError("invalid staged signature")
            return self.command(arguments, timeout)
        self.mock_command.side_effect = fail_staged_signature
        with self.assertRaisesRegex(installer.InstallError, "invalid staged signature"):
            self.install()
        self.original_intact()

    def test_installed_signature_failure_restores_original(self):
        def fail_installed_signature(arguments, timeout=30):
            if arguments[0] == "/usr/bin/codesign" and Path(arguments[-1]) == self.target:
                raise installer.InstallError("invalid installed signature")
            return self.command(arguments, timeout)
        self.mock_command.side_effect = fail_installed_signature
        with self.assertRaisesRegex(installer.InstallError, "invalid installed signature"):
            self.install()
        self.original_intact()

    def test_staged_hash_mismatch_leaves_original_intact(self):
        def corrupt_copy(arguments, timeout=30):
            result = self.command(arguments, timeout)
            if arguments[0] == "/usr/bin/ditto":
                (Path(arguments[2]) / "Contents/MacOS/EmberPDF").write_bytes(b"corrupt")
            return result
        self.mock_command.side_effect = corrupt_copy
        with self.assertRaisesRegex(installer.InstallError, "does not match"):
            self.install()
        self.original_intact()


class CommandTests(unittest.TestCase):
    def test_subprocess_failure_is_wrapped(self):
        with patch.object(installer.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "ps")):
            with self.assertRaises(installer.InstallError):
                installer.run_command(["/bin/ps"])


if __name__ == "__main__":
    unittest.main()
