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

Maintains the living **Coding Style Guide** Notion page — the single source of
truth for Vinnie's durable coding-style preferences on this repo. The page has
two parts: **Style Rules** (distilled imperative bullets, grouped by category)
and an append-only **Change Log** (dated history of each addition).

Do not hardcode the page ID here. Read it from `.claude/coding-style.json` at
the repo root (`notion_page_id` / `notion_page_url`).

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

1. **Read** `.claude/coding-style.json` → get the page ID.
2. **Fetch** the Notion page to see current sections and existing rules (so you
   don't duplicate an existing rule — refine it in place instead).
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

4. **Distill** the preference into a short, imperative bullet: a bold lead
   phrase stating the rule, then a sentence of the *why* / boundary. Match the
   voice of the existing bullets.
5. **Place it** under the correct existing heading. Current categories:
   Naming Conventions · Structure & Architecture · Error Handling ·
   Comments & Documentation · Testing · Formatting · Ruby / Rails Specific ·
   JavaScript Specific · Anti-patterns to Avoid · General. Replace a section's
   `*No entries yet.*` placeholder with the first real bullet. Don't invent new
   headings unless no existing category fits. The hot list at the top of the
   page is not one of these categories. A rule reaches it by promotion
   (step 3), never as the first home for a new rule.
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

- Only ever edit the **hot list**, the **Style Rules**, and the **Change
  Log** sections. Leave the intro callout and section structure alone.
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
