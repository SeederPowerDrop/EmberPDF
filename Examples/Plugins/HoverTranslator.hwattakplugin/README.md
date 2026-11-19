# Hover Translator

PDF 위에 커서를 둔 단어를 호스트의 기기 내 번역 패널에서 번역합니다. 언어 설정과 필요한 다운로드는 호스트 UI에서 확인합니다.

Uses the host's pointer-word capture and macOS translation flow. The plugin receives no PDF object, arbitrary event hook, or network credential. Supported OS versions and installed translation languages determine availability.

## Community authoring

This schema 4 package is an ordinary community example, even though it is also offered in the app's bundled examples list. Copy the directory, change `identifier`, author, title, and description, then validate and install it through the plugin manager. `org.emberpdf.examples.*` is an example identity, not proof of publisher authentication.

The manifest requests `hoverTranslationPanel` with exactly these capabilities: `hoverText`, `localTranslation`. Its template must stay empty and it must not contain a `command`. All behavior is implemented and permission-checked by EmberPDF; this package contains no JavaScript, native executable, shell command, custom HTML, or secret.

Requires an EmberPDF build that supports schema 4. The semantic minimum `0.9.0` alone does not distinguish earlier builds without this API; the host validates the schema at install time. Existing schema 1–3 packages remain supported.

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/HoverTranslator.hwattakplugin
```

Read the [host API](../../../Documentation/PLUGIN-HOST-API.md) and [author guide](../../../Documentation/PLUGIN-DEVELOPMENT.en.md) for package rules and trust boundaries.

