# Static raw-stream reader

EmberPDF uses qpdf only to read bounded, original stream bytes from an immutable
PDF input. The application pairs its typed object graph with Core Graphics before
reuse; qpdf does not replace the document writer, PDFKit, or document validation.
Encrypted, recovered, or warning-producing inputs take the existing writer path.

Pinned official release inputs:

| Source | SHA-256 |
| --- | --- |
| [qpdf 12.4.1](https://github.com/qpdf/qpdf/releases/tag/v12.4.1) | `f045aa277be2356ff53a89a8622945958291177d2483afc20ede7c8a8cd3873c` |
| [libjpeg-turbo 3.2.0](https://github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.2.0) | `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e` |

The release tarball URLs and digests are fixed in
[`scripts/build_qpdf_vendor.py`](../../scripts/build_qpdf_vendor.py). Run
`python3 scripts/build_qpdf_vendor.py --jobs 2` with Xcode command-line tools,
Python 3.12+, and CMake installed. The script verifies source archive digests and
builds Release archives for arm64 with a macOS 14.0 deployment target. The build
uses the SDK's zlib, the pinned static JPEG archive, and qpdf's native crypto
provider (`USE_IMPLICIT_CRYPTO=OFF`, `REQUIRE_CRYPTO_NATIVE=ON`). OpenSSL and
GnuTLS are disabled. See [qpdf's build documentation](https://qpdf.readthedocs.io/en/stable/installation.html).

`lib/macos-arm64` contains the resulting static archives; `include/qpdf` contains
the matching public headers. `build-manifest.json` records source digests,
commands, compiler/SDK versions, the tracked patch and its before/after digests,
and file hashes. Rebuilding with another compiler
or SDK can produce different binary hashes. The installed app needs no Homebrew,
qpdf executable, network download, or additional dynamic library.

The one local patch, `patches/0001-warn-missing-indirect-reference.patch`, adds a
warning immediately before qpdf replaces a nonexistent indirect reference with
a direct null. Without it, a malformed ParentTree slot such as `999 0 R` can lose
its object identity before `getArrayItem` or `getArrayAsVector` returns it, while
Core Graphics refuses that slot. Checking `isIndirect` afterward is insufficient.
The patch preserves qpdf's parsing result but makes our existing warning policy
reject the context and use the original native validation path. It does not
change streams or write PDF bytes. The official release archive and its digest
remain unchanged. The rebuild script accepts only the pinned pristine or exact
patched source, applies the pinned patch once, and refuses unrelated source or
patch modifications.

The bridge copies its input and exposes no file or writer API. Caller-supplied
limits bound input bytes, handles, collection counts, and raw stream output. A
resolved stream length is checked before qpdf allocates its raw read buffer. A
custom Pipeline also stops before accepting bytes beyond the requested cap and
checks cancellation on each chunk. qpdf's parser allocations are also a function
of the input; this is not a separate process or a universal parser memory limit.
Each context must be externally serialized. Swift's registry refuses ambiguous
or changed graphs and falls back to the existing encoder.

Full upstream licenses and notices are in `licenses/` and are copied into
`EmberPDF.app/Contents/Resources/Legal/QPDF/`. qpdf uses Apache-2.0; libjpeg-turbo
includes its BSD/IJG notices. Native crypto's additional upstream notices are in
qpdf's full NOTICE file.
