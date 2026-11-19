# EmberPDF 플러그인 예제 / Plugin examples

[제작 시작](../../Documentation/PLUGIN-DEVELOPMENT.md) · [English](../../Documentation/PLUGIN-DEVELOPMENT.en.md) · [API](../../Documentation/PLUGIN-HOST-API.md) · [호환성](../../Documentation/PLUGIN-COMPATIBILITY.md)

처음 만드는 확장이라면 **[Hello Ember](HelloEmber.hwattakplugin/README.md)**부터 시작한다. PDF 없이도 자기 명령과 화면을 만들고, 화면을 닫아도 창 안에서 상태를 유지하는 가장 작은 예제다. 그다음 **[Research Trail](ResearchTrail.hwattakplugin/README.md)**에서 문서 이벤트와 여러 창이 공유하는 저장소를 살펴본다.

## 복사해서 만드는 커뮤니티 예제

| 패키지 | schema | 배울 내용 |
| --- | --- | --- |
| [HelloEmber](HelloEmber.hwattakplugin/README.md) | 6 | 첫 확장: 자기 명령·화면·창별 메모리 상태 |
| [ResearchTrail](ResearchTrail.hwattakplugin/README.md) | 6 | 창 수명 확장·탭/페이지 이벤트·패널 독립 명령·저장소 |
| [EmberRecall](EmberRecall.hwattakplugin/README.md) | 6 | 선택문 복습 카드·답 가리기·오늘 복습·열린 원문 이동·동시 저장 |
| [OfflineChecklist](OfflineChecklist.hwattakplugin/manifest.json) | 1 | 권한 없이 텍스트 표시. 첫 설치에 적합 |
| [CommunityStarter](CommunityStarter.hwattakplugin/manifest.json) | 3 | 하이라이트·밑줄·펜·학습 모드·페이지 이동 |
| [MarkdownQuote](MarkdownQuote.hwattakplugin/manifest.json) | 1 | 선택 문장을 Markdown으로 미리보기/복사 |
| [ReferenceSearch](ReferenceSearch.hwattakplugin/manifest.json) | 1 | 선택 문장의 공개 HTTPS 검색과 호출별 동의 |
| [QuickCitation](QuickCitation.hwattakplugin/manifest.json) | 1 | 텍스트 출력·복사·링크의 종합 예 |
| [ReadingColors](ReadingColors.hwattakplugin/README.md) | 4 | 앱·PDF 읽기 색상 설정 |
| [MarkdownNotebook](MarkdownNotebook.hwattakplugin/README.md) | 4 | 로컬 메모와 직접 고른 Markdown 파일 |
| [PageClipper](PageClipper.hwattakplugin/README.md) | 4 | 현재 페이지 영역을 PNG로 복사·저장·드래그 |
| [RelatedDocuments](RelatedDocuments.hwattakplugin/README.md) | 4 | 이미 열린 PDF에서 관련 구절 검색·이동 |
| [HoverTranslator](HoverTranslator.hwattakplugin/README.md) | 4 | 커서 아래 단어의 기기 내 번역 |
| [ReadingLab](ReadingLab.hwattakplugin/README.md) | 5 | 패널 수명 JavaScript·빈도 분석·UI·메모 |

복사 후 **identifier·작성자·이름을 바꾸고** 기능과 권한을 수정한다. `org.example.*`와 `dev.example.*`는 예제용이며 제작자 인증이 아니다. schema 3은 2026-09-05 안정화 후보 또는 실제 지원을 확인한 빌드가 필요하다. 이전 0.8.0/build 18과 구별하는 방법은 호환성 문서를 따른다.

schema 1·3 커뮤니티 예제는 개발 소스/검증용이며 기본 번들 목록에 포함되지 않는다. 새 schema 4 예제 5개는 앱의 기본 목록에도 제공하지만, **공식 ID나 번들 신뢰 예외 없이 커뮤니티 설치 규칙을 통과**한다. 따라서 같은 출력과 권한으로 자신의 패키지를 만들 수 있다. schema 4를 지원하는 EmberPDF 빌드가 필요하며, 0.9.0이라는 버전 표기만으로 이전 빌드의 지원 여부를 판단하지 않는다.

## 앱에 포함하는 공식 검토 패키지

TranslationCompanion, PageTranslator, WebBrowser, StudyMarkup, TabletTools, ReadingNavigation은 앱 번들 검토본과 **identifier 및 manifest digest**가 일치해야 설치된다. 이 예제를 수정해 독자 배포하려면 커뮤니티 허용 출력인지 확인하고 자신의 identifier를 사용해야 한다. 공식 패널 출력은 ID만 바꿔도 커뮤니티 패키지로 배포할 수 없다.

[PageTranslator](PageTranslator.hwattakplugin/README.md)는 현재 PDF 페이지를 번역 페이지로 표시한다. macOS 번역·외부 AI·로컬 언어팩을 선택할 수 있으며 원본 PDF는 보존한다. 호스트의 페이지 미리보기 기능이 포함된 EmberPDF 0.9.0 이상이 필요하다.

기존 TranslationCompanion은 원문 편집·문단별 번역·웹 번역 도우미와 저장된 설정을 그대로 제공한다. 페이지 위에 번역문을 표시하는 기능은 별도의 PageTranslator에서 사용한다.

**YouTubeStudy는 검토용 소스 전용**이다. 현재 배포 후보의 기본 패키지에 포함되지 않으며 커뮤니티 검사기로 설치 가능하다고 판정하지 않는다.

## 검증

저장소 루트의 Mac 터미널에서:

```sh
zsh scripts/validate_plugin.sh --examples
zsh scripts/validate_plugin.sh Examples/Plugins/CommunityStarter.hwattakplugin
```

앱 검사기를 사용하는 이 명령은 커뮤니티 배포 규칙을 검사하며, 사용자 설치 폴더에 쓰지 않는다. 처음에는 Swift 테스트 빌드가 필요하다. 테스트 PDF나 스크린샷, 이 인덱스 README 자체를 `.hwattakplugin` 안에 넣지 않는다.

For an independent extension, start with HelloEmber (schema 6): build a command,
panel and per-window counter without opening a PDF. Then use ResearchTrail for
document events and shared persistent storage. ReadingLab demonstrates the older
panel-scoped contract.

For declarative actions, use OfflineChecklist or CommunityStarter, replace the example identity, then
validate and install through the manager. Schema 4 examples demonstrate host-owned appearance,
notes, page clipping, related-PDF search, and local hover translation panels. These five examples
are also offered in the app, but remain installable without a bundled identity or digest exception.
The other community examples demonstrate Markdown copying and confirmed HTTPS searches.
Official web panels and reserved bundles use a separate exact-digest trust gate;
YouTubeStudy is source-only. See the English author guide for packaging and compatibility details.
