# EmberPDF 최종 아이콘 v4 — 선명한 제목과 넉넉한 잉걸불

- 제작일: 2026-10-04
- 도구: OpenAI ImageGen 내장 도구의 이미지 편집.
- 요청: `Ember` 제목만 분명하게 유지하고 본문 글씨는 덜 선명하게, 종이 아래 잉걸불은 더 많이 표현한다.
- 편집 입력: 프로젝트의 `Resources/AppIcon-Ember-v3.png`. 외부 이미지·로고 입력 없음.
- 현재 보존 경로: `Resources/AppIcon-Ember.png`, 1254×1254 RGBA. 제작 당시 파일명은 `AppIcon-Ember-v4.png`.
- SHA-256: `77a24bf885822d5b5c94aa1d04a399a99d81a9bcff05d4f3c8e7bbbf10997212`
- 디자인: 어두운 세리프 제목, 작고 흐릿한 본문 활자, 넓게 모인 주황빛 잉걸불. 종이 하단은 따뜻한 빛을 받으며 가장자리는 온전하게 유지한다.
- 승인: 2026-10-04 사용자가 “좋다. 이대로 하자”라고 최종안을 승인했다.
- 적용: 승인 결과를 바이트 변경 없이 `Resources/AppIcon-Ember.png`로 보존해 앱 기본 아이콘과 설정의 ‘잉걸불’ 선택지로 사용한다. 기존에 직접 선택한 다른 아이콘 설정은 유지한다. 앞선 기본 아이콘은 `Resources/AppIcon-Ember-v1.png`에 보존하며 앱 번들에서 제외한다.
- 중복 정리: 2026-10-17에 같은 내용의 `AppIcon-Ember-v4.png` 복사본을 제거했다. 제작 당시 경로는 마일스톤 태그 `milestone/2026-10-17-build78-before-cleanup`(커밋 `f6b8dc9`)에 보존하며, 현재 보존 파일의 SHA-256은 위 값과 같다.
- 배포 변환: macOS `sips`로 기본 원본의 크기만 변환하고 `iconutil`로 16–1024px의 표준·Retina 표현 10개를 `AppIcon.icns`에 묶는다. 동일 원본의 `AppIcon.png`와 선택용 `AppIcon-Ember.png`도 번들에 포함한다.
- 라이선스·출처: 저장소의 `ASSETS.md` 참조.

## 최종 편집 프롬프트

```text
Use case: precise-object-edit.
Edit this existing EmberPDF app icon with exactly two targeted changes while preserving the overall design.
1. Keep the heading "Ember" spelled exactly E-m-b-e-r, in the same serif style and position, fully sharp, dark and clearly readable. All body text underneath must become subtle, small, pale warm-gray, softly out-of-focus typographic texture. Reduce the body glyph size and ink contrast markedly. Maintain the feel of tiny actual letterforms arranged in words and paragraphs with varied line lengths, but individual body words should not be readable. Do NOT replace the text with horizontal bars, slots, rules, lines, or solid strokes. Only "Ember" is crisp and legible; the body conveys a document quietly. The paper itself remains sharply defined, do not blur the whole paper or icon.
2. Increase the presence and quantity of the glowing EMBERS below the paper. Replace the single isolated coal with a compact low cluster of approximately four irregular smoldering coal pieces spanning about two-thirds of the paper's width, roughly 1.6 times the current ember cluster's width. Warm orange-red outer surfaces and a few golden-orange hot centers; a richer continuous warm bed of embers. Keep their shapes rough and asymmetrical, visually coals rather than gemstones or glossy orange crystals. Make the ember cluster more substantial yet still low enough to retain a clear visible air gap beneath the paper. Soft amber light from the cluster gently warms the lower third of the sheet, fading to ivory above. Do not engulf or touch the document.
Preserve: the existing dark charcoal rounded macOS tile, transparent outer margins, intact ivory rectangular paper, ivory folded top-right corner, balanced nearly frontal composition, refined tactile matte style, soft dimensional shading, and the warm welcoming mood.
The paper is warmed and protected, never burning. No scorch marks, brown damage, charred edges, holes, smoke, flying sparks, tall flames, onion shapes, layered teardrops, hearts, candles, logs, new objects, extra readable text, watermarks, or mockup frames.
Return one finished square icon, preserving genuine alpha outside the tile.
```
