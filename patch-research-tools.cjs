#!/usr/bin/env node
// Post-update patching script for GSD research tool preferences.
// Replaces hardcoded WebSearch/WebFetch/Brave API references with
// Zread MCP + Kindly MCP across agent, command, and workflow files.
//
// Usage:
//   node scripts/patch-research-tools.cjs                  # patches ~/.claude/get-shit-done
//   node scripts/patch-research-tools.cjs --local           # patches .claude/ in cwd (local install)
//   node scripts/patch-research-tools.cjs --all             # patches both global and local
//   node scripts/patch-research-tools.cjs --gsd-dir <path>  # patches a specific directory
//
// Idempotent: safe to run multiple times.
'use strict';

const { readFileSync, writeFileSync, existsSync } = require('fs');
const { join, resolve } = require('path');
const { homedir } = require('os');

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const globalDir = join(homedir(), '.claude', 'get-shit-done');
const localDir = join(process.cwd(), '.claude');
const gsdDirs = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--gsd-dir' && args[i + 1]) {
    gsdDirs.push(resolve(args[i + 1]));
    i++;
  } else if (args[i] === '--local') {
    gsdDirs.push(localDir);
  } else if (args[i] === '--all') {
    gsdDirs.push(globalDir, localDir);
  }
}

if (gsdDirs.length === 0) {
  gsdDirs.push(globalDir);
}

// ---------------------------------------------------------------------------
// Patch definitions
// ---------------------------------------------------------------------------
const patches = [
  // =======================================================================
  // agents/gsd-project-researcher.md
  // =======================================================================
  {
    file: 'agents/gsd-project-researcher.md',
    replacements: [
      // 1. Frontmatter tools line
      {
        from: 'tools: Read, Write, Bash, Grep, Glob, WebSearch, WebFetch, mcp__context7__*',
        to:   'tools: Read, Write, Bash, Grep, Glob, mcp__context7__*, mcp__MetaMCP__Zread__*, mcp__MetaMCP__Kindly-MCP__*',
      },
      // 2. Replace sections 2, 3, and Brave API with Zread + Kindly
      {
        from: `### 2. Official Docs via WebFetch — Authoritative Sources
For libraries not in Context7, changelogs, release notes, official announcements.

Use exact URLs (not search result pages). Check publication dates. Prefer /docs/ over marketing.

### 3. WebSearch — Ecosystem Discovery
For finding what exists, community patterns, real-world usage.

**Query templates:**
\`\`\`
Ecosystem: "[tech] best practices [current year]", "[tech] recommended libraries [current year]"
Patterns:  "how to build [type] with [tech]", "[tech] architecture patterns"
Problems:  "[tech] common mistakes", "[tech] gotchas"
\`\`\`

Always include current year. Use multiple query variations. Mark WebSearch-only findings as LOW confidence.

### Enhanced Web Search (Brave API)

Check \`brave_search\` from orchestrator context. If \`true\`, use Brave Search for higher quality results:

\`\`\`bash
node "$HOME/.claude/get-shit-done/bin/gsd-tools.cjs" websearch "your query" --limit 10
\`\`\`

**Options:**
- \`--limit N\` — Number of results (default: 10)
- \`--freshness day|week|month\` — Restrict to recent content

If \`brave_search: false\` (or not set), use built-in WebSearch tool instead.

Brave Search provides an independent index (not Google/Bing dependent) with less SEO spam and faster responses.`,
        to: `### 2. Zread MCP (co-primary) — GitHub Repo Documentation
For reading GitHub repo docs, files, and structure directly. Cross-validate findings with Context7.

\`\`\`
1. mcp__MetaMCP__Zread__search_doc with repo_name and query
2. mcp__MetaMCP__Zread__read_file for specific files
3. mcp__MetaMCP__Zread__get_repo_structure for repo layout
\`\`\`

Use for changelogs, READMEs, release notes, and source code not covered by Context7. Always cross-validate Context7 and Zread against each other.

### 3. Kindly MCP — Web Search & Fetch
For ecosystem discovery, community patterns, real-world usage. Replaces built-in WebSearch/WebFetch.

\`\`\`
mcp__MetaMCP__Kindly-MCP__web_search with query and num_results (1-5)
mcp__MetaMCP__Kindly-MCP__get_content with url (for specific pages)
\`\`\`

Always include current year in queries. Use multiple query variations. Mark Kindly-only findings as LOW confidence.`,
      },
      // 3. Verification protocol: WebSearch → Kindly
      {
        from: `**WebSearch findings must be verified:**

\`\`\`
For each finding:
1. Verify with Context7? YES → HIGH confidence
2. Verify with official docs? YES → MEDIUM confidence
3. Multiple sources agree? YES → Increase one level
   Otherwise → LOW confidence, flag for validation
\`\`\``,
        to: `**Kindly web search findings must be verified:**

\`\`\`
For each finding:
1. Verify with Context7 or Zread? YES → HIGH confidence
2. Verify with official docs? YES → MEDIUM confidence
3. Multiple sources agree? YES → Increase one level
   Otherwise → LOW confidence, flag for validation
\`\`\``,
      },
      // 4. Confidence table
      {
        from: `| HIGH | Context7, official documentation, official releases | State as fact |
| MEDIUM | WebSearch verified with official source, multiple credible sources agree | State with attribution |
| LOW | WebSearch only, single source, unverified | Flag as needing validation |`,
        to: `| HIGH | Context7, Zread, official documentation, official releases | State as fact |
| MEDIUM | Kindly web search verified with official source, multiple credible sources agree | State with attribution |
| LOW | Kindly web search only, single source, unverified | Flag as needing validation |`,
      },
      // 5. Source priority line
      {
        from: '**Source priority:** Context7 → Official Docs → Official GitHub → WebSearch (verified) → WebSearch (unverified)',
        to:   '**Source priority:** Context7 / Zread → Official Docs → Official GitHub → Kindly web search (verified) → Kindly web search (unverified)',
      },
      // 6. Step 3 execution flow reference
      {
        from: 'For each domain: Context7 → Official Docs → WebSearch → Verify. Document with confidence levels.',
        to:   'For each domain: Context7 / Zread → Official Docs → Kindly web search → Verify. Document with confidence levels.',
      },
      // 7. Success criteria source hierarchy
      {
        from: '- [ ] Source hierarchy followed (Context7 → Official → WebSearch)',
        to:   '- [ ] Source hierarchy followed (Context7 / Zread → Official → Kindly)',
      },
      // 8. MANDATORY note in <role> section
      {
        from: `**Be comprehensive but opinionated.** "Use X because Y" not "Options are X, Y, Z."
</role>`,
        to: `**Be comprehensive but opinionated.** "Use X because Y" not "Options are X, Y, Z."

**CRITICAL: You MUST use Context7, Zread MCP, and Kindly MCP tools for ALL research — NOT built-in WebSearch/WebFetch. See \`<tool_strategy>\` for mandatory requirements.**
</role>`,
      },
      // 9. MANDATORY: MCP tool enforcement at top of tool_strategy
      {
        from: `<tool_strategy>

## Tool Priority Order`,
        to: `<tool_strategy>

## MANDATORY: MCP Tool Usage

**You MUST use these MCP tools for ALL research. DO NOT use built-in WebSearch or WebFetch tools.**

Every research task MUST include at minimum:
- 1+ Context7 query (\`mcp__context7__resolve-library-id\` → \`mcp__context7__query-docs\`) for each library/framework
- 1+ Zread call (\`mcp__MetaMCP__Zread__search_doc\` or \`mcp__MetaMCP__Zread__read_file\`) for repo documentation
- Cross-validation between Context7 and Zread findings
- Kindly MCP (\`mcp__MetaMCP__Kindly-MCP__web_search\`) for web searches — never built-in WebSearch

If a tool call fails, try alternative queries. Never fall back to WebSearch/WebFetch.

## What Each Tool Provides (Always Query Both, Cross-Validate)

| Research target | Context7 contributes | Zread contributes |
|---|---|---|
| Library/framework API docs | API reference, features, versions | Changelog, README, examples, migration guides |
| Specific file (Makefile, config, go.mod) | Related library docs for context | The file itself via \`read_file\` |
| Repo structure/layout | Library overview if indexed | Directory layout via \`get_repo_structure\` |
| Non-library research (patterns, arch) | Related framework/language docs | Repo patterns, real implementation examples |
| Changelog/release notes | Version-specific API docs | The changelog file itself |

**Context7 returns no match?** → Zread becomes sole doc source. Still always attempt Context7 first.
**Non-library topic?** → Context7 may return nothing — that's fine. Always attempt both.

## Tool Priority Order`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-phase-researcher.md
  // =======================================================================
  {
    file: 'agents/gsd-phase-researcher.md',
    replacements: [
      // 1. Frontmatter tools line
      {
        from: 'tools: Read, Write, Bash, Grep, Glob, WebSearch, WebFetch, mcp__context7__*',
        to:   'tools: Read, Write, Bash, Grep, Glob, mcp__context7__*, mcp__MetaMCP__Zread__*, mcp__MetaMCP__Kindly-MCP__*',
      },
      // 2. Tool priority table
      {
        from: `| Priority | Tool | Use For | Trust Level |
|----------|------|---------|-------------|
| 1st | Context7 | Library APIs, features, configuration, versions | HIGH |
| 2nd | WebFetch | Official docs/READMEs not in Context7, changelogs | HIGH-MEDIUM |
| 3rd | WebSearch | Ecosystem discovery, community patterns, pitfalls | Needs verification |`,
        to: `| Priority | Tool | Use For | Trust Level |
|----------|------|---------|-------------|
| 1st | Context7 | Library APIs, features, configuration, versions | HIGH |
| 2nd | Zread MCP | GitHub repo docs/READMEs not in Context7, changelogs | HIGH-MEDIUM |
| 3rd | Kindly MCP | Ecosystem discovery, community patterns, pitfalls | Needs verification |`,
      },
      // 3. Context7 flow: add Zread alongside
      {
        from: `**Context7 flow:**
1. \`mcp__context7__resolve-library-id\` with libraryName
2. \`mcp__context7__query-docs\` with resolved ID + specific query

**WebSearch tips:** Always include current year. Use multiple query variations. Cross-verify with authoritative sources.`,
        to: `**Context7 flow:**
1. \`mcp__context7__resolve-library-id\` with libraryName
2. \`mcp__context7__query-docs\` with resolved ID + specific query

**Zread flow (co-primary, cross-validate with Context7):**
1. \`mcp__MetaMCP__Zread__search_doc\` with repo_name and query
2. \`mcp__MetaMCP__Zread__read_file\` for specific files
3. \`mcp__MetaMCP__Zread__get_repo_structure\` for repo layout

**Kindly MCP tips:** Always include current year. Use multiple query variations. Cross-verify with authoritative sources.`,
      },
      // 4. Replace entire Brave API section with Kindly
      {
        from: `## Enhanced Web Search (Brave API)

Check \`brave_search\` from init context. If \`true\`, use Brave Search for higher quality results:

\`\`\`bash
node "$HOME/.claude/get-shit-done/bin/gsd-tools.cjs" websearch "your query" --limit 10
\`\`\`

**Options:**
- \`--limit N\` — Number of results (default: 10)
- \`--freshness day|week|month\` — Restrict to recent content

If \`brave_search: false\` (or not set), use built-in WebSearch tool instead.

Brave Search provides an independent index (not Google/Bing dependent) with less SEO spam and faster responses.`,
        to: `## Web Search (Kindly MCP)

Use Kindly MCP for all web search and page fetching:

\`\`\`
mcp__MetaMCP__Kindly-MCP__web_search with query and num_results (1-5)
mcp__MetaMCP__Kindly-MCP__get_content with url (for specific pages)
\`\`\`

Returns full markdown content for each result. Use \`get_content\` when you already have a URL.`,
      },
      // 5. Verification protocol
      {
        from: `**WebSearch findings MUST be verified:**

\`\`\`
For each WebSearch finding:
1. Can I verify with Context7? → YES: HIGH confidence
2. Can I verify with official docs? → YES: MEDIUM confidence
3. Do multiple sources agree? → YES: Increase one level
4. None of the above → Remains LOW, flag for validation
\`\`\``,
        to: `**Kindly web search findings MUST be verified:**

\`\`\`
For each Kindly finding:
1. Can I verify with Context7 or Zread? → YES: HIGH confidence
2. Can I verify with official docs? → YES: MEDIUM confidence
3. Do multiple sources agree? → YES: Increase one level
4. None of the above → Remains LOW, flag for validation
\`\`\``,
      },
      // 6. Source hierarchy table
      {
        from: `| HIGH | Context7, official docs, official releases | State as fact |
| MEDIUM | WebSearch verified with official source, multiple credible sources | State with attribution |
| LOW | WebSearch only, single source, unverified | Flag as needing validation |

Priority: Context7 > Official Docs > Official GitHub > Verified WebSearch > Unverified WebSearch`,
        to: `| HIGH | Context7, Zread, official docs, official releases | State as fact |
| MEDIUM | Kindly web search verified with official source, multiple credible sources | State with attribution |
| LOW | Kindly web search only, single source, unverified | Flag as needing validation |

Priority: Context7 / Zread > Official Docs > Official GitHub > Verified Kindly search > Unverified Kindly search`,
      },
      // 7. Step 3 execution flow
      {
        from: 'For each domain: Context7 first → Official docs → WebSearch → Cross-verify. Document findings with confidence levels as you go.',
        to:   'For each domain: Context7 / Zread first → Official docs → Kindly web search → Cross-verify. Document findings with confidence levels as you go.',
      },
      // 8. Success criteria source hierarchy
      {
        from: '- [ ] Source hierarchy followed (Context7 → Official → WebSearch)',
        to:   '- [ ] Source hierarchy followed (Context7 / Zread → Official → Kindly)',
      },
      // 9. Sources section in output format
      {
        from: `### Secondary (MEDIUM confidence)
- [WebSearch verified with official source]

### Tertiary (LOW confidence)
- [WebSearch only, marked for validation]`,
        to: `### Secondary (MEDIUM confidence)
- [Kindly web search verified with official source]

### Tertiary (LOW confidence)
- [Kindly web search only, marked for validation]`,
      },
      // 10. MANDATORY note in <role> section
      {
        from: `- Return structured result to orchestrator
</role>`,
        to: `- Return structured result to orchestrator

**CRITICAL: You MUST use Context7, Zread MCP, and Kindly MCP tools for ALL research — NOT built-in WebSearch/WebFetch. See \`<tool_strategy>\` for mandatory requirements.**
</role>`,
      },
      // 11. MANDATORY: MCP tool enforcement at top of tool_strategy
      {
        from: `<tool_strategy>

## Tool Priority`,
        to: `<tool_strategy>

## MANDATORY: MCP Tool Usage

**You MUST use these MCP tools for ALL research. DO NOT use built-in WebSearch or WebFetch tools.**

Every research task MUST include at minimum:
- 1+ Context7 query (\`mcp__context7__resolve-library-id\` → \`mcp__context7__query-docs\`) for each library/framework
- 1+ Zread call (\`mcp__MetaMCP__Zread__search_doc\` or \`mcp__MetaMCP__Zread__read_file\`) for repo documentation
- Cross-validation between Context7 and Zread findings
- Kindly MCP (\`mcp__MetaMCP__Kindly-MCP__web_search\`) for web searches — never built-in WebSearch

If a tool call fails, try alternative queries. Never fall back to WebSearch/WebFetch.

## What Each Tool Provides (Always Query Both, Cross-Validate)

| Research target | Context7 contributes | Zread contributes |
|---|---|---|
| Library/framework API docs | API reference, features, versions | Changelog, README, examples, migration guides |
| Specific file (Makefile, config, go.mod) | Related library docs for context | The file itself via \`read_file\` |
| Repo structure/layout | Library overview if indexed | Directory layout via \`get_repo_structure\` |
| Non-library research (patterns, arch) | Related framework/language docs | Repo patterns, real implementation examples |
| Changelog/release notes | Version-specific API docs | The changelog file itself |

**Context7 returns no match?** → Zread becomes sole doc source. Still always attempt Context7 first.
**Non-library topic?** → Context7 may return nothing — that's fine. Always attempt both.

## Tool Priority`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-debugger.md
  // =======================================================================
  {
    file: 'agents/gsd-debugger.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Write, Edit, Bash, Grep, Glob, WebSearch',
        to:   'tools: Read, Write, Edit, Bash, Grep, Glob, mcp__MetaMCP__Kindly-MCP__*',
      },
      // 2. "How to Research" section: Web Search line
      {
        from: `**Web Search:**
- Use exact error messages in quotes: \`"Cannot read property 'map' of undefined"\`
- Include version: \`"react 18 useEffect behavior"\`
- Add "github issue" for known bugs`,
        to: `**Kindly MCP Web Search:**
- Use exact error messages in queries: \`"Cannot read property 'map' of undefined"\`
- Include version: \`"react 18 useEffect behavior"\`
- Add "github issue" for known bugs
- \`mcp__MetaMCP__Kindly-MCP__web_search\` with query and num_results
- \`mcp__MetaMCP__Kindly-MCP__get_content\` for specific URLs`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-planner.md
  // =======================================================================
  {
    file: 'agents/gsd-planner.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Write, Bash, Glob, Grep, WebFetch, mcp__context7__*',
        to:   'tools: Read, Write, Bash, Glob, Grep, mcp__context7__*, mcp__MetaMCP__Zread__*, mcp__MetaMCP__Kindly-MCP__*',
      },
    ],
  },

  // =======================================================================
  // commands/gsd/plan-phase.md
  // =======================================================================
  {
    file: 'commands/gsd/plan-phase.md',
    replacements: [
      // 1. allowed-tools list: replace WebFetch + mcp__context7__* with full list
      {
        from: `  - WebFetch
  - mcp__context7__*`,
        to: `  - mcp__context7__*
  - mcp__MetaMCP__Zread__*
  - mcp__MetaMCP__Kindly-MCP__*`,
      },
    ],
  },

  // =======================================================================
  // commands/gsd/discuss-phase.md
  // =======================================================================
  {
    file: 'commands/gsd/discuss-phase.md',
    replacements: [
      // 1. allowed-tools: add Zread and Kindly after Context7
      {
        from: `  - mcp__context7__resolve-library-id
  - mcp__context7__query-docs
---`,
        to: `  - mcp__context7__resolve-library-id
  - mcp__context7__query-docs
  - mcp__MetaMCP__Zread__*
  - mcp__MetaMCP__Kindly-MCP__*
---`,
      },
    ],
  },

  // =======================================================================
  // commands/gsd/research-phase.md
  // =======================================================================
  {
    file: 'commands/gsd/research-phase.md',
    replacements: [
      // 1. Description text
      {
        from: '**Why subagent:** Research burns context fast (WebSearch, Context7 queries, source verification). Fresh 200k context for investigation. Main context stays lean for user interaction.',
        to:   '**Why subagent:** Research burns context fast (Context7, Zread, Kindly queries, source verification). Fresh 200k context for investigation. Main context stays lean for user interaction.',
      },
    ],
  },

  // =======================================================================
  // get-shit-done/workflows/discovery-phase.md
  // =======================================================================
  {
    file: 'get-shit-done/workflows/discovery-phase.md',
    replacements: [
      // 0. Section header
      {
        from: '**MANDATORY: Context7 BEFORE WebSearch**',
        to:   '**MANDATORY: Context7/Zread BEFORE Kindly web search**',
      },
      // 1. Source hierarchy
      {
        from: `1. **Context7 MCP FIRST** - Current docs, no hallucination
2. **Official docs** - When Context7 lacks coverage
3. **WebSearch LAST** - For comparisons and trends only`,
        to: `1. **Context7 MCP FIRST** - Current docs, no hallucination
2. **Zread MCP** - GitHub repo docs, cross-validate with Context7
3. **Official docs** - When Context7/Zread lack coverage
4. **Kindly MCP LAST** - For comparisons and trends only`,
      },
      // 2. Level 2 step 4: WebSearch references
      {
        from: `4. **WebSearch** for comparisons:

   - "[option A] vs [option B] {current_year}"
   - "[option] known issues"
   - "[option] with [our stack]"

5. **Cross-verify:** Any WebSearch finding → confirm with Context7/official docs.`,
        to: `4. **Kindly MCP** for comparisons:

   - \`mcp__MetaMCP__Kindly-MCP__web_search\` with "[option A] vs [option B] {current_year}"
   - "[option] known issues"
   - "[option] with [our stack]"

5. **Cross-verify:** Any Kindly finding → confirm with Context7/Zread/official docs.`,
      },
      // 3. Level 3 step 4: WebSearch for ecosystem
      {
        from: `4. **WebSearch for ecosystem context:**

   - How others solved similar problems
   - Production experiences
   - Gotchas and anti-patterns
   - Recent changes/announcements

5. **Cross-verify ALL findings:**

   - Every WebSearch claim → verify with authoritative source`,
        to: `4. **Kindly MCP for ecosystem context:**

   - How others solved similar problems
   - Production experiences
   - Gotchas and anti-patterns
   - Recent changes/announcements

5. **Cross-verify ALL findings:**

   - Every Kindly search claim → verify with authoritative source`,
      },
      // 4. Success criteria Level 2
      {
        from: '- WebSearch findings cross-verified',
        to:   '- Kindly search findings cross-verified',
      },
      // 5. Success criteria Level 3
      {
        from: '- All WebSearch findings verified against authoritative sources',
        to:   '- All Kindly search findings verified against authoritative sources',
      },
    ],
  },

  // =======================================================================
  // get-shit-done/workflows/discuss-phase.md
  // =======================================================================
  {
    file: 'get-shit-done/workflows/discuss-phase.md',
    replacements: [
      // 1. Context7 for library choices: add Zread alongside
      {
        from: '- **Context7 for library choices:** When a gray area involves library selection (e.g., "magic links" → query next-auth docs) or API approach decisions, use `mcp__context7__*` tools to fetch current documentation and inform the options. Don\'t use Context7 for every question — only when library-specific knowledge improves the options.',
        to:   '- **Context7 + Zread for library choices:** When a gray area involves library selection (e.g., "magic links" → query next-auth docs) or API approach decisions, use `mcp__context7__*` and `mcp__MetaMCP__Zread__*` tools to fetch current documentation and inform the options. Cross-validate findings between Context7 and Zread. Don\'t use these for every question — only when library-specific knowledge improves the options.',
      },
    ],
  },

  // =======================================================================
  // get-shit-done/workflows/new-project.md
  // =======================================================================
  {
    file: 'get-shit-done/workflows/new-project.md',
    replacements: [
      // 1. Quality gate in researcher prompt: add Zread
      {
        from: '- [ ] Versions are current (verify with Context7/official docs, not training data)',
        to:   '- [ ] Versions are current (verify with Context7/Zread/official docs, not training data)',
      },
    ],
  },

  // =======================================================================
  // get-shit-done/workflows/new-milestone.md
  // =======================================================================
  {
    file: 'get-shit-done/workflows/new-milestone.md',
    replacements: [
      // 1. Gates: add Zread alongside Context7
      {
        from: 'Versions current (verify with Context7), rationale explains WHY, integration considered',
        to:   'Versions current (verify with Context7/Zread), rationale explains WHY, integration considered',
      },
    ],
  },

  // =======================================================================
  // get-shit-done/templates/discovery.md
  // =======================================================================
  {
    file: 'get-shit-done/templates/discovery.md',
    replacements: [
      // 1. Source priority + quality checklist + confidence levels
      {
        from: `**Source Priority:**
1. **Context7 MCP** - For library/framework documentation (current, authoritative)
2. **Official Docs** - For platform-specific or non-indexed libraries
3. **WebSearch** - For comparisons, trends, community patterns (verify all findings)

**Quality Checklist:**
Before completing discovery, verify:
- [ ] All claims have authoritative sources (Context7 or official docs)
- [ ] Negative claims ("X is not possible") verified with official documentation
- [ ] API syntax/configuration from Context7 or official docs (never WebSearch alone)
- [ ] WebSearch findings cross-checked with authoritative sources
- [ ] Recent updates/changelogs checked for breaking changes
- [ ] Alternative approaches considered (not just first solution found)

**Confidence Levels:**
- HIGH: Context7 or official docs confirm
- MEDIUM: WebSearch + Context7/official docs confirm
- LOW: WebSearch only or training knowledge only (mark for validation)`,
        to: `**Source Priority:**
1. **Context7 MCP** - For library/framework documentation (current, authoritative)
2. **Zread MCP** - For GitHub repo docs, changelogs, specific files (cross-validate with Context7)
3. **Official Docs** - For platform-specific or non-indexed libraries
4. **Kindly MCP** - For comparisons, trends, community patterns (verify all findings)

**Quality Checklist:**
Before completing discovery, verify:
- [ ] All claims have authoritative sources (Context7, Zread, or official docs)
- [ ] Negative claims ("X is not possible") verified with official documentation
- [ ] API syntax/configuration from Context7/Zread or official docs (never Kindly search alone)
- [ ] Kindly search findings cross-checked with authoritative sources
- [ ] Recent updates/changelogs checked for breaking changes
- [ ] Alternative approaches considered (not just first solution found)

**Confidence Levels:**
- HIGH: Context7, Zread, or official docs confirm
- MEDIUM: Kindly search + Context7/Zread/official docs confirm
- LOW: Kindly search only or training knowledge only (mark for validation)`,
      },
    ],
  },

  // =======================================================================
  // get-shit-done/templates/research.md
  // =======================================================================
  {
    file: 'get-shit-done/templates/research.md',
    replacements: [
      // 1. Sources section
      {
        from: `### Primary (HIGH confidence)
- [Context7 library ID] - [topics fetched]
- [Official docs URL] - [what was checked]

### Secondary (MEDIUM confidence)
- [WebSearch verified with official source] - [finding + verification]

### Tertiary (LOW confidence - needs validation)
- [WebSearch only] - [finding, marked for validation during implementation]`,
        to: `### Primary (HIGH confidence)
- [Context7 library ID] - [topics fetched]
- [Zread repo_name] - [files/docs read]
- [Official docs URL] - [what was checked]

### Secondary (MEDIUM confidence)
- [Kindly web search verified with official source] - [finding + verification]

### Tertiary (LOW confidence - needs validation)
- [Kindly web search only] - [finding, marked for validation during implementation]`,
      },
    ],
  },

  // =======================================================================
  // get-shit-done/templates/research-project/SUMMARY.md
  // =======================================================================
  {
    file: 'get-shit-done/templates/research-project/SUMMARY.md',
    replacements: [
      // 1. Sources section
      {
        from: `### Primary (HIGH confidence)
- [Context7 library ID] — [topics]
- [Official docs URL] — [what was checked]`,
        to: `### Primary (HIGH confidence)
- [Context7 library ID] — [topics]
- [Zread repo_name] — [files/docs read]
- [Official docs URL] — [what was checked]`,
      },
    ],
  },

  // =======================================================================
  // get-shit-done/templates/research-project/STACK.md
  // =======================================================================
  {
    file: 'get-shit-done/templates/research-project/STACK.md',
    replacements: [
      // 1. Sources section
      {
        from: `- [Context7 library ID] — [topics fetched]
- [Official docs URL] — [what was verified]`,
        to: `- [Context7 library ID] — [topics fetched]
- [Zread repo_name] — [files/docs read]
- [Official docs URL] — [what was verified]`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-executor.md — Codanna + Serena (code intelligence)
  // =======================================================================
  {
    file: 'agents/gsd-executor.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Write, Edit, Bash, Grep, Glob\ncolor: yellow',
        to:   'tools: Read, Write, Edit, Bash, Grep, Glob, mcp__codanna__*, mcp__serena__*\ncolor: yellow',
      },
      // 2. CRITICAL note in <role> section
      {
        from: `If the prompt contains a \`<files_to_read>\` block, you MUST use the \`Read\` tool to load every file listed there before performing any other actions. This is your primary context.
</role>

<project_context>`,
        to: `If the prompt contains a \`<files_to_read>\` block, you MUST use the \`Read\` tool to load every file listed there before performing any other actions. This is your primary context.

**CRITICAL: You MUST use Codanna for code understanding and Serena for symbol-level editing — NOT multi-step Grep chains or reading entire files. Check \`mcp__codanna__get_index_info\` first. See \`<code_intelligence>\` for requirements.**
</role>

<project_context>`,
      },
      // 3. Code Intelligence section before execution_flow
      {
        from: `</project_context>

<execution_flow>`,
        to: `</project_context>

<code_intelligence>

## MANDATORY: Code Intelligence Tools

**You MUST use Codanna and Serena. Check index: \`mcp__codanna__get_index_info\` first.**

| Task | Use this | NOT this |
|---|---|---|
| Find code by intent | \`mcp__codanna__semantic_search_with_context\` | Multi-file Grep chains |
| Trace callers/callees | \`mcp__codanna__find_callers\` / \`get_calls\` | Grep for function name |
| Check blast radius | \`mcp__codanna__analyze_impact\` | Manual Grep across files |
| Understand file structure | \`mcp__serena__get_symbols_overview\` | Reading entire file |
| Read specific function | \`mcp__serena__find_symbol\` with \`include_body=True\` | Read tool on whole file |
| Edit a function | \`mcp__serena__replace_symbol_body\` | Edit tool with string-matching |
| Add code at position | \`mcp__serena__insert_after_symbol\` / \`insert_before_symbol\` | Edit tool |
| Cross-codebase rename | \`mcp__serena__rename_symbol\` | Find-and-replace across files |

Fall back to Grep/Read/Edit only if Codanna is not indexed AND Serena cannot handle the operation.
</code_intelligence>

<execution_flow>`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-debugger.md — Codanna + Serena (code intelligence)
  // =======================================================================
  {
    file: 'agents/gsd-debugger.md',
    replacements: [
      // 1. Frontmatter tools (add to existing Kindly tools)
      {
        from: 'tools: Read, Write, Edit, Bash, Grep, Glob, mcp__MetaMCP__Kindly-MCP__*\ncolor: orange',
        to:   'tools: Read, Write, Edit, Bash, Grep, Glob, mcp__MetaMCP__Kindly-MCP__*, mcp__codanna__*, mcp__serena__*\ncolor: orange',
      },
      // 2. CRITICAL note in <role> section
      {
        from: `- Handle checkpoints when user input is unavoidable
</role>`,
        to: `- Handle checkpoints when user input is unavoidable

**CRITICAL: You MUST use Codanna for code investigation and Serena for symbol-level reading — NOT multi-step Grep chains or reading entire files. Check \`mcp__codanna__get_index_info\` first.**
</role>`,
      },
      // 3. Add Codanna/Serena to How to Research section
      {
        from: `- \`mcp__MetaMCP__Kindly-MCP__get_content\` for specific URLs

**Context7 MCP:**
- For API reference, library concepts, function signatures`,
        to: `- \`mcp__MetaMCP__Kindly-MCP__get_content\` for specific URLs

**Codanna (Code Intelligence) — MUST use, check index with \`mcp__codanna__get_index_info\` first:**
- \`mcp__codanna__semantic_search_with_context\` — find code by intent during investigation
- \`mcp__codanna__find_callers\` / \`mcp__codanna__get_calls\` — trace call chains to find bug propagation
- \`mcp__codanna__analyze_impact\` — understand blast radius of a suspected root cause

**Serena (Symbol-Level Code Reading) — MUST use for reading specific functions:**
- \`mcp__serena__get_symbols_overview\` — understand file structure without reading entire files
- \`mcp__serena__find_symbol\` with \`include_body=True\` — read just the suspect function

Fall back to Grep/Read only if Codanna is not indexed AND Serena cannot handle the operation.

**Context7 MCP:**
- For API reference, library concepts, function signatures`,
      },
      // 3. Add Codanna/Serena to Technique Selection table
      {
        from: `## Technique Selection

| Situation | Technique |
|-----------|-----------|
| Large codebase, many files | Binary search |`,
        to: `## Technique Selection

| Situation | Technique |
|-----------|-----------|
| Need to trace call chains or callers | Codanna find_callers / get_calls |
| Need blast radius of a change | Codanna analyze_impact |
| Need to read specific function precisely | Serena find_symbol with include_body |
| Large codebase, many files | Binary search |`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-codebase-mapper.md — Codanna + Serena (code intelligence)
  // =======================================================================
  {
    file: 'agents/gsd-codebase-mapper.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Bash, Grep, Glob, Write\ncolor: cyan',
        to:   'tools: Read, Bash, Grep, Glob, Write, mcp__codanna__*, mcp__serena__*\ncolor: cyan',
      },
      // 2. CRITICAL note in <role> section
      {
        from: `If the prompt contains a \`<files_to_read>\` block, you MUST use the \`Read\` tool to load every file listed there before performing any other actions. This is your primary context.
</role>`,
        to: `If the prompt contains a \`<files_to_read>\` block, you MUST use the \`Read\` tool to load every file listed there before performing any other actions. This is your primary context.

**CRITICAL: You MUST use Codanna for code understanding and Serena for symbol-level reading — NOT multi-step Grep chains or reading entire files. Check \`mcp__codanna__get_index_info\` first.**
</role>`,
      },
      // 3. Add Codanna/Serena guidance to explore_codebase step
      {
        from: `Read key files identified during exploration. Use Glob and Grep liberally.
</step>`,
        to: `Read key files identified during exploration. Use Glob and Grep liberally.

**MUST use Codanna/Serena — check index with \`mcp__codanna__get_index_info\` first:**
- \`mcp__codanna__semantic_search_with_context\` — discover architecture by intent ("authentication flow", "database layer")
- \`mcp__codanna__analyze_impact\` — map dependency chains between components
- \`mcp__serena__get_symbols_overview\` — understand file structure without reading entire files (token-efficient)
- \`mcp__serena__find_symbol\` — read specific classes/functions without loading whole files

Fall back to Grep/Read only if Codanna is not indexed AND Serena cannot handle the operation.
</step>`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-integration-checker.md — Codanna (code intelligence)
  // =======================================================================
  {
    file: 'agents/gsd-integration-checker.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Bash, Grep, Glob\ncolor: blue',
        to:   'tools: Read, Bash, Grep, Glob, mcp__codanna__*\ncolor: blue',
      },
      // 2. CRITICAL note in <role> section
      {
        from: `**Critical mindset:** Individual phases can pass while the system fails. A component can exist without being imported. An API can exist without being called. Focus on connections, not existence.
</role>`,
        to: `**Critical mindset:** Individual phases can pass while the system fails. A component can exist without being imported. An API can exist without being called. Focus on connections, not existence.

**CRITICAL: You MUST use Codanna for tracing cross-phase connections — NOT multi-step Grep chains. Check \`mcp__codanna__get_index_info\` first.**
</role>`,
      },
      // 3. Add Codanna guidance to verification process
      {
        from: `**Run for key exports:**

- Auth exports (getCurrentUser, useAuth, AuthProvider)
- Type exports (UserType, etc.)
- Utility exports (formatDate, etc.)
- Component exports (shared components)`,
        to: `**MUST use Codanna — check index with \`mcp__codanna__get_index_info\` first:**
- \`mcp__codanna__analyze_impact\` — replaces grep chains for tracing export→import→usage across phases
- \`mcp__codanna__find_callers\` — find all callers of a function across the codebase
- \`mcp__codanna__search_symbols\` — find symbols by name with fuzzy matching

**Fallback (only if Codanna not indexed):**

- Auth exports (getCurrentUser, useAuth, AuthProvider)
- Type exports (UserType, etc.)
- Utility exports (formatDate, etc.)
- Component exports (shared components)`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-verifier.md — Codanna (code intelligence)
  // =======================================================================
  {
    file: 'agents/gsd-verifier.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Write, Bash, Grep, Glob\ncolor: green',
        to:   'tools: Read, Write, Bash, Grep, Glob, mcp__codanna__*\ncolor: green',
      },
      // 2. CRITICAL note in <role> section
      {
        from: `**Critical mindset:** Do NOT trust SUMMARY.md claims. SUMMARYs document what Claude SAID it did. You verify what ACTUALLY exists in the code. These often differ.
</role>`,
        to: `**Critical mindset:** Do NOT trust SUMMARY.md claims. SUMMARYs document what Claude SAID it did. You verify what ACTUALLY exists in the code. These often differ.

**CRITICAL: You MUST use Codanna for verifying code relationships — NOT multi-step Grep chains. Check \`mcp__codanna__get_index_info\` first.**
</role>`,
      },
      // 3. Add Codanna guidance to Step 5 (Verify Key Links)
      {
        from: `Key links are critical connections. If broken, the goal fails even with all artifacts present.

Use gsd-tools for key link verification against must_haves in PLAN frontmatter:`,
        to: `Key links are critical connections. If broken, the goal fails even with all artifacts present.

**MUST use Codanna — check index with \`mcp__codanna__get_index_info\` first:**
- \`mcp__codanna__analyze_impact\` — trace full dependency chain from artifact to consumers
- \`mcp__codanna__find_callers\` — verify functions are actually called, not just exported
- \`mcp__codanna__search_symbols\` — detect stub patterns (empty functions, placeholder returns)

Fall back to Grep only if Codanna is not indexed.

Use gsd-tools for key link verification against must_haves in PLAN frontmatter:`,
      },
    ],
  },

  // =======================================================================
  // agents/gsd-plan-checker.md — Codanna (code intelligence)
  // =======================================================================
  {
    file: 'agents/gsd-plan-checker.md',
    replacements: [
      // 1. Frontmatter tools
      {
        from: 'tools: Read, Bash, Glob, Grep\ncolor: green',
        to:   'tools: Read, Bash, Glob, Grep, mcp__codanna__*\ncolor: green',
      },
      // 2. CRITICAL note in <role> section
      {
        from: `You are NOT the executor or verifier — you verify plans WILL work before execution burns context.
</role>`,
        to: `You are NOT the executor or verifier — you verify plans WILL work before execution burns context.

**CRITICAL: You MUST use Codanna for validating symbol references — NOT multi-step Grep chains. Check \`mcp__codanna__get_index_info\` first.**
</role>`,
      },
      // 3. Add Codanna guidance to Step 7 (Check Key Links)
      {
        from: `For each key_link in must_haves: find source artifact task, check if action mentions the connection, flag missing wiring.

\`\`\`
key_link: Chat.tsx -> /api/chat via fetch`,
        to: `For each key_link in must_haves: find source artifact task, check if action mentions the connection, flag missing wiring.

**MUST use Codanna (check index with \`mcp__codanna__get_index_info\` first):** Use \`mcp__codanna__search_symbols\` to verify referenced symbols in must_haves.artifacts exist in the codebase. Fall back to Grep only if Codanna is not indexed.

\`\`\`
key_link: Chat.tsx -> /api/chat via fetch`,
      },
    ],
  },

  // =======================================================================
  // commands/gsd/execute-phase.md — Codanna + Serena (code intelligence)
  // =======================================================================
  {
    file: 'commands/gsd/execute-phase.md',
    replacements: [
      // 1. allowed-tools list
      {
        from: `  - AskUserQuestion
---`,
        to: `  - AskUserQuestion
  - mcp__codanna__*
  - mcp__serena__*
---`,
      },
    ],
  },

  // =======================================================================
  // commands/gsd/map-codebase.md — Codanna + Serena (code intelligence)
  // =======================================================================
  {
    file: 'commands/gsd/map-codebase.md',
    replacements: [
      // 1. allowed-tools list
      {
        from: `  - Write
  - Task
---`,
        to: `  - Write
  - Task
  - mcp__codanna__*
  - mcp__serena__*
---`,
      },
    ],
  },
];

// ---------------------------------------------------------------------------
// Patch execution
// ---------------------------------------------------------------------------
let hasErrors = false;
let totalPatched = 0;
let totalSkipped = 0;
let totalMissing = 0;

for (const gsdDir of gsdDirs) {
  if (!existsSync(gsdDir)) {
    console.log(`\nSkipping ${gsdDir} (directory not found)`);
    continue;
  }

  console.log(`\nPatching ${gsdDir}`);

  for (const { file, replacements } of patches) {
    const filePath = join(gsdDir, file);

    if (!existsSync(filePath)) {
      console.log(`  MISSING  ${file}`);
      hasErrors = true;
      totalMissing++;
      continue;
    }

    let content = readFileSync(filePath, 'utf8');
    let filePatched = 0;
    let fileSkipped = 0;

    for (const { from, to } of replacements) {
      if (content.includes(from)) {
        content = content.replace(from, to);
        filePatched++;
      } else if (content.includes(to)) {
        fileSkipped++;
      } else {
        // Neither from nor to found — content has diverged
        console.log(`  WARNING  ${file}: replacement not found (content may have changed upstream)`);
        console.log(`           Expected: ${JSON.stringify(from.slice(0, 80))}...`);
        fileSkipped++;
      }
    }

    if (filePatched > 0) {
      writeFileSync(filePath, content, 'utf8');
      console.log(`  PATCHED  ${file} (${filePatched} replacement${filePatched > 1 ? 's' : ''}${fileSkipped > 0 ? `, ${fileSkipped} already patched` : ''})`);
    } else {
      console.log(`  OK       ${file} (already patched)`);
    }

    totalPatched += filePatched;
    totalSkipped += fileSkipped;
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
console.log('');
console.log(`Done: ${totalPatched} replacements applied, ${totalSkipped} already patched, ${totalMissing} files missing`);

process.exit(hasErrors ? 1 : 0);
