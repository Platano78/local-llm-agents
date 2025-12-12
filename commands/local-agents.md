---
description: Orchestrate up to 6 parallel local LLM agents using your agent library
argument-hint: <task description>
allowed-tools: Bash(~/.claude/scripts/local-agents/*), Bash(curl:*), Bash(cat:*), Bash(ls:*), Bash(jq:*), Glob, Read, mcp__agent-genesis__search_conversations
---

# Local Multi-Agent Orchestration

**Task**: $ARGUMENTS

---

## Quick Start: Run the Pipeline

For most tasks, just execute the orchestration pipeline:

```bash
~/.claude/scripts/local-agents/orchestrate.sh "$ARGUMENTS"
```

This runs the full pipeline:
1. **Health Check** → Verify servers (8081/8085)
2. **Decompose** → Break task into atomic TDD subtasks
3. **Map** → Assign tasks to available slots
4. **Execute** → Run agents in parallel with ReAct loop
5. **Quality Gate** → Review results via Orchestrator
6. **Synthesize** → Aggregate into final output

---

## Manual Orchestration (Advanced)

If you need fine control, run steps individually:

### Step 1: Check Handoff Context
```bash
cat ~/.claude/scripts/local-agents/HANDOFF.md
```

### Step 2: Verify Infrastructure
```bash
~/.claude/scripts/local-agents/health-check.sh
~/.claude/scripts/local-agents/slot-detector.sh
```

### Step 3: Decompose Task
```bash
~/.claude/scripts/local-agents/tdd-decomposer.sh "$ARGUMENTS" 6 > /tmp/decomposed.json
cat /tmp/decomposed.json | jq .
```

### Step 4: Map to Agents
```bash
~/.claude/scripts/local-agents/agent-mapper.sh /tmp/decomposed.json 6 > /tmp/mapped.json
```

### Step 5: Execute
```bash
~/.claude/scripts/local-agents/execute-agents.sh /tmp/mapped.json /tmp/outputs > /tmp/results.json
```

### Step 6: Quality Review
```bash
~/.claude/scripts/local-agents/quality-gate.sh /tmp/results.json > /tmp/quality.json
```

### Step 7: Synthesize
```bash
~/.claude/scripts/local-agents/synthesize.sh /tmp/results.json /tmp/quality.json
```

---

## Server Configuration

| Server | Port | Purpose | Tokens |
|--------|------|---------|--------|
| Worker | 8081 | Code execution (ReAct agents) | 65K+ |
| Orchestrator | 8085 | Task routing & quality review | 1024+ |

**Response Format** (Reasoning models):
- `reasoning_content`: Chain-of-thought (CoT)
- `content`: Final answer (parse JSON from either)

---

## Agent Library

Your 37+ agents at `~/.claude/agents/`:

| Category | Agents |
|----------|--------|
| **Code Review** | code-review-automation-agent, security-compliance-agent |
| **Performance** | code-optimization-agent, database-optimization-specialist |
| **Development** | web-dev-specialist, unity-master-developer, mcp-architect |
| **Quality** | automated-bug-triage-agent, automated-playtester-agent |
| **Documentation** | documentation-specialist-agent |
| **Game Dev** | narrative-design-agent, gameplay-balancing-agent, mmorpg-architect |
| **Architecture** | codebase-recon-agent, task-decomposition-expert |

---

## TDD Phases

The decomposer assigns tasks to these phases:

| Phase | Purpose |
|-------|---------|
| **RED** | Write failing test specification |
| **GREEN** | Implement minimal code to pass |
| **REFACTOR** | Improve quality without changing behavior |
| **ANALYZE** | Review, audit, investigate (non-implementation) |

---

## Pipeline Files

After execution, find artifacts in `/tmp/local-agents-<timestamp>/`:

| File | Content |
|------|---------|
| `decomposed.json` | Task breakdown |
| `mapped.json` | Agent assignments |
| `results.json` | Execution results |
| `quality.json` | Quality review |
| `synthesis.json` | Final output |
| `outputs/` | Individual task outputs |

---

## Troubleshooting

**No LLM servers?**
```bash
# Check what's running
curl -s http://localhost:8081/health
curl -s http://localhost:8085/health
```

**Decomposition fails?**
- Ensure orchestrator (8085) is running
- Check max_tokens >= 1024 for complex tasks

**Results empty?**
- Check individual task outputs in `outputs/T*.json`
- Look for JSON in both `content` and `reasoning_content`

---

Now execute the pipeline for the user's task.
