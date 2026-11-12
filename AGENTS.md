# AirSQL for AI agents

AirSQL is a Mac app for MySQL, MariaDB and MongoDB. Agents reach it over MCP (`AirSQL --mcp`, set up
in Settings ▸ Agents): schemas and read-only queries on the connections the person has connected, at the access level
they set for each one, and no change without their approval. [Resources/AgentGuide.md](Resources/AgentGuide.md) lists
the tools; [docs/agents.md](docs/agents.md) is the person's side.

## Working on this repository

Coding agents: read [CLAUDE.md](CLAUDE.md) first. It has the layout, the build and test commands, the rules (smallest
change, Command Line Tools only, no third-party packages, every control explains itself, no work on the main thread),
the safety rules for this Mac, and points to the plan that every change follows.

The Docker test lab (every server version, the SSH and proxy routes, throwaway credentials) is described in
[testenv/AGENT.md](testenv/AGENT.md).
