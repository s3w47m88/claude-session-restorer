# windows.json — capture contract (v2)

Written by `claude-iterm-snapshot.py` to `~/.claude/session-state/windows.json`.
Read by `claude-restore-driver.py`. iTerm2 is the source of truth for what is
open; transcripts supply only session identity and mission text.

```json
{
  "captured_at": "2026-09-21T13:45:02-07:00",
  "windows": [
    {
      "window_id": 1293,              // iTerm AppleScript id == CGWindowID
      "title": "Orchestrator",        // window title at capture
      "frame": {"x": 0, "y": 40, "w": 570, "h": 1113},
      "display": "Main",              // display identifier, or null
      "space": 3,                     // macOS Space index; -1 if unknown
      "tabs": [
        {
          "index": 1,
          "title": "Orchestrator",     // tab title
          "sessions": [
            {
              "tty": "/dev/ttys004",
              "name": "Orchestrator",  // iTerm session name
              "badge": "politogy",     // iTerm badge text ("" if none)
              "cwd": "$HOME/Sites/politogy",
              "claude_session_id": "a5a605b6-...", // user var, else inferred, else null
              "session_id_source": "tag",          // "tag" | "inferred-from-process-start" | null
              "claude_running": true,
              "mission": "Stand up the mission queue for Politogy VRM"
            }
          ]
        }
      ]
    }
  ]
}
```

Rules:
- Window and tab ORDER in the arrays is the order to recreate them in.
- `claude_session_id` comes from the iTerm user variable `user.claude_session_id`,
  set by the SessionStart tagging hook (`session_id_source: "tag"`). A session that
  was already running when the hook was installed has no user variable, so it falls
  back to matching the live `claude` process start time against the first timestamp
  in each transcript under the cwd's project slug — measured offsets are +1s to +10s,
  and each id is claimed once so two sessions in the same directory cannot collide
  (`session_id_source: "inferred-from-process-start"`). Null means resume is not
  possible for that session; restore opens a fresh `claude` in `cwd` instead.
- `mission` is the first user message of that session's transcript, trimmed to one
  line, max 200 chars. Wrapper records Claude Code injects (`<local-command-caveat>`,
  `<command-name>`, compaction notices) are skipped so the mission is the human's own
  words; `<pasted_content>` and similar tags are stripped. Null if the transcript has
  no user message yet.
- Liveness is decided by iTerm, never by transcript mtime. A session idle for
  hours is still captured.
- `space` is -1 only when the Space genuinely cannot be determined.
