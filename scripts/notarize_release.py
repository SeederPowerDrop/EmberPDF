#!/usr/bin/env python3
"""Sign and notarize an EmberPDF release without altering its source archive.

The signed staging tree and submitted ZIP stay immutable. Finalization always
copies that tree before stapling, so it can safely restart after an interruption.
Credentials are read by notarytool from an existing Keychain profile only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid
import zipfile


APP_NAME = "EmberPDF.app"
BUNDLE_ID = "com.vibepdf.mac"
APP_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.network.client": True,
}
WORKER_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.inherit": True,
}
CODE_ITEMS = (
    ("Contents/Frameworks/CPDFium.framework", "org.emberpdf.CPDFium", {}, False),
    ("Contents/Helpers/EmberPluginWorker", BUNDLE_ID + ".EmberPluginWorker", WORKER_ENTITLEMENTS, True),
    ("", BUNDLE_ID, APP_ENTITLEMENTS, True),
)
MACHO_FILES = {
    "Contents/MacOS/EmberPDF",
    "Contents/Helpers/EmberPluginWorker",
    "Contents/Frameworks/CPDFium.framework/CPDFium",
}
MACHO_MAGIC = {
    bytes.fromhex(value)
    for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
}
SCHEMA = 1
TIMEOUT = 55


class ReleaseError(RuntimeError):
    pass


def run_command(arguments: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=TIMEOUT, check=False)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()[-2000:]
        raise ReleaseError(f"{Path(arguments[0]).name} failed ({result.returncode}): {detail}")
    return result


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload_digest(root: Path) -> str:
    """Hash every directory, regular file, mode, and literal symlink target."""
    if not root.is_dir() or root.is_symlink():
        raise ReleaseError(f"Expected a real directory: {root.name}")
    records = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            target = os.readlink(path)
            try:
                path.resolve(strict=True).relative_to(root.resolve())
            except (ValueError, OSError, RuntimeError) as error:
                raise ReleaseError(f"Symlink escapes or is broken: {relative}") from error
            record = [relative, "symlink", target]
        elif stat.S_ISREG(mode):
            record = [relative, "file", stat.S_IMODE(mode), file_sha256(path)]
        elif stat.S_ISDIR(mode):
            record = [relative, "directory", stat.S_IMODE(mode)]
        else:
            raise ReleaseError(f"Unsupported filesystem object: {relative}")
        records.append(record)
    return hashlib.sha256(json.dumps(records, ensure_ascii=True, separators=(",", ":")).encode()).hexdigest()


def validate_archive(archive: Path) -> None:
    """Reject path traversal, special files, and extraction through symlinks."""
    entries: dict[str, tuple[zipfile.ZipInfo, int]] = {}
    aliases: dict[str, tuple[zipfile.ZipInfo, int]] = {}

    def filesystem_key(name: str) -> str:
        # Default macOS volumes equate case and Unicode-normalization aliases.
        return unicodedata.normalize("NFD", name).casefold()

    with zipfile.ZipFile(archive) as package:
        members = package.infolist()
        if not members or len(members) > 50000 or sum(item.file_size for item in members) > 2 * 1024**3:
            raise ReleaseError("Archive is empty or exceeds the release size limits")
        for member in members:
            name = member.filename
            path = PurePosixPath(name)
            if not name or "\\" in name or "\x00" in name or path.is_absolute() or ".." in path.parts:
                raise ReleaseError("Archive contains an unsafe path")
            normalized = path.as_posix()
            key = filesystem_key(normalized)
            if normalized in ("", ".") or key in aliases:
                raise ReleaseError("Archive contains a duplicate or empty path")
            if path.parts[0] == "__MACOSX" or any(part.startswith("._") for part in path.parts):
                raise ReleaseError("Archive contains unexpected AppleDouble metadata")
            kind = stat.S_IFMT(member.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise ReleaseError("Archive contains a special filesystem object")
            if member.flag_bits & 1:
                raise ReleaseError("Encrypted archives are not supported")
            entries[normalized] = (member, kind)
            aliases[key] = (member, kind)
        for name, (member, kind) in entries.items():
            path = PurePosixPath(name)
            for parent in path.parents:
                parent_entry = aliases.get(filesystem_key(str(parent)))
                if parent_entry and parent_entry[1] == stat.S_IFLNK:
                    raise ReleaseError("Archive attempts to extract through a symlink")
            if kind == stat.S_IFLNK:
                if member.file_size > 4096:
                    raise ReleaseError("Archive symlink target is too long")
                target = package.read(member).decode("utf-8", errors="strict")
                # EmberPDF's bundle does not need parent-relative links. Reject
                # them before ditto runs: combining '..' with another symlink
                # can escape even when a purely lexical path looks contained.
                if not target or "\\" in target or "\x00" in target or PurePosixPath(target).is_absolute() or ".." in PurePosixPath(target).parts:
                    raise ReleaseError("Archive contains an unsafe symlink")
                stack = list(path.parent.parts)
                for part in PurePosixPath(target).parts:
                    if part == "..":
                        if not stack:
                            raise ReleaseError("Archive symlink escapes the extraction directory")
                        stack.pop()
                    elif part != ".":
                        stack.append(part)
                if not stack or stack[0] != APP_NAME:
                    raise ReleaseError("Archive symlink must remain inside the app")
        bad_member = package.testzip()
        if bad_member is not None:
            raise ReleaseError("Archive CRC verification failed")


def extract_archive(archive: Path, destination: Path) -> None:
    validate_archive(archive)
    destination.mkdir()
    run_command(["/usr/bin/ditto", "-x", "-k", "--norsrc", "--noextattr", str(archive), str(destination)])


def inspect_layout(stage: Path) -> dict:
    app = stage / APP_NAME
    if not app.is_dir() or app.is_symlink():
        raise ReleaseError("The archive must contain EmberPDF.app")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise ReleaseError("Unexpected app version")
    if not isinstance(build, str) or not re.fullmatch(r"[0-9]+", build):
        raise ReleaseError("Unexpected app build number")
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "EmberPDF":
        raise ReleaseError("The source app identifier or executable does not match EmberPDF")
    notes = f"RELEASE-NOTES-{version}.md"
    expected = {APP_NAME, "INSTALL-macOS.txt", notes}
    if {entry.name for entry in stage.iterdir()} != expected:
        raise ReleaseError("Expected exactly the app, installation guide, and matching release notes")
    for name in expected - {APP_NAME}:
        if not (stage / name).is_file() or (stage / name).is_symlink():
            raise ReleaseError("Release documents must be regular files")
    # Checking literal link targets also ensures that code inspection stays in the app.
    payload_digest(app)
    found = set()
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    found.add(path.relative_to(app).as_posix())
    if found != MACHO_FILES:
        raise ReleaseError("Unexpected or missing native executable in the app bundle")
    for relative in ("Contents/MacOS/EmberPDF", "Contents/Helpers/EmberPluginWorker"):
        if not os.access(app / relative, os.X_OK):
            raise ReleaseError("App or worker executable permission is missing")
        architectures = run_command(["/usr/bin/lipo", "-archs", str(app / relative)]).stdout.split()
        if architectures != ["arm64"]:
            raise ReleaseError("This release workflow expects the arm64 app and worker")
    return {"version": version, "build": build, "notes": notes}


def read_entitlements(path: Path) -> dict:
    result = run_command(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)])
    return plistlib.loads(result.stdout.encode()) if result.stdout.strip() else {}


def select_identity(output: str, requested: str) -> dict:
    identities = []
    for line in output.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(Developer ID Application: .* \(([A-Z0-9]{10})\))"\s*', line)
        if match:
            identities.append({"sha1": match[1].upper(), "name": match[2], "team": match[3]})
    matches = [item for item in identities if requested.upper() == item["sha1"] or requested == item["name"]]
    if len(matches) != 1:
        raise ReleaseError("Specify exactly one valid Developer ID Application identity by SHA-1 or full name")
    return matches[0]


def verify_signature(app: Path, *, identity: dict | None = None, expected_hashes: dict | None = None) -> dict:
    run_command(["/usr/bin/codesign", "--verify", "--all-architectures", "--deep", "--strict", str(app)])
    hashes = {}
    for relative, identifier, entitlements, hardened in CODE_ITEMS:
        path = app / relative if relative else app
        run_command(["/usr/bin/codesign", "--verify", "--all-architectures", "--strict", str(path)])
        if read_entitlements(path) != entitlements:
            raise ReleaseError(f"Unexpected entitlements on {relative or APP_NAME}")
        if identity is None:
            continue
        executable = path / "CPDFium" if relative.endswith(".framework") else app / "Contents/MacOS/EmberPDF" if not relative else path
        architectures = run_command(["/usr/bin/lipo", "-archs", str(executable)]).stdout.split()
        for architecture in architectures:
            result = run_command(["/usr/bin/codesign", "-d", "--verbose=4", "--arch", architecture, str(path)])
            details = result.stderr + result.stdout
            fields = {}
            for line in details.splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    fields.setdefault(key, value)
            if fields.get("Identifier") != identifier or fields.get("TeamIdentifier") != identity["team"]:
                raise ReleaseError("Code signing identifier or team does not match")
            if fields.get("Authority") != identity["name"] or not fields.get("Timestamp"):
                raise ReleaseError("Developer ID authority or secure timestamp is missing")
            if "adhoc" in fields.get("CodeDirectory", "") or "Signature=adhoc" in details:
                raise ReleaseError("An ad-hoc signature remains in the release")
            if hardened and "runtime" not in fields.get("CodeDirectory", ""):
                raise ReleaseError("Hardened Runtime is missing from an executable")
            cdhash = fields.get("CDHash", "")
            if not re.fullmatch(r"[0-9a-fA-F]{40}", cdhash):
                raise ReleaseError("Missing code directory hash")
            hashes[f"{relative or APP_NAME}:{architecture}"] = cdhash.lower()
    if expected_hashes is not None and hashes != expected_hashes:
        raise ReleaseError("Signed code changed after preparation")
    return hashes


def write_manifest(directory: Path, manifest: dict) -> None:
    temporary = directory / "manifest.json.tmp"
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, ensure_ascii=True, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, directory / "manifest.json")


def load_manifest(directory: Path) -> dict:
    if not directory.is_dir() or directory.is_symlink():
        raise ReleaseError("Expected the prepared release directory")
    with (directory / "manifest.json").open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("schema") != SCHEMA or manifest.get("bundle_id") != BUNDLE_ID:
        raise ReleaseError("Unsupported release manifest")
    return manifest


def verify_prepared(directory: Path, manifest: dict) -> None:
    stage = directory / "signed"
    metadata = inspect_layout(stage)
    if metadata != manifest["metadata"]:
        raise ReleaseError("Prepared release metadata changed")
    if payload_digest(stage / APP_NAME) != manifest["signed_app_digest"] or payload_digest(stage) != manifest["signed_stage_digest"]:
        raise ReleaseError("Prepared release contents changed")
    if file_sha256(directory / "submission.zip") != manifest["submission_sha256"]:
        raise ReleaseError("The submitted archive changed")
    verify_signature(stage / APP_NAME, identity=manifest["identity"], expected_hashes=manifest["code_hashes"])


def create_archive(stage: Path, archive: Path) -> None:
    run_command(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", str(stage), str(archive)])
    validate_archive(archive)


def prepare(archive: Path, identity_name: str, directory: Path) -> int:
    if os.path.lexists(directory):
        raise ReleaseError("The output directory already exists; choose a new directory")
    if not archive.is_file():
        raise ReleaseError("The source archive does not exist")
    validate_archive(archive)
    identity = select_identity(run_command(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).stdout, identity_name)
    directory.mkdir(parents=True, exist_ok=False)
    stage = directory / "signed"
    extract_archive(archive, stage)
    metadata = inspect_layout(stage)
    verify_signature(stage / APP_NAME)
    with tempfile.TemporaryDirectory(prefix=".entitlements-", dir=directory) as scratch:
        for index, (relative, identifier, entitlements, hardened) in enumerate(CODE_ITEMS):
            path = stage / APP_NAME / relative if relative else stage / APP_NAME
            arguments = ["/usr/bin/codesign", "--force", "--sign", identity["sha1"], "--timestamp", "--identifier", identifier]
            if hardened:
                arguments += ["--options", "runtime"]
            if entitlements:
                entitlement_file = Path(scratch) / f"{index}.plist"
                entitlement_file.write_bytes(plistlib.dumps(entitlements))
                arguments += ["--entitlements", str(entitlement_file)]
            arguments.append(str(path))
            run_command(arguments)
    hashes = verify_signature(stage / APP_NAME, identity=identity)
    submission = directory / "submission.zip"
    create_archive(stage, submission)
    with tempfile.TemporaryDirectory(prefix=".verify-", dir=directory) as scratch:
        extracted = Path(scratch) / "contents"
        extract_archive(submission, extracted)
        if payload_digest(extracted) != payload_digest(stage):
            raise ReleaseError("Submission ZIP did not preserve the signed release")
        verify_signature(extracted / APP_NAME, identity=identity, expected_hashes=hashes)
    manifest = {
        "schema": SCHEMA,
        "bundle_id": BUNDLE_ID,
        "phase": "prepared",
        "metadata": metadata,
        "identity": identity,
        "source_archive_sha256": file_sha256(archive),
        "signed_app_digest": payload_digest(stage / APP_NAME),
        "signed_stage_digest": payload_digest(stage),
        "submission_sha256": file_sha256(submission),
        "code_hashes": hashes,
        "submission_id": None,
    }
    write_manifest(directory, manifest)
    print(f"Prepared Developer ID release {metadata['version']} ({metadata['build']}). Not submitted or notarized yet.")
    print(f"Release directory: {directory}")
    return 0


def submission_id_from_output(output: str | bytes | None) -> str | None:
    text = output.decode("utf-8", errors="replace") if isinstance(output, bytes) else output or ""
    # A timeout can leave incomplete JSON; preserve an already-issued ID anyway.
    match = re.search(r'"id"\s*:\s*"([0-9a-fA-F-]{36})"', text)
    if match:
        try:
            return str(uuid.UUID(match[1]))
        except ValueError:
            pass
    return None


def submit(directory: Path, profile: str) -> int:
    manifest = load_manifest(directory)
    if manifest.get("submission_id") or manifest.get("phase") != "prepared":
        raise ReleaseError("Submission already exists or was attempted. Refusing a duplicate upload; inspect the manifest and Apple submission history.")
    verify_prepared(directory, manifest)
    manifest["phase"] = "submission-started"
    write_manifest(directory, manifest)
    try:
        result = run_command([
            "/usr/bin/xcrun", "notarytool", "submit", str(directory / "submission.zip"),
            "--keychain-profile", profile, "--output-format", "json", "--no-wait",
        ], check=False)
        identifier = submission_id_from_output(result.stdout)
    except subprocess.TimeoutExpired as error:
        identifier = submission_id_from_output(error.stdout)
        manifest["submission_id"] = identifier
        manifest["phase"] = "submitted" if identifier else "submission-uncertain"
        write_manifest(directory, manifest)
        raise ReleaseError("Submission timed out. Its state was saved; do not upload again until the recorded ID or Apple submission history is checked.") from error
    except BaseException:
        manifest["phase"] = "submission-uncertain"
        write_manifest(directory, manifest)
        raise
    manifest["submission_id"] = identifier
    manifest["phase"] = "submitted" if identifier else "submission-uncertain"
    write_manifest(directory, manifest)
    if not identifier:
        raise ReleaseError("Apple did not return a submission ID. The attempt is recorded; check credentials and Apple submission history before any new upload.")
    print(f"Submission ID saved: {identifier}")
    if result.returncode:
        raise ReleaseError("The submission command reported an error after issuing an ID. Use finish to inspect that submission; do not submit again.")
    print("Run finish with the same directory and Keychain profile to check notarization.")
    return 0


def fetch_notary_log(directory: Path, identifier: str, profile: str) -> dict:
    temporary = directory / "notary-log.json.tmp"
    run_command(["/usr/bin/xcrun", "notarytool", "log", identifier, "--keychain-profile", profile, str(temporary)])
    with temporary.open(encoding="utf-8") as stream:
        log = json.load(stream)
    if str(log.get("jobId", "")).lower() != identifier:
        raise ReleaseError("Notarization log does not match the submitted app")
    os.replace(temporary, directory / "notary-log.json")
    return log


def update_distribution_documents(stage: Path, metadata: dict) -> None:
    """Change copies only, after Apple has returned Accepted for this payload."""
    replacements = {
        "INSTALL-macOS.txt": [
            (
                "이 배포본은 개발용 ad-hoc 서명이며 Apple Developer ID 서명과 공증을\n받지 않았습니다. 처음 실행할 때 macOS가 확인 경고를 표시할 수 있습니다.\n배포 출처를 신뢰하고 체크섬을 확인한 경우에만, 앱을 한 번 열어 본 뒤\n시스템 설정 → 개인정보 보호 및 보안에서 해당 앱의 실행 허용 절차를\n진행하세요. 정확한 절차는 사용 중인 macOS 버전의 Apple 공식 안내를 따릅니다.",
                "이 배포본은 Developer ID Application 인증서로 서명하고 Apple 공증을\n받았습니다. 공증 티켓도 앱에 첨부했습니다. ZIP 체크섬을 확인한 뒤\n응용 프로그램 폴더로 옮겨 실행하세요. macOS는 인터넷에서 받은 앱의\n첫 실행 여부를 확인할 수 있습니다. 손상 또는 검증 실패 경고가 나오면\n보안 설정을 우회하지 말고 다운로드 출처와 체크섬을 다시 확인하세요.",
            ),
            (
                "This developer build is ad-hoc signed, without Apple Developer ID signing or\nnotarization. If macOS blocks the first launch, proceed only after verifying the\nsource and checksum, following Apple's instructions for your macOS version:",
                "This build is signed with Developer ID Application, notarized by Apple, and\nincludes a stapled notarization ticket. Verify the source and ZIP checksum before\nlaunching it. macOS may ask whether to open an app downloaded from the internet.\nIf it reports damage or failed verification, check the download instead of\nbypassing security settings. Apple's guidance:",
            ),
        ],
        metadata["notes"]: [
            (
                "- 개발용 ad-hoc 서명. Apple Developer ID 서명과 공증은 받지 않았습니다.",
                "- Developer ID Application 서명 및 Apple 공증 완료. 공증 티켓을 앱에 첨부했습니다.",
            ),
            (
                "이 빌드는 공증을 받지 않아 처음 실행할 때 macOS가 경고할 수 있습니다. 출처와 체크섬을 확인한 경우에만 앱을 한 번 열어 본 뒤 **시스템 설정 → 개인정보 보호 및 보안**의 실행 허용 절차를 선택하세요.",
                "이 배포본은 Developer ID Application 서명과 Apple 공증을 완료했으며 공증 티켓을 포함합니다. 출처와 ZIP 체크섬을 확인하고 응용 프로그램 폴더에서 실행하세요. macOS는 인터넷에서 받은 앱의 첫 실행 여부를 확인할 수 있습니다. 손상 또는 검증 실패 경고가 나오면 다운로드를 다시 확인하세요.",
            ),
        ],
    }
    for filename, pairs in replacements.items():
        path = stage / filename
        text = path.read_text(encoding="utf-8")
        for before, after in pairs:
            if text.count(before) != 1:
                raise ReleaseError(f"Release document wording changed; review notarization text in {filename}")
            text = text.replace(before, after)
        path.write_text(text, encoding="utf-8")


def verify_notarized(app: Path, manifest: dict) -> None:
    verify_signature(app, identity=manifest["identity"], expected_hashes=manifest["code_hashes"])
    run_command(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    assessment = run_command(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)])
    details = assessment.stdout + assessment.stderr
    if "source=Notarized Developer ID" not in details:
        raise ReleaseError("Gatekeeper did not identify this as a notarized Developer ID app")


def finish(directory: Path, profile: str) -> int:
    manifest = load_manifest(directory)
    identifier = manifest.get("submission_id")
    if not identifier or str(uuid.UUID(identifier)) != identifier:
        raise ReleaseError("No confirmed submission ID is recorded; resolve any uncertain upload first")
    verify_prepared(directory, manifest)
    if manifest.get("phase") == "complete":
        archive = directory / manifest["distribution_archive"]
        if file_sha256(archive) != manifest["distribution_sha256"]:
            raise ReleaseError("Completed distribution archive changed")
        if payload_digest(directory / "final") != manifest["final_stage_digest"]:
            raise ReleaseError("Completed distribution contents changed")
        verify_notarized(directory / "final" / APP_NAME, manifest)
        print(f"Already complete and verified: {archive}")
        return 0
    result = run_command(["/usr/bin/xcrun", "notarytool", "info", identifier, "--keychain-profile", profile, "--output-format", "json"])
    info = json.loads(result.stdout)
    if str(info.get("id", "")).lower() != identifier:
        raise ReleaseError("Apple returned a different submission ID")
    status = info.get("status")
    manifest["notary_status"] = status
    write_manifest(directory, manifest)
    if status == "In Progress":
        print(f"Notarization is still in progress ({identifier}). Run finish again later; no new upload is needed.")
        return 3
    log = fetch_notary_log(directory, identifier, profile)
    if str(log.get("sha256", "")).lower() != manifest["submission_sha256"]:
        raise ReleaseError("Apple's notarization log does not match the submitted archive SHA-256")
    if status != "Accepted" or log.get("status") != "Accepted":
        manifest["phase"] = "rejected"
        write_manifest(directory, manifest)
        raise ReleaseError(f"Notarization was not accepted ({status}); the Apple log is saved as notary-log.json")
    manifest["phase"] = "finalizing"
    write_manifest(directory, manifest)
    name = f"EmberPDF-{manifest['metadata']['version']}-macOS-arm64.zip"
    with tempfile.TemporaryDirectory(prefix=".finalize-", dir=directory) as scratch:
        scratch_path = Path(scratch)
        stage = scratch_path / "distribution"
        shutil.copytree(directory / "signed", stage, symlinks=True)
        run_command(["/usr/bin/xcrun", "stapler", "staple", str(stage / APP_NAME)])
        verify_notarized(stage / APP_NAME, manifest)
        update_distribution_documents(stage, manifest["metadata"])
        final_archive = scratch_path / name
        create_archive(stage, final_archive)
        extracted = scratch_path / "verify"
        extract_archive(final_archive, extracted)
        inspect_layout(extracted)
        if payload_digest(extracted) != payload_digest(stage):
            raise ReleaseError("Final ZIP did not preserve the stapled distribution")
        verify_notarized(extracted / APP_NAME, manifest)
        checksum = file_sha256(final_archive)
        checksum_path = scratch_path / (name + ".sha256")
        checksum_path.write_text(f"{checksum}  {name}\n", encoding="utf-8")
        # Only this dedicated output tree is replaced; immutable signed/ stays intact.
        final_stage = directory / "final"
        if os.path.lexists(final_stage):
            if final_stage.is_symlink() or not final_stage.is_dir():
                raise ReleaseError("Unexpected object at the final staging path")
            shutil.rmtree(final_stage)
        os.replace(stage, final_stage)
        os.replace(final_archive, directory / name)
        os.replace(checksum_path, directory / checksum_path.name)
        manifest.update({
            "phase": "complete",
            "distribution_archive": name,
            "distribution_sha256": checksum,
            "final_stage_digest": payload_digest(final_stage),
            "notary_log_sha256": file_sha256(directory / "notary-log.json"),
        })
        write_manifest(directory, manifest)
    print(f"Developer ID signing, notarization, stapling, and Gatekeeper verification passed: {directory / name}")
    print(f"SHA-256: {checksum}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="Copy, validate, and Developer ID-sign an existing release ZIP")
    prepare_parser.add_argument("--archive", required=True, type=Path)
    prepare_parser.add_argument("--identity", required=True, help="SHA-1 or exact full name of a valid Developer ID Application identity")
    prepare_parser.add_argument("--output", required=True, type=Path, help="New output directory; existing directories are refused")
    for command in ("submit", "finish"):
        child = commands.add_parser(command, help="Submit once" if command == "submit" else "Check status and finalize an accepted submission")
        child.add_argument("--directory", required=True, type=Path)
        child.add_argument("--keychain-profile", required=True, help="Existing notarytool Keychain profile; never a password or private key")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            return prepare(args.archive.absolute(), args.identity, args.output.absolute())
        if not args.keychain_profile.strip() or args.keychain_profile.startswith("-"):
            raise ReleaseError("A Keychain profile name is required")
        operation = submit if args.command == "submit" else finish
        return operation(args.directory.absolute(), args.keychain_profile)
    except (ReleaseError, OSError, ValueError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        print(f"Release not completed: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted. The source release and installed app were not modified; inspect the saved manifest before resuming.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
