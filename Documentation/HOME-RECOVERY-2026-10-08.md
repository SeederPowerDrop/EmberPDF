# 홈 배치와 최근 파일 다시 연결 — 2026-10-08

버전: **EmberPDF 0.9.0 (build 32)**

## 홈 화면

왼쪽에는 앱 아이콘·이름·철학 문구·열기 버튼·플러그인 관리를, 오른쪽에는 최근 PDF 목록을 배치한다. 아이콘은 기존 88pt에서 **200pt**로 확대했다. 콘텐츠 폭은 최대 1120pt이고 900pt 미만의 공간에서는 세로로 배치한다. 최근 파일의 날짜를 경로 옆 메타데이터 줄에 고정 폭으로 표시하여 긴 경로 때문에 날짜가 ‘2…’처럼 잘리지 않게 한다. 기록 제거와 원본 보존 동작은 유지한다.

## 오류 조사

스크린샷의 ‘최근 문서 접근 권한을 복원하지 못했습니다’는 PDF 내용 오류가 아니라 저장한 security-scoped bookmark를 해석하는 단계의 실패 메시지다. 조사 시 실제 최근 목록의 일곱 경로에 모두 파일이 남아 있었다. 따라서 해당 파일이 반드시 삭제됐거나 사용자가 잘못 조작했다는 의미가 아니다. 어떤 항목을 클릭했는지는 확인되지 않아 그 클릭의 정확한 원인은 단정하지 않는다.

설치본은 ad-hoc 서명이며, build 30과 31의 designated requirement가 각각 다른 `cdhash`에 묶여 있음을 확인했다. Apple은 [ad-hoc 서명의 요구 조건이 코드 버전에 종속됨](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)과 [security-scoped bookmark의 서명 동일성 요구](https://developer.apple.com/documentation/Foundation/NSURL/bookmarkData%28options%3AincludingResourceValuesForKeys%3ArelativeTo%3A%29?language=obj_7)를 설명한다. 업데이트로 접근 정보가 유효하지 않게 된 것이 유력한 원인이라는 추론이다. 파일 이동·삭제 등 다른 접근 실패도 같은 복구 흐름으로 다룬다.

기존 구현의 확정된 문제는 이미 로드된 PDF도 먼저 이전 bookmark를 해석했고, 실패 시 복구 동작 없이 오류만 표시한 점이다.

## 수정

- 현재 워크스페이스에 이미 로드된 같은 PDF가 있으면 해당 탭을 선택한다. 문서 객체와 미저장 편집을 보존한다. 휴면 탭은 이 경로에 포함하지 않는다.
- 접근 정보를 복원하지 못하면 **파일 다시 선택… / 최근 목록에서 제거 / 취소**를 제공한다. 파일 선택 창은 이전 폴더를 안내하며 사용자가 선택한 PDF의 새 접근 권한을 사용한다.
- 원본 경로를 기억한다는 이유만으로 권한 없이 파일을 여는 fallback은 추가하지 않는다. 진단용 경로는 기존 로드 탭 비교와 선택 창 안내에만 사용한다.
- 선택한 PDF가 실제로 로드되고 잠금이 해제된 뒤에만 새 bookmark를 기록한다. 이미 열린 탭의 접근 권한 갱신도 문서 재로딩이나 편집 상태 변경 없이 유지한다.
- 이동한 파일의 재연결은 기존 항목과 중복 경로를 한 번에 교체한 뒤 일곱 개 제한을 적용한다. 다른 오래된 항목이 먼저 밀려나지 않는다. 취소·열기 실패·bookmark 저장 실패 시 기존 기록을 보존한다.
- 안내 문구 네 개를 지원하는 열 개 언어에 추가했다. 모든 샌드박스 권한과 서명 정책은 유지한다.

이번 변경은 무효화된 접근 정보를 사용자가 복구할 수 있도록 한다. 안정적인 배포 서명으로 바꾸기 전에는 향후 개발용 업데이트에서 파일 재선택이 다시 필요할 수 있다. Developer ID 서명·공증을 수행한 것은 아니다.

## 검증

- `RecentDocumentsStoreTests`: 14개 통과. 새 회귀 6개는 잘못된 bookmark와 취소, 로드된 편집 문서 재선택, 영속 bookmark 복구, 재인증 후 편집 보존, 가득 찬 기록의 이동 파일 교체, 잘못된 PDF 선택 시 기록 보존을 검사한다.
- `MultiDocumentWorkspaceStateTests`: 14개 통과.
- `MultiDocumentEncryptedBatchTests`: 5개 통과.
- `LocalizationAndIconSettingsTests`: 7개 통과.
- 합계 **40개 통과**, 실패·건너뜀 없음 (`work/home-recovery-build32/tests.log`). 이번 변경에 관련된 검사 범위다.
- 정적 검사, 열 개 언어의 키·형식 일치와 문법, 공백 검사 통과 (`work/home-recovery-build32/static.log`).
- 별도 `com.vibepdf.mac.homerecoveryqa` QA 앱에 일곱 개의 합성 PDF와 잘못된 테스트 bookmark를 준비했다. 큰 아이콘·좌우 배치·긴 이름·전체 날짜 표시를 실제 화면에서 확인했다.
- 실제 최근 항목 클릭 → 복구 안내 → 파일 선택 창 → 취소 후 일곱 기록 유지 → 재시도 → 선택한 PDF 열기를 확인했다. 문서를 닫고 앱을 종료·재실행한 다음에는 추가 파일 선택 없이 최근 목록에서 정상적으로 열렸다.
- 선택한 항목만 유효한 bookmark로 갱신됐고 일곱 기록과 모든 원본 PDF 바이트가 유지됨을 확인했다. QA 앱은 종료했으며 사용자 앱의 문서·설정·최근 기록은 변경하지 않았다.

## 설치본

- 앱: `outputs/home-recovery-build32/EmberPDF.app`
- ZIP: `outputs/home-recovery-build32/EmberPDF-0.9.0-macOS-arm64.zip`
- SHA-256: `4a7e52cbb1665cec8874facc251ee59a70f290a046d5fa29e7a173f1ae0ad639`
- 앱·ZIP의 실행 파일, framework/helper, 서명·권한·아이콘·언어·고지 검사 통과 (`work/home-recovery-build32/package.log`).
- `/Applications/EmberPDF.app`의 build 32 설치와 서명을 확인했다. 이전 앱은 `work/home-recovery-build32/EmberPDF-build31-replaced.app`에 보관했다.
- 사용자 앱을 강제로 종료하지 않았다. 문서를 저장한 후 재실행하면 적용된다. GitHub Release 게시·Apple 공증은 이번 작업에 포함하지 않았다.
