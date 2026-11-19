# EmberPDF 아이콘 수정안 — 문서와 주황빛 모서리

- 제작일: 2026-10-04
- 도구: OpenAI ImageGen 내장 도구.
- 계기: 앞선 불씨와 말린 종이가 양파처럼 보인다는 사용자 피드백.
- 방향: 둥근 불꽃 대신 각진 문서 실루엣과 주황·황금빛 접힌 모서리로 표현한다.
- 입력: 텍스트 프롬프트만 사용. 이전 이미지나 외부 시각 자산을 입력하지 않았다.
- 원본: `Resources/AppIcon-Ember-v2.png`.
- 상태: 디자인 수정안. 현재 앱 번들의 기본 자산은 별도의 `AppIcon-Ember.png`이며 이 수정안은 아직 번들에 적용하지 않았다.

## 최종 생성 프롬프트

```text
Use case: logo-brand.
Create ONE finished macOS application icon for EmberPDF, a friendly dependable PDF viewer/editor inspired by the warmth of a lasting ember.
This is a fresh revised concept. The previous concept used curving rolled paper enclosing a nested teardrop flame and looked like a cut onion. Solve that completely: absolutely NO flame silhouettes, droplets, nested organic curves, concentric layers, bulbs, onion-like shapes, or rolled paper.
Design a confident, very simple UPRIGHT RECTANGULAR IVORY DOCUMENT on a warm charcoal rounded-square app tile. The document has almost straight vertical sides, a straight bottom edge, gently softened corners, and a compact folded TOP-RIGHT corner. The folded corner reveals a rich warm ember-orange underside with a tiny golden lit edge. Warmth is expressed ONLY by this small geometric orange paper fold, not by a separate flame object. On the document face, TWO bold short charcoal horizontal bars suggest readable text; no actual lettering. Keep the paper front flat and intact. A coherent document silhouette, not an envelope, folder, book, shield or food.
Premium restrained macOS aesthetic: mostly frontal composition, subtle tactile matte paper/ceramic relief, very slight soft shadows, precise clean geometry, very low texture. Warm off-white document against a dark graphite tile; restrained burnt orange and amber corner accent. No glow clouds, no smoke, no fire damage.
Centered composition, icon tile fills about 88% of the canvas, document fills about 62% of the tile, balanced transparent margins outside smoothly rounded tile corners. Actual transparent alpha outside the tile, not a drawn checkerboard. One single square 1024x1024 icon, no scene, no collage, no presentation mockup. No words, no PDF label, no watermark, no third-party logos. Broad clear shapes that remain recognizable at 32px.
```
