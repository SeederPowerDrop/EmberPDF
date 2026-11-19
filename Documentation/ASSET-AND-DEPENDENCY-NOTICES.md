# 자산 및 의존성 공개 기록

> 자산 권리 확인 기준일: **2026-08-31**
> 의존성 고지 보완: **2026-10-07 — PDFium 본문 편집 엔진 추가**
> 실제 이용 조건은 루트 `LICENSE`, `NOTICE`, `ASSETS.md`, `TRADEMARKS.md`를 따른다.

## 현재 코드 의존성

앱은 macOS가 제공하는 SwiftUI, AppKit, PDFKit, CoreText, Vision, Security, Core Graphics 등의 시스템 프레임워크와, 본문 편집용 제3자 바이너리 타깃 `CPDFium`을 사용합니다. PDF AI 답변 표시는 WebKit과 아래의 로컬 JavaScript·글꼴 리소스를 사용합니다. 외부 AI 공급자와 통신하는 코드는 HTTP API를 호출하지만 해당 공급자의 SDK나 모델을 저장소에 포함하지 않습니다.

### AI 답변 표시

- **KaTeX 0.19.0**: LaTeX 수식을 조판하는 JavaScript, CSS, WOFF2 글꼴. MIT 라이선스이며 원문은 `Resources/AIRichText/katex/LICENSE`에 있습니다. [공식 프로젝트](https://katex.org/).
- **Marked 18.1.0**: Markdown 문단·목록·표·코드를 해석합니다. MIT 라이선스이며 원문은 `Resources/AIRichText/marked/LICENSE`에 있습니다. [공식 프로젝트](https://marked.js.org/).
- **DOMPurify 3.4.16**: 모델 응답에서 만든 HTML을 제한된 표시 요소로 정리합니다. MPL-2.0 또는 Apache-2.0 중 선택하는 라이선스이며 원문 전체를 `Resources/AIRichText/dompurify/LICENSE`에 유지합니다. [공식 프로젝트](https://github.com/cure53/DOMPurify).
- 공식 npm 배포본의 버전·원본 URL·SHA-512 integrity·포함 파일은 `Resources/AIRichText/vendor-manifest.json`에 고정합니다. 표시 엔진은 오프라인으로 번들에서 로드하며 CDN을 사용하지 않습니다. 배포 앱과 ZIP 재검증 시 해당 디렉터리의 모든 파일을 원본과 비교합니다.

### PDFium

- 버전: **157.0.8086.0** (`chromium/8086`), macOS arm64와 x86_64 universal framework.
- 소스: [PDFium chromium/8086](https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/8086). 사전 빌드 배포자와 build recipes: [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/8086).
- 저장소 경로: `Vendor/PDFium/CPDFium.xcframework`. 원본 archive별 SHA-256과 재준비 방법은 [PDFium 기록](../Vendor/PDFium/README.md)에 고정합니다. 재준비 스크립트는 원본 C++ 재빌드를 수행하지 않습니다.
- 라이선스: [binary package LICENSE](../Vendor/PDFium/LICENSE)는 Benoit Blanchon의 MIT 고지입니다. PDFium 자체의 BSD 계열 조건은 [licenses/pdfium.txt](../Vendor/PDFium/licenses/pdfium.txt)에 있으며 다른 구성 라이브러리는 [licenses/](../Vendor/PDFium/licenses/)의 해당 고지를 따릅니다. 이 제3자 코드에 프로젝트 MPL-2.0을 대신 적용하지 않습니다.
- 포함되는 고지: PDFium, FreeType, simdutf, libjpeg-turbo/IJG, ICU, LCMS, Dragonbox, libpng, zlib, HarfBuzz, LLVM libc, fast_float, AGG, Abseil, OpenJPEG. archive의 `LICENSE`와 `licenses/` 전체를 보존합니다.
- 배포: 앱에 framework를 포함·서명하며 앱과 릴리스 ZIP의 `Contents/Resources/Legal/PDFium/`에 고지 전체를 넣습니다. 일반 빌드에는 다운로드가 필요하지 않습니다.
- 실행 경계: V8와 XFA를 끈 빌드이며 본문 편집은 로컬의 분리된 한 페이지에서 처리합니다. 문서 스크립트 실행이나 외부 전송을 추가하지 않습니다. 바이너리 크기와 네이티브 파서의 메모리 비용이 추가되며, 페이지 크기·객체 수·탐색 깊이 상한을 서비스에 둡니다.
- 교체 경계: Swift 서비스 `PDFBodyTextEditor`가 C API를 감싸며 PDFKit이 보기와 문서 상태를 유지합니다. 버전 갱신 시 출처·checksum·라이선스·보안 변경과 편집 호환성을 다시 확인합니다.

### qpdf 및 libjpeg-turbo

- 원본 스트림 읽기에 qpdf 12.4.1과 libjpeg-turbo 3.2.0을 정적으로 링크합니다. qpdf는 Apache-2.0을 따르며, JPEG API는 Independent JPEG Group 고지를 적용합니다.
- [QPDF 빌드 기록](../Vendor/QPDF/README.md)에 고정 버전, 원본 체크섬, 로컬 패치 및 재빌드 방법이 있습니다. 원문은 `Vendor/QPDF/licenses/`에 보존하며, 배포 앱은 같은 파일을 `Contents/Resources/Legal/QPDF/`에 포함합니다.

선택형 로컬 번역 도우미는 사용자가 별도로 설치·실행하는 Python/Argos Translate 환경과 언어팩을 사용합니다. 저장소에는 연동 스크립트만 포함하며 Argos 라이브러리, Python 실행 환경, 번역 모델은 앱이나 ZIP에 넣지 않습니다. 설치 방법과 언어팩 선택·다운로드 경계는 [로컬 번역 안내](LOCAL-TRANSLATION.md)에 기록합니다.

새 패키지, 명령행 도구, OCR 모델 또는 바이너리를 추가할 때는 다음을 PR에 기록해야 합니다.

- 이름, 버전, 원본 URL과 checksum
- 소스 및 모델 라이선스
- 앱과 릴리스 ZIP에 포함되는지 여부
- 네트워크, 샌드박스, 개인정보, 메모리·용량 영향
- 제거하거나 교체할 수 있는 경계

## 앱 아이콘과 생성 자료

`Resources/AppIcon-*.png`, `Resources/AppIcon.svg`와 `Documentation/AppIcon-*.prompt.md`가 저장소에 있습니다. 프로젝트 소유자는 다음 사항을 확인했습니다.

- [x] 각 이미지가 직접 제작되었거나 공개·수정·재배포할 권리가 있음
- [x] ImageGen 제작 과정에 제3자 이미지·로고를 입력 자료로 사용하지 않음
- [x] 제3자 상표·캐릭터·앱 아이콘을 의도적으로 모사하지 않음
- [x] 권리가 확인된 자산을 코드와 같은 MPL-2.0으로 제공

파일별 출처와 SHA-256은 루트 [ASSETS.md](../ASSETS.md)에 기록합니다.

## 사용자 제공 소개 그림

파일: `Resources/AboutAuthor-SeederPowerDrop-UserProvided.jpg`

프로젝트 소유자는 2026-08-31에 이 그림을 공개 저장소와 앱·릴리스 ZIP에 포함하고 MPL-2.0으로 공개·수정·재배포할 권한이 있음을 확인했습니다. `Resources/AboutAuthor-UserProvided-NOTICE.txt`에 출처, checksum과 적용 라이선스를 기록하며 별도 자산 예외는 없습니다.

## 테스트 PDF와 스크린샷

회귀 테스트는 코드에서 생성한 합성 PDF를 사용합니다. README의 0.8.0 실제 창 캡처와 0.9.0 구현 뷰 미리보기도 직접 만든 예제 문서·가상 파일 목록을 사용하며, 생성 방식과 체크섬은 [ASSETS.md](../ASSETS.md)에 구분해 기록합니다. 새 회귀 자료에도 실제 계약서·교재·논문·서명·학생 정보 대신 합성 문서를 우선합니다. 공개 문서를 사용한다면 출처와 라이선스를 fixture 옆 NOTICE에 기록합니다. 버그 이슈의 스크린샷도 파일명, 경로, 계정 정보와 본문을 비식별화합니다.

## 외부 서비스 이름과 링크

OpenAI, Anthropic, Google Gemini, DeepSeek, Qwen 등은 호환 기능을 설명하기 위해 언급됩니다. 프로젝트가 해당 회사의 공식 제품이거나 보증을 받았다는 뜻이 아닙니다. 저장소와 앱은 해당 회사의 SDK·API 키·계정을 포함하지 않으며, 외부 AI는 사용자가 직접 선택하고 키와 전송 내용을 확인한 요청에만 사용합니다.

외부 서비스의 상표 정책, API 이용 약관, 개인정보 처리와 모델별 출력 표시 의무는 MPL-2.0이 대신 허가하거나 보증하는 범위가 아니며 시점과 사용 방식에 따라 달라질 수 있습니다. 공급자 기능을 새로 추가·변경하는 기여자와 수정본 배포자는 당시의 공식 정책을 확인하고, 사용자는 자신의 계정과 이용 방식에 적용되는 조건을 확인해야 합니다. 이 공개 기록은 각 외부 서비스의 모든 후속 사용에 대한 법률 자문이나 준수 보증이 아닙니다.
