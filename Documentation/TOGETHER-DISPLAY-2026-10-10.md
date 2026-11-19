# 함께 보기 버튼·페이지 배치 수정 — 2026-10-10

대상: EmberPDF 0.9.0 (build 45), macOS arm64.

## 변경

- 함께 보기 진입 버튼에 항상 칠하던 강조 배경을 제거하고, 아이콘도 일반 글자색으로 표시한다. 기존 툴바의 호버·누름·비활성 표시는 유지한다. 비교 화면 제목과 문서 선택창의 강조색은 유지한다.
- 비교 PDFView가 원래 탭의 `pageColumns` 값을 받아 2페이지 또는 3–12페이지 개요를 `.twoUpContinuous`로 표시하던 경로를 분리한다. 각 비교 영역은 항상 `.singlePageContinuous`를 사용하고 세로로 이어서 보여 준다.
- 비교 영역의 크기를 변경해도 한 열을 유지한다. 원래 탭의 페이지 묶음·두 페이지 방식·탐색 방식과 일반 viewport 저장 상태는 변경하지 않는다.

## 검증

- 관련 검사 **81개 통과, 실패·건너뜀 없음**. `work/comparison-fix-build45/tests.log`.
- 실제 SwiftUI `PDFKitViewer` 세 개를 동시에 구성하여 원래 탭의 1·2·4페이지 설정, 넓고 좁은 가로 배치와 세로 배치 전환을 검사했다. 동일한 PDFView를 유지하며 연속 페이지의 x 좌표·폭이 같고 한 열을 형성하는지, 현재 페이지·원래 설정·일반 viewport가 보존되는지 확인했다.
- 순수 표시 정책은 1–12페이지 설정 × 모든 탐색 방식 × 모든 2페이지 방식을 검사한다. 기존 비교 동기 스크롤·고정·종료와 페이지 맞춤 회귀도 통과했다.
- 테스트 호스트의 네이티브 PDFView 렌더링 세 장과 실제 툴바 렌더링 한 장을 확인했다. `work/comparison-fix-build45/comparison-layout-*.png`, `toolbar-entry.png`. 실행 중인 사용자 앱과 사용자 PDF는 조작하지 않았다.
- 버튼 화면 생성용 임시 검사는 `work/comparison-fix-build45/TogetherButtonPreviewTests.swift`에 보관하며 제품 테스트에서는 제거했다. 네이티브 비교 배치 회귀 검사는 제품 테스트에 남긴다.
- 정적 검증, 10개 언어 키·자리표시자 일치 통과. `work/comparison-fix-build45/validation.log`.

## 패키지

- Release arm64 빌드, 앱·worker 서명/권한과 ZIP 재추출 검증 통과. `work/comparison-fix-build45/package.log`.
- 설치: `/Applications/EmberPDF.app` — **0.9.0 (45)**. 설치 바이너리가 Release 산출물과 일치하며 서명 검증 통과. `work/comparison-fix-build45/install.log`.
- 이전 앱: `work/comparison-fix-build45/EmberPDF-build44-replaced.app`.
- ZIP: `outputs/comparison-fix-build45/EmberPDF-0.9.0-macOS-arm64.zip`.
- ZIP SHA-256: `7cbf61b5cac101e4d30657a54892588265f34dc18947f95a7ea456ff717fe172`.
- 실행 파일 SHA-256: `9535c45a6a33da306ae7ade9d6187ec5913a7949a45dd8a51253b082d98f15d5`.
- 사용자 앱은 종료하지 않았다. 저장 후 종료·재실행하면 새 빌드가 적용된다. 공개 배포·공증은 수행하지 않았다.
