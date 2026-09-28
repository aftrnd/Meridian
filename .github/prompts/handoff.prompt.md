---
description: Escalate the current task to Claude Code via Scripts/HANDOFF-ACTIVE.md
agent: agent
---

Hand this task off to Claude, following the **Two assistants** section of [AGENTS.md](../../AGENTS.md#two-assistants-qwen-first-claude-for-the-hard-parts).

1. Overwrite `Scripts/HANDOFF-ACTIVE.md` with the handoff template from AGENTS.md. Fill every section.
   - **Evidence** must be real command output or `meridian.log` lines, not paraphrase.
   - **Tried and ruled out** must list every attempt this session, including why it failed.
2. If there are uncommitted changes, don't discard them. Say in **State** which files are modified and whether they build.
3. Stop there. Don't keep trying to fix the problem. Tell me: "Handoff written — open Claude Code and say *take the handoff*."
