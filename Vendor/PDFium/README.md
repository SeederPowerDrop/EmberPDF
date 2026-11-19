# PDFium native text engine

Pinned PDFium **157.0.8086.0**, distributed as a universal macOS framework for
SwiftPM. PDF viewing and document ownership remain in PDFKit. JavaScript (V8)
and XFA are disabled in this build; the editing service never runs document
actions or JavaScript.

Upstream source: https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/8086

Prebuilt binary producer and build recipes:
https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/8086

The two downloaded archives were verified against these SHA-256 digests:

| Asset | SHA-256 |
|---|---|
| `pdfium-mac-arm64.tgz` | `e98679e052c07edbb5a627980902abb823d4b3f35744d877bd21668bd9fc13ab` |
| `pdfium-mac-x64.tgz` | `933a85a138f6027243c56bff8676375c33ceeb767401389415ffc44d689ca85d` |

`scripts/prepare_pdfium.sh` downloads exactly these assets, verifies them,
combines the two architectures, changes the Mach-O install name to
`@rpath/CPDFium.framework/CPDFium`, and adds a module map, bundle metadata and an
ad-hoc signature. It does not rebuild PDFium's C++ source. Normal builds use
the checked-in XCFramework without a network download.

`LICENSE` and the complete `licenses/` directory are from the upstream binary
archives, including PDFium's BSD-style terms and its bundled dependencies.
`scripts/build_app.sh` embeds/signs the framework and includes all these notices
in `Contents/Resources/Legal/PDFium/` in the app and release ZIP.

This engine edits page content; it is not a document sanitization or secure
redaction facility. Preserve this distinction when adding product features.
