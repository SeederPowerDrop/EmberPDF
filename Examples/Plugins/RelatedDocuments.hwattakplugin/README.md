# Related Documents

현재 페이지의 단어나 직접 입력한 검색어로 이미 열린 PDF에서 관련 구절을 찾아 이동합니다.

Searches text in already open PDFs and navigates to matched passages. This is a local, bounded text search, not a background scan of the computer or an external semantic-search service. Image-only pages require OCR.

## Community authoring

This schema 4 package is an ordinary community example, even though it is also offered in the app's bundled examples list. Copy the directory, change `identifier`, author, title, and description, then validate and install it through the plugin manager. `org.emberpdf.examples.*` is an example identity, not proof of publisher authentication.

The manifest requests `relatedDocumentsPanel` with exactly these capabilities: `openDocumentsRead`, `currentPageText`, `workspaceNavigation`. Its template must stay empty and it must not contain a `command`. All behavior is implemented and permission-checked by EmberPDF; this package contains no JavaScript, native executable, shell command, custom HTML, or secret.

Requires an EmberPDF build that supports schema 4. The semantic minimum `0.9.0` alone does not distinguish earlier builds without this API; the host validates the schema at install time. Existing schema 1–3 packages remain supported.

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/RelatedDocuments.hwattakplugin
```

Read the [host API](../../../Documentation/PLUGIN-HOST-API.md) and [author guide](../../../Documentation/PLUGIN-DEVELOPMENT.en.md) for package rules and trust boundaries.

