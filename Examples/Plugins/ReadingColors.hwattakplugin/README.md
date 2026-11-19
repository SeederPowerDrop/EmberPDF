# Reading Colors

앱 밝기·색상과 PDF 종이 색상을 호스트의 읽기 설정 패널에서 바꿉니다.

Changes the app appearance and display-only PDF paper colors through host controls. It does not modify PDF pixels or saved documents.

## Community authoring

This schema 4 package is an ordinary community example, even though it is also offered in the app's bundled examples list. Copy the directory, change `identifier`, author, title, and description, then validate and install it through the plugin manager. `org.emberpdf.examples.*` is an example identity, not proof of publisher authentication.

The manifest requests `appearancePanel` with exactly these capabilities: `appearanceWrite`. Its template must stay empty and it must not contain a `command`. All behavior is implemented and permission-checked by EmberPDF; this package contains no JavaScript, native executable, shell command, custom HTML, or secret.

Requires an EmberPDF build that supports schema 4. The semantic minimum `0.9.0` alone does not distinguish earlier builds without this API; the host validates the schema at install time. Existing schema 1–3 packages remain supported.

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/ReadingColors.hwattakplugin
```

Read the [host API](../../../Documentation/PLUGIN-HOST-API.md) and [author guide](../../../Documentation/PLUGIN-DEVELOPMENT.en.md) for package rules and trust boundaries.

