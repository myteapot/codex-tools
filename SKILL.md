---
name: codex-desktop-session-repair
description: Use this when Codex Desktop conversations are missing from the sidebar, have broken or mixed model_provider IDs, appear under the wrong project, or need careful repair across ~/.codex session JSONL files and Codex Desktop state SQLite databases.
---

# Codex Desktop Session Repair

Use this skill for forensic repair of Codex Desktop local conversation data. Do not treat the data as a single flat set of JSONL files: recent Desktop builds keep sidebar state in `~/.codex/state_*.sqlite`, while the full transcript still lives under `~/.codex/sessions/**/*.jsonl`.

Prefer careful inspection and small, reversible edits over one-shot normalization. Provider IDs, database schema versions, and sidebar grouping rules can change between builds.

## Core Rules

- Back up every file before editing it.
- Parse JSONL with a JSON parser. Do not use ad hoc string replacement for records.
- Prefer the newest or actively opened `~/.codex/state_*.sqlite` database. If Codex Desktop is running, `lsof -p <app-server-pid>` can show which state DB it has open.
- Update both the JSONL source record and the SQLite `threads` row when repairing metadata used by the sidebar.
- Do not rewrite historical `turn_context` or `exec_command` events unless the user explicitly asks. Those record what actually happened at the time.
- Close and reopen Codex Desktop after metadata repairs so the sidebar reloads state.

## Identify Storage

Find the active Desktop app-server process and state database:

```sh
ps auxww | rg -i 'codex.*app-server|Codex'
lsof -nP -p <PID> | rg 'state_[0-9]+\.sqlite|sessions/.+jsonl'
```

Inspect schema before assuming column names:

```sh
sqlite3 ~/.codex/state_5.sqlite '.tables'
sqlite3 ~/.codex/state_5.sqlite '.schema threads'
```

Typical thread metadata lives in `threads`:

- `id`
- `title`
- `rollout_path`
- `created_at`, `updated_at`, `created_at_ms`, `updated_at_ms`
- `source`
- `model_provider`
- `cwd`
- `archived`

## Audit Sidebar Counts

Compare visible, non-archived Desktop conversations against session files:

```sh
sqlite3 -header -column ~/.codex/state_5.sqlite \
  "SELECT id,title,cwd,source,archived,datetime(updated_at,'unixepoch') AS updated
   FROM threads
   WHERE archived=0
   ORDER BY updated_at_ms DESC;"
```

If old `session_index.jsonl` exists, treat it as auxiliary. It may not be the current sidebar source:

```sh
wc -l ~/.codex/session_index.jsonl
rg '"type":"session_meta"' ~/.codex/sessions -g '*.jsonl'
```

When comparing counts, separate user-visible sessions from subagent or guardian sessions. In JSONL, internal sessions often have `payload.source` as an object rather than a simple string.

## Repair Model Provider IDs

First determine the expected provider ID from a healthy fresh conversation or the current Desktop database. For OpenAI-backed Desktop sessions it is commonly:

```text
openai
```

Audit before changing anything:

```sh
sqlite3 -header -column ~/.codex/state_5.sqlite \
  "SELECT model_provider,count(*) FROM threads GROUP BY model_provider;"
```

For JSONL, inspect only the first `session_meta` record. If repairing a session, update:

- first JSONL record: `payload.model_provider`
- SQLite row: `threads.model_provider`

Keep a per-file backup and verify every edited JSONL file still parses.

## Repair Missing Project Conversations

If a conversation exists in the database but is absent from the expected project group in the sidebar, compare:

- `threads.cwd`
- first JSONL `session_meta.payload.cwd`
- paths referenced in user messages, tool calls, and final answers
- nearby healthy conversations for that project

Common failure mode:

```text
threads.cwd = /Users/mac/Codes
actual project = /Users/mac/Codes/lore
```

This can hide the thread from `Project > lore` while also making it awkward in the global conversation list.

Only repair `cwd` when evidence is strong. Good evidence includes repeated references to the child project path, final artifacts inside that project, or user confirmation.

Repair both sources:

1. Back up the rollout JSONL.
2. Back up the SQLite DB with `.backup`.
3. Change only the first `session_meta.payload.cwd`.
4. Update `threads.cwd` for the same `id`.
5. Leave historical `turn_context.cwd` and tool-event `cwd` records unchanged.

Example SQLite update:

```sh
sqlite3 ~/.codex/state_5.sqlite \
  "UPDATE threads
   SET cwd='/Users/mac/Codes/lore'
   WHERE id='THREAD_ID'
     AND cwd='/Users/mac/Codes';"
```

## Verify Repairs

Always run:

```sh
sqlite3 ~/.codex/state_5.sqlite 'PRAGMA integrity_check;'
```

Verify the target thread:

```sh
sqlite3 -header -column ~/.codex/state_5.sqlite \
  "SELECT id,title,cwd,model_provider,archived,datetime(updated_at,'unixepoch') AS updated
   FROM threads
   WHERE id='THREAD_ID';"
```

Verify JSONL parsing with a real parser:

```sh
node - <<'NODE'
const fs = require('fs');
const file = process.argv[1];
let n = 0;
for (const line of fs.readFileSync(file, 'utf8').split(/\n/)) {
  if (!line) continue;
  JSON.parse(line);
  n++;
}
console.log(`jsonl_records=${n}`);
NODE /path/to/rollout.jsonl
```

Ask the user to restart Codex Desktop and confirm the sidebar result.

## Restore From Backup

For JSONL, restore the backup file over the edited rollout.

For SQLite, close Codex Desktop first, then restore the `.backup` copy:

```sh
cp ~/.codex/state_5.sqlite.before-repair ~/.codex/state_5.sqlite
```

If WAL or SHM files are present and Desktop is closed, remove only the matching restored database sidecars when necessary:

```sh
rm -f ~/.codex/state_5.sqlite-wal ~/.codex/state_5.sqlite-shm
```
