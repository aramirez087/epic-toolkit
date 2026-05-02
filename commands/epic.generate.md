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

## Complexity Assessment — Single Epic or Multi-Epic?

Before designing sessions, assess the problem to decide: **one epic** or **multiple epics**?

**Default to one epic** unless complexity justifies splitting. Use this heuristic:

- **Split into multiple epics when TWO or more of these apply:**
  - The problem spans **3+ independent subsystems** with no shared state (e.g., auth + billing + email as separate features)
  - The total session count would exceed **10-12 sessions** for a single epic
  - Different subsystems need **different models** (e.g., opus for complex logic, haiku for straightforward CRUD)
  - A subsystem is **risky or experimental** — splitting lets you retry just that epic if it fails
  - The work touches **3+ non-overlapping directory trees** that could be owned by independent teams

- **Keep as one epic when:**
  - Sessions share significant state or files
  - The charter needs to define architecture consumed by all feature sessions
  - Sessions feed into a final integration/CI gate that depends on everything

**User hints override this assessment.** If the user says "make 3 epics" or "epic-count: 2", follow their directive.

### Multi-epic structure

Each epic is a directory under `docs/claude-sessions/`:

```
docs/claude-sessions/
  epic-1-subsystem-name/
    session-00-operator-rules.md   (shared operator rules — reuse across epics)
    session-01-charter.md
    session-02-feature.md
    ...
  epic-2-another-subsystem/
    session-00-operator-rules.md   (same content or inherit from epic-1)
    session-01-charter.md          (Continuity references epic-1 handoff paths)
    ...
```

**Cross-epic dependencies:** Later epics reference prior epic handoffs in their `Continuity` section using paths like `docs/roadmap/epic-1-subsystem-name/session-NN-handoff.md`. Each epic runs sequentially — epic-N starts after epic-(N-1) completes and merges to trunk.

**Per-epic model selection:** Set the default model per epic via `--model` when running `run-sessions.sh`. Individual sessions can override via frontmatter `model:`.

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

Required fields: `session`, `title`, `depends_on`, `touches`, `parallel_safe`. Two optional overrides can also appear in the frontmatter:

- `model` — overrides the `--model` CLI arg for this session. Common values: `"opus"` (complex reasoning), `"sonnet"` (balanced), `"haiku"` (fast/simple). Also supports provider-prefixed IDs like `"gpt5"`, `"gemini"`, `"glm"`.
- `cli` — overrides the CLI for this session. Use `"claude"` or `"opencode"`. Omit to auto-detect.

Example with all fields:

    ---
    session: NN
    title: "Short title"
    depends_on: [<prior session numbers>]
    touches:
      - <glob this session may modify>
      - <another glob>
    parallel_safe: true
    model: "opus"
    cli: "claude"
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

### Multi-epic mode

When splitting into multiple epics (per the Complexity Assessment above), treat each epic as an independent unit with its own charter, feature sessions, and CI gate. Design each epic's DAG using the same rules above, then:

- **Epic ordering:** If epic-2 depends on epic-1 output, epic-2's charter session references epic-1's handoff docs in its `Continuity` section using explicit file paths like `docs/roadmap/epic-1-name/session-NN-handoff.md`.
- **Shared operator rules:** Copy `session-00-operator-rules.md` to each epic directory verbatim, or have later epics' session-00 include a note pointing to the original epic's operator rules.
- **Model strategy:** Assign `model: "opus"` to sessions doing complex architecture or risky work; `model: "sonnet"` or `model: "haiku"` for straightforward feature work. You can also set a default model per epic via `--model` when running `run-sessions.sh`.

### Frontmatter fields

- `session` — integer, must match the filename's NN. Required.
- `title` — short human title. Required.
- `depends_on` — list of prior session numbers (empty for session 01). Required. Omitting it implicitly chains the session linearly to the prior number, which defeats parallelism — always declare it explicitly.
- `touches` — list of file globs this session may modify. The runner uses these to detect overlaps between siblings in the same wave. Required for any session that writes code; empty list `[]` is fine for pure-validation sessions.
- `parallel_safe` — boolean. `false` forces solo-wave (charter, CI gate, anything with side effects on shared state). Default `true` for feature work.
- `model` — optional. Overrides the `--model` argument passed to `run-sessions.sh`. Use to assign different models to different sessions within the same epic. Common values: `opus` (complex reasoning), `sonnet` (balanced), `haiku` (fast/simple tasks). Also supports provider prefixes like `gpt5`, `gemini`, `glm`.
- `cli` — optional. Overrides the `--cli` argument. Use `claude` or `opencode` to force a specific CLI for this session.

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
3. Assess complexity (per the Complexity Assessment section above) to decide: **single epic** or **multiple epics**? If multiple, determine the split points and naming.
4. Decompose the work into a DAG that **maximizes the size of parallel waves** without creating `touches` overlaps between siblings. For multi-epic, design each epic's DAG independently, then ensure cross-epic dependencies are handled via handoff file references in Continuity sections.
5. Create the directory `docs/claude-sessions/<epic-name>/` for each epic (or `docs/claude-sessions/<epic-1>/`, `docs/claude-sessions/<epic-2>/`, etc.).
6. Write every required session file into the appropriate directory. For multiple epics, write all session files for epic-1 first, then epic-2, etc. — each epic's session numbering restarts at 01.
7. Ensure each file matches the required outer markdown structure exactly, including frontmatter on sessions 01+.
8. After writing the files for each epic, run `python3 scripts/epic-dag.py docs/claude-sessions/<epic-name> --show` to render the wave layout. If the output collapses into mostly single-session waves, your DAG is too sequential — revisit the dependencies and split file ownership.
9. In your response, report: **for each epic** — the created directory, the session files written, the wave layout (paste the `epic-dag.py --show` output), and the stack/quality-gate set selected. If multi-epic, also describe the cross-epic dependency order and which epic each session belongs to.
