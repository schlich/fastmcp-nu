# Protocol core: JSON-RPC 2.0 + MCP routing as pure functions.
#
# Nothing in this module prints, reads stdin or touches the network, so any
# transport can drive it and tests can call it directly. A server is a
# manifest (see reflect.nu) plus an `invoke` closure,
# {|command: string, args: record| ...}, that runs a command by name.
# Entries may instead carry their own `handler` closure, {|args| ...}.

use shape.nu *

# Protocol revisions this server speaks, newest first.
export const PROTOCOL_VERSIONS = ['2025-11-25' '2025-06-18' '2025-03-26' '2024-11-05']

const PARSE_ERROR = -32700
const INVALID_REQUEST = -32600
const METHOD_NOT_FOUND = -32601
const INVALID_PARAMS = -32602
const INTERNAL_ERROR = -32603
const RESOURCE_NOT_FOUND = -32002

# Attach an invoke closure to a manifest, making it a server.
export def server [
  invoke?: closure  # {|command, args| ...} that runs a command by name
]: record -> record {
  let manifest = $in
  let base = {info: {name: 'fastmcp-nu', version: '0.1.0'}, instructions: null, tools: [], resources: [], templates: [], prompts: []}
  # merge, not upsert: upsert would call a closure value to compute the field.
  $base | merge $manifest | merge {invoke: $invoke}
}

def ok [result: any]: nothing -> record {
  {result: $result}
}

def fail [code: int, message: string, data?: any]: nothing -> record {
  let error = {code: $code, message: $message}
  {error: (if $data == null { $error } else { $error | insert data $data })}
}

def rpc-response [id: any, outcome: record]: nothing -> record {
  if 'error' in $outcome {
    {jsonrpc: '2.0', id: $id, error: $outcome.error}
  } else {
    {jsonrpc: '2.0', id: $id, result: $outcome.result}
  }
}

def type-of []: any -> string {
  $in | describe --detailed | get type
}

# Flatten a caught Nushell error into one readable message.
export def error-text [err: record]: nothing -> string {
  let details = ($err.details? | default {})
  let labels = ($details.labels? | default [] | each {|l| $l.text? } | compact | where $it != '')
  let help = ($details.help? | default '')
  [$err.msg? ...$labels (if $help != '' { $"help: ($help)" })]
  | compact
  | where $it != ''
  | uniq
  | str join "\n"
}

# Run an entry's command and fully collect its output.
def invoke-entry [server: record, entry: record, args: record]: nothing -> any {
  if ($entry.handler? | type-of) == 'closure' {
    do $entry.handler $args | collect
  } else if ($server.invoke? | type-of) == 'closure' {
    do $server.invoke $entry.command $args | collect
  } else {
    error make {msg: $"no handler for '($entry.command? | default ($entry.spec.name? | default '?'))'"}
  }
}

# Validate and convert call arguments against a command's parameters.
# Returns {args, errors}; only known, conforming arguments are kept.
export def prepare-args [params: list, args: record]: nothing -> record {
  mut out = {}
  mut errors = []
  let known = ($params | each {|p| $p.name })
  for key in ($args | columns) {
    if $key not-in $known {
      let expected = (if ($known | is-empty) { 'none' } else { $known | str join ', ' })
      $errors = ($errors | append $"unknown argument '($key)'; expected one of: ($expected)")
    }
  }
  for p in $params {
    # Fill declared defaults here: Nushell keeps a flag's default when passed
    # null, but an optional positional would take the null instead.
    let given = ($args | get --optional $p.name)
    let value = (if $given == null { $p.default? } else { $given })
    if $value == null {
      if not $p.optional {
        $errors = ($errors | append $"missing required argument '($p.name)'")
      }
      continue
    }
    let t = (if $p.kind == 'rest' { {kind: list, items: $p.type} } else { $p.type })
    let r = ($value | conform $t $p.name)
    $errors = ($errors | append $r.errors)
    let allowed = ($p.enum? | default [])
    if ($r.errors | is-empty) and ($allowed | is-not-empty) {
      let values = (if $p.kind == 'rest' { $r.value } else { [$r.value] })
      let bad = ($values | where {|v| $v not-in $allowed })
      if ($bad | is-not-empty) {
        $errors = ($errors | append $"($p.name): ($bad | each { to nuon } | str join ', ') is not one of ($allowed | each { to nuon } | str join ', ')")
      }
    }
    $out = ($out | insert $p.name $r.value)
  }
  {args: $out, errors: $errors}
}

def initialize [server: record, params: record]: nothing -> record {
  let requested = $params.protocolVersion?
  let version = (if $requested in $PROTOCOL_VERSIONS { $requested } else { $PROTOCOL_VERSIONS.0 })
  mut caps = {}
  if ($server.tools | is-not-empty) { $caps = ($caps | insert tools {listChanged: false}) }
  if ($server.resources | is-not-empty) or ($server.templates | is-not-empty) {
    $caps = ($caps | insert resources {subscribe: false, listChanged: false})
  }
  if ($server.prompts | is-not-empty) { $caps = ($caps | insert prompts {listChanged: false}) }
  if ($server.prompts | is-not-empty) or ($server.templates | is-not-empty) {
    $caps = ($caps | insert completions {})
  }
  let result = {protocolVersion: $version, capabilities: $caps, serverInfo: $server.info}
  ok (if ($server.instructions? | default '') == '' { $result } else { $result | insert instructions $server.instructions })
}

# Is this value already an MCP CallToolResult? ({content: [{type: ...}]})
def is-tool-result []: any -> bool {
  let v = $in
  if ($v | type-of) != 'record' or ($v.content? | type-of) != 'list' {
    return false
  }
  $v.content | all {|c| ($c | type-of) == 'record' and 'type' in $c }
}

def tool-result [tool: record, value: any]: nothing -> record {
  if ($value | is-tool-result) {
    return ({isError: false} | merge $value)
  }
  let kind = ($value | type-of)
  let content = match $kind {
    'nothing' => { [] }
    'string' => { [{type: text, text: $value}] }
    'binary' => { [{type: text, text: ($value | encode base64)}] }
    _ => { [{type: text, text: ($value | to json --raw)}] }
  }
  let result = {content: $content, isError: false}
  if ($tool.wrap? | default false) {
    $result | insert structuredContent {result: $value}
  } else if $kind == 'record' {
    $result | insert structuredContent $value
  } else {
    $result
  }
}

def tool-error [message: string]: nothing -> record {
  {content: [{type: text, text: $message}], isError: true}
}

def call-tool [server: record, params: record]: nothing -> record {
  let name = $params.name?
  let tool = ($server.tools | where {|t| $t.spec.name == $name } | get 0?)
  if $tool == null {
    return (fail $INVALID_PARAMS $"Unknown tool: ($name)")
  }
  let args = ($params.arguments? | default {})
  if ($args | type-of) != 'record' {
    return (fail $INVALID_PARAMS 'tools/call arguments must be an object')
  }
  let prepared = (prepare-args $tool.params $args)
  if ($prepared.errors | is-not-empty) {
    return (ok (tool-error $"Invalid arguments for ($name):\n($prepared.errors | str join "\n")"))
  }
  try {
    let value = (invoke-entry $server $tool $prepared.args)
    ok (tool-result $tool $value)
  } catch {|err|
    ok (tool-error (error-text $err))
  }
}

def resource-contents [uri: string, mime: any, value: any]: nothing -> list<record> {
  if ($value | type-of) == 'record' and ($value.contents? | type-of) == 'list' {
    return $value.contents
  }
  match ($value | type-of) {
    'string' => { [{uri: $uri, mimeType: ($mime | default 'text/plain'), text: $value}] }
    'binary' => { [{uri: $uri, mimeType: ($mime | default 'application/octet-stream'), blob: ($value | encode base64)}] }
    'nothing' => { [{uri: $uri, mimeType: ($mime | default 'text/plain'), text: ''}] }
    _ => { [{uri: $uri, mimeType: ($mime | default 'application/json'), text: ($value | to json --indent 2)}] }
  }
}

# Find the resource or template matching a URI; returns {entry, args} or null.
export def match-resource [server: record, uri: string]: nothing -> any {
  let static = ($server.resources | where {|r| $r.spec.uri == $uri } | get 0?)
  if $static != null {
    return {entry: $static, args: {}}
  }
  for tpl in $server.templates {
    let found = ($uri | parse --regex $tpl.regex)
    if ($found | is-not-empty) {
      let row = $found.0
      let args = (
        $tpl.vars | enumerate | reduce --fold {} {|v, acc|
          $acc | insert $v.item ($row | get $"v($v.index)" | url decode)
        }
      )
      return {entry: $tpl, args: $args}
    }
  }
  null
}

def read-resource [server: record, params: record]: nothing -> record {
  let uri = $params.uri?
  if ($uri | type-of) != 'string' {
    return (fail $INVALID_PARAMS 'resources/read needs a uri')
  }
  let found = (match-resource $server $uri)
  if $found == null {
    return (fail $RESOURCE_NOT_FOUND $"Resource not found: ($uri)" {uri: $uri})
  }
  let prepared = (prepare-args $found.entry.params $found.args)
  if ($prepared.errors | is-not-empty) {
    return (fail $INVALID_PARAMS ($prepared.errors | str join '; ') {uri: $uri})
  }
  try {
    let value = (invoke-entry $server $found.entry $prepared.args)
    ok {contents: (resource-contents $uri $found.entry.spec.mimeType? $value)}
  } catch {|err|
    fail $INTERNAL_ERROR (error-text $err) {uri: $uri}
  }
}

def prompt-message [m: any]: nothing -> record {
  if ($m | type-of) == 'string' {
    return {role: user, content: {type: text, text: $m}}
  }
  let content = $m.content?
  {
    role: ($m.role? | default user)
    content: (if ($content | type-of) == 'string' { {type: text, text: $content} } else { $content })
  }
}

def prompt-result [prompt: record, value: any]: nothing -> record {
  let kind = ($value | type-of)
  let messages = (
    if $kind == 'record' and 'messages' in $value {
      $value.messages | each {|m| prompt-message $m }
    } else if $kind == 'list' {
      $value | each {|m| prompt-message $m }
    } else if $kind == 'record' {
      [(prompt-message $value)]
    } else {
      [(prompt-message ($value | into string))]
    }
  )
  let description = (if $kind == 'record' { $value.description? } else { null } | default $prompt.spec.description?)
  if $description == null { {messages: $messages} } else { {description: $description, messages: $messages} }
}

def get-prompt [server: record, params: record]: nothing -> record {
  let name = $params.name?
  let prompt = ($server.prompts | where {|p| $p.spec.name == $name } | get 0?)
  if $prompt == null {
    return (fail $INVALID_PARAMS $"Unknown prompt: ($name)")
  }
  let args = ($params.arguments? | default {})
  if ($args | type-of) != 'record' {
    return (fail $INVALID_PARAMS 'prompts/get arguments must be an object')
  }
  let prepared = (prepare-args $prompt.params $args)
  if ($prepared.errors | is-not-empty) {
    return (fail $INVALID_PARAMS $"Invalid arguments for prompt ($name): ($prepared.errors | str join '; ')")
  }
  try {
    ok (prompt-result $prompt (invoke-entry $server $prompt $prepared.args))
  } catch {|err|
    fail $INTERNAL_ERROR (error-text $err)
  }
}

# completion/complete: offer enum values (from `string@[a b c]` completions)
# for prompt arguments and resource template variables.
def complete-argument [server: record, params: record]: nothing -> record {
  let ref = ($params.ref? | default {})
  let arg = ($params.argument? | default {})
  let entry = match $ref.type? {
    'ref/prompt' => { $server.prompts | where {|p| $p.spec.name == $ref.name? } | get 0? }
    'ref/resource' => { $server.templates | where {|t| $t.spec.uriTemplate == $ref.uri? } | get 0? }
    _ => { null }
  }
  let param = (if $entry == null { null } else { $entry.params | where {|p| $p.name == $arg.name? } | get 0? })
  let prefix = ($arg.value? | default '' | into string)
  let values = (
    $param.enum? | default []
    | each {|v| $v | into string }
    | where {|v| $v | str starts-with --ignore-case $prefix }
  )
  ok {completion: {values: ($values | first 100), total: ($values | length), hasMore: (($values | length) > 100)}}
}

def route [server: record, method: string, params: record]: nothing -> record {
  match $method {
    'initialize' => { initialize $server $params }
    'ping' => { ok {} }
    'tools/list' => { ok {tools: ($server.tools | each {|t| $t.spec })} }
    'tools/call' => { call-tool $server $params }
    'resources/list' => { ok {resources: ($server.resources | each {|r| $r.spec })} }
    'resources/templates/list' => { ok {resourceTemplates: ($server.templates | each {|t| $t.spec })} }
    'resources/read' => { read-resource $server $params }
    'prompts/list' => { ok {prompts: ($server.prompts | each {|p| $p.spec })} }
    'prompts/get' => { get-prompt $server $params }
    'completion/complete' => { complete-argument $server $params }
    _ => { fail $METHOD_NOT_FOUND $"Method not found: ($method)" }
  }
}

def handle-one [server: record, msg: any]: nothing -> any {
  if ($msg | type-of) != 'record' {
    return (rpc-response null (fail $INVALID_REQUEST 'Invalid Request: expected a JSON object'))
  }
  let id = $msg.id?
  if $msg.jsonrpc? != '2.0' {
    return (rpc-response $id (fail $INVALID_REQUEST 'Invalid Request: jsonrpc must be "2.0"'))
  }
  let method = $msg.method?
  if $method == null {
    # A response to a server-initiated request; this server sends none.
    return null
  }
  if ($method | type-of) != 'string' {
    return (rpc-response $id (fail $INVALID_REQUEST 'Invalid Request: method must be a string'))
  }
  if 'id' not-in $msg {
    # Notifications (initialized, cancelled, ...) never get a response.
    return null
  }
  let params = ($msg.params? | default {})
  if ($params | type-of) != 'record' {
    return (rpc-response $id (fail $INVALID_PARAMS 'params must be an object'))
  }
  let outcome = (try { route $server $method $params } catch {|err| fail $INTERNAL_ERROR (error-text $err) })
  rpc-response $id $outcome
}

# Handle one decoded JSON-RPC message (or a batch list). Returns the
# response record (or list), or null when nothing should be sent.
export def handle [server: record]: any -> any {
  let msg = $in
  if ($msg | type-of) == 'list' {
    if ($msg | is-empty) {
      return (rpc-response null (fail $INVALID_REQUEST 'Invalid Request: empty batch'))
    }
    let responses = ($msg | each {|m| handle-one $server $m } | compact)
    if ($responses | is-empty) { null } else { $responses }
  } else {
    handle-one $server $msg
  }
}

# Handle one line of JSON text. Returns the compact JSON response, or null.
export def "handle json" [server: record]: string -> any {
  let text = $in
  let parsed = (try { {value: ($text | from json)} } catch { null })
  let response = (
    if $parsed == null {
      rpc-response null (fail $PARSE_ERROR 'Parse error')
    } else {
      $parsed.value | handle $server
    }
  )
  if $response == null { null } else { $response | to json --raw }
}
