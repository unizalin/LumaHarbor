# LumaHarbor Task 2 Claude handoff

Continue only the remaining Task 2 Round 4 review fix. The authoritative brief
is stored beside this handoff so it is available to both Codex and Claude:

```text
<CODEX_IPAD_DURABILITY_WORKTREE>/sdd/codex-task2-round4-task2-brief.md
```

## Start here

1. Work only in:
   `<CODEX_IPAD_DURABILITY_WORKTREE>`
2. Read the brief above completely.
3. Read the existing report:
   `sdd/codex-task2-round4-task2-report.md`.
4. Confirm branch `codex/ipad-multi-source-library-durability` and exact
   starting HEAD `60f270125fedc32da92d33851ad8fd015c7399d0`.
5. Confirm the only pre-existing worktree changes are these three untracked
   handoff documents; preserve them exactly and do not add, modify, stash,
   delete, or commit them:
   - `sdd/codex-task2-round4-task1-brief.md`
   - `sdd/codex-task2-round4-task2-brief.md`
   - `sdd/lumaharbor-task2-claude-handoff.md`
6. Execute the brief with strict RED-to-GREEN TDD.
7. Append the required evidence to the existing Task 2 report.
8. Create the one independent fix commit specified by the brief.
9. Run every verification command in the brief.
10. Do not push, merge, rebase, amend, squash, or start product Task 3.
11. Stop after the completion response. Codex will do the independent
    read-only review; do not perform or claim that review yourself.

The `/private/tmp` copies no longer exist. Do not wait for or refer back to
those temporary paths; these `sdd/` files replace them.
