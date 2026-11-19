# HwattakPDF 외부 AI와 MCP

> 구현 기준: 2026-08-19
> 원칙: 로컬 PDF 기능은 AI 계정 없이 동작하고, PDF AI 전송 확인창은 기본으로 표시하며 사용자가 설정에서 켜고 끌 수 있다.

## 제공 범위

PDF 툴바의 `PDF AI` 버튼은 활성 탭 오른쪽에 크기 조절 가능한 보조 패널을 연다. 다음 작업을 제공한다.

- 선택 텍스트, 현재 페이지, 선택 페이지 또는 문서 전체의 대표 페이지 요약
- 주장·근거·한계와 후속 확인 사항 분석
- 수학·과학 문제의 식, 단계별 풀이와 검산
- 문맥에 맞는 채우기 초안 작성과 검토 후 자유 텍스트 주석 추가
- 열린 탭과 최근 문서에서 관련 PDF를 찾는 로컬 검색
- 공급자가 지원할 때 출처 링크가 있는 웹 조사
- OpenAI Responses API의 원격 MCP 도구 호출과 호출별 승인·거부

`문서 전체`는 모든 페이지를 외부로 보내는 의미가 아니다. 현재 페이지를 우선하고 처음·마지막 페이지를 포함해 최대 24페이지, 페이지당 최대 8,000자, 합계 최대 48,000자를 대표 추출한다. 전송 텍스트에는 `[S1 | 파일명 | p.N]` 같은 근거 표시만 들어가며 로컬 파일 경로는 들어가지 않는다.

## 공급자

| 공급자 | 기본 API | 일반 질문 | 웹 검색 | 원격 MCP |
| --- | --- | --- | --- | --- |
| OpenAI | [Responses API](https://developers.openai.com/api/docs/guides/migrate-to-responses) | 지원 | [web search](https://developers.openai.com/api/docs/guides/tools-web-search) | [remote MCP](https://developers.openai.com/api/docs/guides/tools-connectors-mcp) |
| Anthropic Claude | [Messages API](https://platform.claude.com/docs/en/api/messages/create) | 지원 | 현재 앱에서는 미지원 | 현재 앱에서는 미지원 |
| Google Gemini | [generateContent](https://ai.google.dev/api/generate-content) | 지원 | Google Search Suggestions 표시 요건을 구현하기 전까지 비활성 | 현재 앱에서는 미지원 |
| DeepSeek | [OpenAI-compatible Chat API](https://api-docs.deepseek.com/) | 지원 | 현재 앱에서는 미지원 | 현재 앱에서는 미지원 |
| Alibaba Cloud Qwen | [OpenAI-compatible API](https://help.aliyun.com/en/model-studio/compatibility-of-openai-with-dashscope) | 지원 | 현재 앱에서는 미지원 | 현재 앱에서는 미지원 |
| 사용자 지정 | OpenAI-compatible `chat/completions` | 지원 | 서버별 별도 기능은 자동 가정하지 않음 | 현재 앱에서는 미지원 |

ChatGPT·Claude·Gemini의 소비자 구독과 개발자 API 키·사용량 과금은 별개일 수 있다. 모델 ID는 설정에서 바꿀 수 있다. 공식 공급자의 API 주소는 키 탈취를 막기 위해 고정하며, 임의 HTTPS 주소는 별도 `OpenAI-compatible` 설정과 별도 Keychain 자격 증명만 사용한다.

## 전송과 승인 경계

1. 사용자가 작업과 PDF 범위를 고른다.
2. 앱이 로컬에서 제한된 텍스트 문맥을 만든다.
3. 전송 확인창이 켜져 있으면 시트에서 공급자, 호스트, 범위, 시스템 지시·대화·질문·PDF 문맥의 문자 수와 미리보기를 확인한다.
4. 기본 설정에서는 사용자가 체크박스를 켜고 동의해야 요청을 시작한다. **AI 패널 … → 전송 전 확인창 표시**를 끄면 요청 시 고정한 공급자·범위로 바로 전송한다. 하단 안내 문구는 별도 표시 설정이다. PDF AI와 학습 모드 빠른 작업에 적용하며 독립된 페이지 번역 화면에는 적용하지 않는다.
5. 웹 검색을 켜면 검색 질의가 AI 공급자와 검색 서비스로 전달될 수 있음을 따로 표시한다.
6. MCP 호출은 `require_approval: "always"`로 요청한다. 서버 URL, 도구 이름과 인자를 보여 주고 모든 호출을 개별 승인 또는 거부한 뒤에만 두 번째 요청을 보낸다.
7. AI 답변은 자동으로 PDF를 바꾸지 않는다. 채우기 초안은 확인 대화상자와 기존 텍스트 편집 시트를 모두 통과한 뒤에만 주석으로 추가된다.

일반 OpenAI 요청은 `store: false`를 사용한다. MCP 승인은 `previous_response_id` 연속 요청이 필요하므로 MCP를 명시적으로 켠 요청만 `store: true`를 사용하며, 전송 시트에서 공급자 보존 정책 적용 사실을 알린다.

## 보안과 개인정보

- API 키는 공급자 종류와 설정 UUID별로 현재 macOS 사용자의 비동기화 Keychain에 저장한다. UserDefaults에는 비밀이 아닌 모델·URL·토글만 저장한다.
- 정식 프로비저닝된 앱에서는 Data Protection Keychain과 `WhenUnlockedThisDeviceOnly`를 요청한다. 현재 개발용 ad-hoc 번들은 entitlement가 없는 환경을 위해 비동기화 login Keychain 호환 경로를 가진다.
- build 58부터 AI API 키의 조회·저장·삭제는 시스템 인증창을 허용하지 않는다. 접근이 막힌 키는 앱에서 재입력을 안내하며, 읽은 뒤 옛 항목의 표시 이름이나 접근 권한을 바꾸지 않는다.
- 사용자가 API 키 저장을 누르면 항상 새 UUID와 EmberPDF 표시 이름의 항목에 저장하고, 성공한 뒤에만 공급자 설정을 전환한다. 저장 실패 시 기존 설정을 유지하며, 이전 항목 정리는 인증창 없이 가능한 경우에만 처리한다.
- OpenAI, Anthropic, Gemini, DeepSeek, Qwen 자격 증명은 각 공식 HTTPS endpoint에만 붙인다. 사용자 지정 endpoint는 공식 공급자의 키를 재사용할 수 없다.
- 원격 MCP v1은 사용자 정보·query·fragment가 없는 공개 HTTPS URL만 허용한다. 인증이 필요한 사설 MCP 서버는 아직 연결하지 않는다.
- PDF 문맥은 신뢰하지 않는 입력으로 감싼다. 문서 안의 명령이나 링크만을 근거로 웹/MCP 도구를 호출하지 않고, 민감한 원문·개인 식별자·전체 문단을 도구 인자로 재전송하지 말라는 시스템 규칙을 붙인다.
- HTTP 응답은 최대 16 MiB에서 중단해 오작동하거나 악의적인 사용자 지정 endpoint의 메모리 폭증을 제한한다.
- 모델 응답 본문의 임의 링크는 실행 경계로 신뢰하지 않는다. 검증된 `http`/`https` 출처만 별도 링크 UI로 연다.

외부 공급자에 실제로 전송된 데이터의 저장·학습·지역 처리·삭제 정책은 해당 공급자 계정과 계약에 따른다. 민감한 계약서·의료·재무·학생 정보는 조직 정책과 공급자 설정을 확인한 뒤 사용해야 한다.

## 로컬 관련 PDF 검색

관련 PDF 검색은 외부 모델을 호출하지 않는다. 현재 열린 탭과 보안 북마크로 접근할 수 있는 최근 PDF 중 최대 16개를 대상으로 대표 페이지를 한 문서씩 읽고, 한국어·CJK bigram과 단어 기반 점수로 최대 6개를 반환한다. 휴면 탭의 `PDFDocument`를 깨우지 않고 transient reader와 작은 LRU 텍스트 캐시만 사용하므로 대형 탭 메모리 예산을 우회하지 않는다.

## 대화 목록과 답변 표시

PDF AI 제목 아래의 대화 이름을 누르면 해당 PDF의 대화 목록이 열린다. 새 대화, 목록 검색, 다시 열기, 이름 변경·삭제를 지원한다. 메시지는 개별 복사·삭제할 수 있다. 일반 PDF는 앱의 로컬 Application Support에 기록을 저장하고 재실행 후 다시 연다. 암호 PDF와 아직 파일로 저장하지 않은 문서는 메모리에만 유지한다. API 키·전송 미리보기·MCP 승인 정보는 대화 기록에 넣지 않는다. 공급자와 설정의 구분도 보존하여 다른 공급자로 바꾸면 새 대화를 시작한다.

답변은 오프라인 Markdown·KaTeX 표시 엔진으로 문단, 제목, 목록, 표, 코드와 인라인·독립 수식을 렌더링한다. 이미지 데이터는 크기와 형식을 확인한 정적 PNG/JPEG/WebP/GIF를 표시한다. 공개 HTTPS 이미지 링크는 호스트와 ‘이미지 불러오기’를 표시하며, 사용자가 누를 때만 읽는다. 원격 페이지의 스크립트나 HTML을 실행하지 않는다.

이미지 생성 도구를 요청에 자동으로 추가하지는 않는다. 공급자가 실제로 반환한 OpenAI 이미지 생성 결과, Gemini inlineData, 호환 API 이미지 응답과 Markdown 이미지 링크를 표시하는 범위다. 원본 답변을 복사하면 Markdown과 LaTeX를 그대로 얻는다. 재실행 후에는 PDF가 외부에서 편집될 가능성을 고려해 과거 답변의 페이지 이동 버튼·초안 적용 권한을 복원하지 않는다.

## 알려진 한계

- 스캔 이미지만 있는 페이지는 AI 전송 전에 Apple Vision OCR을 먼저 실행해야 텍스트 문맥을 얻을 수 있다.
- AI의 초안은 기존 AcroForm 필드 값을 자동 결정하거나 원래 PDF 본문을 직접 수정하지 않는다. 현재는 검토 가능한 자유 텍스트 주석으로 추가한다.
- 답변의 정확성, 수학적 검산, 법률·의료·재무 판단은 사용자가 원문과 출처로 다시 확인해야 한다.
- 대화 기록은 PDF 파일 위치를 기준으로 구분한다. 파일을 다른 위치로 옮기면 별도 기록으로 취급한다. 암호 PDF의 대화 기록은 앱 종료 시 유지되지 않는다.
- OAuth 로그인, ChatGPT/Claude 소비자 계정 연결, 로컬 LLM 다운로드, 인증형 MCP와 조직별 proxy 정책은 후속 범위다.
