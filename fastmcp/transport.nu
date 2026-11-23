# Transports: wire the pure protocol core to stdio or to http-nu.

use protocol.nu [handle "handle json" error-text PROTOCOL_VERSIONS]

def log [message: string]: nothing -> nothing {
  print --stderr $"[fastmcp-nu] ($message)"
}

def respond-line [server: record, line: string]: nothing -> any {
  if ($line | str trim) == '' {
    return null
  }
  try {
    $line | handle json $server
  } catch {|err|
    log $"failed to handle a message: (error-text $err)"
    null
  }
}

# Write a stream of protocol messages, one per line.
#
# When FASTMCP_OUTPUT_FD is set (the runner's stdout guard), this process's
# stdout is the client's stderr, and each message goes to that descriptor
# through a short-lived `cat` that inherits it. Stray output from tools then
# cannot corrupt the JSON-RPC stream.
#
# Two simpler designs do not work: reopening /dev/fd/N fails because
# Node-based clients connect stdio through sockets, and one long-lived `cat`
# fed by a stream stalls because Nushell buffers a stream piped into an
# external command's stdin.
#
# Keep `if` and `each` first in their blocks, with no `let` before them:
# implicit input only reaches a block's first pipeline.
def write-messages []: any -> nothing {
  if ($env.FASTMCP_OUTPUT_FD? | default '') == '' {
    each {|message| print $message } | ignore
  } else {
    each {|message| $message + "\n" | ^sh -c $"exec cat >&($env.FASTMCP_OUTPUT_FD)" } | ignore
  }
}

# Serve newline-delimited JSON-RPC 2.0 from stdin to stdout.
#
# Run the script with `nu --stdin` and pipe stdin in implicitly: input is
# processed line by line as it arrives, never collected.
export def "serve stdio" [server: record]: any -> nothing {
  lines
  | each {|line| respond-line $server $line }
  | compact
  | write-messages
}

def respond [status: int, body: any, headers: record = {}]: nothing -> any {
  $body | metadata set { merge {'http.response': {status: $status, headers: $headers}} }
}

def json-error [status: int, code: int, message: string]: nothing -> any {
  let body = ({jsonrpc: '2.0', id: null, error: {code: $code, message: $message}} | to json --raw)
  respond $status $body {content-type: 'application/json'}
}

# Browsers send Origin; reject cross-site origins to block DNS rebinding.
def origin-allowed [origin: string, allowed: list<string>]: nothing -> bool {
  if '*' in $allowed or $origin in $allowed {
    return true
  }
  let host = (try { $origin | url parse | get host } catch { '' })
  $host in ['localhost' '127.0.0.1' '::1' '[::1]']
}

def body-text [body: any]: nothing -> string {
  match ($body | describe --detailed | get type) {
    'nothing' => { '' }
    'binary' => { $body | decode utf-8 }
    _ => { $body | into string }
  }
}

def handle-post [server: record, req: record, body: any]: nothing -> any {
  let version = ($req.headers?.'mcp-protocol-version'? | default '')
  let parsed = (try { {value: (body-text $body | from json)} } catch { null })
  if $version != '' and $version not-in $PROTOCOL_VERSIONS {
    json-error 400 -32600 $"Unsupported MCP-Protocol-Version: ($version)"
  } else if $parsed == null {
    json-error 400 -32700 'Parse error'
  } else {
    let response = ($parsed.value | handle $server)
    if $response == null {
      # Only notifications or responses: acknowledge without a body.
      respond 202 null
    } else {
      respond 200 ($response | to json --raw) {content-type: 'application/json'}
    }
  }
}

# One if/else chain on purpose: `return` drops pipeline metadata, which is
# where http-nu reads the status and headers.
def handle-http [server: record, mount: string, allowed: list<string>, req: record, body: any]: nothing -> any {
  let origin = ($req.headers?.origin? | default '')
  if $req.path != $mount {
    respond 404 'Not Found' {content-type: 'text/plain'}
  } else if $origin != '' and not (origin-allowed $origin $allowed) {
    json-error 403 -32600 $"Forbidden origin: ($origin)"
  } else if $req.method == 'POST' {
    handle-post $server $req $body
  } else {
    # Stateless: no session to DELETE and no server-to-client SSE stream.
    respond 405 'Method Not Allowed' {allow: 'POST', content-type: 'text/plain'}
  }
}

# Build an http-nu handler closure serving MCP Streamable HTTP.
#
# Make it the last expression of an http-nu script:
#   fastmcp serve http $server --path /mcp
export def "serve http" [
  server: record
  --path: string = '/mcp'          # Endpoint path
  --allow-origin: list<string> = []  # Extra allowed Origin values ('*' allows any)
]: nothing -> closure {
  let mount = $path
  let allowed = $allow_origin
  {|req|
    let body = $in
    try {
      handle-http $server $mount $allowed $req $body
    } catch {|err|
      json-error 500 -32603 (error-text $err)
    }
  }
}
