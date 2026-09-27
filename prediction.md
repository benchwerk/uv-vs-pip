# Prediction, written before any timed run

Written and signed on 2026-09-15, before the first timed install, and published with the results whether it was right or
not. *In this published copy the form's instructions were removed and references to a working video title were rephrased
as "the claim"; the predicted values, the claim itself, the confidence notes and the two expectations below are
unchanged from the signed version. This repository was created after the study, so its history cannot timestamp the
prediction: its date is as recorded here and in [`editorial_log.md`](editorial_log.md).*

| State | pip median (s) | uv median (s) | Ratio pip/uv | Confidence |
| :-- | :-- | :-- | :-- | :-- |
| cold | 22.0 | 2.5 | 8.8x | High (Network bounded, uv parallel DL dominates) |
| warm | 6.0 | 0.3 | 20.0x | Medium (Depends on disk/overlayfs hardlink perf) |
| partial | 9.0 | 1.0 | 9.0x | Medium |
| frozen | 4.0 | 0.3 | 13.3x | High (`--no-deps` skips pip's per-package metadata check; nothing to resolve in a pinned file) |
| noop | 1.5 | 0.05 | 30.0x | High (uv skips almost everything) |
| warm_nocompile *(state added after review)* | — | — | — | No prediction: added after the prediction was signed. pip's number here vs `warm` is the bytecode-compilation cost. |

**The claim being tested:** *"uv's warm-cache advantage is far smaller than its cold-cache advantage."* It is the claim
as originally framed: *"in CI it's 4x"*. **Metric for the claim:** the ratio of medians, pip ÷ uv, the unit the claim
uses. Predicted cold 8.8x, warm 20x. **Prediction: the claim is FALSE.** (In absolute seconds saved it would read as
true, since cold saves ~19.5 s and warm ~5.7 s, but that is a different claim.)

**Consequence for the claim** (added at the pre-run review): the table predicts warm 20x > cold 8.8x. If that holds, the
claim as framed is **wrong**, and the finding is the opposite: uv's advantage is *larger* where it matters. The framing
follows the data, not the other way round.

**Expected to surprise:**
> The pip/uv *ratio* might actually be higher on warm and noop than on cold, because while the absolute seconds drop
> massively, pip is still bottlenecked by sequential I/O and python startup overhead while uv's Rust hardlinking and
> noop checks are near-instantaneous.

**How the harness might be wrong:**
> If the WSL2 overlay filesystem fails to hardlink the wheels for uv and falls back to full copying, uv's warm/frozen
> times might spike, dramatically reducing its relative multiplier on warm cache.

Date: 2026-09-15. Drafted with an AI agent; read, confirmed and signed by benchwerk before the first timed run.

---

## Outcome, added after the runs of 2026-09-15 (`2026-09-15_2016` primary, `2026-09-15_2051` repeat)

| State | Predicted ratio | Measured (run 1) | Measured (run 2) | Verdict |
| :-- | :-- | :-- | :-- | :-- |
| cold | 8.8x | 2.7x | 1.5x | **Wrong, and unmeasurable.** See below. |
| warm | 20x | **120x** | 115x | **Direction right, magnitude wrong by 6x.** |
| partial | 9x | 28x | 25x | Wrong by 3x, same direction |
| frozen | 13.3x | 124x | 126x | Wrong by 9x |
| noop | 30x | 34x | 34x | **Right.** |

**The claim** (*"uv's warm-cache advantage is far smaller than its cold-cache advantage"*): predicted FALSE, **measured
FALSE, emphatically.** Warm is 120x; cold is 1.5–2.7x. The original framing was wrong in both numbers and in direction.

**The expected surprise** (*"the ratio might be higher warm than cold"*) was correct in kind and underestimated
six-fold.

**The harness risk** (uv falling back from hardlinks to copying) did not happen: `checks.json` records 11,296 files
hardlinked, 408 generated.

**Not predicted:** the cold state does not reproduce. Run 1 cold: pip 56–69 s, uv 8–29 s. Run 2 cold, 35 minutes later
on the same machine: pip 59–223 s, uv 18–130 s. The cold number, the one most uv comparisons quote, measured the home
connection at that minute, not the tools. It is reported as a range with that caveat and is not a headline.

### Addendum: VPS (aarch64, datacenter link), 2026-09-16

| State | Predicted (laptop) | VPS measured | Note |
| :-- | :-- | :-- | :-- |
| cold | 8.8x | **14.7x** | Reproducible here: 14.7x and 13.8x in two sessions. The prediction was made for the laptop, which could not measure it. |
| warm | 20x | **177x** | |
| partial | 9x | 81x | |
| frozen | 13.3x | 183x | |
| noop | 30x | 38x | |

A different machine and architecture, so not a re-test of the prediction, but the same shape: the warm ratio is an order
of magnitude above the cold ratio on both machines.
