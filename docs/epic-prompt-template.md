# Epic Prompt Template

Copy everything below the `---`, paste it after your context/review, and send to Claude.

---

Generate a sequence of session `.md` files that will be executed autonomously by the `/epic` command. Each session runs as a FRESH Claude Code process with zero memory of prior sessions. **Sessions form a directed acyclic graph and parallel siblings run concurrently in per-session worktrees** — design for that.

## File structure

Directory: `docs/claude-sessions/<epic-name>/` (kebab-case name).

```
session-00-operator-rules.md
session-01-<kebab-desc>.md
session-02-<kebab-desc>.md
...
```

Numbers zero-padded to two digits. Session 00 is always operator rules.

## File format

Sessions 01+ MUST start with YAML frontmatter, then a markdown body, then a fenced ` ```md ``` ` prompt. Session 00 has no frontmatter.

    ---
    session: NN
    title: "Short title"
    depends_on: [<prior session numbers>]
    touches:
      - <glob this session may modify>
    parallel_safe: true
    ---

    # Session NN: Title

    Paste this into a new Claude Code session:

    ```md
    <prompt content here>
    ```

The script extracts ONLY content between the ` ```md ` and closing ` ``` `. Everything outside is ignored. Never nest ``` fences inside — use 4-space indented blocks for code examples within prompts.

## DAG design — design for parallelism

- **Charter (session 01)**: `depends_on: []`, `parallel_safe: false`. Audits the codebase, defines architecture, creates scaffolding (directories, type signatures, empty modules) that downstream sessions will fill in. This is what makes wave 2 parallelizable.
- **Feature sessions**: each owns a disjoint directory or file family. Multiple features in wave 2 all `depends_on: [01]`, `parallel_safe: true`. The `touches` globs must not overlap between siblings.
- **Composition sessions** (wave 3+): `depends_on: [<feature ids>]` — wait for the relevant feature siblings to merge into trunk first.
- **CI gate (final session)**: `depends_on: [<all prior session ids>]`, `parallel_safe: false`. Runs alone after every other session is merged.

If two slices touch the same files, do NOT make them parallel siblings. Either sequence them (declare a dependency edge) or merge them into one session.

## Session 00 — Operator Rules

Prepended to every session. Must contain:
- Role/persona for Claude across the initiative
- Hard constraints (safety, architecture, coding standards)
- Handoff convention: "End every session with a handoff under `docs/roadmap/<epic-name>/`"
- Definition of done: builds pass, tests pass, decisions documented, next-session inputs explicit

## Sessions 01–NN — Required sections

Each prompt inside the fence must have:

1. **Continuity**: Omit when `depends_on: []`. Otherwise first line lists every parent: `Continue from Session XX, YY artifacts.` Reference file paths, not memory.
2. **Mission**: One sentence.
3. **Repository anchors**: Explicit file paths this session reads/modifies. Should be consistent with `touches` frontmatter.
4. **Tasks**: Numbered, concrete. No vague items.
5. **Deliverables**: Exact paths. Always include `docs/roadmap/<epic-name>/session-NN-handoff.md`.
6. **Quality gates** (if code changes): the exact CI commands the project actually configures.
7. **Exit criteria**: Testable conditions.

## Sequencing

- Session 01 = charter. Solo wave. Audit codebase, define architecture, document decisions, lay scaffolding for parallel fan-out. Minimal code.
- Middle waves = feature work, parallel where possible. One feature/module per session. Each completable in one context window. `touches` globs disjoint across siblings in the same wave.
- Final session = CI gate. Solo wave. `depends_on` lists every prior session. Run all tests, verify consistency, produce go/no-go report.
- Every session produces a handoff doc with: what was done, decisions, open issues, next-session inputs.
- Split any session that feels too large.

## Rules

- No TBDs, TODOs, or deferred decisions in prompts.
- Never reference other sessions as if Claude remembers them — use file paths.
- Keep prompts under 60 lines.
- Frontmatter is mandatory on every session 01+ (`session`, `title`, `depends_on`, `touches`, `parallel_safe`).

## Validate

After writing the files, run:

    python3 "${CLAUDE_PLUGIN_ROOT}/scripts/epic-dag.py" docs/claude-sessions/<epic-name> --show

Inspect the wave layout. If most waves have a single session, the DAG is too sequential — re-examine dependencies and split file ownership to widen waves.
