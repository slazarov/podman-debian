# LPS 3PL Portal — Claude Code Instructions

## Project
Django 6.0 multi-tenant 3PL portal. Depositors view inventory/orders/receipts synced from dsWMS (MS SQL Server, read-only). Metronic v9 (Tailwind) + KTUI + HTMX frontend. PostgreSQL. Podman rootless deployment.

## Key Paths
| Path | Contents |
|------|----------|
| `src/` | Django root — `manage.py`, `config/`, `apps/`, `templates/`, `static/`, `locale/` |
| `src/config/settings/` | Env-split settings: `dev.py`, `prod.py`, `test.py` |
| `src/apps/` | 8 apps: accounts, api, audit, core, dswms, inventory, orders, portal |
| `deploy/` | Containerfile, gunicorn config, quadlets, lima, env overrides, scripts |
| `vendor/` | Pre-compiled Metronic v9 + KTUI — **read-only, never modify** |
| `tests/` | pytest suite (run from project root) |
| `docs/` | dsWMS schema docs, package compatibility tracking |
| `_bmad-output/planning-artifacts/` | PRD, architecture, UX spec, epics (implementation specs) |


## Conventions
- **Package manager:** `uv` — never use raw `pip`
- **Python:** >= 3.13
- **Multi-tenancy:** All querysets MUST filter by `depositor_id` (manual RLS)
- **Templates:** Use `{% partialdef %}` for HTMX partials (not `{% partial %}`)
- **Settings:** No hardcoded secrets — use env vars or Podman secrets
- **Containerfiles:** No `USER` directive — Podman runs rootless

## Don'ts
- **vendor/** — read-only pre-compiled assets, never modify
- **dsWMS** — read-only access only (pymssql), never write
- **Docker Compose** — project uses Podman quadlets + systemd, not Compose

<!-- rtk-instructions v2 -->
## RTK (Token Optimization)
Always prefix these commands with `rtk`. Filters verbose output to save tokens. Safe for ALL commands. Use in `&&` chains too: `rtk cmd1 && rtk cmd2`. 

Commands:

`ls, tree, read, smart, git, gh, pnpm, err, test, json, deps, env, find, diff, log, docker, kubectl, summary, grep, init, wget, gain, cc-economics, config, vitest, prisma, tsc, next, lint, prettier, playwright, cargo, npm, npx, curl, discover, learn, proxy, ruff, pytest, pip, go, golangci-lint, help`
<!-- /rtk-instructions -->

<!-- code-intelligence-mcp-routing v2 -->
## MCP Tool Routing
Use automatically based on task — don't wait for user to ask.

| Task | Use | Key tools |
|------|-----|-----------|
| Understand/search code | **Codanna** | `semantic_search_with_context`, `find_symbol`, `analyze_impact`, `find_callers` |
| Refactor/rename code | **Serena** | `rename_symbol`, `replace_symbol_body`, `find_referencing_symbols` |
| Library/framework docs | **Context7 + ZRead** | Always query both in Sonnet sub-agent (see protocol below) |
| Web research | **Kindly MCP** | `web_search`, `get_content` — changelogs, community solutions, edge cases |
| Read a specific file | **Read tool** | Fastest for known paths |
| Find files by pattern | **Glob tool** | Fastest for file discovery |
| Text search | **Grep tool** | Fastest for content search |

### Library Doc Protocol
Spawn a **Sonnet sub-agent** (Task tool, `model: "sonnet"`) that queries **both** Context7 (`query-docs`) and ZRead (`search_doc`) in parallel. Prefer ZRead for version/API accuracy, Context7 for usage patterns. Conflicts: defer to ZRead. Return concise summary only — no raw docs in main context. Add Kindly MCP web search in same sub-agent if official docs are insufficient.

**Library ID lookup:** Before querying Context7 or ZRead, read `docs/packages.md` for the exact Context7 and ZRead library identifiers. This table maps every project dependency to its correct MCP library ID — use it instead of guessing or calling `resolve-library-id`.

### Story Dev & Validation: Mandatory MCP Verification
During **dev-story** and **code-review** workflows, verify ALL infrastructure and library choices against real docs:
1. **Read `docs/packages.md`** first — get Context7/ZRead library IDs for every technology in the story
2. **Spawn Sonnet sub-agents** to query Context7 + ZRead + Kindly (web) in parallel for each technology area (e.g., Lima config, Podman quadlets, PostgreSQL images, Python packages)
3. **Verify versions exist** — don't assume a version doesn't exist based on training data. Web search Docker Hub, PyPI, npm, etc.
4. **Verify API/config syntax** — check actual docs for correct keys, values, breaking changes between versions
5. **Check for breaking changes** — version upgrades often change paths, APIs, defaults (e.g., PostgreSQL 18 PGDATA path change)

This is NOT optional. Skipping MCP verification risks silent runtime failures from wrong versions, changed APIs, or incorrect syntax.

### MCP Notes
- **Codanna indexes `vendor/`** — use for Metronic/KTUI source search
- **Codanna indexes docs** — use `semantic_search_docs` / `search_documents` for planning artifacts (PRD/architecture/UX/epics)
- **Serena:** Run `onboarding` once per project before first use
- **Don't duplicate:** If Codanna found the symbol, don't re-search with Grep
<!-- /code-intelligence-mcp-routing -->
