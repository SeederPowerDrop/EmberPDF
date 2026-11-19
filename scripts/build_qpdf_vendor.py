#!/usr/bin/env python3
"""Rebuild EmberPDF's pinned, static, arm64/macOS14 read-only PDF dependency."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "qpdf-12.4.1": ("https://github.com/qpdf/qpdf/releases/download/v12.4.1/qpdf-12.4.1.tar.gz",
                    "f045aa277be2356ff53a89a8622945958291177d2483afc20ede7c8a8cd3873c"),
    "libjpeg-turbo-3.2.0": ("https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz",
                           "6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"),
}
PATCHES = [{
    "source": "qpdf-12.4.1",
    "file": "libqpdf/QPDF_objects.cc",
    "patch": "patches/0001-warn-missing-indirect-reference.patch",
    "sha256": "ec2246330083bb88f09fe919ed68a5695863d062d8202b184966220f6346b6f2",
    "beforeSHA256": "af850c896d4e648320891d491f55e666386b152298352bb21bc40d06463b1690",
    "afterSHA256": "e6f26b256197d429a56830925ec903e5d55f637325e2846ea4eef64bcf6de15a",
    "reason": "Warn before a missing indirect reference is normalized to direct null. CoreGraphics rejects this malformed ParentTree slot; the reader must refuse the whole context rather than skip its validation. ObjGen is already lost after upstream getArrayItem/getArrayAsVector, so an indirect-null test alone is insufficient."
}]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", type=Path, default=ROOT / "work/async-save86/native-qpdf")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    work = args.work_directory.resolve()
    work.mkdir(parents=True, exist_ok=True)
    vendor = ROOT / "Vendor/QPDF"
    commands = []
    patch_reports = []
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1")
    # No package-manager search directories or external crypto providers.
    for key in ("CMAKE_PREFIX_PATH", "CPPFLAGS", "LDFLAGS", "CPATH", "LIBRARY_PATH"):
        env.pop(key, None)

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    cmake = shutil.which("cmake")
    if not cmake:
        raise RuntimeError("CMake is required to rebuild the vendored archives")

    def record_argument(value):
        for local, placeholder in (
            (str(work), "${QPDF_WORK_DIR}"),
            (sdk, "${MACOS_SDK}"),
            (cmake, "cmake"),
            (str(Path.home()), "${BUILD_HOME}"),
        ):
            if local:
                value = value.replace(local, placeholder)
        return value

    def run(command, cwd=None):
        arguments = [str(value) for value in command]
        # Keep host paths in the local build log and record portable placeholders in the manifest.
        commands.append([record_argument(value) for value in arguments])
        print("RUN", json.dumps(arguments), flush=True)
        subprocess.run(arguments, check=True, env=env, cwd=cwd)

    for name, (url, digest) in SOURCES.items():
        archive = work / (name + ".tar.gz")
        if not archive.exists():
            with urllib.request.urlopen(url) as source, archive.open("wb") as target:
                shutil.copyfileobj(source, target)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise RuntimeError("Source checksum mismatch: " + archive.name)
        source_directory = work / name
        if not source_directory.exists():
            with tarfile.open(archive) as source:
                source.extractall(work, filter="data")
        patches = [patch for patch in PATCHES if patch['source'] == name]
        by_file = {name + '/' + patch['file']: patch for patch in patches}
        # Cached source may be pristine or byte-exactly patched; no other edits
        # are accepted. The official tarball digest is never changed.
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                if member.isfile():
                    cached = work / member.name
                    original_digest = hashlib.sha256(source.extractfile(member).read()).hexdigest()
                    allowed = {original_digest}
                    if member.name in by_file:
                        patch = by_file[member.name]
                        assert original_digest == patch['beforeSHA256']
                        allowed.add(patch['afterSHA256'])
                    if (not cached.is_file() or cached.is_symlink() or
                        hashlib.sha256(cached.read_bytes()).hexdigest() not in allowed):
                        raise RuntimeError("Extracted source changed: " + member.name)
        for patch in patches:
            patch_file = vendor / patch['patch']
            assert hashlib.sha256(patch_file.read_bytes()).hexdigest() == patch['sha256'], 'Tracked patch changed.'
            target = source_directory / patch['file']
            before = hashlib.sha256(target.read_bytes()).hexdigest()
            if before == patch['beforeSHA256']:
                run(['/usr/bin/patch', '--batch', '--fuzz=0', '-p1', '-i', patch_file], cwd=source_directory)
                state = 'applied to verified pristine source'
            else:
                assert before == patch['afterSHA256']
                state = 'already applied; exact patched source verified without reapplying'
            assert hashlib.sha256(target.read_bytes()).hexdigest() == patch['afterSHA256']
            patch_reports.append({**patch, 'applicationState': state})

    flags = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
             "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DCMAKE_OSX_SYSROOT=" + sdk,
             "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
             "-DCMAKE_C_FLAGS=-ffile-prefix-map=" + str(Path.home()) + "=/EmberPDFBuilder",
             "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=" + str(Path.home()) + "=/EmberPDFBuilder"]
    jpeg_source = work / "libjpeg-turbo-3.2.0"
    jpeg_build = work / "jpeg-build"
    run([cmake, "-S", jpeg_source, "-B", jpeg_build, *flags,
         "-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON", "-DWITH_TURBOJPEG=OFF",
         "-DWITH_TOOLS=OFF", "-DWITH_TESTS=OFF"])
    run([cmake, "--build", jpeg_build, "--target", "jpeg-static", "--parallel", args.jobs])
    qpdf_source = work / "qpdf-12.4.1"
    qpdf_build = work / "qpdf-build"
    run([cmake, "-S", qpdf_source, "-B", qpdf_build, *flags,
         "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_STATIC_LIBS=ON", "-DBUILD_DOC=OFF",
         "-DINSTALL_MANUAL=OFF", "-DINSTALL_EXAMPLES=OFF", "-DUSE_IMPLICIT_CRYPTO=OFF",
         "-DREQUIRE_CRYPTO_NATIVE=ON", "-DREQUIRE_CRYPTO_OPENSSL=OFF",
         "-DREQUIRE_CRYPTO_GNUTLS=OFF", "-DDEFAULT_CRYPTO=native",
         "-DJPEG_LIBRARY=" + str(jpeg_build / "libjpeg.a"),
         "-DJPEG_INCLUDE_DIR=" + str(jpeg_source),
         "-DZLIB_LIBRARY=" + str(Path(sdk) / "usr/lib/libz.tbd"),
         "-DZLIB_INCLUDE_DIR=" + str(Path(sdk) / "usr/include")])
    # Generated jconfig.h lives beside libjpeg.a; libqpdf needs both header paths.
    # The exported JPEG include cache accepts a semicolon-separated list.
    run([cmake, "-S", qpdf_source, "-B", qpdf_build,
         "-DJPEG_INCLUDE_DIR=" + str(jpeg_source) + ";" + str(jpeg_build)])
    run([cmake, "--build", qpdf_build, "--target", "libqpdf", "--parallel", args.jobs])
    include = vendor / "include/qpdf"
    include.mkdir(parents=True, exist_ok=True)
    for source in (qpdf_source / "include/qpdf").iterdir():
        if source.is_file():
            shutil.copy2(source, include / source.name)
    libraries = vendor / "lib/macos-arm64"
    libraries.mkdir(parents=True, exist_ok=True)
    shutil.copy2(qpdf_build / "libqpdf/libqpdf.a", libraries / "libqpdf.a")
    shutil.copy2(jpeg_build / "libjpeg.a", libraries / "libjpeg.a")
    licenses = vendor / "licenses"
    licenses.mkdir(parents=True, exist_ok=True)
    for directory, name, target in [(qpdf_source, "LICENSE.txt", "qpdf-LICENSE.txt"),
                                     (qpdf_source, "NOTICE.md", "qpdf-NOTICE.md"),
                                     (jpeg_source, "LICENSE.md", "libjpeg-turbo-LICENSE.md"),
                                     (jpeg_source, "README.ijg", "libjpeg-turbo-README.ijg")]:
        shutil.copy2(directory / name, licenses / target)
    manifest = {"architecture": "arm64", "minimumMacOS": "14.0", "crypto": "native only",
                "sources": {name: {"url": url, "sha256": digest} for name, (url, digest) in SOURCES.items()},
                "patches": patch_reports,
                "commands": commands,
                "compiler": subprocess.check_output(["xcrun", "clang++", "--version"], text=True),
                "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
                "files": {str(p.relative_to(vendor)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(vendor.rglob("*")) if p.is_file() and p.name != "build-manifest.json"}}
    (vendor / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Vendored static archives and licenses prepared", flush=True)


if __name__ == "__main__":
    main()
