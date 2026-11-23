# Fixture server exercising every parameter kind and result shape.

use fastmcp ["attr mcp-tool" "attr mcp-resource" "attr mcp-prompt"]

export const MCP_SERVER = {name: sink, version: '9.9.9', title: 'Kitchen sink'}

# Echo every kind of parameter back
#
# Covers positionals, defaults, rest, flags, switches and converted types.
@mcp-tool echo-all
export def "kitchen sink" [
  name: string                    # Required positional
  count?: int = 2                 # Optional positional with a default
  ...tags: string                 # Rest parameter
  --ratio: float                  # Flag with a value
  --loud (-l)                     # Switch
  --when: datetime                # Converted from an ISO string
  --wait: duration = 1sec         # Converted from "5min"-style strings
  --point: record<x: int, y: int>  # Nested record
]: nothing -> record {
  {name: $name, count: $count, tags: $tags, ratio: $ratio, loud: $loud, when: $when, wait: $wait, point: $point}
}

# Writes to stdout before returning
@mcp-tool
export def noisy []: nothing -> string {
  print 'stray print'
  ^echo 'stray external'
  'clean result'
}

# Returns MCP content blocks directly
@mcp-tool
export def picture [] {
  {content: [{type: image, data: 'iVBORw0KGgo=', mimeType: 'image/png'}]}
}

# Always fails
@mcp-tool {annotations: {destructiveHint: false}}
export def fails [] {
  error make {msg: 'kaboom', help: 'do not call this'}
}

# Runs an external command and returns its output
@mcp-tool
export def shout [word: string]: nothing -> string {
  $word | ^tr '[:lower:]' '[:upper:]'
}

# Four raw bytes
@mcp-resource mem://bytes
export def bytes [] {
  0x[DEADBEEF]
}

# Echo a path from a reserved-expansion template
@mcp-resource {uri: 'file://{+path}', mimeType: 'text/plain'}
export def file-at [path: string] {
  $"path=($path)"
}

# Ask for a code review
@mcp-prompt
export def review [
  code: string                         # Code to review
  lang?: string@[nu nushell python rust]  # Language
] {
  [
    {role: assistant, content: 'Paste the code.'}
    {role: user, content: $"Review this ($lang | default nu) code:\n($code)"}
  ]
}

# Not annotated, so never exposed
export def hidden [] { 'secret' }
