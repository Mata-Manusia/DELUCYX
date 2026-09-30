/** Block glyphs, tallest last — one row of these is an 8-level bar chart. */
const LEVELS = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

/**
 * Renders `values` as a fixed-width block sparkline (oldest left).
 * The last `width` samples are kept; shorter series are left-padded with blanks.
 * Heights scale to `max`, or to the series peak when `max` is omitted.
 */
export function sparkline(values: number[], width: number, max?: number): string {
  if (width <= 0) return ""
  const window = values.slice(-width)
  const padding = " ".repeat(Math.max(0, width - window.length))
  const peak = max ?? Math.max(1, ...window)
  const scale = peak > 0 ? peak : 1

  const bars = window
    .map((value) => {
      const ratio = Math.max(0, Math.min(1, value / scale))
      const index = ratio <= 0 ? 0 : Math.min(LEVELS.length - 1, Math.floor(ratio * LEVELS.length))
      return LEVELS[index] ?? "█"
    })
    .join("")

  return padding + bars
}

/** Smallest and strongest RSSI the meter spans: below -95 dBm is noise, -35 dBm is on top of the AP. */
const SIGNAL_FLOOR = -95
const SIGNAL_CEILING = -35

/** RSSI (dBm) → 0..`cells` filled blocks. `0` means "radio reported nothing". */
export function signalLevel(dbm: number, cells = 5): number {
  if (!Number.isFinite(dbm) || dbm === 0) return 0
  const ratio = Math.max(0, Math.min(1, (dbm - SIGNAL_FLOOR) / (SIGNAL_CEILING - SIGNAL_FLOOR)))
  return Math.round(ratio * cells)
}

/** Fixed-width signal meter: solid block per level, `·` for the unused cells. */
export function signalBar(dbm: number, cells = 5): string {
  const level = signalLevel(dbm, cells)
  return "█".repeat(level) + "·".repeat(cells - level)
}
