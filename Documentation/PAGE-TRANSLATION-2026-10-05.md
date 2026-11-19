# 현재 페이지 번역 플러그인 — 2026-10-05

EmberPDF 0.9.0 (build 21)에 **페이지 번역** 기본 플러그인을 추가했다.
현재 페이지의 그림과 글 영역을 캡처하고, 해당 위치에 번역문을 배치한 PDF를
별도 미리보기에서 읽는다. 원본 문서와 파일은 수정하지 않는다.

## 사용 방법

1. 플러그인 관리에서 **페이지 번역**을 설치한다.
2. PDF의 원하는 페이지에서 **현재 페이지를 번역해서 보기**를 실행한다.
3. 원문·대상 언어와 번역 엔진을 확인하고 번역한다.
4. **원문 / 번역문**을 전환하거나 확대해서 읽고, 필요하면 번역 PDF 사본을 저장한다.

macOS 번역, 로컬 Argos 언어팩, 사용자가 설정한 외부 AI를 사용한다. 외부 AI에는
확인한 원문 텍스트만 전달하며 페이지 이미지나 PDF 파일을 전송하지 않는다.
기존 번역 도우미의 웹 번역·원문 편집 기능과 설치 manifest는 유지한다.
페이지 번역 설정에서는 적용되지 않는 웹 서비스 옵션을 숨기고, 기본 대상 언어와
읽기 전용 원문을 펼쳐서 시작할지 선택할 수 있게 했다.

## 표현과 처리 범위

- 실행 시점의 현재 페이지를 고정해서 처리한다. 원문 페이지 이동이 열린 결과를 바꾸지 않는다.
- 배경 그림은 보존하고 원문 글 영역을 덮어 번역문을 표시한다. 원문의 글꼴과
  복잡한 표·수식·배경 무늬를 정확하게 재현하는 방식은 아니다.
- 영역에 들어가지 않는 긴 번역에는 번호를 표시하고 이어지는 페이지에 전체 내용을 싣는다.
- 텍스트 없는 스캔 페이지에는 OCR이 먼저 필요하다. 복사 제한, 누락된 글 영역,
  과도하게 겹친 영역 또는 크기 제한에 걸리면 실패 이유를 표시한다.
- 번역 페이지를 만들 수 없어도 완료된 번역 텍스트는 확인할 수 있다.
- 저장 대상이 원본과 같거나 원본을 가리키는 심볼릭 링크·하드 링크이면 차단한다.

## 이번 검증

검증 환경은 Apple Silicon Mac, macOS 15.7.5이며 아래는 이번 기능과 직접 관련된
선별 검사 결과다. 프로젝트 전체 회귀 검사나 실제 번역 서비스의 품질 검증을 뜻하지 않는다.

| 검사 | 결과 |
| --- | --- |
| 번역·렌더링·플러그인·권한·현지화 관련 테스트 | 84개 실행, 실패 0 |
| 설정 화면 후속 수정 | 컴파일 및 기존 플러그인 호환 테스트 3개 재실행, 실패 0 |
| 페이지 레이아웃 테스트 | 위 84개 중 8개: 여러 단, 회전·CropBox, 한글, 긴 번역, 잘못된 매핑·겹침, 원본 보존 |
| 플러그인 시스템 테스트 | 위 84개 중 44개: 현재 페이지만 처리, 고정 캡처, 복사 권한, 기존 도우미 호환 등 |
| 프로젝트 정적 검사 | 통과 — build 21, 10개 언어 |
| Release 앱·ZIP 패키징 | 성공 — arm64, ad-hoc 서명 검증, 기본 플러그인 6개 포함 |
| 합성 PDF의 시각 확인 | PDFKit으로 한글 결과·회전·여러 페이지로 이어지는 결과 확인 |
| 실제 앱 화면에서 번역 엔진 실행 | 미완료 — 별도 시험용 앱 실행이 자동 승인 검토에서 차단되어 사용자 확인 대기 |

시험 PDF는 직접 만든 짧은 문서이며 사용자 문서를 외부 번역 서비스로 보내지 않았다.
합성 번역 결과로 렌더러를 확인했으므로 실제 번역 엔진의 번역 품질이나 언어팩 설치
흐름까지 검증한 것으로 해석하지 않는다. 제공된 Poppler 실행 환경에는 한글 CMap
경로 문제가 있어 시각 확인에 macOS의 PDFKit을 사용했다.

재현 명령:

```sh
env CLANG_MODULE_CACHE_PATH="$PWD/work/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/module-cache" \
  XDG_CACHE_HOME="$PWD/work/swiftpm-cache" \
  swift test --disable-sandbox -j 2 \
  --filter 'PageTranslationLayoutTests|PageTranslationTests|PageTranslationExportPolicyTests|LocalTranslationServiceTests|PluginSystemTests|PluginAuthoringTests|PDFPermissionBoundaryTests|LocalizationAndIconSettingsTests'
./scripts/validate_project.sh
./scripts/build_app.sh
```

당시 로컬 산출물은 build 21의 `EmberPDF.app`과 배포 ZIP이다. 후속 빌드와 구분한
보관본은 `outputs/EmberPDF-0.9.0-build21-macOS-arm64.zip`이며, ZIP의 SHA-256은
`73e741094fc1f9b191bf49cdd057d04a1faa5fce424970ecc926fbb3e0f73da2`이다.
GitHub Release 공개와 Apple 공증은 수행하지 않았다.
