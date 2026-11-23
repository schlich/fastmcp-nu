# Stateful tools: Nushell values are immutable, so keep state in SQLite.
#
# `stor` is an in-memory database that lives as long as the server process
# (one stdio session, or every request to one http-nu server). Swap in
# `open notes.db | query db ...` for notes that survive restarts.
#
#   fastmcp-nu run examples/notes.nu

use fastmcp ["attr mcp-tool" "attr mcp-resource"]

export const MCP_SERVER = {name: notes, version: '0.1.0'}

def ensure-table []: nothing -> nothing {
  try { stor create --table-name notes --columns {title: str, body: str} | ignore }
}

# Save a note
@mcp-tool {annotations: {idempotentHint: false}}
export def add-note [
  title: string  # Short title
  body: string   # Note text
]: nothing -> record<id: int, title: string> {
  ensure-table
  stor insert --table-name notes --data-record {title: $title, body: $body} | ignore
  stor open | query db 'select rowid as id, title from notes order by rowid desc limit 1' | first
}

# List saved notes
@mcp-tool {annotations: {readOnlyHint: true}}
export def list-notes [
  --search: string  # Only notes whose title or body contains this text
]: nothing -> table<id: int, title: string> {
  ensure-table
  let pattern = $"%($search | default '')%"
  stor open | query db 'select rowid as id, title from notes where title like ?1 or body like ?1 order by rowid' --params [$pattern]
}

# One note's full text
@mcp-resource 'notes://{id}'
export def note [id: int]: nothing -> string {
  ensure-table
  let rows = (stor open | query db 'select title, body from notes where rowid = ?1' --params [$id])
  if ($rows | is-empty) {
    error make {msg: $"no note with id ($id)"}
  }
  $"# ($rows.0.title)\n\n($rows.0.body)"
}
