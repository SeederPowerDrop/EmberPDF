#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Install a signed macOS app without replacing an app that is still running.

Close the destination app normally before running this tool. It never terminates
processes. The backup parent must already exist, on the destination filesystem,
so moving the old bundle and restoring it on failure are atomic renames.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata


class InstallError(Exception):
    pass


def run_command(arguments, timeout=30):
    try:
        return subprocess.run(arguments, check=True, capture_output=True,
                              text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise InstallError(f"Command failed: {arguments[0]}: {detail}") from error


def bundle_metadata(app):
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise InstallError(f"Cannot read app metadata: {app}") from error
    keys = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion",
            "CFBundleShortVersionString")
    if not isinstance(info, dict) or any(
        not isinstance(info.get(key), str) or not info[key].strip() for key in keys
    ):
        raise InstallError(f"Missing bundle identity, executable or version: {app}")
    executable_name = info["CFBundleExecutable"]
    if (executable_name in (".", "..") or "/" in executable_name
            or any(ord(char) < 32 for char in executable_name)):
        raise InstallError(f"Invalid bundle executable: {app}")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}(?:[dab][0-9]+|fc[0-9]+)?",
                        info["CFBundleVersion"]):
        raise InstallError(f"Invalid build version: {app}")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info["CFBundleShortVersionString"]):
        raise InstallError(f"Invalid release version: {app}")
    executable = app / "Contents/MacOS" / executable_name
    try:
        executable.resolve(strict=True).relative_to(app.resolve(strict=True))
    except (OSError, ValueError, RuntimeError) as error:
        raise InstallError(f"Executable must exist inside the app: {app}") from error
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise InstallError(f"Bundle executable is not executable: {executable}")
    return {key: info[key] for key in keys}


def executable_digest(app, metadata):
    digest = hashlib.sha256()
    with (app / "Contents/MacOS" / metadata["CFBundleExecutable"]).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_signature(app):
    run_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])


def canonical_path(path):
    # APFS is usually case-insensitive and accepts both Unicode normalizations.
    # Conservatively treating equivalent spellings as the same path is safe.
    try:
        return unicodedata.normalize("NFC", str(path.resolve())).casefold()
    except (OSError, RuntimeError) as error:
        raise InstallError(f"Cannot verify executable path: {path}") from error


def running_processes(apps, executable_name):
    """Read comm (executable path), never args, which may contain document paths."""
    output = run_command(["/bin/ps", "-ww", "-axo", "pid=,comm="])
    if not output.strip():
        raise InstallError("Cannot verify running apps: ps returned no processes.")
    prefixes = [canonical_path(app).rstrip("/") + "/" for app in apps]
    matches = []
    for line in output.splitlines():
        match = re.fullmatch(r"\s*([0-9]+)\s+(.+?)\s*", line)
        if not match or int(match.group(1)) < 1:
            raise InstallError("Cannot verify running apps: malformed ps output.")
        pid, command = int(match.group(1)), match.group(2)
        path = Path(command)
        if path.is_absolute():
            if any(canonical_path(path).startswith(prefix) for prefix in prefixes):
                matches.append(pid)
        elif path.name == executable_name:
            # Some processes only expose a short command name. Do not assume
            # such a process belongs to a different copy of the destination app.
            raise InstallError(
                f"Cannot verify executable location for {executable_name} (PID {pid}). "
                "Close the app normally and retry.")
    return matches


def require_stopped(apps, executable_name):
    pids = running_processes(apps, executable_name)
    if pids:
        raise InstallError(
            "Destination app is still running (PID " + ", ".join(map(str, pids))
            + "). Save your documents and quit the app normally before installing. "
            "No running app will be replaced.")


def validate_paths(source, target, backup):
    paths = [Path(value).expanduser().absolute() for value in (source, target, backup)]
    source, target, backup = paths
    for path in paths:
        if path.suffix != ".app":
            raise InstallError(f"App bundle paths must end in .app: {path}")
    # Replacing a symlink would replace the alias, not its app. Resolve aliases
    # for process detection but require explicit real paths for installation.
    if target.is_symlink():
        raise InstallError("Destination is a symlink; provide its real app path.")
    if os.path.lexists(backup):
        raise InstallError(f"Backup already exists: {backup}")
    resolved = [path.resolve() for path in paths]
    for index, first in enumerate(resolved):
        for second in resolved[index + 1:]:
            if first == second or first in second.parents or second in first.parents:
                raise InstallError("Source, destination and backup must be separate bundles.")
    if not source.is_dir() or not target.is_dir():
        raise InstallError("Both source and destination app bundles must exist.")
    if not backup.parent.is_dir():
        raise InstallError(f"Create the backup parent directory first: {backup.parent}")
    if target.parent.stat().st_dev != backup.parent.stat().st_dev:
        raise InstallError("Backup must be on the same filesystem as the destination.")
    return source, target, backup


def install(source, target, backup, check_only=False):
    source, target, backup = validate_paths(source, target, backup)
    source_info, target_info = bundle_metadata(source), bundle_metadata(target)
    if (source_info["CFBundleIdentifier"] != target_info["CFBundleIdentifier"]
            or source_info["CFBundleExecutable"] != target_info["CFBundleExecutable"]):
        raise InstallError("Source and destination bundle identities/executables do not match.")
    executable_name = target_info["CFBundleExecutable"]
    require_stopped([target], executable_name)
    verify_signature(source)
    expected = executable_digest(source, source_info)
    original = executable_digest(target, target_info)
    report = {"status": "checked" if check_only else "installed",
              "source": str(source), "target": str(target), "backup": str(backup),
              "version": source_info["CFBundleShortVersionString"],
              "build": source_info["CFBundleVersion"],
              "previousBuild": target_info["CFBundleVersion"], "sha256": expected}
    if check_only:
        return report

    staging = Path(tempfile.mkdtemp(prefix="." + target.stem + "-update-", dir=target.parent))
    staged = staging / target.name
    moved_old = False
    installed_new = False
    preserve_staging = False
    try:
        run_command(["/usr/bin/ditto", str(source), str(staged)], timeout=120)
        verify_signature(staged)
        if bundle_metadata(staged) != source_info or executable_digest(staged, source_info) != expected:
            raise InstallError("Staged app does not match the verified source.")
        # Staging/signature checks take time; a user may launch the app meanwhile.
        require_stopped([target], executable_name)
        if (bundle_metadata(target) != target_info
                or executable_digest(target, target_info) != original):
            raise InstallError("Destination changed during staging; installation cancelled.")
        if os.path.lexists(backup):
            raise InstallError(f"Backup appeared during staging: {backup}")
        target.rename(backup)
        moved_old = True
        # A last check narrows the launch race before the replacement is placed.
        require_stopped([target, backup], executable_name)
        staged.rename(target)
        installed_new = True
        verify_signature(target)
        if bundle_metadata(target) != source_info or executable_digest(target, source_info) != expected:
            raise InstallError("Installed app does not match the verified source.")
    except BaseException as error:
        if moved_old:
            try:
                if installed_new:
                    # Never replace an app launched during verification either.
                    require_stopped([target], executable_name)
                    target.rename(staging / "failed-install.app")
                backup.rename(target)
            except BaseException as rollback_error:
                preserve_staging = True
                raise InstallError(
                    f"Installation failed: {error}. Automatic restoration could not finish: "
                    f"{rollback_error}. Original app is preserved at {backup}; "
                    f"staging is preserved at {staging}.") from error
        raise
    finally:
        if not preserve_staging:
            shutil.rmtree(staging)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--backup", required=True, type=Path)
    parser.add_argument("--check-only", action="store_true",
                        help="Validate without staging or changing any bundle.")
    arguments = parser.parse_args(argv)
    try:
        result = install(arguments.source, arguments.target, arguments.backup, arguments.check_only)
    except (InstallError, OSError) as error:
        print(f"Installation refused: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
