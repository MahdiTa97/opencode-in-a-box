# `oc` help, errors, colour and icons (design)

Date: 2026-11-15
Status: approved in conversation — the user chose approach A ("الف هر چه صلاح میدانی. اگر بتونی از آیکون و رنگ هم استفاده کنی خوبه")

## Intent

The two things that annoy the user in daily use are the quality of `oc help`
and the quality of its error messages. Today `oc nonsense` dumps the whole
table, `oc logs --since` reaches sudo before noticing its argument is missing,
and `oc up` asks for a password before discovering there is no `.env`. Every
`doctor` FAIL states the symptom but not the fix.

This round makes `oc` explain itself well: per-command help, errors that name
the fix, validation before privilege escalation, and coloured, icon-led output
on a terminal that degrades to plain text everywhere else.

## Goals

- `oc help <command>` and `oc <command> --help` print the same text: usage,
  flags, two examples, and what the command touches (volumes? sessions?).
- Every error is one line prefixed `oc: `, followed by `hint:` and, when the
  fix is a command this repo owns, `fix: <command>`.
- Arguments are validated **before** `need_docker`, so a typo never costs a
  password prompt.
- `doctor` prints `fix:` under each FAIL with the command that repairs it.
- Colour and icons appear only on an interactive UTF-8 terminal; every byte
  that reaches a pipe, a file, or the test suite is plain ASCII.
- `oc doctor --json` and `oc status --json` emit one JSON object per line for
  scripting, and imply plain output.

## Non-goals

- No new dependency: still POSIX `sh`, still `awk`/`sed`/`jq` only.
- Not a framework adoption (`bashly`, `cobra`, `clap`) — decided in conversation.
- No interactive prompts or menus; `oc` must stay usable in scripts.
- No change to what any command runs, only to how it explains itself.

## Anti-goals

- Colour that survives into a pipe or a log. That is why the test suite asserts
  the absence of `\033`.
- Emoji. They break column alignment across fonts; the icons are three
  single-width glyphs.
- Help text that duplicates the dispatch table. One helper per command prints
  it, and `oc help <cmd>` calls the same helper.

## Approaches

**A. Hand-rolled (chosen).** A `help_<cmd>` function per command, a `say`/`die`
pair for messages, an `is_color` probe, and a Levenshtein-lite suggestion for
unknown commands. Roughly +200 lines of `sh`, zero dependencies, every message
written for this project.

**B. `bashly`.** Generates parser, help and completion from YAML. Rejected: it
needs ruby or docker to regenerate, the output is thousands of generated lines,
its error strings are generic (the exact thing being improved), and hand-written
messages are lost on every regeneration.

**C. Go/Rust binary (`cobra`/`clap`).** Best help UX and completion, but adds a
toolchain, needs one binary per architecture, and inherits the same sudo-PATH
problem that already hides `node` from `sudo`. It also breaks the "runs anywhere
that has docker" property.

## Design

### Output primitives

```
is_color   → 1 when [ -t 1 ] && NO_COLOR unset-or-empty && TERM != dumb
is_utf8    → 1 when LC_ALL/LC_CTYPE/LANG matches *[Uu][Tt][Ff]-8*
ok()     verdict for doctor/status
warn()   "
fail()   "
err()    `oc: <msg>` on stderr, exit 1
usage_err() `oc: <msg>` + `hint: oc help <cmd>`, exit 2
```

Icons: `✓` pass, `!` warn, `✗` fail, and the ASCII fallbacks `ok`, `!`, `x`.
Colours: green/33/yellow/31/red bold on the verdict only, never on the message
body, so redirecting stderr never changes the meaning of a line.

Every command's help lives in `help_<cmd>()`, and the dispatcher passes
`--help`/`-h` to `cmd_<cmd>` before doing anything else.

### Validation order

```
cmd_up:  parse flags → validate .env via scripts/check-env.sh → need_docker → run
```

`check-env.sh` already holds the `.env` rules (single source, DRY); `up`,
`config` and `doctor` all call it. If it fails, `fix: ./setup.sh`.

### Suggestions

`did_you_mean <word>` compares against the 13 command names with a small
edit-distance loop in `awk` and suggests the best match at distance ≤ 2.

### `--json`

`doctor` and `status` accept `--json`; they then print one object with
`ok/warn/fail` counts and an array of `{id, status, text, fix}`. Colour and
icons are off. `jq` is already a dependency for the rest of the repo, so the
output is validated in tests with `jq -e`.

## What is left to the builder

- Exact wording of each help block's examples.
- Whether `status --json` returns one object or one line per service (chosen:
  one object per service, newline-delimited).
- The colour codes: 32 green, 33 yellow, 31 red, bold only for the verdict.

## Acceptance

- `oc help up`, `oc up --help` and `oc help` all exit 0; the first two print
  identical text.
- `oc nonsense` exits 2 with `did you mean: doctor` and does not print the table.
- `oc up --nope` exits 2 without invoking docker.
- `oc logs --since` exits 2 with `--since needs a value` and without docker.
- `oc up` in a repo without `.env` exits 1, prints `fix: ./setup.sh`, and the
  shim log stays empty.
- Piped output contains no `\033`; `NO_COLOR=1` and `OC_ASCII=1` behave the same.
- `oc doctor --json` parses with `jq -e` and has `checks` with eight entries.
- A `doctor` FAIL line is followed by a `fix:` line.
