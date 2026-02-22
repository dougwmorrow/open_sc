# Crafting CLAUDE.md for autonomous coding agents

**The single most important insight about CLAUDE.md is counterintuitive: less is dramatically more.** Research across Anthropic's official docs, production teams processing billions of tokens monthly, and community analysis of instruction-following behavior converges on one finding — frontier LLMs can reliably follow roughly **150–200 total instructions**, and Claude Code's system prompt already consumes ~50 of those slots. Every unnecessary line in your CLAUDE.md uniformly degrades the agent's ability to follow *all* instructions, including the critical ones. This makes CLAUDE.md the highest-leverage configuration point for autonomous agent performance, and getting it right requires treating it as a carefully tuned prompt rather than a comprehensive manual.

---

## How CLAUDE.md actually works under the hood

CLAUDE.md is not injected as a system prompt. Claude Code wraps its contents in a `<system-reminder>` tag and delivers it as a **user message** following the system prompt, with an important caveat: the wrapper explicitly tells Claude that "this context may or may not be relevant to your tasks" and instructs it to ignore content that isn't highly relevant. This architecture means Claude will actively skip CLAUDE.md sections it deems irrelevant to the current task — a critical detail for autonomous operation where no human is present to redirect.

Claude Code discovers CLAUDE.md files by recursing upward from the working directory to the filesystem root, loading all parent-level files at startup. Files in **child directories** load on-demand only when Claude reads files in those subdirectories. The full memory hierarchy, from highest to lowest precedence, is:

| Tier | Location | Scope | Git strategy |
|------|----------|-------|-------------|
| Enterprise policy | `/etc/claude-code/CLAUDE.md` (Linux) or `/Library/Application Support/ClaudeCode/CLAUDE.md` (macOS) | All org users | MDM-deployed |
| Project shared | `./CLAUDE.md` or `./.claude/CLAUDE.md` | Team | Committed |
| Project rules | `.claude/rules/*.md` | Team (path-scoped) | Committed |
| Project local | `CLAUDE.local.md` | Individual | Gitignored |
| User global | `~/.claude/CLAUDE.md` | All your projects | N/A |

More specific instructions always take precedence over broader ones. All files combine rather than replace each other, with conflicts resolved by specificity. CLAUDE.md also supports an `@path/to/file` import syntax that resolves recursively up to **5 levels deep**, enabling modular organization without embedding entire files into context.

---

## The WHAT / WHY / HOW framework for structuring content

The most battle-tested organizational framework, validated across production teams and Anthropic's own guidance, structures CLAUDE.md around three pillars. **WHAT** maps the project — tech stack, directory structure, key entry points. **WHY** explains the purpose behind architectural decisions so the agent can make aligned choices when facing ambiguity. **HOW** provides the exact verification commands and workflow steps the agent needs to execute autonomously.

Anthropic's official plugin quality criteria weight these areas explicitly: **commands/workflows documented** and **architecture clarity** each carry the highest weight (20 points), followed by non-obvious patterns, conciseness, currency, and actionability (15 points each). A production-ready CLAUDE.md should contain these sections and nothing more:

**Universal verification commands** form the non-negotiable core. Every CLAUDE.md must include exact, copy-paste-ready test, lint, typecheck, and build commands. These are the agent's only mechanism for self-verification during autonomous operation.

**Project structure map** provides the spatial orientation Claude needs to navigate non-trivial codebases. Keep it to key directories with one-line descriptions — not a comprehensive tree.

**Decision boundaries and error recovery rules** are critical specifically for autonomous operation. These tell the agent when to proceed confidently versus when to stop and escalate (detailed in the autonomous patterns section below).

**Git workflow conventions** should cover branching strategy, commit message format, and explicit prohibitions like never committing to main or force-pushing.

**Pointers to detailed documentation** use progressive disclosure — instead of embedding content, write trigger conditions: "For Stripe integration details → see `docs/payments.md`" or "If you encounter FooBarError → see `docs/troubleshooting.md`." Claude reads files on demand, so this keeps instruction count low while making detailed information accessible.

What to explicitly exclude: **code style rules** that linters handle, **comprehensive API documentation**, **project history**, and anything Claude already does correctly without instruction.

---

## Sizing and the 150-instruction ceiling

HumanLayer's analysis of instruction-following research found that as instruction count increases, compliance degrades **uniformly** — the model doesn't just ignore new instructions but begins ignoring all of them. With Claude Code's system prompt consuming ~50 instruction slots, your CLAUDE.md has roughly **100–150 slots** before significant degradation begins. Production benchmarks from teams at scale:

- **HumanLayer's own root CLAUDE.md**: under 60 lines
- **Shrivu Shankar's enterprise monorepo** (billions of tokens/month): 13KB with strict per-section token budgets allocated like "ad space"
- **Community consensus**: root file under **200–300 lines**, with subdirectory files at 50–100 lines
- **Fresh session baseline cost**: ~20K tokens (10% of 200K context) from CLAUDE.md plus system prompt in a monorepo

The forcing function philosophy applies here: if your CLI commands are too complex to document concisely, that's a tooling problem — write a bash wrapper with a clear API and document *that*. Keeping CLAUDE.md short forces you to simplify your actual development environment, which benefits both human and AI developers.

For each line in your CLAUDE.md, apply this litmus test: **"Would removing this cause Claude to make a mistake it doesn't currently make?"** If not, cut it. Document what Claude gets wrong, not everything it should theoretically know.

---

## Modular rules in .claude/rules/ solve priority saturation

The `.claude/rules/` directory, introduced in Claude Code v2.0.64, provides the key mechanism for scaling beyond a monolithic CLAUDE.md without hitting the instruction ceiling. All `.md` files in this directory load automatically at the same priority as CLAUDE.md — but the real power is **path-scoped conditional loading** via YAML frontmatter:

```yaml
---
paths: src/api/**/*.ts
---
# API endpoint rules
- All endpoints must validate input using Zod schemas
- Use the standard error response format from src/api/errors.ts
```

Rules without a `paths` field load unconditionally. Rules with path patterns only activate when Claude works with matching files. This isn't just organization — it's **scoping when instructions receive elevated attention**, directly addressing the priority saturation problem.

Best practices for the rules directory:

- **One topic per file** with descriptive filenames (`testing.md`, `security.md`, `api-design.md`)
- **Subdirectories for grouping** (`frontend/`, `backend/`, `shared/`)
- **Use conditional rules sparingly** — only add `paths:` when rules truly apply to specific file types
- **Keep root CLAUDE.md under 100–200 lines** with universal instructions; extract domain-specific content into targeted rule files
- **Use symlinks** to share rules across projects: `ln -s ~/company-standards/security.md .claude/rules/security.md`

The community tool **claude-rules-doctor** (by nulone) can detect dead rule files where `paths:` globs don't match any actual files in your repository.

---

## Structuring for autonomous and headless operation

Autonomous operation in Claude Code primarily uses the `-p` / `--print` flag for headless execution, with `--dangerously-skip-permissions` for fully unattended runs. The CLAUDE.md must compensate for the absent human by providing explicit decision boundaries, error recovery procedures, and completion criteria.

**Decision boundary instructions** are the most critical addition for autonomous operation. Production-validated patterns include:

```markdown
## Autonomous rules
- Proceed without asking for: new tests, lint fixes, clear feature implementations
- STOP and ask for: schema changes, auth/security modifications, file deletions, ambiguous requirements
- If a fix fails after 2 attempts: document the issue in tasks/blocked.md, move on
- Never mark a task complete without: tests passing + typecheck clean + lint clean
- If requirements are ambiguous: write a spec (inputs/outputs/edge cases) before coding
- When blocked: ask exactly ONE question with a recommended default
```

**Error recovery must follow a strict protocol.** The "stop-the-line" pattern works best: on any unexpected failure, immediately stop adding features, preserve evidence, then follow a reproduce → localize → fix root cause → add regression test → verify cycle. Never fix symptoms.

**The block-at-submit pattern** is critical for autonomous agents. Rather than using hooks that block mid-edit (which consumes massive context — one team reported 160K tokens in 3 rounds of failed format-check loops), enforce quality gates at **commit time**. A PreToolUse hook on `git commit` that checks for passing tests lets the agent complete its work uninterrupted, then validates the final result. As one production user put it: "Blocking an agent mid-plan confuses or even 'frustrates' it."

**Compaction survival instructions** protect against context window overflow during long autonomous sessions:

```markdown
## Context management
When compacting, always preserve:
- Full list of modified files and their status
- All test commands and their most recent results  
- Current task state and remaining steps
- Key architectural decisions made this session
```

**Safety requirements for `--dangerously-skip-permissions`**: always sandbox in Docker with `--network none`, limit tools via `--allowedTools`, use git worktrees to isolate each agent session, and set `--max-budget-usd` to cap spending.

---

## Seven anti-patterns that cripple autonomous agents

**The over-specified CLAUDE.md** is the most common failure mode. When the file grows too long, Claude ignores half of it because important rules get lost in noise. The fix: ruthlessly prune, and convert any rule Claude already follows naturally into a hook or linter config instead.

**Using CLAUDE.md as a linter** wastes instruction slots on rules like "use 2-space indentation" or "always use semicolons." These should be handled by deterministic tools (ESLint, Prettier, Biome) enforced via hooks. As HumanLayer states: "Never send an LLM to do a linter's job."

**@-file embedding** (`@docs/full-api-reference.md`) injects the entire referenced file into context on every single session, silently bloating the instruction count. Use natural-language pointers with trigger conditions instead.

**Negative-only constraints** ("Never use `--foo-bar`") leave the agent stuck when it believes it needs that flag. Always provide the alternative: "Never use `--foo-bar`; prefer `--baz` instead."

**Blindly using /init output** generates a CLAUDE.md that captures obvious patterns but misses the nuances that actually matter. Always heavily edit the auto-generated file — a bad line affects every phase of every workflow.

**Block-at-write hooks** that run formatters after every file edit consume enormous context through repeated failure-correction loops. Block at commit time instead, letting the agent finish its work before validation.

**Complex slash command libraries** represent a subtle anti-pattern. If you've built an elaborate system of custom commands, you've re-introduced the rigidity that agents are designed to eliminate. The whole point is describing what you want in natural language.

---

## AGENTS.md, subagents, and multi-agent orchestration

**AGENTS.md** is an emerging cross-platform open standard — a "README for agents" — now stewarded by the Agentic AI Foundation under the Linux Foundation. Over **60,000 open-source projects** use it, with support from OpenAI Codex, Google Jules, Cursor, Amp, Factory, and 20+ other tools. Claude Code does **not** natively read AGENTS.md (a feature request exists at GitHub issue #6235), but you can bridge the gap by adding `@AGENTS.md` to your CLAUDE.md or symlinking between the two files.

For teams using multiple AI coding tools, the pragmatic approach is maintaining AGENTS.md as the single source of truth and referencing it from tool-specific files. Claude ignores YAML frontmatter, while Cursor uses it, so rules written in Cursor's format work across both tools.

**Claude Code's native subagent system** (`.claude/agents/`) defines specialized agents as Markdown files with YAML frontmatter specifying name, description, and allowed tools. Each subagent gets its own context window and cannot spawn further subagents. The experimental **Agent Teams** feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) enables cross-session coordination where one session acts as team lead and teammates work independently with automatic message delivery. CLAUDE.md loads normally for all teammates, making it the primary mechanism for shared context — three teammates reading a clear CLAUDE.md is far cheaper than three teammates independently exploring the codebase.

For **CrewAI integration**, a CrewAI-Claude MCP server exists that bridges the two systems through the Model Context Protocol, though CrewAI's YAML-based agent configuration operates at a fundamentally different abstraction layer than file-based CLAUDE.md context. **LangChain's research** on context engineering found that "a concise, structured guide in the form of CLAUDE.md always outperformed simply wiring in documentation tools," with the best results combining both approaches — base knowledge via CLAUDE.md plus on-demand access to specific docs.

---

## A production-ready template

Based on the synthesis of all sources, here is a reference CLAUDE.md optimized for autonomous operation:

```markdown
# [Project Name] — [one-line tech stack description]

## Structure
- app/api/ — REST endpoints (Express)
- app/web/ — Next.js frontend  
- packages/shared/ — Shared types and utilities
- docs/ — Detailed architecture and integration guides

## Commands
- Test: `pnpm test` (single file: `pnpm test -- path/to/file`)
- Typecheck: `pnpm type:check`
- Lint+fix: `pnpm lint --fix`
- Build: `pnpm build`
- Dev: `pnpm dev` (port 3000)

## Workflow
- Feature branches only: `feature/short-description`. Never commit to main.
- Conventional Commits: feat:, fix:, docs:, refactor:, test:, chore:
- Run test + typecheck + lint before every commit.
- Commit incrementally after each verified step. Do NOT push unless asked.

## Autonomous rules
- Proceed without asking: new tests, lint fixes, clear feature work, branch creation
- STOP and ask: schema changes, auth/security code, file deletions, ambiguous requirements
- If a fix fails twice: document in tasks/blocked.md, move on
- Never done without: all tests passing + zero type errors + zero lint errors
- Ambiguous requirements: write a spec (inputs/outputs/edge cases) before coding

## Error recovery
- Test failure → STOP features → reproduce → fix root cause → regression test → verify
- Build failure → fix before any other work
- When blocked: ask ONE question with a recommended default

## Context (read on demand, not at startup)
- Stripe integration → docs/payments.md
- Auth patterns → docs/auth.md
- DB migrations → docs/database.md (MUST read before any schema change)

## Gotchas
- The webhook handler in app/api/webhooks validates signatures — never bypass
- Product images stored in Cloudinary, not locally
- Hooks handle formatting and pre-commit linting — don't check these manually
```

## Conclusion

The core insight for CLAUDE.md in autonomous operation is that **instruction quality matters exponentially more than instruction quantity**. The 150-instruction ceiling means every line must earn its place through a direct impact on agent behavior. The most effective CLAUDE.md files share three properties: they are **short** (under 200 lines at root), **actionable** (exact commands, explicit decision boundaries, concrete alternatives for every prohibition), and **layered** (universal rules in root CLAUDE.md, domain rules in `.claude/rules/` with path scoping, detailed docs accessible on demand via progressive disclosure pointers).

The field is converging on a clear architectural pattern: use CLAUDE.md for Claude Code-specific context, AGENTS.md for cross-platform agent guidance, `.claude/rules/` for path-scoped domain rules, and deterministic hooks for anything that must be enforced without exception. For autonomous operation specifically, the decision boundary instructions — when to proceed versus when to stop — are the single most impactful addition you can make, because they replace the judgment calls a human operator would otherwise provide.
