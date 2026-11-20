# EmberPDF 1.0.0 배포 후보

**버전 1.0.0 · build 91 · 2026-11-20**

EmberPDF는 기존 HwattakPDF를 이어 개발한 Apple Silicon용 macOS PDF 작업 공간입니다. 여러 문서를 한 곳에서 읽고 검색하고 비교할 수 있으며, 주석·본문 편집·페이지 정리·로컬 OCR을 지원합니다. 프로젝트 소개와 기능은 [5개 언어 소개 문서](GITHUB-OVERVIEW.md)에서 확인할 수 있습니다.

build 91은 macOS가 저장 보조 프로세스의 상태를 일시적으로 제공하지 않을 때 기존 대기 시간 안에서 다시 확인합니다. 프로세스 신원, 자원 한도, 저장 취소 검사는 유지합니다. 원본 접근성 태그의 연결을 검증할 수 없는 편집 페이지에는 저장 보호가 적용됩니다.

DMG는 Apple Silicon 및 macOS 14 이상을 대상으로 합니다. 이 후보는 ad-hoc 서명을 사용하며 Developer ID 서명과 Apple 공증을 받지 않았습니다. [설치 안내](INSTALL-DMG-macOS.txt) · [검증 범위](RELEASE-VALIDATION-1.0.0.md)
