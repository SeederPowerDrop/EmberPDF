# Page Clipper

현재 페이지에서 영역을 선택한 뒤 이미지 복사·PNG 저장·드래그로 다른 앱에 옮깁니다. 원본 PDF를 수정하지 않습니다.

Exports a user-selected region as PNG through explicit copy, save, or drag gestures. The host enforces copy permission, source identity, revoked permissions, output size limits, and source overwrite protection. Export keeps the original document colors.

## Community authoring

This schema 4 package is an ordinary community example, even though it is also offered in the app's bundled examples list. Copy the directory, change `identifier`, author, title, and description, then validate and install it through the plugin manager. `org.emberpdf.examples.*` is an example identity, not proof of publisher authentication.

The manifest requests `pageClipPanel` with exactly these capabilities: `pageImage`, `clipboardWrite`, `fileExport`. Its template must stay empty and it must not contain a `command`. All behavior is implemented and permission-checked by EmberPDF; this package contains no JavaScript, native executable, shell command, custom HTML, or secret.

Requires an EmberPDF build that supports schema 4. The semantic minimum `0.9.0` alone does not distinguish earlier builds without this API; the host validates the schema at install time. Existing schema 1–3 packages remain supported.

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/PageClipper.hwattakplugin
```

Read the [host API](../../../Documentation/PLUGIN-HOST-API.md) and [author guide](../../../Documentation/PLUGIN-DEVELOPMENT.en.md) for package rules and trust boundaries.

