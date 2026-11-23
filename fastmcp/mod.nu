# FastMCP for Nushell: build Model Context Protocol servers from ordinary
# annotated commands.
#
#   use fastmcp ["attr mcp-tool"]
#
#   # Add two numbers
#   @mcp-tool
#   export def add [a: int, b: int]: nothing -> int { $a + $b }
#
# Run the module with `fastmcp-nu run server.nu` (stdio) or
# `fastmcp-nu run server.nu --http :3001` (Streamable HTTP via http-nu).

# Mark a command as an MCP tool.
#
# Bare `@mcp-tool` uses the command's name and comment. Pass a string to
# rename the tool, or a record with any of: name, title, description,
# annotations (readOnlyHint, destructiveHint, idempotentHint, openWorldHint)
# and _meta.
export alias "attr mcp-tool" = echo

# Mark a command as an MCP resource.
#
# Pass the URI as a string, or a record with uri plus any of: name, title,
# description, mimeType, annotations. A URI containing {var} placeholders
# becomes a resource template whose variables fill the command's parameters.
export alias "attr mcp-resource" = echo

# Mark a command as an MCP prompt.
#
# The command's parameters become the prompt's arguments. Return a string
# (one user message), a list of messages, or {messages: [...]}. Pass a
# string to rename the prompt, or a record with name, title, description.
export alias "attr mcp-prompt" = echo

export use reflect.nu [discover]
export use protocol.nu [server handle "handle json" PROTOCOL_VERSIONS]
export use registry.nu ["server new" "add tool" "add resource" "add prompt"]
export use transport.nu ["serve stdio" "serve http"]
export use bootstrap.nu [codegen]
