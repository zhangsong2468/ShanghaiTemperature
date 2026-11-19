# Regional map — step 4

Adds the sixth widget, “江浙沪 · 体感地图”, supporting systemLarge only. Existing widget kinds and the app display name remain unchanged. A nested WidgetBundle keeps the top-level builder at five entries and groups the Hangzhou/map pair.

Geometry is extracted from the already-downloaded Natural Earth 1:10m administrative geometry, not hand-drawn. The 75 KB resource retains all three regions' sourced polygon rings/holes and rounds coordinates to five decimals. The source hash and attribution are retained. A fitted Mercator projection preserves the regional aspect ratio; temperature interpolation is based on geographical coordinates and is clipped with even-odd polygon filling.

The map raster uses inverse-distance interpolation of the actual sample apparent temperatures. The neighbour count comes from step 3. Interpolated temperatures are classified using the final width-capped cuts, so every display interval remains at most 3°C. The colour field crosses administrative boundaries and is clipped to the combined region outline. Sparse 100-point interpolation is a modelled regional depiction, not a precise mountain/coastal observation map.

Temperature ranges are directly labelled beside the map with leaders to each rendered band's eastern edge. Only the ten required lowercase place labels are included, without city temperatures. City labels use collision candidates and a reserved right-side range-label column. Actual text layout and clipping still require WidgetKit visual verification.

Palette hue principally follows absolute apparent temperature (blue/cyan through amber/orange/red), while approximate apparent solar longitude provides a small, continuous seasonal adjustment across all 24 terms. No month/day season switches are hard-coded. Formula is Meeus-style; exact term-time boundaries must be checked against authoritative almanacs before release. At unexpectedly hot/cold times the temperature still wins over the seasonal theme.

The gallery/placeholder asset is the actual archived 2025-11-19 15:00 local-formula replay with a visible “历史回放 · 非实时” label. Installed widgets show an honest waiting state at this stage; step 5 connects live weather, source mode, cache, preparation progress and refresh. Historical gallery data is never used as a live error fallback.

Checks: resource geometry rings/bounds, exactly ten labels, replay sample counts and <=3°C display widths, projection round-trip, structural source/resource membership. Native Swift compilation, raster performance, text placement and WidgetKit rendering have NOT been verified here.


## Calendar-day solar-term display

Header now shows the bounding pair (e.g. 立冬—小雪); on a term's Shanghai-local calendar day it shows only that term for the entire day, independent of the exact crossing hour. Published Hong Kong Observatory calendar dates for 2025–2027 are embedded in the core calendar; UTC+8 matches Shanghai. Sources: https://www.hko.gov.hk/en/gts/time/calendar/text/files/T2025e.txt , T2026e.txt and T2027e.txt. Other years use an explicitly identified approximate solar-longitude crossing fallback. This changes the header only; seasonal colour interpolation still uses continuous solar phase.

## Fine continuous edges

Raster increased from 160×224 to 320×448 with high-quality image resampling. Interpolation now uses continuous positive Gaussian-tapered Shepard weights from all samples, avoiding abrupt changes when a point enters/leaves a k-nearest set. The bandwidth follows median grid spacing for the neighbour count selected by the historical analysis. A small, gradient-aware smoothstep colour transition spans roughly 1.5 raster pixels, capped relative to the adjacent band width. It changes display antialiasing only; numerical cut values, <=3°C widths and source apparent temperatures remain unchanged.

No decorative noise, artificial contours or forced breaks are added. Long connected boundaries can be real and are preserved. Native raster speed and visual softness still require Swift/WidgetKit rendering verification.
