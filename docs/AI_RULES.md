# Personal OS — AI Development Rules

## Before coding

1. Read `docs/CURRENT_STATE.md`.
2. Read the relevant architecture documentation.
3. Identify the exact task.
4. Do not modify unrelated modules.

## While coding

- Prefer small changes.
- Preserve existing architecture unless there is a concrete reason to change it.
- Do not invent APIs or project structure.
- Explain important architectural changes.
- Keep code readable and modular.

## After coding

Always:

1. Build the affected project.
2. Run relevant tests.
3. Inspect compiler errors.
4. Fix regressions before moving on.
5. Update `docs/CURRENT_STATE.md`.

## Git

Each completed feature should eventually have its own commit.

Preferred format:

`feat(mac-detective): add process disk io`

For fixes:

`fix(mac-detective): restore fs usage parser`

For documentation:

`docs: update project state`

## Important

Never declare a feature complete without verifying it with a build or test.
