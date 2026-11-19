# EmberPDF 잉걸불 아이콘 — 첫 제작안 v1 기록

- 제작일: 2026-10-04
- 도구: OpenAI ImageGen 내장 도구. CLI/API 대체 경로는 사용하지 않았다.
- 입력: 아래 텍스트 프롬프트만 사용. 외부 이미지·로고 입력 없음.
- 보존 원본: `Resources/AppIcon-Ember-v1.png`, 1254×1254 RGBA, 실제 투명 여백 포함. 처음에는 `Resources/AppIcon-Ember.png`로 저장했으며 최종안 적용 시 이 기록용 파일명으로 보존했다.
- SHA-256: `9f4b544472ce4beb35a427c0fb0a2fc7d244eb809169a140aa7f762064c692f8`
- 방향: 차분한 숯빛 타일 안에 접힌 아이보리 문서와 주황·황금빛 불씨를 하나의 형태로 결합했다. 누구나 편하게 문서를 읽고 편집하도록 오래 곁을 지키는 도구라는 의미를 담았다.
- 당시 적용: 앱의 첫 잉걸불 기본 아이콘과 설정의 ‘잉걸불’ 선택지로 사용했다. 현재는 [사용자가 승인한 v4](AppIcon-Ember-v4.prompt.md)로 교체했으며 v1 기록은 앱 번들에 포함하지 않는다.
- 당시 배포 변환: 원본 미술 수정 없이 macOS `sips`로 크기만 변환하고 `iconutil`로 16–1024px의 표준·Retina 표현 10개를 `AppIcon.icns`에 묶었다. 현재 배포에는 같은 방식으로 v4를 사용한다. 기존에 직접 고른 다른 아이콘 설정은 유지한다.
- 라이선스·출처: 저장소의 `ASSETS.md` 참조.

## 최종 생성 프롬프트

```text
Use case: logo-brand.
Asset type: production macOS application icon for EmberPDF, a welcoming, dependable PDF viewer and editor. The name signifies anger transformed into a quiet, enduring ember that helps everyone read and work with documents.
Create ONE finished square 1024x1024 app icon, not a concept sheet or presentation.
Design: a single bold, original sculptural paper-ember emblem, centered inside a dark warm charcoal rounded-square macOS tile. The emblem is an ivory sheet with one simple folded corner, whose lower center curls into a compact glowing orange ember/teardrop. Paper and ember should feel like one continuous, elegantly folded object. A small amber inner core suggests lasting warmth. The paper must look intact and cared for, not burning or being destroyed. One iconic silhouette, immediately legible at 32px.
Style: beautifully restrained premium macOS icon, precise geometry, subtly dimensional matte ceramic/paper relief, crisp silhouette, very soft restrained shading. Almost front-on view, balanced broad shapes, spacious negative space, 2 or 3 distinct material planes. Warm off-white upper paper, burnt-orange to honey-amber ember, dark basalt tile. No visible texture noise.
Layout: tile occupies roughly 88% of square canvas with balanced transparent margins, smoothly rounded corners. Emblem occupies about 62% of the tile, comfortably centered. Real transparent alpha outside the tile; no checkerboard pattern drawn into the image. Tiny soft drop shadow only. Keep the tile clean and almost flat, without glossy glass effects.
Text: no text, no letters, no PDF label, no watermark, no typography.
Avoid: a roaring flame, fire hazards, smoke, sparks, charred or torn paper, faces, hearts, shields, sparks scattered outside the icon, busy linework, neon bloom, lens flare, mockup devices or extra surrounding panels. No reference images or third party logos.
```
