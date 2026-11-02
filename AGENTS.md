# AirSQL for AI agents

AirSQL is a Mac app for MySQL and MariaDB, in development (0.1.0): there is nothing to install or drive yet. Agent
access over MCP is planned ([docs/dev/plan.md](docs/dev/plan.md), §2.8): schemas and read-only queries at the access
level the person at the Mac sets for each connection, and no change without their approval.

## Working on this repository

Coding agents: read [CLAUDE.md](CLAUDE.md) first. It has the layout, the build and test commands, the rules (smallest
change, Command Line Tools only, no third-party packages, every control explains itself, no work on the main thread),
the safety rules for this Mac, and points to the plan that every change follows.

The Docker test lab (every server version, the SSH and proxy routes, throwaway credentials) is described in
[testenv/AGENT.md](testenv/AGENT.md).
