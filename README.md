# fastmcp-nu

A pure-Nushell take on [FastMCP](https://gofastmcp.com): write ordinary
Nushell commands, mark them with an attribute, and serve them as a
[Model Context Protocol](https://modelcontextprotocol.io) server. Nushell
already has FastMCP's two hardest pieces built in: custom attributes stand in
for decorators, and `scope commands` reflects each signature, its types and
its comments, which become the JSON Schema.

```nu
use fastmcp ["attr mcp-tool"]

# Get the current weather for a city
@mcp-tool
export def get-weather [
  city: string                      # City name (e.g. "St. Louis")
  units?: string@[metric imperial]  # "metric" or "imperial"
]: nothing -> record {
  {city: $city, units: ($units | default imperial), temp: 72}
}
```

```
bin/fastmcp-nu run server.nu                 # stdio
bin/fastmcp-nu run server.nu --http :3001    # Streamable HTTP via http-nu
```

The protocol core is plain Nushell with no dependencies. stdio needs only
`nu`; HTTP additionally needs [http-nu](https://github.com/cablehead/http-nu).

## Requirements

- Nushell 0.113 or newer (developed on 0.116.1; http-nu 0.17.2 embeds 0.113.1).
- Optional: `http-nu` for `--http`, and `node` for the streaming test.

## Quick start

Try the bundled example:

```
bin/fastmcp-nu inspect examples/weather.nu   # what clients will see
bin/fastmcp-nu run examples/weather.nu       # serve it over stdio
```

Register it with an MCP client. For Claude Code:

```
claude mcp add weather -- /path/to/fastmcp-nu/bin/fastmcp-nu run /path/to/fastmcp-nu/examples/weather.nu
```

For clients configured with JSON (Claude Desktop, Cursor, and others):

```json
{
  "mcpServers": {
    "weather": {
      "command": "/path/to/fastmcp-nu/bin/fastmcp-nu",
      "args": ["run", "/path/to/fastmcp-nu/examples/weather.nu"]
    }
  }
}
```

Or explore it with the official MCP Inspector:

```
npx @modelcontextprotocol/inspector bin/fastmcp-nu run examples/weather.nu
```

## Writing a server

A server is a Nushell module. Import the attributes you use from `fastmcp`
(the runner puts it on the library path) and export annotated commands.

### Tools: `@mcp-tool`

| Nushell                                    | MCP                                               |
| ------------------------------------------ | ------------------------------------------------- |
| command name (`get weather` → `get_weather`) | tool `name`                                     |
| leading `#` comment (plus its extra lines) | `description`                                     |
| `# comment` after a parameter              | that property's `description`                     |
| required positional                        | listed in `required`                              |
| `x?: T`, `--flag: T`, `--switch`, `...rest` | optional properties                              |
| `= default`                                | `default` (and applied when the argument is absent) |
| `string@[a b c]`                           | `enum: [a, b, c]`                                 |
| `-> record<...>`                           | `outputSchema`; the record is `structuredContent` |
| `-> list<...>`, `-> int`, ...              | `outputSchema` wrapping `{result: ...}`           |

Parameter types map to JSON Schema as follows: `string`, `path`, `glob` →
string; `int` → integer; `float`, `number` → number; `bool` → boolean;
`list<T>` → array; `record<a: T>` → object with every field required;
`table<...>` → array of objects; `oneof<A, B>` → `anyOf`; `datetime` → ISO
8601 string; `duration` (`"5min"`), `filesize` (`"10KB"`) → string;
`binary` → base64 string. Incoming arguments are converted to these types,
and numbers or booleans sent as strings are accepted, so a model that sends
`"3"` for an `int` still succeeds.

The attribute takes an optional string (the tool name) or a record:

```nu
@mcp-tool {name: weather, title: 'Current weather', annotations: {readOnlyHint: true}}
```

Return any value. A string becomes text content. A record also becomes
`structuredContent`. Any other value is sent as compact JSON text. To send
images or other content blocks, return a complete result:
`{content: [{type: image, data: $b64, mimeType: 'image/png'}]}`.

If a tool raises an error (`error make`, a failing external, a type error),
the client gets `isError: true` with the error's message and help text, not
a JSON-RPC protocol error, so the model can read it and retry. Arguments are
validated before the call: missing, unknown, mistyped or out-of-enum
arguments are reported the same way.

### Resources: `@mcp-resource`

```nu
# Supported cities
@mcp-resource {uri: 'weather://cities', mimeType: 'application/json'}
export def cities [] { [{city: Lisbon}] }

# A report for one city; {city} fills the parameter
@mcp-resource 'weather://report/{city}'
export def report [city: string]: nothing -> string { ... }
```

A URI with `{var}` placeholders becomes a resource template (`{+var}` also
matches `/`). Strings are served as `text/plain`, binary as a base64 `blob`,
anything else as JSON, unless `mimeType` says otherwise.

### Prompts: `@mcp-prompt`

```nu
# Plan an outfit for the weather
@mcp-prompt
export def outfit [city: string, style?: string@[casual formal]] {
  $"Check the weather in ($city), then suggest a ($style | default casual) outfit."
}
```

Parameters become prompt arguments. Return a string (one user message), a
list of strings or `{role, content}` records, or `{messages: [...]}`.
`string@[...]` lists also drive `completion/complete` for prompt arguments
and template variables.

### Server metadata

Export an `MCP_SERVER` constant to set `serverInfo` and `instructions`; the
name defaults to the file name.

```nu
export const MCP_SERVER = {name: weather, version: '0.1.0', instructions: 'Weather lookups.'}
```

## How it works

Four layers, each in its own file under `fastmcp/`:

| Layer                     | File                          | Job |
| ------------------------- | ----------------------------- | --- |
| Authoring & discovery     | `mod.nu`, `reflect.nu`        | `attr mcp-*` aliases; `discover` turns `scope commands` into a manifest |
| Schema reflection         | `shape.nu`                    | parse `syntax_shape` strings; JSON Schema; argument conversion |
| Protocol core             | `protocol.nu`                 | pure JSON-RPC 2.0 + MCP router: `handle`, `handle json` |
| Transports                | `transport.nu`                | `serve stdio`; `serve http` returns an http-nu handler |

The attributes are aliases of `echo`. An attribute must be a command that
can run at parse time, and Nushell only allows builtins there, which rules
out a custom `def`.

### Dynamic dispatch: bootstrap codegen

Nushell parses statically, so `tools/call` cannot call a command whose name
arrives in a runtime string. `fastmcp-nu run` therefore works in two passes:

1. A child `nu` imports the module and runs `fastmcp discover`, producing a
   manifest (schemas plus parameter metadata) as plain data.
2. `bootstrap.nu` generates a script that embeds that manifest and a
   dispatcher with one `match` arm per command, such as
   `"get-weather" => { get-weather ($args."city"?) ($args."units"?) }`. The
   runner caches the script (content-addressed, under `$nu.cache-dir`) and
   `exec`s `nu --stdin` (or `http-nu`) on it.

Every call then runs inside that one `nu` process, with no new interpreter
per call. `fastmcp-nu build` prints the generated script so you can read it.

### Closure registry

For servers built in-process without the runner, register closures
directly. They go through the same protocol core:

```nu
use fastmcp

def calc [] {
  fastmcp server new calc
  | fastmcp add tool add {|args| $args.a + $args.b } -d 'Add two numbers' -p {a: int, b: int}
}

# serve stdio must be the first pipeline in main: Nushell passes a command's
# input (here, stdin) implicitly only to the first pipeline of its body.
def main [] {
  fastmcp serve stdio (calc)
}
```

Run it with `nu -n --stdin -I /path/to/fastmcp-nu calc.nu`; the include path
must be absolute. `examples/calc.nu` is a complete version.

### stdio and the stdout guard

MCP over stdio is newline-delimited JSON-RPC on stdout, so any stray
output corrupts the stream: a `print` in a tool, or an external command
that is not the tool's last expression. By default the runner starts the
server under `sh -c 'exec 3>&1 1>&2; ...'`. The real stdout is kept on fd
3 and is written only by the transport (one short `cat >&3` per message),
while everything else a tool prints goes to stderr, which clients log.
`--no-guard` turns this off.

Input is processed with `lines | each` as it arrives, never collected, so
the server answers each request without waiting for EOF.

### Streamable HTTP via http-nu

`--http ADDR` generates a script whose value is an http-nu handler closure
and `exec`s `http-nu ADDR` on it. It serves `POST /mcp` (or `--path`) with
`application/json` responses, answers notification-only posts with `202`,
and returns `405` for `GET` and `DELETE`, since it is stateless with no
sessions and no server-initiated SSE stream. It validates
`MCP-Protocol-Version` and rejects cross-site `Origin` headers, to block DNS
rebinding, unless they are allowed with `--allow-origin`.

## Gotchas

- **Return, don't print.** Tools return values. Use `print --stderr` for
  logs. The stdout guard catches mistakes, but other transports have no
  guard.
- **State lives outside values.** Nushell data is immutable, so keep
  state in SQLite. `stor` (in-memory) lasts as long as the server process,
  and `open file.db | query db` survives restarts. See `examples/notes.nu`.
- **Flags vs positionals.** Both work; argument names are the Nushell
  parameter names (`--max-results` is the property `max-results`).
- **Optional positional defaults.** Nushell gives a positional the null it
  is passed rather than its default, so the core fills declared defaults
  before the call.

## Tests

```
nu tests/run.nu            # everything
nu tests/run.nu protocol   # files matching "protocol"
```

The suite covers shape parsing, discovery, the protocol core (through the
closure registry), codegen, stdio end to end (with and without the guard,
plus a Node client that keeps stdin open), and HTTP through http-nu. The
HTTP and streaming tests skip themselves when `http-nu` or `node` is
missing.
