# EmberPDF 플러그인 API 참조

schema 3 문서 명령, schema 4 호스트 패널, schema 5 패널형 SDK, schema 6 창 수명 확장을 정리한다. 기존 schema 1·2 패키지도 계속 읽을 수 있다.

이 문서는 **실행형 API, 문서 명령과 호스트 패널의 참조**다. 처음 제작한다면 [플러그인 만들기](PLUGIN-DEVELOPMENT.md)를 먼저 읽는다. [English quick start](PLUGIN-DEVELOPMENT.en.md), [보안](PLUGIN-SECURITY.md), [호환성·코어 확장 절차](PLUGIN-COMPATIBILITY.md)도 함께 제공한다. 처음 실행할 예제는 [Hello Ember](../Examples/Plugins/HelloEmber.hwattakplugin/README.md)다. JavaScript 메서드를 찾는다면 [실행형 SDK](#실행형-sdk--schema-56)로, 앱 명령의 선언형 프리셋을 만든다면 [명령과 스타일 참조](#명령과-스타일-참조)로 이동한다.

## 사용하기

1. **플러그인 → 플러그인 관리…**에서 기본 플러그인을 검토·설치한다.
2. `Study Markup`: 텍스트를 선택하고 노란색/초록색 하이라이트 또는 파란색 밑줄을 실행한다.
3. `Tablet Tools`: 학습 모드 전환, 가는 파란 펜, 굵은 빨간 펜, 지우개, 선택 도구를 제공한다. 펜은 학습 또는 에디팅 모드에서 사용할 수 있다.
4. `Reading Navigation`: 앞뒤 페이지 이동과 보기·에디팅·학습 모드 전환을 제공한다.
5. **⇧⌘P**로 명령 팔레트를 열고 명령/플러그인 이름을 검색한다. Enter는 첫 번째 실행 가능한 결과를 실행하고 Esc는 닫는다. 메뉴와 툴바에서도 실행할 수 있다.

이 문서의 명령 프리셋과 번역·웹 브라우저 등 기본 패키지를 앱에 포함한다. 설치와 활성화는 사용자가 선택한다. 설치·업데이트·비활성화·삭제와 변조 검사에는 기존 플러그인 관리 경로를 사용한다.

## 직접 만들기

`MyStudy.hwattakplugin` 디렉터리 안에 다음 `manifest.json`을 넣는다. ZIP으로 공유했다면 설치 전에 압축을 푼다. `README.md`도 넣을 수 있다.

```json
{
  "schemaVersion": 3,
  "identifier": "org.example.my-study",
  "displayName": "My Study",
  "version": "1.0.0",
  "author": "Your name",
  "description": "My PDF annotation presets",
  "minimumHostVersion": "0.8.0",
  "capabilities": ["annotationWrite", "toolControl"],
  "actions": [
    {
      "id": "underline-blue",
      "title": "파란색 밑줄",
      "output": "documentCommand",
      "template": "",
      "command": {"kind": "underline", "color": "#007AFF", "width": 1.5, "opacity": 1}
    },
    {
      "id": "fine-pen",
      "title": "가는 파란 펜",
      "output": "documentCommand",
      "template": "",
      "command": {"kind": "pen", "color": "#007AFF", "width": 1.2}
    }
  ]
}
```

자신의 식별자를 사용한다. `dev.hwattakpdf.*`는 앱에 포함한 원본과 digest가 일치해야 하는 공식 영역이므로 예제를 수정할 때는 식별자도 바꾼다. 구형 0.8.0 바이너리는 schema 3을 지원하지 않으므로 2026-09-05 안정화 후보 또는 이후 빌드가 필요하다.

## 명령과 스타일 참조

한 action은 한 command를 실행한다. 모든 문서 명령에는 열린 PDF가 필요하다. 일반 PDF의 보기·에디팅·학습 모드는 모두 markup을 허용하지만, 암호화 문서의 실제 편집 권한과 선택 객체 소유권은 실행 경계에서 다시 확인한다.

| `command.kind` | 필요한 권한 | 입력과 조건 | 결과 |
| --- | --- | --- | --- |
| `highlight` | `annotationWrite` | 현재 문서의 텍스트 선택과 markup 권한. 색·굵기·투명도 선택 가능 | 주석 추가, Undo/Redo |
| `underline` | `annotationWrite` | 위와 같음 | 밑줄 appearance 추가, Undo/Redo |
| `pen` | `toolControl` | 필기 가능한 학습/에디팅 모드. 색·굵기 선택 가능 | 펜 선택과 설정. 현재 3열 이상이면 최대 2열로 조정 |
| `eraser` | `toolControl` | 모드가 지우개를 허용하고 markup 권한이 있어야 함 | 지우개 선택. 명령 자체가 주석을 지우지는 않음 |
| `selection` | `toolControl` | 열린 문서 | 선택 도구로 전환 |
| `viewerMode`, `editingMode`, `studyMode` | `workspaceNavigation` | 열린 문서 | 모드 전환. 문서의 암호/권한을 확대하지 않음 |
| `nextPage`, `previousPage` | `workspaceNavigation` | 다음/이전 페이지가 문서 범위 안에 있어야 함 | 현재 페이지 한 칸 이동 |

| 스타일 | 허용 값 | 생략하면 |
| --- | --- | --- |
| `color` | ASCII `#RRGGBB`; 알파·색상 이름 미지원 | 강조/밑줄은 현재 학습 팔레트 색, 펜은 기존 펜 색 |
| `width` | 유한한 숫자 0.2~32, PDF 페이지 좌표의 pt | 밑줄 1.5, 펜은 기존 굵기, 하이라이트는 선택 줄 전체 높이 |
| `opacity` | 유한한 숫자 0.1~1. 강조/밑줄에만 허용 | 굵기를 지정한 강조는 0.42, 그 외 강조/밑줄은 1 |

하이라이트에 굵기를 주면 선택 줄 높이를 넘지 않는 중앙 강조 띠를 만든다. 펜에는 opacity를 지정하지 않는다. 나머지 종류에는 스타일 필드를 넣지 않는다. `pressure`, `pressureEnabled`, `commands`, `onload`, `script`, `shortcut`은 지원 필드가 아니다.

일반 하이라이트(굵기 없음, 불투명도 약 1)는 native Highlight로 저장한다. 굵기/투명도를 지정한 강조와 밑줄은 Stamp appearance로 저장될 수 있다. PDF에 보이는 결과와 다른 앱의 native 편집 도구 호환성을 구분한다.

`template`은 필수이며 `documentCommand`에서는 빈 문자열이다. 나머지 출력에는 `command`를 넣지 않는다. 한 패키지에서 텍스트 출력과 문서 명령을 함께 사용할 수 있으며 권한은 모든 action의 합집합이다. 정확한 파일·문자열·최종 출력 상한은 [공통 형식 참조](PLUGINS.md)에 있다.

명령이 문서를 수정해도 원본 파일을 직접 덮어쓰지 않는다. 호스트의 저장·복구·충돌 감지 정책이 적용된다. 실행 직전에 활성 상태, 현재 registry의 digest, action 소유권을 확인하며 주석에는 문서 권한·선택 페이지 소유권과 Undo 경계를 적용한다. 비활성화·제거는 이미 생성한 PDF 주석을 삭제하지 않는다.

## 호스트 패널 — schema 4

각 패널은 호스트가 구현한 예제 기능이다. 플러그인의 HTML·SwiftUI·JavaScript를 삽입하지 않으며, `template`은 빈 문자열이고 `command`는 없어야 한다. 커뮤니티 식별자로 선언할 수 있다.

| `output` | 필수 capability 합집합 | 사용자 동작과 접근 범위 |
| --- | --- | --- |
| `appearancePanel` | `appearanceWrite` | 호스트 읽기 색상 설정. 화면만 바꾸고 PDF 원본은 유지 |
| `notesPanel` | `notesWrite`, `fileReadWrite`, `documentMetadata`, `selectedText` | 로컬 Markdown 편집/미리보기, macOS 파일 선택·저장, 버튼으로 PDF 출처·선택 글 삽입 |
| `pageClipPanel` | `pageImage`, `clipboardWrite`, `fileExport` | 현재 페이지/영역을 PNG로 내보내기. 복사 권한·문서 revision·기하 범위 확인 |
| `relatedDocumentsPanel` | `openDocumentsRead`, `currentPageText`, `workspaceNavigation` | 열린 PDF 일부 페이지에서 공통 단어와 문맥 찾기. 외부 전송·임의 폴더 검색 없음 |
| `hoverTranslationPanel` | `hoverText`, `localTranslation` | 사용자가 켠 패널에서 현재 PDF의 단어만 읽어 기기 내 번역. macOS 15 이상 |

권한은 action별로 계산되며 manifest에는 전체 합집합만 선언한다. 오래된 request는 registry digest·enabled 상태·현재 권한을 재검증하여 차단한다. 파일 패널처럼 모달 UI를 거친 작업도 돌아온 뒤에 권한을 다시 확인한다. 노트 세션은 화면의 생명주기와 분리되어 권한이 철회되어도 미저장 글을 삭제하지 않는다. 앱을 종료하거나 탭을 없앨 때 사용자의 호스트 저장 흐름으로 회수할 수 있다.

노트는 UTF-8 1 MiB 한도이며 native text preview만 제공한다. HTML, 이미지 URL, Markdown 링크는 자동 실행/읽기를 하지 않는다. leaf symlink와 비일반 파일을 거부하고 hardlink 파일을 덮어쓰지 않는다. 파일의 inode·크기·수정시각·SHA256을 비교해 외부 편집 충돌을 감지한다. 쓰기 실패 시 dirty 상태를 유지하고 자동으로 위험한 직접 덮어쓰기로 전환하지 않는다. 다중 탭 닫기는 모든 노트/PDF 결정이 끝날 때까지 “버리기”를 지연하여 뒤쪽 취소가 앞쪽 글을 지우지 않게 한다.

관련 문서 검색은 일부 페이지를 대상으로 하는 단어 기반 탐색이며 완전한 색인/의미 검색이 아니다. 클립은 0/90/180/270도 회전과 crop box를 반영하며 이미지 출력은 화면 읽기 색상과 별개인 원본 색상이다. 대상 PDF·Markdown·Word 앱이 PNG 붙여넣기/드래그를 지원해야 한다. 커서 번역은 해당 앱 창의 입력 이벤트만 관찰하며, 비활성화·패널 닫기·문서 변경 때 수집과 진행 중 요청을 취소한다.

`PluginPanelRequest`, `PluginNotesSession`, `PluginPageClipService`, SwiftUI view는 **내부 호스트 구현**이지 패키지가 import하는 공개 Swift SDK가 아니다. 실제 제작 예제와 완전한 manifest는 [개발 가이드](PLUGIN-DEVELOPMENT.md#코드가-필요-없는-플러그인과-기존-형식)를 참고한다.

## 실행형 SDK — schema 5·6

schema 5 `scriptPanel`과 schema 6 `runtime`은 같은 `ember` API를 사용하고 수명 계약을 구분한다. 신규 지속 확장은 schema 6을 선택한다. [개발 가이드](PLUGIN-DEVELOPMENT.md#1-먼저-완성된-예제를-실행하세요), [Research Trail](../Examples/Plugins/ResearchTrail.hwattakplugin/manifest.json), [TypeScript SDK](PluginSDK/emberpdf.d.ts)가 완전한 예제와 호출 타입을 제공한다.

schema 6의 최상위 `runtime`은 `apiVersion: 1`, `entry: "main.js"`, 소문자 64자리 `sha256`, `activation: "window"`, 명시적인 `capabilities`로 구성된다. `backgroundExecution`을 포함하며 루트 권한은 runtime과 action의 정확한 합집합이다. `actions: []`도 허용하며 runtime과 `scriptPanel`의 혼합은 거부한다. schema 5는 기존 action의 `scriptSHA256`·`scriptCapabilities`와 빈 template 계약을 유지한다. `main.js`는 UTF-8 128 KiB이고 시작할 때 승인된 bytes를 재검사한다.

### API 경계

`await ember.call(method, params)`는 JSON만 전달한다. 알 수 없는 메서드·인자, 승인되지 않은 권한, 범위 밖 페이지·ID, 지나치게 큰 값은 거부한다. script 권한은 `documentMetadata`, `selectedText`, `currentPageText`, `documentTextRead`, `openDocumentsRead`, `workspaceNavigation`, `annotationWrite`, `toolControl`, `notesWrite`, `fileReadWrite`, `appearanceWrite`, `pluginStorage`다. `backgroundExecution`은 schema 6 runtime의 추가 권한이다. `fileReadWrite`는 사용자가 호스트에서 선택한 파일 노트의 접근에만 쓰이며 임의 경로를 공개하지 않는다.

| 메서드 | capability | 입력/결과와 범위 |
| --- | --- | --- |
| `app.getContext` | 없음, 활성 runtime 필요 | `{}` → `{apiVersion: 1, windowID, workspaceID, tabID, hasDocument}`. PDF가 없으면 tabID가 null일 수 있음 |
| `document.getInfo` | `documentMetadata` | 이름, 1-based 페이지/페이지 수, revision, copyAllowed, workspace/tab ID. 파일 경로 없음 |
| `document.getSelection` | `selectedText` | 현재 문서의 선택 글, truncated, revision. 선택 없으면 빈 글. PDF 복사 권한 확인 |
| `document.getPageText` | 현재 페이지는 `currentPageText` 또는 `documentTextRead`, 다른 페이지는 `documentTextRead` | `{pageNumber?}` → 글·pageNumber·revision·truncated. 1-based이며 생략 시 현재 페이지. 화면 이동 없음 |
| `commands.execute` | kind별 권한 | `{kind, color?, width?, opacity?}` → `{executed: true, kind, revision, pageNumber}`. 아래 권한 표와 기존 명령 검증·Undo 적용 |
| `workspace.listDocuments` | `openDocumentsRead` | 열린 문서의 이름/페이지/workspace/tab ID 목록, 최대 128개·truncated |
| `workspace.search` | `openDocumentsRead` | `{query}` → `{documents: [{workspaceID, tabID, name, matches: [{pageNumber, snippet}]}], partial, scannedDocuments}`. 최대 8개 열린 문서·전체 24결과/문서당 3결과, query UTF-8 1 KiB |
| `workspace.navigate` | `workspaceNavigation` | `{workspaceID, tabID, pageNumber?}` → 실제 열린 탭·유효한 페이지로 이동 |
| `notes.get` | `notesWrite`, 파일 노트는 추가로 `fileReadWrite` | 현재 탭의 메모리 노트·modified·truncated |
| `notes.append` | `notesWrite`, 파일 노트는 추가로 `fileReadWrite` | `{text}` → 메모리 노트 뒤에 추가, 파일 자동 저장 없음 |
| `appearance.get/set` | `appearanceWrite` | get은 `{}`, set은 `{mode?, paper?}` → mode·paper·effectiveMode. 유효한 호스트 enum만 사용 |
| `storage.get/set` | `pluginStorage` | get은 `{}` → `{value}`, 미저장 시 null. set은 `{value}` → `{saved: true}`. 플러그인별 JSON 64 KiB |
| `storage.compareAndSet` | `pluginStorage` | `{expected, value}` → `{saved: boolean}`. 현재 JSON과 expected가 같을 때만 원자적으로 교체. 각 값 64 KiB, 미저장 expected는 null. 충돌 시 다시 읽고 제한 재시도 |

| `commands.execute` kind | 필요한 권한 |
| --- | --- |
| `highlight`, `underline` | `annotationWrite` + `selectedText`, 현재 문서의 선택과 PDF 복사·편집 권한 |
| `pen`, `eraser`, `selection` | `toolControl`, 현재 모드·문서의 허용 조건 |
| `viewerMode`, `editingMode`, `studyMode`, `nextPage`, `previousPage` | `workspaceNavigation`, 열린 문서·페이지 경계 |

스타일은 기존 문서 명령과 같은 `#RRGGBB` 색, 폭 0.2~32, 불투명도 0.1~1이다. 펜은 불투명도를 받지 않으며 스타일을 지원하지 않는 kind에 넣으면 거부한다. 원문 결과는 최대 16,000자/UTF-8 64 KiB이므로 `truncated`를 확인한다. 메서드 입력은 JSON 64 KiB, 일반 문서 API 출력은 192 KiB 한도다. PDFKit/AppKit 객체·security bookmark·파일 경로는 넘기지 않는다.

### UI·명령·이벤트·수명

`ember.apiVersion`은 1이다. `ember.ui.render({title?, text?, items?, fields?, actions?})`로 네이티브 화면을 구성한다. items는 `{title, detail?}`, fields는 `{id, label, value?}`, actions는 `{id, label}`이다. schema 6의 `ui.open()`과 `ui.close()`는 표시만 바꾸고 null로 완료된다. 패널을 닫아도 worker는 유지된다.

`ember.commands.register({id, title, run})`는 확장·창별 명령을 등록하고 동기적인 제거 함수를 반환한다. UI나 팔레트의 명령이 다른 창의 runtime으로 전달되지 않도록 호스트가 범위를 묶는다. 등록·제거 metadata는 한 microtask에 합쳐 전송한다.

초기 이벤트 구독은 진입점 또는 동기적인 load 처리에서 등록한다. 비동기 load 완료를 기다려 app.ready를 보내지 않으므로 await 이후 구독은 첫 알림을 놓칠 수 있다.

schema 6은 `app.ready`, `workspace.changed`, `document.changed`, `documents.changed`, `page.changed`, `selection.changed`를 보낸다. payload는 `app.getContext`와 같은 문맥이며 원문·경로를 포함하지 않는다. UI action은 `{id, values}`, input은 `{id, value}`다. schema 5는 기존 `load`와 빈 page/selection payload를 유지한다. 진행 중 문서 요청이 문맥 전환으로 취소되면 `CONTEXT_CHANGED`를 처리하고 새 문맥에서 요청한다.

runtime은 사용자 검토·권한 승인 후 활성화된 동안 각 창에서 시작하며 PDF 없이도 실행된다. 패널·탭·워크스페이스와 독립적인 수명을 갖는다. 실행기는 앱 전체 최대 8개이며 하나의 오류가 다른 실행기를 종료하지 않도록 분리한다. 비활성화·필수 권한 철회·안전 모드·창 종료·업데이트·제거 시 명령·구독·화면·진행 요청을 회수한다. `ember.dispose(callback)`은 최선 노력의 로컬 정리이며 강제 종료에서 보장하지 않는다. 정리 중에는 새 API 호출을 할 수 없다. `app.getContext`와 `ui.open/close`는 schema 6 broker에서만 제공한다.

schema 5는 열린 PDF의 패널 수명을 그대로 유지한다. 패널 닫힘이나 문서 교체 시 중지한다. 같은 SDK가 수명이 다른 두 형식을 지원하는 것이며 새 지속 확장을 schema 5로 표기하지 않는다.

각 worker는 dispatch 3초, 동시에 진행하는 호출 16개, 분당 호출 240회, IPC 256 KiB·UI 64 KiB 한도를 가진다. UI items 100개·fields 12개·actions/등록 명령 24개, 이벤트 listener 32개, 정리 callback 32개 한도가 있다. JS heap에 별도의 강제 바이트 상한을 제공한다는 뜻은 아니다. 네이티브 자원 접근을 늘릴 때에는 버전·권한·취소·Undo·자원 한도·회귀 검증을 API와 함께 정의한다.

## iPad·태블릿 필기

Mac의 Sidecar로 iPad에 앱 창을 표시하고 학습/에디팅 모드에서 펜을 선택한다. 펜 설정의 **태블릿 필압 사용**이 켜져 있으면 macOS의 tablet-point 이벤트와 pressure를 읽는다. 마우스는 기존 고정 굵기 Ink 경로를 사용한다.

필압 획은 표준 PDF appearance를 가진 Stamp로 저장한다. 한 획의 샘플 수는 8,192개로 제한하고 긴 획은 간소화한다. 현재 세션에서 생성한 획은 학습 모드의 신뢰 경계 안에서 지울 수 있다. 저장 후 재개방한 Stamp를 지우려면 에디팅 모드를 사용한다. 외부 PDF가 같은 이름을 붙였다고 학습 모드에서 자동 편집 권한을 얻지는 않는다.

앱 이벤트 처리와 저장 결과는 합성 테스트로 확인했다. 실제 iPad/Wacom의 필압·지연·팜 리젝션은 기기 검증이 남아 있다. 별도 iPad 앱, 무선 펜 전송 프로토콜, 기기 페어링은 이번 구현에 포함하지 않는다. Apple이 설명하는 Sidecar 입력 범위는 [공식 안내](https://support.apple.com/en-us/102597)를 참고한다.

## 확장 범위

EmberPDF SDK는 개발자가 독립적인 기능과 UI·이벤트 흐름을 작성하는 버전형 API다. 예제 패널은 가능한 조합의 일부다. 현재 API로 표현할 수 있는 로직은 플러그인만 배포하고, 추가 네이티브 자원은 호스트 API 기여로 확장한다. [호환성·API 제안 절차](PLUGIN-COMPATIBILITY.md)를 따른다. 지원하지 않는 기능을 manifest에 써 넣으면 무시하지 않고 거부한다.
