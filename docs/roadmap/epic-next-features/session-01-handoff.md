# Session 01 Architecture Decision Record: Epic Toolkit Next Features

## Executive Summary

This charter session analyzed the epic-toolkit codebase and designed the architecture for 6 new features that extend timeout handling, configuration management, per-session tool selection, and cleanup automation. All features can be implemented in parallel across sessions 02-04 with no coupling dependencies, enabling maximum development velocity.

## Current System Architecture

### Core Components Analysis

**scripts/epic-dag.py** (394 lines)
- DAG parser using minimal YAML frontmatter parsing (stdlib only)
- Kahn-style wave computation for parallel scheduling  
- Outputs: `--bash` (line-oriented for shell), `--json` (structured), `--show` (human-readable)
- Current SESSION output: `SESSION <wave> <id> <file> <deps> <slug> <parallel>`
- Backward-compatible column extension strategy already in place

**scripts/run-sessions.sh** (1183 lines)
- Bash 3.2+ compatible orchestrator with worktree isolation
- CLI auto-detection: `OPENCODE_SESSION_ID` → opencode, `CLAUDECODE` → claude, PATH fallback
- Current flags: `--start`, `--end`, `--max-parallel`, `--strict`, `--sequential`, `--model`, `--cli`, etc.
- Two-pass execution: PLAN (read-only) → EXECUTE (commits)
- `run_cli()` function wraps AI CLI invocations with progress tracking

**Documentation Structure**
- README.md: high-level overview with common flags table
- docs/epic-guide.md: comprehensive user guide with detailed options table
- commands/epic.md: Claude Code slash command interface
- .opencode/commands/epic.md: OpenCode slash command interface (nearly identical)

## Feature Requirements Analysis

Based on sessions 02-05, the following 6 feature areas were identified:

### 1. Per-Session Model Override (Session 02)
**Interface Contract:**
- New frontmatter key: `model: "opus"` (optional, string)
- Parsing location: `load_sessions()` in epic-dag.py line ~116
- Storage: session dict `s["model"]` (default: empty string)
- Output: extend `emit_bash()` SESSION lines with `<model>` column
- JSON output: include `model` field in session objects

### 2. Per-Session CLI Override (Session 02) 
**Interface Contract:**
- New frontmatter key: `cli: "claude"` (optional, string)  
- Parsing location: `load_sessions()` in epic-dag.py line ~116
- Storage: session dict `s["cli"]` (default: empty string)
- Output: extend `emit_bash()` SESSION lines with `<cli>` column  
- JSON output: include `cli` field in session objects

### 3. Timeout Wrapping (Session 03)
**Interface Contract:**
- New CLI flag: `--timeout MINS` (default 0 = no timeout)
- Config key: `timeout` in `.epic-config.json`
- Implementation: wrap `run_cli()` calls with `timeout` command when > 0
- Exit code 124 detection → mark session as "timed out after Xm"
- Retry integration: timeout applies per retry attempt

### 4. Retry Logic (Session 03)
**Interface Contract:**
- New CLI flag: `--retry N` (default 0 = no retry)
- Config key: `retry` in `.epic-config.json`
- Implementation: retry loop in `run_one_session()` on failure
- Log retry attempts in session logs
- Final failure only after all retries exhausted

### 5. Configuration File Support (Session 03)
**Interface Contract:**
- File location: `${REPO_ROOT}/.epic-config.json`
- Schema (all optional):
  ```json
  {
    "timeout": 0,
    "retry": 0, 
    "cli": "",
    "model": "sonnet",
    "maxParallel": 4,
    "autoCommit": true,
    "autoPr": true,
    "skipPlan": false,
    "keepWorktree": false
  }
  ```
- Precedence: CLI flags > config file > hardcoded defaults
- Error handling: silent fallback with warning log on malformed JSON

### 6. Stale Worktree Cleanup (Session 03)
**Interface Contract:**
- Trigger: before trunk worktree setup in run-sessions.sh
- Scope: scan `.epic-worktrees/<repo>/` for `epic--<name>--sNN-*` patterns
- Logic: remove worktrees/branches NOT in current DAG plan
- Safety: only touch epic-pattern worktrees, never other git worktrees
- Logging: report what was cleaned up

## Parallelization Analysis

### No Coupling Dependencies Found

After analyzing all file touch patterns and interface contracts:

**Session 02 (DAG Extensions)**
- Touches: `scripts/epic-dag.py` only
- Dependencies: Session 01 handoff for interface contracts
- No shared files with other implementation sessions

**Session 03 (Runner Features)** 
- Touches: `scripts/run-sessions.sh` only
- Dependencies: Session 01 handoff for interface contracts
- Consumes extended DAG output from Session 02, but interface is pre-defined
- No shared files with other implementation sessions

**Session 04 (Documentation)**
- Touches: `README.md`, `docs/epic-guide.md`, `commands/epic.md`, `.opencode/commands/epic.md`
- Dependencies: Session 01 handoff for feature specifications
- No shared files with other implementation sessions

**Conclusion:** Sessions 02-04 can execute in parallel with zero coordination.

## Exact Interface Contracts

### DAG Parser Extensions (Session 02)

**Input Interface:**
```yaml
# New optional frontmatter keys
model: "opus"           # string, default ""
cli: "opencode"         # string, default ""
```

**Output Interface Changes:**
```bash
# Current: SESSION <wave> <id> <file> <deps> <slug> <parallel>
# New:     SESSION <wave> <id> <file> <deps> <slug> <parallel> <model> <cli>
```

**Code Changes:**
- `parse_frontmatter()`: no changes needed (already extracts all keys)
- `load_sessions()`: add `s["model"] = fm.get("model", "")` and `s["cli"] = fm.get("cli", "")`
- `emit_bash()`: append `{s['model']} {s['cli']}` to SESSION lines
- JSON output schema: add `model` and `cli` fields to session objects

### Runner Core Extensions (Session 03)

**CLI Interface:**
```bash
--timeout MINS          # default 0 (no timeout)
--retry N               # default 0 (no retry)  
```

**Configuration Schema:**
```json
{
  "timeout": 0,           # minutes, 0 = disabled
  "retry": 0,             # count, 0 = disabled
  "cli": "",              # override auto-detection
  "model": "sonnet",      # default model
  "maxParallel": 4,       # max concurrent sessions
  "autoCommit": true,     # fallback commit on success
  "autoPr": true,         # auto-create PR
  "skipPlan": false,      # single-pass mode
  "keepWorktree": false   # retain trunk worktree
}
```

**Code Changes:**
- Add argument parsing for `--timeout` and `--retry`
- Add config file loading with try/catch and fallback
- Modify `run_cli()` to wrap with `timeout` command when enabled
- Add retry loop in `run_one_session()` 
- Add stale cleanup before worktree setup
- Extend DAG consumption to read model/cli columns

### Documentation Updates (Session 04)

**File Modification Matrix:**
- README.md: add flags to table, add config section, add frontmatter example
- docs/epic-guide.md: extend options table, add config reference, add frontmatter section
- commands/epic.md: add flags to description and defaults
- .opencode/commands/epic.md: sync with commands/epic.md

**Consistency Requirements:**
- Flag names, defaults, and descriptions must match across all files
- Frontmatter examples must be identical
- Config schema must be documented consistently

## Implementation Plan

### Wave 2: Parallel Implementation (Sessions 02-04)

**Session 02: DAG Parser Extensions**
1. Modify `load_sessions()` to extract `model` and `cli` frontmatter
2. Store in session dict with empty string defaults
3. Extend `emit_bash()` to append two columns to SESSION lines
4. Update JSON output schema to include new fields
5. Add backward compatibility comment
6. Run quality gates: syntax check, --show, --bash column count, --json validation

**Session 03: Runner Core Features** 
1. Add CLI parsing for --timeout and --retry flags
2. Implement `.epic-config.json` loading with error handling
3. Modify `run_cli()` to use timeout command when enabled
4. Add retry logic in `run_one_session()`
5. Implement stale worktree cleanup before trunk setup
6. Update DAG consumption to read model/cli from extended output
7. Run quality gates: syntax check, dry-run validation, flag parsing

**Session 04: Documentation Updates**
1. Update README.md flags table and add config section
2. Extend docs/epic-guide.md with full reference material
3. Add new flags to both command files
4. Ensure consistency across all four files
5. Run quality gates: grep validation for new terms, consistency checks

### Wave 3: Integration Verification (Session 05)

**Session 05: CI Gate and Integration Testing**
1. Run syntax validation on all modified files
2. Test functional integration of all new features
3. Verify backward compatibility with existing epics
4. Cross-check documentation consistency 
5. Produce go/no-go report with specific test results

## Risk Analysis and Mitigations

### Low Risk (Mitigated by Design)

**Backward Compatibility**
- Mitigation: All new features default to existing behavior
- Validation: Existing epics continue working unchanged
- Test: Run with all defaults, verify identical output

**Bash 3.2 Compatibility**
- Mitigation: Use only basic constructs, no `local -n`, `mapfile`, `readarray`
- Validation: All new code follows existing patterns
- Test: Parse with `bash -n` on macOS (ships with Bash 3.2)

**Python 3.8+ Stdlib Only**
- Mitigation: Only use json, os, sys modules (already used)
- Validation: No new imports required
- Test: `python3 -m py_compile` on target files

### Medium Risk (Managed with Safeguards)

**Config File Parsing Errors**
- Risk: Malformed JSON could crash the runner
- Mitigation: try/catch with silent fallback and warning log
- Test: Create malformed `.epic-config.json`, verify graceful handling

**Column Count Changes Breaking Parsers**
- Risk: External scripts that parse `--bash` output could break  
- Mitigation: Append columns to end, document backward compatibility
- Test: Verify older parsers ignore extra columns

**Stale Cleanup Affecting Wrong Worktrees**
- Risk: Accidentally removing non-epic worktrees
- Mitigation: Strict pattern matching for `epic--<name>--sNN-*` only
- Test: Create non-epic worktrees, verify they're untouched

### Mitigation Validation Plan

Each implementation session includes specific test commands to verify mitigations work correctly. The CI gate session (05) runs comprehensive integration tests to catch any missed edge cases.

## File-by-File Modification Plan

### Session 02 Files
- **scripts/epic-dag.py**: Add model/cli parsing and output columns (~15 line changes)

### Session 03 Files  
- **scripts/run-sessions.sh**: Add flags, config loading, timeout wrapper, retry logic, cleanup (~50 line changes)

### Session 04 Files
- **README.md**: Add flag table rows, config section (~15 line changes)
- **docs/epic-guide.md**: Extend options table, add config reference (~30 line changes) 
- **commands/epic.md**: Add flags to description and defaults (~10 line changes)
- **.opencode/commands/epic.md**: Mirror changes from commands/epic.md (~10 line changes)

### Session 05 Files
- **None**: Read-only validation and testing

## Success Criteria

### Technical Validation
- [ ] All syntax checks pass (python compile, bash -n)
- [ ] Functional tests pass for all new features
- [ ] Backward compatibility preserved (existing epics unchanged)
- [ ] Documentation consistency verified across 4 files
- [ ] Integration tests demonstrate end-to-end functionality

### Interface Contracts Fulfilled  
- [ ] DAG parser accepts `model` and `cli` frontmatter
- [ ] `--bash` output includes 2 additional columns
- [ ] Runner accepts `--timeout` and `--retry` flags  
- [ ] `.epic-config.json` loaded with proper precedence
- [ ] Stale worktrees cleaned before execution
- [ ] All documentation updated and consistent

## Deliverables for Downstream Sessions

### For Session 02 (DAG Extensions)
- **Required Input**: This handoff document
- **Expected Output**: 
  - Modified `scripts/epic-dag.py` with model/cli parsing
  - Working `--bash` output with 8 columns (was 6)
  - Updated JSON schema with new fields
  - docs/roadmap/epic-next-features/session-02-handoff.md

### For Session 03 (Runner Features)
- **Required Input**: This handoff document  
- **Expected Output**:
  - Modified `scripts/run-sessions.sh` with all new flags and features
  - Working timeout wrapper and retry logic
  - Functional `.epic-config.json` support
  - Working stale cleanup automation
  - docs/roadmap/epic-next-features/session-03-handoff.md

### For Session 04 (Documentation)  
- **Required Input**: This handoff document
- **Expected Output**:
  - Updated README.md with new flags and config
  - Updated docs/epic-guide.md with full reference
  - Updated commands/epic.md with new interface
  - Updated .opencode/commands/epic.md in sync
  - docs/roadmap/epic-next-features/session-04-handoff.md

### For Session 05 (Integration)
- **Required Input**: All three implementation handoffs
- **Expected Output**: 
  - Go/no-go report with specific test results
  - docs/roadmap/epic-next-features/session-05-handoff.md

## Architecture Decision Summary

1. **Feature Isolation**: Each new feature is independently configurable with sensible defaults
2. **Backward Compatibility**: Zero breaking changes to existing behavior or output formats  
3. **Parallel Implementation**: Sessions 02-04 have no coupling and can run concurrently
4. **Progressive Enhancement**: New features layer on top of existing architecture without modification
5. **Robust Error Handling**: All failure modes have graceful degradation paths
6. **Documentation-First**: All features documented consistently across 4 user-facing files

This architecture enables rapid parallel development while maintaining the stability and usability that makes epic-toolkit reliable for production use.