# Agent Handoff Template

Copy the headings below into a handoff report and replace every instruction sentence with concrete evidence. Do not omit a section; write `None` only when the section genuinely has no entries.

## Status

State exactly one of: `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, or `IN_PROGRESS`.

## Git state

- Record the source branch.
- Record the full HEAD commit SHA.
- Record the base branch.
- Record ahead and behind counts.
- State whether the branch has an upstream.
- State explicitly whether push, merge, or rebase occurred.

## Changes

- List every commit created during the task.
- List every modified, added, moved, or deleted file.
- Explain behavior changes without copying the entire diff.

## Verification

- List each command that actually ran.
- Record exit code, executed test count, skip count, and failure count when available.
- Record unavailable tests as `SKIPPED` or `NOT RUN`; never report them as `PASS`.
- Link to committed reports or repository-relative ignored evidence paths without exposing private absolute paths.

## Dirty files

- List each remaining dirty file.
- Identify its owner or origin.
- State whether the next agent may modify it.

## Concerns and blockers

- Describe each known correctness, durability, privacy, performance, or verification concern.
- State the exact condition required to clear each blocker.

## Next action

- Give the next agent one bounded objective.
- Name the files and verification gates in scope.
- Repeat prohibited operations, including push, merge, rebase, destructive cleanup, and modification of preserved dirty files when those restrictions still apply.

## Suggested skills

- Name only the skills that directly apply to the next bounded objective.
- Use `using-git-worktrees` before isolated implementation work.
- Use `test-driven-development` for product behavior changes.
- Use `verification-before-completion` before reporting completion.
- Use `handoff` whenever ownership changes again.
