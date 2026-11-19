# Markdown Notebook

PDF 옆에서 로컬 노트를 작성하거나 사용자가 직접 선택한 Markdown 파일을 열고 저장합니다. 선택 문장을 노트에 넣는 동작은 사용자가 실행합니다.

Provides a host-owned local notebook and explicitly selected Markdown files. Reading selected PDF text requires the document's copy permission; no directory-wide access or executable Markdown is granted.

## Community authoring

This schema 4 package is an ordinary community example, even though it is also offered in the app's bundled examples list. Copy the directory, change `identifier`, author, title, and description, then validate and install it through the plugin manager. `org.emberpdf.examples.*` is an example identity, not proof of publisher authentication.

The manifest requests `notesPanel` with exactly these capabilities: `notesWrite`, `fileReadWrite`, `documentMetadata`, `selectedText`. Its template must stay empty and it must not contain a `command`. All behavior is implemented and permission-checked by EmberPDF; this package contains no JavaScript, native executable, shell command, custom HTML, or secret.

Requires an EmberPDF build that supports schema 4. The semantic minimum `0.9.0` alone does not distinguish earlier builds without this API; the host validates the schema at install time. Existing schema 1–3 packages remain supported.

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/MarkdownNotebook.hwattakplugin
```

Read the [host API](../../../Documentation/PLUGIN-HOST-API.md) and [author guide](../../../Documentation/PLUGIN-DEVELOPMENT.en.md) for package rules and trust boundaries.

