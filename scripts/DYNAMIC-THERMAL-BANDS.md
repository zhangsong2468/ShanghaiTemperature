# Dynamic temperature bands — map step 3

Input: a `ThermalComparison` containing current apparent temperatures and matching-definition historical distributions for each grid point. Network and local modes are not mixed. Output: a Codable snapshot with band bounds, representative values, point assignments, source, timestamp and diagnostic scores. The original apparent temperatures are retained unchanged.

No precomputed weekly Celsius cut table or fixed 4°C interval is used. On each invocation:

1. Sort neighbours by latitude-adjusted geographical distance. Evaluate 3, 4, 6 and 8 nearest neighbours (limited by point count) using historical leave-one-location interpolation errors. Each year contributes equal weight. Choose the neighbour count with the smallest historical mean absolute interpolation error.
2. Use the median yearly median absolute interpolation residual, multiplied by 1.4826, as a robust spatial-resolution scale. The multiplier is a normal-residual scale convention; this is not a measured sensor accuracy or certified uncertainty. A 0.000001 numerical floor prevents log(0), not a physical minimum band width.
3. Find the exact minimum squared-error one-dimensional partitions for one through five bands. Equal values are never split. Candidate cuts are midpoints between adjacent current temperatures, so they move with the observed field rather than staying on a fixed Celsius grid.
4. Compare candidates using `n log(max(SSE/n, spatialScale²)) + (2k−1+isolatedSamples) log(n)`. An isolated sample has no same-band neighbour among the selected nearest neighbours. This penalises extra bands and fine spatial speckles. It is an engineering information-criterion-style score, not a formally derived Gaussian-mixture BIC or a claim of optimal joint spatial segmentation. A strong isolated cold/hot feature can still outweigh the complexity penalty.
5. For same-source, same-grid snapshots up to two hours apart, retain prior nonempty band cuts only when their score is within `log(n)` of the new winner. A meaningful feature change overrides this near-tie stabilisation. Source/grid changes disable carryover. No temperature values are averaged away.

Rendering contours, geographical clipping, label placement, seasonal palettes and geometric smoothing belong to step 4. The score discourages isolated sample bands but cannot guarantee zero map polygons; it must not erase genuine mountain/coastal differences merely to produce a smooth image.

`python3 scripts/test-thermal-bands.py` checks uniform and narrow fields, multiple regions, translation of Celsius boundaries, near-tie stability, major changes and invalid inputs. `check-thermal-bands.py --history Widgets/Resources/WeatherHistory --at 2025-11-19T15:00` replays real local-formula archive samples, excludes 2025 from the historical reference and reports diagnostics. Neither Python execution substitutes for Swift compilation, API-source replay or actual widget rendering.

Initial actual local-formula replays (all at 15:00, 2025, 100 points, reference years 2015–2024) produced: Jan 15 — 5 bands; Apr 15 — 3; Jul 15 — 3; Oct 15 — 5; Nov 19 — 2. These are archived dates, not current conditions. They are initial checks rather than full multi-day/seasonal acceptance tests.


## Width-cap revision (algorithm version 2)

User requirement: each displayed interval spans at most 3°C. The statistical model still selects data-driven base boundaries; a final subdivision splits only base intervals wider than 3°C into equal pieces no wider than 3°C. A small region can still have a single narrow band. Total displayed bands may exceed five when required by the range. Unsampled intermediate intervals are retained because interpolation can create those values on the map. Source temperatures are not altered.

The snapshot stores `baseCuts` separately for temporal near-tie comparisons. `cuts` and `bands` describe the final display scale; `criterionScore` describes the underlying statistical candidate before width-cap subdivision. Old algorithm-version snapshots are not reused for temporal hysteresis. Map rendering must consume the final display cuts.
