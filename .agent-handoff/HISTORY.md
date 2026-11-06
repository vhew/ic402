# Handoff history (append-only)

One entry per formal handoff, appended in the handoff commit itself (`.agent-handoff/PROTOCOL.md`
§3 step 9). Newest last. Never edit or delete past entries; if one turns out to be wrong, append a
correction. The full record of the latest handoff is `CURRENT.md`, and older records are in Git
(`git log -p -- .agent-handoff/CURRENT.md`). This file is public: no secrets or private details.

Entry format:

```
## HO-yyyymmddTHHMMZ-<from> — <from> -> <to> [(machine)]
- Branch / implementation commit: <branch> @ <short SHA>
- Progress: <one or two lines>
- Decisions: <new decisions, if any>
- Risks / open: <what the receiver must watch>
```

---

_No formal handoffs yet._
