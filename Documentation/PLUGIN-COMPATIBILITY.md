# 플러그인 호환성과 확장 설계

상태 기준: **2026-10-06, 0.9.0 build 27 확장 소스**. “현재 동작”은 코드에 있는 규칙이고, “제안”은 구현·배포를 약속한 API가 아니다. 아래 설계용 용어를 manifest에 임의로 추가하면 현재 검사기는 거부한다.

[제작 시작](PLUGIN-DEVELOPMENT.md) · [문서 명령 참조](PLUGIN-HOST-API.md) · [보안과 신뢰](PLUGIN-SECURITY.md)

## 1. 현재 지원 범위

| 대상 | schema 1~3 | schema 4 패널 | schema 5 패널 SDK | schema 6 창 수명 runtime |
| --- | --- | --- | --- | --- |
| 0.9.0 build 27 소스 | 지원 | 지원 | 지원 | API 1 지원 |
| 0.9.0 build 26 | 지원 | 지원 | 지원 | 미지원 |
| 0.9.0 build 25 및 이전 갤러리 소스 | 지원 | 미지원 | 미지원 | 미지원 |
| 이전 0.8.0/build 18 바이너리 | schema 3은 지원하지 않을 수 있음 | 미지원 | 미지원 | 미지원 |
| 임의의 과거/향후 빌드 | 실제 산출물 검사 | 실제 산출물 검사 | 실제 산출물 검사 | 실제 산출물 검사 |

`minimumHostVersion: "0.9.0"`만으로 build 25·26·27의 SDK 차이를 구분하지 못한다. 개발자는 지원 schema와 실제 시험한 빌드·소스 revision·검증 날짜를 README에 기록한다. 설치 parser는 지원하지 않는 schema를 거부하며, manifest에 임의 `minimumHostBuild` 필드를 추가해서 우회할 수 없다. **현재 최소 build 필드는 없다.** build 27의 소스 반영과 실제 빌드·배포·공개 릴리스 여부를 혼동하지 않는다.

과거 성능·checksum 보고서는 그 당시 산출물에만 적용한다. 소스를 바꿔 다시 빌드했다면 기존 checksum을 새 파일에 재사용하지 않는다.

### 버전 필드의 차이

| 이름 | 의미 | 현재 검사 |
| --- | --- | --- |
| `schemaVersion` | manifest의 문법·출력·명령 계약 | 지원 집합 1·2·3·4·5·6 중 하나인지 검사. 알 수 없는 키·enum은 거부 |
| `runtime.apiVersion` | 실행형 창 확장 API 계약 | 현재 1, 모르는 값은 거부 |
| `version` | 제작자가 배포한 플러그인의 버전 | `major.minor.patch` 문법만 검사. 설치본보다 큰지 검사하지 않음 |
| `minimumHostVersion` | 요구하는 EmberPDF 앱 버전 | 앱의 `CFBundleShortVersionString`과 숫자 비교. 생략 가능하지만 배포자는 명시 권장 |

세 성분 버전은 각 성분 0~999999, 불필요한 앞자리 0 없이 쓴다. prerelease·build metadata·범위 표현은 지원하지 않는다. `^0.8`, `>=0.8.0`, `0.8.0-beta`, `0.8.0+19`를 쓰면 안 된다. `minimumHostVersion`은 schema 기능을 자동 협상하거나 대체 명령을 골라 주지 않는다.

### 패키지별 지원 기능

| 출력 | 최소 schema | 일반 커뮤니티 패키지 |
| --- | --- | --- |
| `showText`, `copyText`, `openURL` | 1 | 사용 가능. 상위 schema에서도 기존 토큰 규칙 유지 |
| `translatePanel`, `browserPanel`, `youtubePanel` | 2 | 공식 번들의 동일 identifier+manifest digest만 허용 |
| `documentCommand` | 3 | 사용 가능. 문서 명령 10종 중 선택 |
| `appearancePanel`, `notesPanel`, `pageClipPanel`, `relatedDocumentsPanel`, `hoverTranslationPanel` | 4 | 사용 가능. 호스트 UI와 기능 요청 |
| `scriptPanel` + `main.js` | 5 | 패널 수명 JavaScript, 승인된 JSON API·네이티브 UI |
| `runtime` + `main.js` | 6 | 창 수명 JavaScript, 독립적인 명령·이벤트·패널·상태 |

build 27은 기존 12개 검토본에 schema 6 Research Trail 예제를 추가한다. 번들 포함만으로 설치하지 않는다. 사용자가 설치·활성화하고 필요한 권한을 승인한 runtime은 창 수명에 따라 자동 시작한다. 커뮤니티의 schema 4~6은 일반 권한·형식·digest 검증을 따르며 공식 웹 패널 allowlist를 우회하지 않는다. YouTube는 소스 검토 전용이다. [기본 패키지 목록](PLUGINS.md#090-기본-플러그인-검토-및-설치).

## 2. 우리가 지킬 호환성 원칙

다음은 기여와 릴리스 검토를 위한 **유지보수 원칙**이다. 지원 기간이나 미래 구현을 보장하는 계약은 아니다.

1. **기존 의미 보존:** 배포한 명령·토큰·권한의 뜻을 조용히 바꾸지 않는다. 같은 `highlight`가 다음 버전에서 파일 저장까지 수행하게 만들면 안 된다.
2. **파괴적인 변경 분리:** 문법이나 의미가 달라지면 새 schema/명령과 마이그레이션 설명을 제안한다. 구형 패키지의 오류를 숨기고 일부만 실행하지 않는다.
3. **권한 확대 가시화:** 새 입력·파일/네트워크 접근은 명시적인 권한과 검토 UI가 필요하다. 기존 권한에 묻어 추가하지 않는다.
4. **이전 호환 경로 시험:** 기존 schema 1 텍스트와 schema 2 번들 패널 테스트를 함께 유지한다. 공식 패키지의 digest와 지역화 식별 규칙 변경도 확인한다.
5. **재현 가능한 배포:** 고유 앱 버전/빌드, 소스 commit, 패키지 version, checksum과 실제 시험 결과를 기록한다.

현재 호스트는 조건부 action, optional capability, fallback template, 최대 호스트 버전, dependency resolver, 패키지 간 호출을 지원하지 않는다. schema 3 기능과 구형 앱 지원을 함께 제공하려면 별도의 호환 릴리스를 배포하고 어떤 파일을 선택할지 설명한다. 새 명령을 옛 schema로 표기하지 않는다.

플러그인 업데이트는 동일 identifier의 수동 검토 교체다. 낮은 version으로도 되돌릴 수 있으며, 활성 상태와 호스트 옵션은 유지한다. 플러그인 제거가 이미 저장한 주석을 제거하지는 않는다. schema 5·6의 bounded 플러그인 전용 JSON 설정은 제공하지만 임의 설정 파일 경로나 문서 migration callback은 없다.

## 3. 독립 확장의 호환 계약

호환 대상은 EmberPDF의 버전형 API다. 패키지 로직은 호스트 내부 Swift 타입 대신 `ember` 계약을 사용한다. 명령·문서 이벤트·네이티브 UI·플러그인별 저장소를 조합해 개발자가 새 동작을 제공한다. 새 플러그인을 설치할 때 호스트 코드를 수정하거나 다시 빌드하지 않는다.

| 계약 | 호스트와 개발자의 책임 |
| --- | --- |
| 창 수명 | `activation: "window"`·`backgroundExecution`; 패널을 숨겨도 동작하며 창 종료·비활성화·권한 철회 시 회수 |
| 명령 범위 | 확장과 창별로 명령을 구분, 같은 local ID의 다른 플러그인 명령이 충돌하지 않음 |
| 문서 문맥 | 이벤트에서 opaque context를 받고 승인된 API로 현재 문서를 요청; 이전 문서 비동기 결과는 취소 |
| UI | `render`로 내용을, `open/close`로 표시를 제어. 화면 수명은 실행 수명과 분리 |
| 저장소 | 플러그인별 JSON 64 KiB, 여러 창 공유. compareAndSet의 원자적인 조건부 교체와 충돌 재시도 |
| 수정 | `commands.execute`는 호스트의 PDF 권한·모드·선택·Undo 계약을 유지 |
| 실패와 정리 | worker별 시간·요청 한도, 앱 전체 최대 8개. 종료 시 host가 모든 기여를 회수; dispose는 최선 노력 |

[개발 시작](PLUGIN-DEVELOPMENT.md#1-먼저-완성된-예제를-실행하세요)과 [타입 선언](PluginSDK/emberpdf.d.ts)을 API 기준으로 삼는다. 패키지가 사용하는 메서드·권한·지원 schema와 시험한 앱 빌드를 README에 기록한다.

## 4. PDF·OS·입력 장치 호환성

### PDF 파일

문서 명령은 살아 있는 PDFKit 문서에 호스트가 수행한다. 플러그인에 `PDFDocument`나 `PDFPage` 객체를 전달하지 않는다. 주석·Undo·dirty 상태·원본 충돌 감지·암호화 문서 저장 정책은 호스트가 소유한다. 문서가 바뀌었거나 현재 권한/선택이 유효하지 않으면 주석 명령은 실패한다.

native Highlight/Ink와 사용자 정의 appearance를 가진 Stamp는 PDF 안에 저장된다. 다른 PDF 앱에서 **보이는 것**과 그 앱의 원래 도구로 **재편집할 수 있는 것**은 다르다. 굵기·투명도 강조, 밑줄과 필압 Stamp는 저장 후 화면을 확인한다. 압축·복사·다른 앱의 주석 처리에 대한 보편적 호환 보장은 없다.

학습 모드의 외부 주석 편집 제한도 유지한다. 저장 후 다시 연 Stamp는 이전 런타임 객체와 다른 객체이므로 이름만 보고 학습 모드 편집 신뢰를 복원하지 않는다. 필요한 편집은 에디팅 모드에서 한다.

### OS·언어·입력

- manifest와 JavaScript 소스는 CPU 독립적이지만 실행 호스트와 helper는 현재 macOS 앱이다. 배포 후보의 검증 아키텍처는 arm64다. iOS·Windows·Linux 실행 호환을 뜻하지 않는다.
- 일반 플러그인의 이름·명령 제목은 manifest의 문자열 그대로다. 여러 언어 manifest 선택이나 `locales/` 폴더는 지원하지 않는다. 짧은 이중 언어 제목이나 언어별 배포 설명을 사용할 수 있다. 호스트의 공통 UI 지역화와 구분한다.
- `pen`은 호스트 펜을 설정한다. Sidecar/태블릿 연결, 압력 이벤트의 품질은 OS와 기기의 영역이다. manifest에는 `pressureEnabled` 필드나 장치 드라이버가 없다.
- 실제 iPad/Wacom 필압·지연·팜 리젝션을 시험하지 않았다면 지원을 보장한다고 쓰지 않는다. 기기 설정은 [Apple Sidecar 안내](https://support.apple.com/en-us/102597)를 참고한다.

## 5. 아직 없는 기능을 추가하는 방법

현재 host action으로 표현할 수 있으면 선언형 패키지를 만들고, 기존 API와 native view 어휘로 표현할 수 있으면 schema 6 runtime 로직을 작성한다. 새 문서 접근 권한·네트워크·UI 종류·수정 transaction이 필요하면 호스트 API를 제안하거나 코어에 기여한다. 기존 API를 조합하는 새 기능에는 호스트 배포가 필요하지 않다. 새로운 네이티브 자원 API 자체를 추가할 때는 호스트 변경과 배포가 필요하다.

### 제안서에 담을 내용

```text
사용자 문제: 어떤 작업을 몇 단계 줄이고 싶은가?
구체적 예: 입력 문서/선택 → 사용자가 누르는 명령 → 기대 결과
현재 API로 부족한 점:
필요 입력: 선택 텍스트 / 특정 페이지 / 주석 / 장치 이벤트 중 무엇인가?
결과: 읽기 / 주석 변경 / 파일 저장 / 외부 전송 / 사용자 정의 UI
권한과 데이터 수명: 수집 이유, 저장 위치, 삭제/철회 시점
실행 모델: 사용자 실행인가, 이벤트/백그라운드 실행인가?
실패 처리: 취소, 탭/문서 변경, 권한 거부, Undo, 중복 실행
자원 예산: 최대 페이지·바이트·시간·동시 작업 수
호환성: 기존 schema/플러그인/PDF에 미치는 영향
검증: 개인정보 없는 fixture, 예상 결과, 최소 지원 환경
```

일반 제안은 [이슈 선택 화면](https://github.com/SeederPowerDrop/EmberPDF/issues/new/choose)을 사용한다. 보안 제보는 [비공개 절차](../SECURITY.md)를 따른다. 접수는 구현 일정이나 승인 보장이 아니다.

### 코어 기여자가 새 문서 명령을 연결할 때

| 변경 위치 | 함께 검토할 내용 |
| --- | --- |
| `Sources/HwattakPDF/Plugins/PluginDocumentCommand.swift` | Kind·입력 범위·필요 capability·실행 가능 조건 |
| `PluginModels.swift`, `PluginManifestValidator.swift` | schema 협상과 정확한 권한 합집합, 알 수 없는 필드 거부 |
| `PluginActionRunner.swift`, `PluginActionLauncher.swift` | 실행 직전 활성 설치본·action 소유권, 오래된 요청 무효화 |
| `Models/PDFWorkspaceState.swift` | 중앙 문서 권한, 현재 문서 객체, revision, Undo와 저장 경계 |
| 메뉴·툴바·팔레트와 지역화 | 실행 가능 표시와 실제 실행 조건의 일치, 필요한 10개 언어 공통 문구 |
| `Tests/HwattakPDFTests/PluginSystemTests.swift` 등 | 정상·잘못된 값·권한 거부·stale selection·비활성화·Undo/Redo·저장 결과 |

앱이 사용하는 PDFKit 객체를 임의의 worker로 넘기지 않는다. 긴 작업은 입력을 제한하고 취소·진행률·문서 revision 검사를 갖춘다. 패키지 README, API 표, 예제 검사, schema 1·2 회귀 검증도 PR에 포함한다. [코어 기여 원칙](../CONTRIBUTING.md).

## 6. 커뮤니티 확장을 위한 다음 단계 — 설계 제안

| 단계 | 제공하려는 경험 | 배포 전에 필요한 조건 |
| --- | --- | --- |
| 현재 | 선언형 명령·호스트 패널·격리 JavaScript SDK v1·로컬 검토 설치 | schema 6 창 수명·패널 독립·허용 API·검증 범위 안에서 사용 |
| API 계약 정리 | 버전별 지원표, 기계 판독 가능한 schema와 문서 생성, 호환 fixture 모음 | 동일 의미의 기존 명령 유지, 고유한 앱 릴리스 식별, 최소 버전 오류 UX |
| 더 넓은 호스트 API | 주석 읽기·선택 영역 작업·학습 데이터 같은 요청별 확장 | 기능별 별도 권한, 읽기 범위·수명·Undo transaction·대용량 예산 |
| 실행형 SDK 확장 | 더 다양한 native view, 문서 수정 transaction, 추가 백그라운드 작업 모델 등 | 기존 격리·권한·한도를 유지하고 취소·Undo·자원 제한·오류 복구를 각각 추가 검토 |
| 커뮤니티 디렉터리 | 검색·버전 확인·검토된 업데이트 흐름 | 출처·서명/무결성 정책, 신고·격리·철회 절차, 호환 배포 선택, 업데이트 권한 재검토 |

schema 4 호스트 패널·schema 5 패널 SDK·schema 6 창 수명 API 1은 현재 구현 범위다. 이 표의 다음 단계가 일정이나 배포 약속은 아니며 자동 리뷰 서버·서명 카탈로그는 없다. 앱 프로세스 안에서 임의 Swift/네이티브 라이브러리를 실행하도록 파일 검사만 풀어서는 문서 권한·안정성을 보장할 수 없다. 격리된 코드도 PDF 수정은 호스트의 검증된 변경 경로로 요청하게 설계해야 한다.
