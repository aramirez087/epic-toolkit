---
description: Generate an epic session plan under docs/claude-sessions from a problem statement.
---

# /epic.generate - Generate Claude session files

Use the user input below as the full problem statement and generate the requested session files.

## User Input

```text
$ARGUMENTS
```

You are the most experienced project manager in the world, with deep full-stack engineering experience across many languages and stacks. Your job is to turn the problem statement into a concrete sequence of markdown session files that will drive autonomous Claude Code runs and solve the problem in the best practical way.

The problem statement is the user input above. Treat it as required input. If it is empty, stop and ask the user to provide the problem statement.

Generate a sequence of session `.md` files that will be executed by `/epic`. Each session runs as a fresh Claude Code process with zero memory of prior sessions. **Sessions are scheduled as a DAG and run in parallel waves where the dependency graph allows.** Follow these rules exactly.

## File structure

Directory: `docs/claude-sessions/<epic-name>/` where `<epic-name>` is a kebab-case slug.

Required filenames:
- `session-00-operator-rules.md`
- `session-01-<kebab-desc>.md`
- `session-02-<kebab-desc>.md`
- Continue sequentially as needed

Use zero-padded two-digit numbers. Session 00 is always operator rules.

## File format

Sessions 01+ MUST start with YAML frontmatter declaring DAG metadata, then the markdown body, then a fenced ` ```md ... ``` ` block containing the prompt. Session 00 has no frontmatter.

    ---
    session: NN
    title: "Short title"
    depends_on: [<prior session numbers>]
    touches:
      - <glob this session may modify>
      - <another glob>
    parallel_safe: true
    ---

    # Session NN: Title

    Paste this into a new Claude Code session:

    ```md
    <prompt content here>
    ```

The automation extracts only the content inside the ` ```md ` fence. Never nest code fences inside those prompts. If you need code examples inside a prompt, use four-space-indented blocks instead.

## DAG design — this is the critical step

You are not writing a linear list. You are designing a **directed acyclic graph** of work. Independent slices should run as **siblings in the same wave** so the runner executes them in parallel worktrees and saves real wall time. Bottlenecks (charter, CI gate, anything that mutates shared infrastructure) sit in their own waves.

### How to decompose

1. **Charter (session 01)** is always solo: `depends_on: []`, `parallel_safe: false`. Audits the codebase, defines architecture, writes scaffolding files that downstream sessions will fill in. This unblocks the parallel fan-out below.
2. **Feature/subsystem sessions** are the parallel siblings. Split work so each one **owns a directory or file family that no other session touches**. e.g., `src/auth/**` is owned by one session, `src/email/**` by another, `src/billing/**` by a third. They all `depends_on: [01]` and `parallel_safe: true`.
3. **Composition sessions** depend on multiple feature siblings. e.g., an admin UI that uses auth and billing has `depends_on: [02, 04]`.
4. **CI gate (final session)** has `depends_on: [<every prior session id>]` and `parallel_safe: false`. It runs after every other session has merged into trunk.

If two slices would touch the same files, **don't make them parallel siblings** — sequence them, or merge them into one session, or have the charter create a clean boundary first.

### Frontmatter fields

- `session` — integer, must match the filename's NN. Required.
- `title` — short human title. Required.
- `depends_on` — list of prior session numbers (empty for session 01). Required. Omitting it implicitly chains the session linearly to the prior number, which defeats parallelism — always declare it explicitly.
- `touches` — list of file globs this session may modify. The runner uses these to detect overlaps between siblings in the same wave. Required for any session that writes code; empty list `[]` is fine for pure-validation sessions.
- `parallel_safe` — boolean. `false` forces solo-wave (charter, CI gate, anything with side effects on shared state). Default `true` for feature work.

## Session 00 requirements

Session 00 must contain (no frontmatter):

- Role and persona for Claude across the initiative
- Hard constraints covering safety, architecture, and coding standards
- This exact handoff convention: `End every session with a handoff under docs/roadmap/<epic-name>/`
- Definition of done covering builds passing, tests passing, decisions documented, and explicit next-session inputs

## Session 01+ required prompt sections

Inside each fenced prompt for sessions 01 and above, include:

1. `Continuity`
   - For sessions with `depends_on: []`, omit this section.
   - Otherwise, the first line must list every parent: `Continue from Session XX, YY artifacts.`
   - Reference file paths only, never prior-session memory.
2. `Mission` — one sentence.
3. `Repository anchors` — explicit file paths the session reads or modifies. Should be consistent with the session's `touches` frontmatter.
4. `Tasks` — numbered, concrete, and specific.
5. `Deliverables`
   - Exact output paths.
   - Must always include `docs/roadmap/<epic-name>/session-NN-handoff.md`.
6. `Quality gates`
   - Detect the project's language(s) and toolchain by inspecting the repo (e.g., `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Gemfile`, `pom.xml`, `build.gradle`, `*.csproj`, `mix.exs`, etc.) before choosing gates. For greenfield repos, infer from the problem statement.
   - List the exact commands the session must run, scoped to what changed. Cover at minimum these categories whenever the language supports them: format check, lint/static analysis, type check, unit tests, and build.
   - Common patterns by stack (use the variant the repo actually configures; do not invent commands):
     - Rust: `cargo fmt --all -- --check`, `cargo clippy --workspace -- -D warnings`, `RUSTFLAGS="-D warnings" cargo test --workspace`
     - Node/TS: `npm run lint`, `npm run check` (or `tsc --noEmit`), `npm test` or `npx vitest run`, `npm run build`
     - Python: `ruff check .` (or `flake8`), `mypy .` (or `pyright`), `pytest`
     - Go: `gofmt -l .`, `go vet ./...`, `go test ./...`, `go build ./...`
     - Java/Kotlin: `./gradlew check` or `mvn verify`
     - Ruby: `bundle exec rubocop`, `bundle exec rspec`
     - .NET: `dotnet format --verify-no-changes`, `dotnet test`, `dotnet build`
   - If the project uses a monorepo layout (e.g., `dashboard/`, `apps/web`, `services/api`), prefix commands with the correct working directory (`cd <dir> && ...`).
   - Never include gates the project cannot run. Omit categories that don't apply.
7. `Exit criteria` — testable completion conditions.

## Sequencing rules

- **Session 01 is the charter and is always solo** (`depends_on: []`, `parallel_safe: false`). Audit the codebase, define architecture, document decisions, and create empty scaffolds (directories, placeholder files, type signatures) that downstream sessions will fill. Keep code changes minimal but lay the structural foundation for parallel fan-out.
- **Middle sessions own disjoint file regions and run in parallel** wherever the work allows. Aim for the widest waves the dependency graph supports — e.g., 3-4 feature sessions all depending on the charter, then a composition session depending on the relevant feature siblings.
- **The final session is a CI gate**, depends on every prior session, and is `parallel_safe: false`. Run the full CI checklist for whatever languages and tools the project actually uses (format check, lint/static analysis, type check, unit/integration tests, build, and any project-specific verification such as DB migration replay or schema diff). Fix every failure including type errors, lint warnings treated as errors, and coverage regressions, and produce a go/no-go report. Its prompt must explicitly list every CI command and instruct the agent to iterate until all pass.
- Every session must produce a handoff doc listing what was done, decisions made, open issues, and next-session inputs.
- If a session feels too large, split it before writing files.

## Hard rules

- No `TBD`, `TODO`, or deferred-decision placeholders in prompts.
- Never write prompts that assume Claude remembers prior sessions — use file paths.
- Keep each prompt under 60 lines.
- Every session 01+ MUST include valid frontmatter with at minimum `session`, `title`, `depends_on`, `touches`, `parallel_safe`.

## Execution instructions

1. Inspect the repository before deciding session boundaries. Identify the language(s), package manager(s), test framework(s), and any monorepo structure so quality gates and anchors are accurate.
2. For a greenfield repo, infer the stack from the problem statement and pin the chosen tools (with versions where reasonable) in Session 00 and/or Session 01.
3. Decompose the work into a DAG that **maximizes the size of parallel waves** without creating `touches` overlaps between siblings.
4. Choose the minimal number of sessions that still de-risks the work.
5. Create the directory `docs/claude-sessions/<epic-name>/` if it does not exist.
6. Write every required session file into that directory.
7. Ensure each file matches the required outer markdown structure exactly, including frontmatter on sessions 01+.
8. After writing the files, run `python3 scripts/epic-dag.py docs/claude-sessions/<epic-name> --show` to render the wave layout. If the output collapses into mostly single-session waves, your DAG is too sequential — revisit the dependencies and split file ownership.
9. In your response, report: the created directory, the session files written, the wave layout (paste the `epic-dag.py --show` output), and the stack/quality-gate set you selected.
