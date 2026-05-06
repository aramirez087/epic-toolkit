# Epic Prompt Template

Copy everything below the `---`, paste it after your context/review, and send to Claude.

---

Generate a sequence of session `.md` files that will be executed autonomously by the `/epic-toolkit:epic` command in Claude Code, or `/epic` in OpenCode. Each session runs as a FRESH Claude Code process with zero memory of prior sessions. **Sessions form a directed acyclic graph and parallel siblings run concurrently in per-session worktrees** — design for that.

## Complexity Assessment — Single Epic or Multi-Epic?

Before designing sessions, assess the problem to decide: **one epic** or **multiple epics**?

**Default to one epic** unless complexity justifies splitting. Use this heuristic:

- **Split into multiple epics when TWO or more of these apply:**
  - The problem spans **3+ independent subsystems** with no shared state
  - The total session count would exceed **10–12 sessions** for a single epic
  - Different subsystems need **different models** (e.g., opus for complex logic, haiku for CRUD)
  - A subsystem is **risky or experimental** — splitting lets you retry just that epic
  - The work touches **3+ non-overlapping directory trees**

- **Keep as one epic when:**
  - Sessions share significant state or files
  - The charter needs to define architecture consumed by all feature sessions
  - Sessions feed into a final integration/CI gate that depends on everything

**User hints override this assessment.** If the user says "make 3 epics" or "epic-count: 2", follow their directive.

## Multi-epic structure

Each epic is a directory under `docs/claude-sessions/`:

```
docs/claude-sessions/
  epic-1-subsystem-name/
    session-00-operator-rules.md
    session-01-charter.md
    session-02-feature.md
    ...
  epic-2-another-subsystem/
    session-00-operator-rules.md   (same content or inherit from epic-1)
    session-01-charter.md           (Continuity references epic-1 handoff paths)
    ...
```

**Cross-epic dependencies:** Later epics reference prior epic handoffs in their `Continuity` section using paths like `docs/roadmap/epic-1-subsystem-name/session-NN-handoff.md`. Each epic runs sequentially — epic-N starts after epic-(N-1) completes and merges to trunk.

**Per-epic model selection:** Set the default model per epic via `--model` when running `run-sessions.sh`. Individual sessions can override via frontmatter `model:`.

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

Required fields: `session`, `title`, `depends_on`, `touches`, `parallel_safe`. Optional fields:

- `model` — overrides the `--model` CLI arg for this session. Common values: `"opus"`, `"sonnet"`, `"haiku"`, or provider-prefixed IDs like `"gpt5"`, `"gemini"`, `"glm"`.
- `cli` — overrides the CLI for this session. Use `"claude"` or `"opencode"`. Omit to auto-detect.
- `produces` — list of paths or `fnmatch` globs the session must emit. The runner fails the session if any declared entry is missing from its diff. Recommended for any session that produces code; the toolkit can't enforce delivery without it.
- `skip_deliverables_check` — `true` to opt out of post-session validation. Use only for kickoff or docs-only sessions; without this, a session that commits only `.wolf/*` and a handoff doc will fail.

Example with all fields:

    ---
    session: NN
    title: "Short title"
    depends_on: [<prior session numbers>]
    touches:
      - <glob this session may modify>
    parallel_safe: true
    produces:
      - <exact file path the session creates or modifies>
      - <glob, e.g. "src/feature/**/*.ts">
    model: "opus"
    cli: "claude"
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

### Multi-epic mode

When splitting into multiple epics, treat each epic as an independent unit with its own charter, feature sessions, and CI gate. Design each epic's DAG using the same rules above, then:

- **Epic ordering:** If epic-2 depends on epic-1 output, epic-2's charter references epic-1's handoff docs in its `Continuity` section using explicit file paths like `docs/roadmap/epic-1-name/session-NN-handoff.md`.
- **Shared operator rules:** Copy `session-00-operator-rules.md` to each epic directory verbatim, or have later epics' session-00 include a note pointing to the original epic's operator rules.
- **Model strategy:** Assign `model: "opus"` to sessions doing complex architecture or risky work; `"sonnet"` or `"haiku"` for straightforward work. You can also set a default model per epic via `--model` when running.

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
- Optional frontmatter fields: `model`, `cli`, `produces`, `skip_deliverables_check`.
- Declare `produces:` on every session that creates code so the runner can verify delivery; only docs-only/kickoff sessions should rely on the metadata-only fallback.

## Validate

After writing the files, run:

    python3 "${CLAUDE_PLUGIN_ROOT}/scripts/epic-dag.py" docs/claude-sessions/<epic-name> --show

Inspect the wave layout. If most waves have a single session, the DAG is too sequential — re-examine dependencies and split file ownership to widen waves.

For multi-epic, run the validation for each epic directory separately and report all wave layouts.
