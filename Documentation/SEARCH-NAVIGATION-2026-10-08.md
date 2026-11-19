# 검색 결과 중앙 이동 — 2026-10-08

버전: **EmberPDF 0.9.0 (build 29)**

검색 결과를 선택했을 때 PDFKit의 기본 이동이 일치 문구를 화면 위쪽에 붙여 앞뒤 문맥을 읽기 어려웠다. 이제 결과 목록 클릭과 Enter·이전·다음 이동이 같은 경로로 읽기 영역의 세로 중앙에 문구를 표시한다.

PDF 좌표를 실제 스크롤 영역의 좌표로 변환하므로 확대 배율·페이지 회전·crop box를 반영한다. PDFKit이 검색 결과를 보이게 한 가로 위치는 유지하고 세로 위치만 조정한다. 문서 처음·끝이나 화면보다 작은 페이지에서는 스크롤 가능한 범위로 제한하며 중앙 정렬을 위해 확대 배율이나 페이지 여백을 바꾸지 않는다.

기본 선택 애니메이션을 끄고, 페이지 맞춤과 화면 배치가 완료된 뒤 한 번만 위치를 보정한다. 검색 결과·문서·편집 버전이 바뀌거나 검색 취소·뷰 분리·사용자 스크롤/확대/클릭이 발생하면 대기 중인 보정을 취소한다. 탭 복귀의 저장된 읽기 위치가 있다면 그 위치를 복원한다. 검색 결과가 추가될 때마다 화면을 다시 움직이지 않는다.

build 28의 현재 페이지부터 순환 검색, 검색 중 사이드바와 결과 조작, Enter/Shift-Enter 탐색은 유지한다. 수동 스크롤 후 가까운 검색어에만 적용하는 기존 작은 위치 보정은 별도의 동작이다.

## 검증

이번 변경의 관련 검사 **115개 통과, 기존 환경 제한에 의한 건너뜀 2개, 실패 0**을 확인했다. 이전 build 28의 전체 회귀 검사 수와 구분하며 이번에는 아래 범위를 실행했다.

| 검사 | 결과 | 로그 |
| --- | --- | --- |
| 검색 위치·장식 및 실제 PDFView | 10개 통과 | `work/search-centering-tests.log` |
| 검색 모델·페이지 탐색·페이지 맞춤·검색 스크롤 정책 | 58개 통과 | `work/search-center-navigation-tests.log` |
| 방향키 입력·페이지 탐색 | 30개 통과 | `work/search-center-keyboard-tests.log` |
| 실제 검색 입력창의 Return·Shift-Return | 1개 통과 | `work/search-center-toolbar-tests.log` |
| 화면 스크롤·확대 | 16개 통과, 기존 macOS 15 PDFKit 호스트 제한 2개 건너뜀 | `work/search-center-viewport-tests.log` |
| 프로젝트 정적 검사·10개 언어 일치 | 통과 | `work/search-center-static.log` |

새 위치 검사 3개는 1.7배 확대·crop·90도 회전 페이지의 연속/단일 페이지 보기, 문서 양 끝의 이동 범위 제한, 연속 결과 변경과 검색 취소 뒤 지연 보정 취소를 실제 화면 좌표로 확인한다.

별도 식별자의 QA 앱에서 8페이지 합성 PDF를 열어 4페이지 첫 결과 검색, 5페이지 결과 목록 클릭, Enter로 다음 일치 항목 이동을 확인했다. 각 강조 문구가 도구줄을 제외한 읽기 영역의 세로 중앙에 표시됐으며, 이후 직접 스크롤한 위치를 유지했다. 사용자의 기존 앱과 문서는 조작하지 않았다.

## 설치본

- 앱: `outputs/search-center-build29/EmberPDF.app`
- ZIP: `outputs/search-center-build29/EmberPDF-0.9.0-macOS-arm64.zip`
- SHA-256: `7ebb38f834a1bcc95ebdf68560a9c8a65d2d89bcad720567cc38967392808a10`
- 패키지 및 ZIP의 실행 파일·framework·helper·ad-hoc 서명·권한·아이콘·현지화·고지 검증 통과: `work/search-center-package.log`.
- `/Applications/EmberPDF.app`에 build 29를 설치하고 설치본 버전과 서명을 확인했다. 기존 build 28은 `work/body-text/EmberPDF-build28-replaced.app`에 보존했다. 실행 중인 앱을 종료하지 않았으므로 사용자 문서를 저장하고 재실행하면 적용된다.
- GitHub Release 게시와 Apple 공증은 포함하지 않았다.
