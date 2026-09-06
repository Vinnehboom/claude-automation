---
name: coding-style
description: >-
  Record Vinnie's durable coding-style preferences into the shared "Coding Style
  Guide" Notion page for this repo. Use when the user explicitly invokes
  `/coding-style <preference>`, or passively when the user states or corrects a
  style choice during a task in a way that reads as a durable rule ("always...",
  "I prefer...", "we never...", or the same correction repeated). Reads the target
  page from `.claude/coding-style.json`. This is the doc that `/ticket-pipeline`
  (and other skills) read before implementing tickets.
---

# Coding Style skill

Maintains the living **Coding Style Guide** in Notion — the single source of
truth for Vinnie's durable coding-style preferences on this repo. It has two
halves:

- The **Style Rules database** (`rules_database` in `.claude/coding-style.json`).
  One row per rule. The row title IS the rule, written as a terse imperative.
  The row's page body holds the reasoning, the boundaries and the exceptions —
  what a reader consults when the one-line rule leaves doubt. Columns:
  `Category`, `Status` (Active/Superseded), `Hot list`, `Enforced by`, `Added`.
- The **guide page** (`notion_page_url`), which keeps the intro callout, the
  hot list, and the append-only **Change Log**.

Do not hardcode either ID here. Read both from `.claude/coding-style.json` at
the repo root.

## When to trigger

**Explicit:** the user runs `/coding-style <preference>` — always capture.

**Passive:** during any other task, the user states or corrects a style choice.
Only capture when it reads as a *durable* preference, not a one-off:

- Capture when signaled by "always", "never", "I prefer", "from now on", "we
  do/don't...", or the **same correction repeated** across the session.
- Do **not** capture task-specific or one-off decisions ("just for this file",
  "here let's...", a choice driven by the immediate ticket rather than taste).
- When genuinely ambiguous, ask a one-line confirmation before writing.

## What to write

1. **Read** `.claude/coding-style.json` → get the page and database pointers.
2. **Fetch** the guide page AND query the rules database, so you see every
   existing rule (do not duplicate one — refine it in place instead).
3. **Test for a repeat before you write anything.** Read the Style Rules and
   the Change Log. Ask whether the guide already carries this rule, in any
   wording. A repeat is a correction of a rule that is already written down.

   When it is a repeat, do NOT append a new bullet. Four bullets about code
   comments exist because four repeats were each answered with a fifth
   bullet. A rule that keeps coming back is not under-written. It is
   unenforced. Writing it down harder is the one response the record shows
   does not work. Answer a repeat this way instead:

   - **Sharpen the existing bullet in place**, when the wording is genuinely
     loose. Give it no neighbour.
   - **Promote it to the hot list** at the top of the guide, when it is not
     there already. Mirror the same line into the project's `CLAUDE.md` hot
     list and into `references/developer.md`. All three copies must stay
     identical.
   - **Propose a mechanical check** when a machine can test the rule — a
     rubocop cop, a lint rule, a git hook. Say so to the user and let them
     decide whether to file a ticket for it. Every rule with a cop behind it
     has stayed fixed. The rules that recur are the ones with nothing
     mechanical behind them.
   - **Record the repeat in the Change Log** as a promotion, not as a new
     rule: `YYYY-MM-DD — <category>: promoted <rule> to the hot list after a
     repeat (context: ...)`.

   Then go to step 6. Steps 4 and 5 are for a rule the guide does not have
   yet.

4. **Distill** the preference into a row. The **title** is the rule alone, as
   one terse imperative sentence — no rationale, no hedging, no "because".
   The **page body** carries the why, the boundary, the exception, and the
   source. Split them deliberately: a title that needs a subordinate clause is
   two rules or a body sentence. Match the voice of the existing rows.
5. **Set the columns.** `Status` is Active. `Hot list` is unchecked unless
   step 3 promoted it. `Enforced by` names the cop, script or hook if one
   exists, and stays empty otherwise — an empty value is the signal that this
   rule can only be held by hand. `Added` is today. `Category` is one of:
   Naming Conventions · Structure & Architecture · Error Handling ·
   Comments & Documentation · Testing · Formatting · Ruby / Rails Specific ·
   JavaScript Specific · Anti-patterns to Avoid · General. Replace a section's
   Don't invent a new category unless no existing one fits — adding a
   `Category` option is a schema change, so ask first. The hot list is a
   column, not a category. A rule reaches it by promotion (step 3), never as
   the first home for a new rule.
6. **Prepend a Change Log line** (newest at top) in the exact format:
   `YYYY-MM-DD — <category>: <what changed> (context: <brief source, e.g. file/ticket/discussion>)`
   Anchor this edit on the first existing `- ` bullet under `## Change Log`.
   Set `old_str` to that whole bullet line. Set `new_str` to your new
   bullet, then a newline, then that same bullet line again, unchanged.
   **Never anchor on the italic format line above the bullets, and never
   anchor on part of a bullet, such as its date and category prefix.**
   Both mistakes corrupt the log, and both have happened: one entry kept a
   stray `2026-09-02 — Structure & Architecture:` prefix from the bullet
   above it, and another had the format line spliced onto its end.
   Repaired 2026-09-05, on Vinnie's request.
7. **Re-fetch the page and read the top three Change Log bullets.** If a
   line is split, merged, duplicated, or carries text from its neighbor,
   correct it now. A corrupted entry looks fine to the writer. It stays
   invisible until somebody reads the log months later.
8. **Confirm** back to the user with a one-liner ("Added under Testing: ...",
   or "Promoted to the hot list: ...") — do not dump the whole doc back.

## Guardrails

- Only ever add or edit **rows** in the Style Rules database, and the **hot
  list** and **Change Log** sections of the guide page. Leave the intro
  callout alone. Never change the database schema, its columns, or its views.
- Retire a rule by setting its `Status` to Superseded, never by deleting the
  row. The history is the point.
- The hot list has three copies: the top of the Notion page, the project's
  `CLAUDE.md`, and `references/developer.md`. A change to one is a change to
  all three. A copy that drifts is worse than no copy.
- **Never fabricate a preference.** Capture only what the user actually stated
  or clearly implied. If you're inferring, ask first.
- Keep bullets terse and imperative — this doc is read as binding guidance by
  other skills, so noise costs everyone.
- When editing the Notion page, use a targeted `update_content` (search/replace
  on the specific bullet or the placeholder) rather than rewriting the page.
- Use today's real date for the Change Log entry.
