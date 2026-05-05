# codex-useful-tools

Small maintenance tools for Codex Desktop data.

## Fix Codex Model Provider

`tools/fix_codex_model_provider.rb` normalizes Codex session metadata so
`payload.model_provider` is set to `openai`.

Dry run:

```sh
ruby tools/fix_codex_model_provider.rb
```

Apply changes:

```sh
ruby tools/fix_codex_model_provider.rb --write
```

By default it scans `~/.codex/sessions/**/*.jsonl`, edits only the first
`session_meta` line in each file, and creates a `.bak` backup beside every
changed file.

## Fix Codex Sessions

`tools/fix_codex_sessions.rb` does the provider normalization above and also
repairs `~/.codex/session_index.jsonl` by adding missing live sessions. This is
useful when Codex Desktop has valid session files but the sidebar shows fewer
conversations.

Dry run:

```sh
ruby tools/fix_codex_sessions.rb
```

Apply changes:

```sh
ruby tools/fix_codex_sessions.rb --write
```
