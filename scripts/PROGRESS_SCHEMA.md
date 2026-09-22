# Restore progress contract

`claude-restore-driver.py` writes `~/.claude/session-state/restore-progress.json`
atomically (temp file + `os.replace`) every time a counter changes. The app and
the menu-bar item are read-only consumers; nothing else writes this file.

```json
{
  "state": "running",
  "started_at": "2026-09-22T11:20:04-07:00",
  "updated_at": "2026-09-22T11:20:31-07:00",
  "finished_at": null,
  "total_windows": 7,
  "total_sessions": 9,
  "opened_windows": 3,
  "ready_sessions": 2,
  "current": "window 3 of 7 — Politogy Next.js migration",
  "error": null
}
```

| Field | Meaning |
| --- | --- |
| `state` | `running`, `done`, or `failed`. Anything else: treat as unknown and show nothing. |
| `started_at` / `updated_at` | ISO 8601 with offset. |
| `finished_at` | null while running; set once on the terminal write. |
| `total_windows` / `total_sessions` | Known before the first window opens, so progress is determinate from the start. |
| `opened_windows` | Windows created so far. |
| `ready_sessions` | Sessions that have been handed their continuation prompt. The honest completion signal — a window can exist while its session is still answering reopen prompts. |
| `current` | One short human-readable line for the UI. Never nil while running. |
| `error` | Message when `state` is `failed`, else null. |

**Fraction to display:** `ready_sessions / total_sessions`. Fall back to
`opened_windows / total_windows` only if `total_sessions` is 0. Clamp to 0...1
and never let it go backwards.

**Staleness:** the file persists after a run. Ignore any file whose `state` is
terminal, and treat `state: "running"` with an `updated_at` older than 5 minutes
as a dead run (the driver was killed) — show nothing rather than a stuck bar.

A dry run writes nothing.
