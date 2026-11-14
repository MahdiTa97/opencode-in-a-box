---
description: Run the project's type check, lint, and tests, and report the real output
---

Verify the change you just made, with evidence, before claiming it is done.

1. Detect the project's own commands from its files, in this order of
   preference: `package.json` scripts (`typecheck`, `lint`, `test`), `Makefile`
   targets, `pyproject.toml`/`tox.ini`, `Cargo.toml`, `go.mod`.
2. Run them in this order: type check, lint, tests. Do not substitute a
   narrower command for the project's own script.
3. If a command is missing, say so explicitly and continue with the rest. Do
   not invent a replacement tool that the project does not depend on.
4. Redirect long output and read the tail; never paste a wall of log.

Report back as a short table:

| check | command | result |

Then, if anything failed, quote the first failing output verbatim (a few
lines), name the file and line, and stop. Do not summarise a failure as
"minor", and do not claim the work is complete when a check is red.

If every check passed, say so in one line and list what you ran. If you could
not run a check, say which and why.
