# EmberPDF 아이콘 수정안 — 잉걸불 위에서 따뜻해지는 문서

- 제작일: 2026-10-04
- 도구: OpenAI ImageGen 내장 도구의 이미지 편집.
- 요청: 종이 아래에 불씨를 두고, 종이가 타지 않고 따뜻해지는 느낌. 단순한 선 대신 글자처럼 조판된 문서.
- 편집 입력: 프로젝트의 `Resources/AppIcon-Ember-v2.png`만 사용했다. 외부 이미지나 로고는 입력하지 않았다.
- 결과: `Resources/AppIcon-Ember-v3.png`, 1254×1254 RGBA.
- SHA-256: `fb92dff25331836ad5bb16695f4aedad83c4dd1276fc99161d1530e899096ad3`
- 디자인: 숯빛 타일, 온전한 아이보리 문서, 세리프 제목과 문단, 아래에서 주황·황금빛을 내는 작은 잉걸불. 문서 아랫부분에 따뜻한 빛이 번진다.
- 상태: 디자인 검토용 수정안. 현재 배포 앱의 기본 자산 `AppIcon-Ember.png`를 교체하지 않았다.
- 이미지 속 문구는 아이콘의 문서 표현을 위한 장식 조판이다. 앱 기능이나 성능에 대한 문구가 아니다.

## 최종 편집 프롬프트

```text
Use case: precise-object-edit / logo-brand.
Edit the provided EmberPDF macOS icon to follow this precise new direction: an intact written sheet of paper being gently warmed by a small ember BELOW it.
Keep the warm-charcoal rounded square tile, the restrained premium matte dimensional style, the nearly frontal view, centered composition, and genuine transparent margins of the reference.
Replace the current two large horizontal bars with document typography: a modest serif heading "Ember" and below it several lines of delicate dark-gray serif-like character shapes, broken into short words with natural spaces, varying line lengths, and paragraph spacing. The body should look like real small typesetting on a book/manuscript page, not lines, dashes, thick bars, slots or decorative rules. Only the heading needs to be readable at icon size. Make the typesetting refined and calm, avoid loud marketing lettering.
Keep a clearly rectangular warm ivory paper sheet with a small ivory folded top-right corner. Remove the orange top corner. Make the page slightly smaller vertically and move it upward to leave clear space for an ember centered underneath.
At the bottom, BELOW the sheet, place one compact asymmetrical glowing ember: a low broad angular piece of warm orange-red coal with a golden hot center, two or three simple faceted planes. It is immediately identifiable as a smoldering ember, not a gemstone, onion, bulb, drop, heart, candle, campfire or pile of logs. A tiny restrained upward flicker may sit directly on the coal, but must stay below the sheet and must NOT touch or overlap the paper. Preserve a small visible air gap between the ember and the page.
Warm golden light from the ember gently illuminates the bottom edge and lower third of the ivory sheet, fading upward to natural white. The paper feels comforted and warmed, not on fire. Its full bottom edge remains clean, straight and intact. No char, burns, brown scorch marks, holes, torn edges, smoke, flying sparks, heat squiggles, or tall flames. Avoid nested teardrop flame layers and concentric organic contours; the previous version looked like an onion.
Single cohesive simple app icon. The paper is the dominant silhouette, the ember is a smaller purposeful secondary motif. Broad readable shapes at 32px, beautifully crisp at large size. Soft small shadows, subtle warm light, no neon bloom. Actual transparency outside tile. No external objects, no presentation sheet, no mockup devices, no watermark.
```
