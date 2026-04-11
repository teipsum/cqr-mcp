# MCP Integration

How to connect CQR MCP Server to your MCP client. All examples assume the server has been cloned, `mix deps.get` has been run, and `mix run --no-halt` starts the server cleanly.

## Claude Desktop

### Configuration file location

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Linux:** `~/.config/Claude/claude_desktop_config.json`

### Minimal configuration

```json
{
  "mcpServers": {
    "cqr": {
      "command": "/path/to/elixir",
      "args": ["--sname", "cqr", "-S", "mix", "run", "--no-halt"],
      "cwd": "/path/to/cqr-mcp",
      "env": {
        "CQR_AGENT_ID": "twin:your_name",
        "CQR_AGENT_SCOPE": "scope:company"
      }
    }
  }
}
```

Replace `/path/to/elixir` with the output of `which elixir` and `/path/to/cqr-mcp` with the absolute path to the cloned repository. Restart Claude Desktop after editing the config.

### Persistent storage

The configuration above runs in-memory — the sample dataset is seeded on every launch and any data asserted via `cqr_assert` is lost when Claude Desktop restarts. To persist data across restarts, append `--persist` after a `--` separator so Mix forwards it as a script argument:

```json
{
  "mcpServers": {
    "cqr": {
      "command": "/path/to/elixir",
      "args": ["--sname", "cqr", "-S", "mix", "run", "--no-halt", "--", "--persist"],
      "cwd": "/path/to/cqr-mcp",
      "env": {
        "CQR_AGENT_ID": "twin:your_name",
        "CQR_AGENT_SCOPE": "scope:company"
      }
    }
  }
}
```

Persistent mode opens (or creates) `~/.cqr/grafeo.db` and does **not** seed the sample dataset. Supply a path after `--persist` to choose a custom location, or append `--reset` to wipe the database and re-seed the sample data as a factory reset.

### Verification

Once Claude Desktop reconnects:

1. Open the tool picker. Four tools appear: `cqr_resolve`, `cqr_discover`, `cqr_certify`, `cqr_assert`.
2. Open the resource browser. The `cqr://session` resource shows the current agent identity, visible scopes, connected adapters, and protocol version.
3. Ask Claude a grounded question: *"Use cqr_discover to show me what's connected to churn rate."* The tool call, result envelope, and quality metadata should render inline.

### Scoping the agent

`CQR_AGENT_SCOPE` controls which scopes the connected Claude instance can see. Set it to `scope:company:finance` and the agent's DISCOVER results will include finance and its ancestors/descendants but exclude sibling scopes like `scope:company:engineering`. This is how you run multiple parallel Claude instances against the same CQR server with different access boundaries.

## Cursor / VS Code

Cursor supports MCP servers via its own config file. Create `.cursor/mcp.json` in your workspace (or edit the global config) and add the same server entry as above. Cursor picks up the tools and resources automatically on reload.

For VS Code with the Continue or similar MCP-capable extensions, the configuration shape follows the same pattern — `command`, `args`, `cwd`, `env`. Consult your extension's docs for the config file location.

CQR works well as a context source for coding agents: point `CQR_AGENT_SCOPE` at an engineering scope and the agent gains access to your organizational metric definitions, relationship graphs, and certified glossary terms without pulling any of it into the model's training data.

## Custom MCP Clients

Any MCP client that speaks JSON-RPC 2.0 over stdio can connect to CQR. SSE transport is planned for V1.1.

### Tool schemas

Four tools are exposed. Full JSON Schema definitions are available via the standard `tools/list` MCP method.

```
cqr_resolve(entity, scope?, freshness?, reputation?)
cqr_discover(topic, scope?, depth?, direction?)
cqr_certify(entity, status, authority?, evidence?)
cqr_assert(entity, type, description, intent, derived_from,
           scope?, confidence?, relationships?)
```

Required fields for each tool are enforced by the server; missing fields produce a structured error envelope rather than a crash.

### Resource URIs

```
cqr://session        Agent identity, scope, visible scopes, connected adapters
cqr://scopes         Organizational scope hierarchy
cqr://entities       Entity definitions with metadata
cqr://policies       Governance rules per scope
cqr://system_prompt  Agent generation contract (see below)
```

### Agent generation contract

The `cqr://system_prompt` resource is the most important piece of integration for custom agents. It returns a three-component prompt designed to teach an LLM how to use CQR effectively:

1. **Grammar reference** — condensed PEG specification, one primitive per section
2. **Active schema** — entities, scopes, and relationships formatted for LLM consumption (one entity per line, UPPERCASE relationship types, indented scope tree). This format has been empirically validated to outperform JSON, YAML, and free-text representations.
3. **Few-shot examples** — natural-language-to-CQR translation pairs, two or more per primitive

Load `cqr://system_prompt` into your agent's system prompt at startup. Validated accuracy with this contract is 94–97% syntactic and 93–96% semantic across models from 8B to 14B parameters on local hardware.

## System Prompt Guidance

When building a custom agent on top of CQR, the system prompt should teach the model three habits:

```
You have access to a governed context layer via the CQR MCP tools.

Before answering questions that depend on organizational knowledge:
1. DISCOVER before RESOLVE. If the user asks about a concept you have not
   seen in this session, call cqr_discover first to orient yourself in the
   neighborhood. Only call cqr_resolve once you have identified the specific
   canonical entity you want.

2. Check quality metadata on every response. The `quality` envelope tells you
   how fresh the data is, who owns it, and whether it is certified. If
   freshness exceeds your task's tolerance, mention the staleness to the user
   or request confirmation before acting on the value.

3. Respect scope boundaries. If cqr_resolve or cqr_discover returns a
   scope_access error, do not retry against the same scope. Use the error's
   `suggestions` field to pick a visible scope, or tell the user you do not
   have access to the requested domain.

When asserting new context with cqr_assert, populate INTENT with the user's
actual question and DERIVED_FROM with the entities you used to derive the
finding. These fields are mandatory and they are the governance paper trail —
future agents and humans will audit them.
```

Load this snippet alongside `cqr://system_prompt` and the agent will handle CQR idiomatically on the first try.
