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

### Using the `cqr` startup script (recommended)

The repo ships a small wrapper at `scripts/cqr` intended to be copied to
`~/bin/cqr` (or anywhere on your `PATH`). It cleans up any stale BEAM
processes with SIGTERM first (so persistent-mode Grafeo can checkpoint to
disk), falls back to SIGKILL only if the process does not exit, and then
launches the server with a stable `--sname cqr` node name. With the script
installed, the Claude Desktop config collapses to:

```json
{
  "mcpServers": {
    "cqr": {
      "command": "/Users/you/bin/cqr",
      "env": {
        "CQR_AGENT_ID": "twin:your_name",
        "CQR_AGENT_SCOPE": "scope:company"
      }
    }
  }
}
```

Any flags the script receives are forwarded to `mix run --no-halt -- "$@"`,
so `"args": ["--persist"]` enables durable storage and `"args": ["--persist",
"--reset"]` wipes-and-reseeds on the next launch -- no need to change the
`command` shape.

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

Persistent mode opens (or creates) `~/.cqr/grafeo.grafeo` and does **not** seed the sample dataset. Supply a path after `--persist` to choose a custom location, or append `--reset` to wipe the database and re-seed the sample data as a factory reset.

### Verification

Once Claude Desktop reconnects:

1. Open the tool picker. Thirteen tools appear: `cqr_resolve`, `cqr_discover`, `cqr_assert`, `cqr_assert_batch`, `cqr_certify`, `cqr_signal`, `cqr_update`, `cqr_trace`, `cqr_refresh`, `cqr_compare`, `cqr_hypothesize`, `cqr_anchor`, `cqr_awareness`.
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

Thirteen tools are exposed. Full JSON Schema definitions are available via
the standard `tools/list` MCP method; the summary below mirrors what
`lib/cqr_mcp/tools.ex` declares today. Fields marked `(required)` are
enforced by the server -- missing or empty values produce a structured
error envelope (JSON-RPC code `-32602`), not a crash.

#### `cqr_resolve`

Canonical entity retrieval with quality metadata.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity` | string | yes | Entity reference, e.g. `entity:finance:arr` |
| `scope` | string | no | Scope constraint, e.g. `scope:company:finance` |
| `freshness` | string | no | Max age, e.g. `24h`, `7d`, `30m` |
| `reputation` | number | no | Minimum reputation `0.0 - 1.0` |

#### `cqr_discover`

Neighborhood scan combining graph traversal, BM25, and HNSW vector search.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `topic` | string | yes | Either `entity:ns:name` or a plain free-text search term (no quotes) |
| `scope` | string | no | One scope, or comma-separated scopes (`scope:product,scope:finance`) |
| `depth` | integer | no | Traversal depth, default `2` |
| `direction` | string | no | `outbound`, `inbound`, or `both` (default) |

#### `cqr_assert`

Agent write with a mandatory `INTENT` and `DERIVED_FROM` paper trail.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity` | string | yes | New entity's semantic address |
| `type` | string | yes | `metric`, `definition`, `policy`, `derived_metric`, `observation`, or `recommendation` |
| `description` | string | yes | Human-readable description |
| `intent` | string | yes | Why the agent is asserting this (task context) |
| `derived_from` | string | yes | Comma-separated `entity:ns:name` source refs |
| `scope` | string | no | Target scope; defaults to agent's active scope |
| `confidence` | number | no | Self-assessed confidence `0.0 - 1.0`, default `0.5` |
| `relationships` | string | no | Comma-separated shorthand `REL:entity:ns:name:strength` (valid `REL` values: `CORRELATES_WITH`, `CONTRIBUTES_TO`, `DEPENDS_ON`, `CAUSES`, `PART_OF`) |

#### `cqr_certify`

Governance lifecycle: `proposed -> under_review -> certified -> (contested -> under_review) -> superseded -> proposed`. `contested` is entered automatically when an UPDATE proposes a `redefinition` or `reclassification` on a certified entity; the only transition out of `contested` is back to `under_review`. `superseded` is non-terminal — `CERTIFY STATUS proposed` puts a superseded entity back into the forward lifecycle.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity` | string | yes | Entity to certify |
| `status` | string | yes | Target status: `proposed`, `under_review`, `certified`, `contested`, or `superseded` |
| `authority` | string | no | Bare identifier (`cfo`) or quoted free-form (`"agent:twin:michael"`) |
| `evidence` | string | no | Supporting rationale |

#### `cqr_update`

Governed content evolution. Writes a `VersionRecord` audit node (linked by `PREVIOUS_VERSION` on apply, or `PENDING_UPDATE` on contest) capturing the prior state. The governance matrix (see `docs/cqr-protocol-specification.md`) decides whether the change applies, transitions the entity to `contested` for pending review, or is blocked.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity` | string | yes | Entity to update (`entity:namespace:name`) |
| `change_type` | string | yes | One of `correction`, `refresh`, `scope_change`, `redefinition`, `reclassification` |
| `description` | string | no | New description text |
| `type` | string | no | New entity type identifier |
| `evidence` | string | no | Rationale for the change; recorded on the VersionRecord |
| `confidence` | number | no | New confidence score `0.0 - 1.0` |

#### `cqr_trace`

Walk the provenance chain of an entity.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity` | string | yes | Entity to trace |
| `depth` | integer | no | How many hops to follow `DERIVED_FROM`, default `1` |
| `time_window` | string | no | Filter events to a window, e.g. `24h`, `7d` |

#### `cqr_signal`

Write a reputation assessment; certification status is preserved.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `entity` | string | yes | Entity to signal |
| `score` | number | yes | New reputation score `0.0 - 1.0` |
| `evidence` | string | yes | Rationale for the change |

#### `cqr_refresh`

Staleness scan. `CHECK` mode is the only mode shipped today.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `threshold` | string | no | Staleness threshold, default `24h` |
| `scope` | string | no | Scope to check; defaults to the agent's full visible set |

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

When a user asks "how did this come to exist?" or "why should I trust this?",
call cqr_trace on the entity. The trace returns the assertion record, full
certification history, signal history, and the derived-from chain — enough
to explain provenance end to end.

When you observe that a source's data quality has changed — a pipeline just
refreshed, a source went stale, a validation check failed — call cqr_signal
with a new reputation score and a short evidence string. Signals preserve
certification status; they only move the reputation dial. Downstream agents
(and downstream humans reading TRACE) will see the update.

Before answering high-stakes questions, consider cqr_refresh as a cheap
pre-flight check. It returns any stale context in your visible scope, sorted
most-stale-first. If the answer depends on an entity in that list, mention
the staleness or call cqr_resolve with a freshness constraint.
```

Load this snippet alongside `cqr://system_prompt` and the agent will handle CQR idiomatically on the first try.
