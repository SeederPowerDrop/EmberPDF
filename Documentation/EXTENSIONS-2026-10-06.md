# EmberPDF 독립 확장 API — 2026-10-06

대상 소스: **0.9.0 build 27**. 이 문서는 구현 계약과 검증 증거를 구분한다. 아래 범위의 자동 검사, release 패키지, 설치 앱 확인을 완료했다. [build 26 결과](PLUGIN-FOUNDATION-2026-10-05.md)는 과거 산출물에만 적용한다.

## 목적과 이번 변경

EmberPDF가 제공하는 기본 기능을 넘어 개발자가 독립적인 기능을 작성·배포하도록 한다. 번역·노트·색상·클립 같은 사례는 기능 목록의 끝이 아니다. 개발자는 버전형 API로 문서 정보를 읽거나 승인된 작업을 호출하고, 자신의 계산·명령·이벤트 처리·화면·상태를 만든다. 기존 API를 사용하는 새 플러그인은 호스트를 다시 빌드하지 않고 설치한다.

schema 6은 코드의 수명을 패널에서 분리한다. 사용자가 검토·설치·활성화한 확장은 `backgroundExecution` 권한 아래 각 앱 창에서 시작하고, PDF가 없어도 사용할 수 있다. 패널을 숨기거나 탭·워크스페이스를 바꾸어도 명령과 이벤트는 유지된다. 화면은 `ui.render`와 `ui.open/close`로 제어한다.

| 경계 | 이번 계약 |
| --- | --- |
| 패키지 | `runtime: {apiVersion: 1, entry: "main.js", sha256, activation: "window", capabilities}`. schema 6만 허용하며 actions가 비어도 유효 |
| 수명 | 창·플러그인별 독립 worker, 앱 전체 최대 8개. 패널 숨김은 실행 종료가 아님 |
| 명령 | 플러그인·창 범위를 구분하며 메뉴·도구줄·명령 팔레트에서 현재 창의 명령을 실행 |
| 이벤트 | app.ready·workspace.changed·document.changed·documents.changed·page.changed·selection.changed·view.action·view.input |
| 문맥 | app.getContext는 apiVersion·windowID·workspaceID·tabID·hasDocument만 반환. 원문·경로를 자동 노출하지 않음 |
| 문서 읽기 | 현재 페이지는 currentPageText 또는 documentTextRead. 다른 페이지는 documentTextRead가 필요하며 PDF 복사 권한 확인 |
| 문서 명령 | commands.execute는 주석·도구·페이지/모드 명령을 권한·선택 소유권·모드·Undo 경계로 연결 |
| 정리 | disable·필수 권한 철회·안전 모드·업데이트·제거·창 종료에서 worker·명령·이벤트·UI·진행 요청 회수 |

schema 1~5는 계속 지원한다. schema 5 scriptPanel은 기존 패널 수명을 유지하며 schema 6과 같은 패키지에 중복 코드 진입점을 선언하지 못한다. 승인되지 않은 새 runtime이 설치 폴더에 나타나도 기존 형식의 권한 이전으로 자동 승인하지 않는다.

## 보안과 실패 처리

각 확장은 별도 JavaScriptCore 프로세스로 실행한다. 승인된 JSON API만 공개하며 앱/PDFKit 객체·직접 파일 경로·Node·DOM·직접 네트워크·셸 API를 넘기지 않는다. 각 worker의 dispatch 3초 감시, 호출·큐·메시지·UI 상한은 유지한다. 다른 worker가 실패해도 정상 worker를 함께 종료하지 않는 구조다.

문서 전환은 확장을 없애는 대신 이전 문서의 진행 요청을 취소한다. 오래된 읽기 결과가 새 문서에 표시·적용되지 않도록 `CONTEXT_CHANGED` 오류를 전달한다. 갤러리·같이 보기의 읽기 전용 문맥에서는 문서 명령을 차단한다. `ember.dispose`는 최선 노력의 로컬 정리이며 강제 종료에서 성공을 보장하지 않는다. 필수 저장은 정상 실행 중 처리한다.

해시는 승인한 manifest와 코드를 묶는 무결성 검사이며 게시자 인증이 아니다. JS heap의 엄격한 바이트 상한, 공개 카탈로그·게시자 서명·자동 업데이트는 이번 계약에 포함되지 않는다. 여러 창의 플러그인별 JSON 저장소는 공유된다. `storage.compareAndSet`은 비교·교체를 MainActor에서 중단 없이 수행해 오래된 값으로 덮어쓰는 것을 막는다. 개발자는 충돌 결과를 받고 다시 읽어 제한된 횟수만 재시도한다. [보안 참조](PLUGIN-SECURITY.md).

## 독립 개발 예제

[Research Trail](../Examples/Plugins/ResearchTrail.hwattakplugin/README.md)은 `backgroundExecution`, `documentMetadata`, `pluginStorage`만 사용하는 runtime-only 패키지다. 개발자 코드가 페이지 방문 기록과 자체 명령·화면을 작성한다. PDF 없이 시작하고, 패널을 닫은 채 문서를 오가며, 명령으로 기록을 다시 표시한다. 예제 패키지는 공식 ID나 번들 신뢰 예외 없이 일반 커뮤니티 검사 규칙을 통과하도록 작성했다.

[한국어 제작 가이드](PLUGIN-DEVELOPMENT.md) · [English](PLUGIN-DEVELOPMENT.en.md) · [호스트 API](PLUGIN-HOST-API.md) · [TypeScript 선언](PluginSDK/emberpdf.d.ts) · [호환 계약](PLUGIN-COMPATIBILITY.md).

## 검증 상태

자동 검사 로그는 `work/ember-extensions-20261006/extension-tests.log`, `storage-tests.log`, `notes-clip-tests.log`에 남겼다. 첫 실행에서 발견한 이벤트 등록 변수 가림, 다중 worker 파이프 대기, 비정상 JSON 스칼라, FIFO 사전 검사 문제를 수정한 뒤 실패했던 범위를 재검증했다. 총 143개는 중복 실행을 제외한 고유 검사 수다. `scripts/validate_project.sh`와 `git diff --check`도 통과했다.

| 항목 | 현재 증거 |
| --- | --- |
| manifest·권한·코드 해시 회귀 | PluginRuntimeManifestTests 8개 통과. 해시·권한·정적/동적 계약을 포함한 관련 회귀 총 143개 고유 XCTest 통과 |
| 페이지 읽기·문서 명령 권한 | PluginScriptHostAPITests 10개 통과. 명시적 페이지 읽기·권한·보호 PDF·선택 소유권·문서 명령 포함 |
| 원자적 저장소 | PluginScriptStorageTests 4개 통과. Research Trail JS 모의 검사에서 8창·16방문 보존, 56충돌 재시도와 다시 열기 최신값 확인 |
| 다중 실행기·문맥·명령 범위 | PluginExtensionHostTests 8개, PluginScriptSessionTests 15개 통과. 실제 helper 사용, 빈 문서·창 구분·권한 철회·읽기 전용 명령 차단·8개 worker·정상 취소 확인 |
| 노트·클립 회귀 | PluginNotesTests 16개, PluginPageClipTests 6개 통과. FIFO를 파일 조정기 호출 전에 거부하도록 보강 |
| 지역화 | 새 공통 문구 6개를 10개 언어에 추가, strings 문법 검사 통과 |
| release 빌드·서명·ZIP | arm64 0.9.0 build 27 빌드·패키지 검증 통과. /Applications 설치본의 실행 파일·helper가 최종 산출물과 일치하고 strict/deep 서명 검증 통과 |
| 설치 앱에서 Research Trail | 일반 권한 검토 후 설치, 팔레트 명령 실행, 패널 숨김 중 1→2페이지 기록, Reading Lab과 동시 실행, 배경 실행 권한 철회 시 해당 확장만 종료, 권한 복원과 앱 재시작 후 명령 재등록을 확인 |

이 표는 해당 범위의 검증만 기록한다. 전체 저장소의 모든 테스트, 모든 개발자 확장, 장시간 자원 사용이나 외부 보안 감사를 대신하지 않는다.

## 설치와 실제 화면 확인

최종 ZIP: `outputs/EmberPDF-0.9.0-macOS-arm64.zip`

SHA-256: `d66e63226bbca4d057252a8a24a080f24d1f37cea6b8c3f3d97df1d242495223`

실제 macOS 앱에는 build 27을 설치했다. GUI 검증은 저장소의 합성 2페이지 PDF로 진행했다. Research Trail의 데이터와 화면은 패키지의 main.js만 작성하며, 앱 소스에는 읽기 이력 전용 기능이 없다. 닫힌 패널에서도 페이지 2 기록이 추가되고, Reading Lab을 연 뒤에도 두 실행기가 유지됨을 확인했다. 배경 실행 권한을 끄면 Research Trail 화면·명령이 사라지고 Reading Lab은 계속 실행됐다. 최종 앱을 다시 실행했을 때 패널을 열기 전부터 도구줄에 읽기 여정 명령이 등록됐다. 실제 UI의 오래된 ‘실행 코드/상주 작업 없음’ 안내도 10개 언어에서 수정했다.

검증 뒤 Research Trail 예제는 설치된 채 비활성화했다. 테스트 PDF와 테스트 패널을 닫고 기존 12개 탭 및 원래 선택된 문서의 34페이지를 복원했다. PDF 없는 시작과 여러 워크스페이스·창의 전환은 위 실제-helper 통합 검사에서 확인한 범위이며, GUI에서 별도로 같은 항목을 전부 반복한 것은 아니다.

build 26 백업: `outputs/EmberPDF-0.9.0-build26-macOS-arm64.zip`, `work/ember-extensions-20261006/EmberPDF-build26.app`.
