# Local LLM Agents

**TDD-driven task orchestration for local LLMs**

A lightweight, bash-based pipeline for running AI agents on your local hardware. No API keys required - just your GPU and any OpenAI-compatible LLM server.

## Features

- **TDD Workflow**: RED → GREEN → REFACTOR cycle for reliable code generation
- **Parallel Execution**: Run multiple agents simultaneously (limited by GPU slots)
- **Dynamic Agent Selection**: LLM picks the best agent for each task
- **Self-Improving**: Generates new agents on-demand when needed
- **Quality Gates**: Automatic review and scoring of outputs
- **Works with Any Local LLM**: vLLM, LM Studio, llama.cpp, Ollama

## Requirements

- **Local LLM Server**: Any OpenAI-compatible endpoint (default: `localhost:8081`)
- **jq**: JSON processor (`apt install jq` or `brew install jq`)
- **curl**: HTTP client (usually pre-installed)
- **bash**: Version 4.0+ recommended

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/yourusername/local-llm-agents.git
cd local-llm-agents

# 2. Run the install script
./install.sh

# 3. Start your local LLM server (example with vLLM)
vllm serve your-model --port 8081

# 4. Run a task
./scripts/orchestrate.sh "Create a Python function to check if a number is prime" 2
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     ORCHESTRATE.SH                          │
├─────────────────────────────────────────────────────────────┤
│  1. Health Check    → Verify LLM server is running          │
│  2. Decompose       → Break task into TDD subtasks          │
│  3. Map Agents      → Select best agent for each task       │
│  4. Execute         → Run agents in parallel batches        │
│  5. Quality Gate    → Review and score outputs              │
│  6. Synthesize      → Combine results into final output     │
└─────────────────────────────────────────────────────────────┘
```

## Usage

### Basic Usage

```bash
# Run with default 2 parallel slots
./scripts/orchestrate.sh "Your task description"

# Run with custom slot count
./scripts/orchestrate.sh "Your task description" 4
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKER_PORT` | `8081` | Port for the main LLM worker |
| `ORCHESTRATOR_PORT` | `8085` | Port for orchestrator model (optional) |
| `AGENT_POOL` | `./agents` | Directory containing agent definitions |
| `WORK_DIR` | `/tmp/local-agents-*` | Working directory for outputs |

### Example Tasks

```bash
# Code generation
./scripts/orchestrate.sh "Create a Python class for a binary search tree"

# Testing
./scripts/orchestrate.sh "Write unit tests for the UserService class"

# Refactoring
./scripts/orchestrate.sh "Refactor the database module to use connection pooling"
```

## Agent Pool

Agents are Markdown files in the `agents/` directory. Each agent has:
- A system prompt defining its role
- Suggested tools it can use
- Output format expectations

### Included Agents

| Agent | Purpose |
|-------|--------|
| `code-generator-agent` | Writes implementation code |
| `test-writer-agent` | Creates unit tests |
| `code-reviewer-agent` | Reviews code quality |
| `refactor-agent` | Improves code structure |
| `documentation-agent` | Writes documentation |

### Creating Custom Agents

```markdown
---
name: my-custom-agent
category: development
phase: GREEN
---

# My Custom Agent

You are a specialized agent for [specific task].

## Instructions
1. Analyze the task
2. Produce output in the specified format
3. Include relevant details

## Output Format
[Define expected output structure]
```

## How It Works

### 1. Task Decomposition

The pipeline breaks your task into atomic TDD subtasks:

```json
{
  "parallel_groups": [
    {
      "group": 1,
      "description": "Write failing tests",
      "tasks": [{"id": "T1", "phase": "RED", "task": "Write test for..."}]
    },
    {
      "group": 2, 
      "description": "Implement to pass tests",
      "tasks": [{"id": "T2", "phase": "GREEN", "task": "Implement..."}]
    }
  ]
}
```

### 2. Dynamic Agent Selection

For each task, the pipeline:
1. Queries the LLM to select the best agent from the pool
2. Falls back to phase-based defaults if no match
3. Can generate new agents on-demand for specialized tasks

### 3. Parallel Execution

```
Available Slots: 2

Batch 1 (RED phase):
┌─────────┐  ┌─────────┐
│ Slot 1  │  │ Slot 2  │  ← Run in parallel
│ T1      │  │ T2      │
└─────────┘  └─────────┘
[Wait for batch completion]

Batch 2 (GREEN phase):
┌─────────┐  ┌─────────┐
│ Slot 1  │  │ Slot 2  │  ← Run in parallel
│ T3      │  │ T4      │
└─────────┘  └─────────┘
```

### 4. Quality Gate

Every execution is reviewed:
- Overall quality score (0-100)
- Per-task assessment
- Critical issues flagged
- Recommendations provided

## Supported LLM Servers

| Server | Tested | Notes |
|--------|--------|-------|
| vLLM | ✅ | Recommended for multi-slot execution |
| LM Studio | ✅ | Easy setup, good for single slot |
| llama.cpp | ✅ | Lightweight option |
| Ollama | ✅ | Use with `OLLAMA_HOST` |
| LocalAI | ⚠️ | Should work, not extensively tested |

## Project Structure

```
local-llm-agents/
├── scripts/
│   ├── orchestrate.sh      # Main pipeline
│   ├── health-check.sh     # Server health verification
│   ├── tdd-decomposer.sh   # Task decomposition
│   ├── agent-mapper.sh     # Agent selection
│   ├── agent-selector.sh   # Dynamic LLM-based selection
│   ├── agent-generator.sh  # On-demand agent creation
│   ├── execute-agents.sh   # Parallel execution
│   ├── react-executor.sh   # ReAct loop for agents
│   ├── quality-gate.sh     # Output review
│   ├── synthesize.sh       # Result aggregation
│   └── tool-executor.sh    # Tool execution
├── prompts/
│   ├── decompose.txt       # Decomposition prompt
│   ├── quality-review.txt  # Quality gate prompt
│   ├── synthesize.txt      # Synthesis prompt
│   └── tool-instructions.txt
├── agents/                 # Agent definitions
├── examples/               # Example usage
└── install.sh              # Installation script
```

## Troubleshooting

### "No LLM server available"

Start your local LLM server:
```bash
# vLLM
vllm serve model-name --port 8081

# LM Studio
# Start via GUI, enable server on port 8081

# Ollama
OLLAMA_HOST=0.0.0.0:8081 ollama serve
```

### "Empty response from LLM"

- Check if model is loaded and responding
- Try increasing timeout: `LLM_TIMEOUT=60`
- Verify the model supports chat completions API

### "Agent file not found"

- Ensure `AGENT_POOL` points to correct directory
- Check agent filename matches expected pattern: `agent-name.md`

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [vLLM](https://github.com/vllm-project/vllm) - High-throughput LLM serving
- [LM Studio](https://lmstudio.ai/) - Desktop app for local LLMs
- [Ollama](https://ollama.ai/) - Run LLMs locally
