# Option+상하좌우 페이지 이동 — 2026-10-10

대상: EmberPDF 0.9.0 (build 43), macOS arm64.

## 변경

- build 42에서 모든 Option 조합을 네이티브 PDFKit으로 넘겨 새 방향키 옵션이 적용되지 않던 경로를 수정한다.
- ‘상하좌우 다 사용하기’에서 Option+↑/←는 이전 페이지·묶음, Option+↓/→는 다음 페이지·묶음으로 이동한다. 일반 Option 반복 속도는 기본 방향키 속도와 같다.
- 네이티브 1/2페이지 보기와 SwiftUI 3–12페이지 보기에서 적용한다. 공유 반복기는 호출한 화면이 명시적으로 허용한 경우에만 Option을 받으며 기존 사이드바와 두 탐색 모드는 유지한다.
- 검색·메모·폼·주석 편집기 및 활성 텍스트 선택은 기존 커서·선택 조작을 우선한다. Shift+Option, Command, Control 조합을 가져오지 않는다. 함께 보기의 고정과 동기 이동은 기존 처리를 유지한다.

## 검증

- 관련 검사 **117개 통과, 실패·건너뜀 없음**. `work/option-arrows-build43/tests.log`.
- 네이티브 PDFView: Option+네 방향키, 보기/편집/학습 모드, 1/2페이지 보기와 여러 확대율, 문서 시작·끝, Shift/Option 선택 보호, 폼·사이드 편집기 포커스, 기존 탐색 모드와 비교 보기 동작을 검사했다.
- 공유 반복기: 네 방향 Option 즉시 이동 및 반복, 키 해제, 반복 중 Option 추가·해제, OS 반복 중복 방지, 모드별 허용 범위, Command/Control/Shift+Option 양보, 포커스 이동 후 취소를 검사했다.
- SwiftUI 격자는 allDirections일 때만 Option을 허용한다. 기존 3–12페이지 묶음 이동과 사이드바의 키 처리 회귀 검사도 통과했다.
- 정적 검증 및 10개 언어의 키/자리표시자 일치 통과. 이번 확인은 자동 네이티브 이벤트 검사이며 별도 실앱 UI 조작은 수행하지 않았다.

## 패키지

- Release arm64 빌드, 앱/worker 서명·권한 및 ZIP 재추출 검증 통과. `work/option-arrows-build43/package.log`.
- 설치: `/Applications/EmberPDF.app` — **0.9.0 (43)**. 설치 실행 파일과 Release 산출물 일치 및 서명 검증 통과.
- 이전 앱: `work/option-arrows-build43/EmberPDF-build42-replaced.app`.
- ZIP: `outputs/option-arrows-build43/EmberPDF-0.9.0-macOS-arm64.zip`.
- ZIP SHA-256: `b829769a4fb774fedd437f043116afea146e93a2486058da6bf1365f0cd5be17`.
- 실행 파일 SHA-256: `96ca0cb3f6af0cf64b69111d72e4c5de472062d586d92bfc18250b94e9020a16`.
- 실행 중인 사용자 앱을 종료하거나 기존 설정을 변경하지 않았다. 저장 후 종료·재실행하면 새 빌드가 적용된다. 공개 배포·공증은 수행하지 않았다.
