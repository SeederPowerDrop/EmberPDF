# EmberPDF 플러그인 개발 시작하기

EmberPDF 플러그인은 앱 안에서 동작하는 작은 프로그램입니다. 개발자는 JavaScript로 자신만의 기능을 만들고, 명령과 화면을 추가하며, PDF 정보와 문서 변경 이벤트를 사용할 수 있습니다. 제공된 API로 만든 기능은 EmberPDF를 다시 빌드하지 않고 설치할 수 있습니다.

이 가이드에서는 **버튼을 누를 때마다 숫자가 늘어나는 플러그인**을 실행한 뒤, 코드를 바꾸고 PDF 정보를 읽는 기능까지 붙여 봅니다. 완성 코드를 먼저 실행하고, 필요한 부분을 하나씩 이해하는 순서입니다.

기준: **EmberPDF 0.9.0 build 27 · macOS 14 이상**. 앱 정보에서 빌드 번호를 확인하세요. 이 실습에는 PDF, Xcode, 별도의 JavaScript 빌드 도구가 필요하지 않습니다.

[English](PLUGIN-DEVELOPMENT.en.md) · [API 참조](PLUGIN-HOST-API.md) · [TypeScript 타입](PluginSDK/emberpdf.d.ts) · [예제 목록](../Examples/Plugins/README.md)

## 1. 먼저 완성된 예제를 실행하세요

### 예제 폴더 준비

[HelloEmber.hwattakplugin](../Examples/Plugins/HelloEmber.hwattakplugin)을 통째로 복사하고 폴더 이름을 `MyExtension.hwattakplugin`으로 바꿉니다. 저장소를 내려받았다면 저장소 루트에서 다음 명령을 실행해도 됩니다. 처음 복사할 때 쓰는 명령이므로 `work/MyExtension.hwattakplugin` 폴더가 이미 있다면 다른 폴더 이름을 사용하세요.

```sh
mkdir -p work
cp -R Examples/Plugins/HelloEmber.hwattakplugin work/MyExtension.hwattakplugin
```

`.hwattakplugin`은 파일 하나가 아니라 **다음 파일이 들어 있는 폴더**입니다. 예제는 앱의 기본 설치 목록에 포함되지 않으므로 이 폴더를 직접 선택해 설치합니다.

```text
MyExtension.hwattakplugin/
├── manifest.json   ← 이름, 버전, 필요한 권한
├── main.js         ← 실제 기능
├── README.md       ← 사용 설명
└── LICENSE         ← 예제 코드의 이용 조건
```

### 설치하고 버튼 눌러 보기

1. EmberPDF에서 **플러그인 → 플러그인 관리… → 플러그인 설치…**를 엽니다.
2. 복사한 `MyExtension.hwattakplugin` 폴더를 선택합니다. ZIP으로 받았다면 먼저 압축을 풉니다.
3. 이름이 **Hello Ember**, 요청 권한이 **앱을 사용하는 동안 동작** 하나인지 확인하고 설치합니다.
4. 관리 창을 닫고 EmberPDF의 문서 창으로 돌아갑니다. PDF가 없는 빈 문서 창이어도 됩니다.
5. **⇧⌘P**를 누르고 `Hello Ember`를 검색한 뒤 Enter를 누릅니다. **플러그인** 메뉴에서도 같은 명령을 실행할 수 있습니다.
6. 열린 패널에서 **Record an idea**를 누릅니다. 숫자가 `0`에서 `1`로 바뀌면 성공입니다.

**Close panel**로 패널을 닫고 같은 명령을 다시 실행해 보세요. 숫자는 그대로 `1`입니다. 화면을 숨겨도 플러그인은 계속 동작하기 때문입니다. 이 예제의 숫자는 창 안의 메모리에만 있으므로 창을 닫거나 플러그인을 중지하면 초기화됩니다.

## 2. 두 파일이 하는 일을 살펴보세요

### main.js: 무엇을 할지 작성하는 코드

아래는 예제의 전체 코드입니다. EmberPDF가 제공하는 `ember` 객체로 명령을 등록하고 화면을 표시합니다.

```javascript
// SPDX-License-Identifier: MIT
let count = 0;

async function renderPanel() {
  await ember.ui.render({
    title: 'Hello Ember',
    text: `Ideas recorded in this window: ${count}`,
    actions: [
      { id: 'add-idea', label: 'Record an idea' },
      { id: 'close', label: 'Close panel' }
    ]
  });
}

ember.commands.register({
  id: 'open-hello',
  title: 'Hello Ember',
  run: async () => {
    await renderPanel();
    await ember.ui.open();
  }
});

ember.on('view.action', async ({ id }) => {
  if (id === 'add-idea') {
    count += 1;
    await renderPanel();
  } else if (id === 'close') {
    await ember.ui.close();
  }
});
```

실행 순서는 다음과 같습니다.

1. EmberPDF가 플러그인을 시작하면 `Hello Ember` 명령과 버튼 이벤트 처리가 등록됩니다.
2. 사용자가 명령을 실행하면 `renderPanel()`이 화면 내용을 만들고 `ui.open()`이 패널을 엽니다.
3. 버튼을 누르면 `view.action` 이벤트에 버튼의 `id`가 전달됩니다. 코드는 그 값에 따라 숫자를 늘리거나 패널을 닫습니다.

`ui.render()`는 제목·본문·버튼 등 화면의 **내용**을 정합니다. `ui.open()`과 `ui.close()`는 그 화면을 **보이거나 숨깁니다**. 숫자를 세는 기능은 전부 이 파일에 있고, EmberPDF 본체에는 카운터를 위한 코드를 추가하지 않았습니다.

### manifest.json: 앱에 플러그인을 소개하는 파일

아래는 위 코드와 함께 설치할 수 있는 전체 설정입니다. `runtime`은 실행할 코드와 실행 조건을 지정하는 부분입니다.

```json
{
  "schemaVersion": 6,
  "identifier": "org.emberpdf.examples.hello-ember",
  "displayName": "Hello Ember",
  "version": "1.0.0",
  "author": "EmberPDF SDK Examples",
  "description": "A first independent extension with its own command, panel and per-window counter. Works without an open PDF.",
  "minimumHostVersion": "0.9.0",
  "capabilities": ["backgroundExecution"],
  "actions": [],
  "runtime": {
    "apiVersion": 1,
    "entry": "main.js",
    "sha256": "4c2e55462065cbd4d5a71c1e869bd9ab5fbdfe51b1cd5361381dec50b386afc3",
    "activation": "window",
    "capabilities": ["backgroundExecution"]
  }
}
```

처음에는 다음 항목만 이해하면 됩니다.

| 항목 | 의미 |
| --- | --- |
| `identifier` | 플러그인을 구별하는 고유 이름입니다. 같은 이름으로 다시 설치하면 업데이트 대상으로 인식합니다. |
| `displayName`, `author`, `version` | 사용자에게 표시할 이름, 제작자, 플러그인 버전입니다. |
| `schemaVersion: 6` | 이 가이드에서 사용하는 플러그인 설정 형식입니다. |
| `runtime.apiVersion: 1` | 코드에서 사용하는 EmberPDF API의 버전입니다. |
| `runtime.entry: "main.js"` | EmberPDF가 실행할 파일입니다. 현재 파일명은 `main.js`로 고정입니다. |
| `runtime.activation: "window"` | 활성화한 플러그인을 각 앱 창에서 시작합니다. |
| `capabilities` | 필요한 권한입니다. 이 예제는 창이 열려 있는 동안 동작하는 권한 하나만 요청합니다. |
| `runtime.sha256` | 설치 검토를 받은 코드와 실제 실행할 코드가 같은지 확인하는 값입니다. 코드를 고치면 함께 갱신합니다. |

`actions`가 비어 있는 것은 명령을 `main.js`에서 등록하기 때문입니다. 이 예제처럼 실행 코드만 있는 패키지는 바깥쪽 `capabilities`와 `runtime.capabilities`에 **같은 권한 목록**을 씁니다. 선언형 액션까지 함께 쓰는 경우의 규칙은 [형식 참조](PLUGINS.md)에 있습니다.

## 3. 코드를 고치고 다시 설치하세요

먼저 작은 변경부터 해보겠습니다. `main.js`의 `Record an idea`를 `아이디어 하나 기록`으로 바꾸세요. 수정 대상은 **복사해 둔 원본 폴더**입니다. 앱 내부에 설치된 사본은 직접 편집하지 않습니다.

코드가 바뀌면 다음 순서로 적용합니다.

1. `main.js`를 저장합니다.
2. 저장소 루트에서 아래 명령으로 새 해시를 구합니다.
3. 출력에서 파일명 앞의 64자리 값을 복사해 `manifest.json`의 `runtime.sha256`에 넣습니다.
4. 플러그인 `version`을 `1.0.1`로 올리고, 관리 창의 **플러그인 설치…**에서 같은 원본 폴더를 다시 선택합니다. `identifier`는 유지합니다.
5. 업데이트 검토를 마치고 `Hello Ember`를 다시 실행합니다. 버튼 이름이 바뀌었는지 확인합니다.

```sh
shasum -a 256 work/MyExtension.hwattakplugin/main.js
```

코드뿐 아니라 주석·공백·줄바꿈을 바꿔도 해시는 달라집니다. 위 manifest의 해시는 예제 원본 파일용입니다. 코드를 직접 붙여 넣어 만든 경우에도 저장한 파일의 해시를 다시 구하세요. 업데이트하면 실행기가 다시 시작하므로 저장하지 않은 카운터 값은 초기화됩니다.

## 4. 현재 PDF의 정보를 읽어 보세요

이제 패널에 PDF 이름과 페이지 번호를 표시해 보겠습니다. 앱이 가진 정보를 읽으려면 해당 권한을 먼저 선언합니다.

`manifest.json`의 두 `capabilities` 목록을 모두 `["backgroundExecution", "documentMetadata"]`로 바꿉니다. 그런 다음 `main.js`의 **renderPanel 함수만** 아래 코드로 교체합니다. 나머지 명령과 버튼 코드는 그대로 둡니다.

```javascript
async function renderPanel() {
  const context = await ember.call('app.getContext');
  let info = null;
  if (context.hasDocument) {
    try {
      info = await ember.call('document.getInfo');
    } catch (error) {
      // 조회하는 사이 PDF가 닫혔다면 빈 문서 안내를 표시합니다.
      if ((await ember.call('app.getContext')).hasDocument) throw error;
    }
  }

  await ember.ui.render({
    title: 'Hello Ember',
    text: info
      ? `${info.name} · ${info.pageNumber}/${info.pageCount}페이지 · 아이디어 ${count}개`
      : `PDF를 열어 보세요. 아이디어 ${count}개`,
    actions: [
      { id: 'add-idea', label: '아이디어 하나 기록' },
      { id: 'close', label: '패널 닫기' }
    ]
  });
}
```

앞 절처럼 해시와 버전을 갱신해 다시 설치합니다. 이번 검토에는 **문서 이름·페이지 정보 읽기**가 추가로 표시됩니다. PDF를 연 뒤 명령을 실행하면 이름과 페이지 번호가 나오고, PDF가 없어도 안내 문구를 표시합니다.

이 코드는 명령이나 버튼을 실행할 때 화면을 갱신합니다. 페이지나 문서를 바꿀 때도 자동으로 갱신하려면 파일 끝에 다음 코드를 추가하고 다시 설치하세요.

```javascript
ember.on('page.changed', renderPanel);
ember.on('document.changed', renderPanel);
```

이벤트는 파일이 실행될 때 바로 등록하세요. `app.ready` 같은 초기 이벤트를 사용한다면 다른 API 응답을 기다린 뒤에 등록할 경우 첫 알림을 놓칠 수 있습니다. 문서 전환 중 완료되지 않은 문서 요청은 `CONTEXT_CHANGED`로 취소될 수 있습니다. 이 예제의 이벤트 처리는 다음 문서 이벤트에서 새 정보를 읽습니다. 여러 단계의 작업을 만들 때는 [이벤트와 취소 규칙](PLUGIN-HOST-API.md#ui명령이벤트수명)을 확인하세요.

## 5. 기능을 늘릴 때 찾아볼 것

아래는 출발점입니다. 플러그인의 기능은 개발자가 작성하는 코드와 API 조합으로 결정됩니다.

| 만들고 싶은 기능 | 사용할 API·문서 |
| --- | --- |
| 선택한 글이나 페이지 내용을 분석 | `document.getSelection`, `document.getPageText` — [메서드·권한 표](PLUGIN-HOST-API.md#api-경계) |
| 문서·페이지 이동에 반응 | `ember.on` — [이벤트와 실행 수명](PLUGIN-HOST-API.md#ui명령이벤트수명) |
| 입력란·목록·버튼으로 자체 화면 구성 | `ember.ui.render` — [PanelDescription 타입](PluginSDK/emberpdf.d.ts) |
| 여러 PDF를 검색하고 결과로 이동 | `workspace.search`, `workspace.navigate` — [API 참조](PLUGIN-HOST-API.md#api-경계) |
| 설정이나 기록을 앱 재시작 후에도 유지 | `storage.get/set`; 여러 창에서 함께 수정하면 `storage.compareAndSet` — [Research Trail 예제](../Examples/Plugins/ResearchTrail.hwattakplugin/README.md) |
| 주석·도구·읽기 색상·노트와 연결 | `commands.execute`, `appearance.get/set`, `notes.get/append` — [API 참조](PLUGIN-HOST-API.md#api-경계) |

TypeScript를 쓴다면 [emberpdf.d.ts](PluginSDK/emberpdf.d.ts)를 **개발 프로젝트 쪽**에 두고, 결과를 `main.js` 하나로 묶어 패키지에 넣습니다. 앱이 제공하는 `ember` 객체를 사용하므로 별도의 SDK 실행 파일은 넣지 않습니다.

사용자는 플러그인 설정에서 **권한을 각각 켜고 끌 수 있습니다**. 실행에 필요한 권한이 철회되면 해당 확장은 멈춥니다. 처음부터 실제 사용하는 권한만 요청하고, 각 권한의 이유를 README에 설명하세요.

실행 환경은 별도 JavaScript 실행기입니다. 화면은 앱이 제공하는 UI 요소로 구성하며, Node.js·브라우저 DOM·직접 파일/네트워크 접근은 제공하지 않습니다. API 호출, 화면 크기, 실행 시간에도 한도가 있으므로 긴 작업은 [API 참조](PLUGIN-HOST-API.md#실행형-sdk--schema-56)와 [보안·자원 제한](PLUGIN-SECURITY.md)을 확인해 설계하세요. 필요한 기능이 API에 없다면 [API 확장 제안](PLUGIN-COMPATIBILITY.md#5-아직-없는-기능을-추가하는-방법)을 남길 수 있습니다.

### 코드가 필요 없는 플러그인과 기존 형식

이 가이드의 기본 선택은 **schema 6**입니다. 이미 앱에 있는 명령이나 패널을 묶는 것만 필요할 때는 아래 형식도 사용할 수 있습니다. 구체적인 기능과 권한은 각 예제를 참고하세요.

| 용도 | 형식 | 예제 |
| --- | --- | --- |
| 안내문·인용 복사·링크 열기 | schema 1 | [OfflineChecklist](../Examples/Plugins/OfflineChecklist.hwattakplugin/manifest.json), [MarkdownQuote](../Examples/Plugins/MarkdownQuote.hwattakplugin/manifest.json) |
| 하이라이트·펜 등 앱 명령의 프리셋 | schema 3 | [CommunityStarter](../Examples/Plugins/CommunityStarter.hwattakplugin/manifest.json) |
| 앱이 제공하는 노트·색상·클립 패널 열기 | schema 4 | [호스트 패널 참조](PLUGIN-HOST-API.md#호스트-패널--schema-4) |
| 패널을 연 동안만 실행하는 기존 코드 | schema 5 | [Reading Lab](../Examples/Plugins/ReadingLab.hwattakplugin/README.md) |

버전별 지원 여부와 과거 빌드의 차이는 [호환성 표](PLUGIN-COMPATIBILITY.md#1-현재-지원-범위)에 모았습니다.

## 6. 오류를 해결하고 다른 사람에게 공유하세요

### 막혔을 때

| 증상 | 먼저 확인할 것 |
| --- | --- |
| 설치가 거부됨 | build 27인지, 폴더를 선택했는지, `main.js` 해시가 실제 파일과 같은지 확인합니다. |
| 불필요한 파일 오류 | `.DS_Store`, `package.json`, `node_modules`와 개발용 파일은 패키지 밖에 둡니다. |
| 설치했는데 명령이 안 보임 | 활성화 상태·필수 권한·전체 일시 중지 상태를 확인하고 문서 창으로 돌아갑니다. 실행 중인 확장의 오류 메시지도 확인합니다. |
| 코드 변경이 반영되지 않음 | 원본을 저장하고 해시를 갱신한 뒤, 관리 창에서 같은 식별자로 다시 설치합니다. |
| PDF 정보를 읽지 못함 | 두 권한 목록, 현재 PDF 유무를 확인합니다. 원문 읽기에는 PDF 복사 권한도 필요합니다. |
| 실행 중 멈춤 | 패널의 오류를 확인합니다. 종료되지 않는 반복문이나 과도한 API 호출은 실행 제한에 걸릴 수 있습니다. |

### 명령으로 패키지 검증하기 — 선택 사항

앱의 설치 검토만으로 시작할 수 있습니다. EmberPDF 소스와 [Swift/Xcode 개발 환경](../CONTRIBUTING.md#2-개발-환경)이 있다면 저장소 루트에서 아래 명령도 사용할 수 있습니다.

```sh
zsh scripts/validate_plugin.sh work/MyExtension.hwattakplugin
```

이 검사는 앱과 같은 패키지 검증 규칙을 사용합니다. 성공하면 `PLUGIN VALID`가 나오며 종료 코드가 0입니다. 처음에는 Swift 빌드가 필요합니다. **패키지 구조와 권한을 검사할 뿐 코드를 실행하지는 않으므로**, 앱에서 명령 실행·패널 닫기·문서 전환·권한 해제도 확인하세요.

### 배포 폴더 묶기

배포 전에는 예제의 `identifier`, 이름과 제작자를 자신의 값으로 바꿉니다. 식별자는 `dev.yourname.my-extension`처럼 정합니다. 소문자 영문·숫자를 기본으로 점과 하이픈을 사용하세요. 식별자를 바꾸면 앱에서는 별도 플러그인이 됩니다. 첫 배포 이후에는 그 식별자를 유지하세요. README에는 사용법, 권한을 요청하는 이유, 실제 시험한 앱 빌드와 알려진 한계를 적습니다. 예제의 MIT 라이선스 고지도 함께 보존합니다.

JavaScript 파일을 빠뜨리지 않도록 네 파일을 명시해서 압축합니다. 저장소 루트에서 실행하세요.

```sh
cd work
zip -X MyExtension.zip \
  MyExtension.hwattakplugin/manifest.json \
  MyExtension.hwattakplugin/main.js \
  MyExtension.hwattakplugin/README.md \
  MyExtension.hwattakplugin/LICENSE
unzip -l MyExtension.zip
```

받는 사람은 ZIP을 풀고 `MyExtension.hwattakplugin` 폴더를 설치하면 됩니다. 현재 공유·업데이트는 패키지를 전달하고 앱에서 검토해 설치하는 방식입니다. 공개 카탈로그와 자동 업데이트는 아직 제공하지 않습니다. 허용 파일·버전 규칙은 [패키지 형식 참조](PLUGINS.md), 보안 문제의 제보 방법은 [보안 정책](../SECURITY.md)에 있습니다.
