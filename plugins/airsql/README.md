# AirSQL for Claude Code

This plugin adds AirSQL's MCP server to Claude Code, and a skill that tells Claude when to use it. AirSQL is a native
Mac app for MySQL, MariaDB and MongoDB; its server (`AirSQL --mcp`) talks to the AirSQL running on your Mac.

```sh
claude plugin marketplace add kleash/airsql
claude plugin install airsql@airsql
```

Then, in AirSQL: Settings ▸ Agents ▸ **Allow AI agents to use AirSQL**, and choose each connection's access (Off,
Schema, Schema + read, Schema + read + analytics). Connections start at Off. Claude never sees passwords and can't
change data: it reads within the access you chose, and proposes changes in a console tab for you to run.

Without the plugin: Settings ▸ Agents ▸ Add to Claude Code…, or

```sh
claude mcp add --scope user airsql -- /Applications/AirSQL.app/Contents/MacOS/AirSQL --mcp
```

More: [AI agents in AirSQL Help](https://kleash.github.io/airsql/agents.html).
