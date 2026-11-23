# Authoring & discovery: turn commands annotated with @mcp-tool,
# @mcp-resource and @mcp-prompt into an MCP server manifest.
#
# A manifest is plain data (it round-trips through NUON), so the codegen
# runner can compute it once and embed it in the generated server script:
#
#   {
#     info: {name, version, title?}
#     instructions: string?
#     tools: [{spec, command, params, wrap}]
#     resources: [{spec, command, params}]
#     templates: [{spec, command, params, regex, vars}]
#     prompts: [{spec, command, params}]
#   }
#
# `spec` is exactly what the MCP list methods return; the other fields are
# what the protocol core needs to validate arguments and dispatch calls.

use shape.nu *

const ATTRS = ['mcp-tool' 'mcp-resource' 'mcp-prompt']

# Normalise an attribute's value to an options record.
# `@mcp-tool` gives {}, `@mcp-tool "name"` gives {<primary>: "name"}.
def attr-options [cmd: record, attr: string, primary: string]: nothing -> any {
  let found = ($cmd.attributes? | default [] | where name == $attr)
  if ($found | is-empty) {
    return null
  }
  let value = $found.0.value
  if ($value | is-empty) {
    return {}
  }
  match ($value | describe --detailed | get type) {
    'record' => { $value }
    'string' => { {} | insert $primary $value }
    _ => {
      error make {msg: $"@($attr) on '($cmd.name)' takes a record or a string, got ($value | describe)"}
    }
  }
}

def is-jsonable []: any -> bool {
  ($in | describe --detailed | get type) in ['string' 'int' 'float' 'bool' 'list' 'record']
}

def command-description [cmd: record]: nothing -> string {
  [$cmd.description? $cmd.extra_description?]
  | compact
  | where $it != ''
  | str join "\n\n"
}

def mcp-name [command: string]: nothing -> string {
  $command | str replace --all ' ' '_'
}

def signature-rows [cmd: record]: nothing -> list<record> {
  $cmd.signatures | values | get 0? | default []
}

# Parameters of a command, in signature order.
export def params-of [cmd: record]: nothing -> list<record> {
  signature-rows $cmd
  | where {|p| $p.parameter_type in ['positional' 'named' 'switch' 'rest'] and $p.parameter_name != 'help' }
  | each {|p|
    let kind = $p.parameter_type
    {
      name: $p.parameter_name
      kind: $kind
      optional: ($p.is_optional or $kind in ['switch' 'rest'])
      type: (if $kind == 'switch' { {kind: bool} } else { parse-shape $p.syntax_shape })
      description: ($p.description | default '')
      default: $p.parameter_default
      enum: (if ($p.completion | describe --detailed | get type) == 'list' { $p.completion } else { null })
    }
  }
}

# JSON Schema for one parameter.
export def param-schema [p: record]: nothing -> record {
  let base = (json-schema $p.type)
  mut s = (if $p.kind == 'rest' { {type: array, items: $base} } else { $base })
  if $p.enum? != null {
    $s = (if $p.kind == 'rest' { $s | upsert items.enum $p.enum } else { $s | upsert enum $p.enum })
  }
  if ($p.description? | default '') != '' {
    $s = ($s | upsert description $p.description)
  }
  if $p.kind == 'switch' {
    $s = ($s | upsert default false)
  } else if $p.default? != null and ($p.default | is-jsonable) {
    $s = ($s | upsert default $p.default)
  }
  $s
}

# JSON Schema for a command's whole argument object.
export def input-schema [params: list]: nothing -> record {
  let props = ($params | reduce --fold {} {|p, acc| $acc | insert $p.name (param-schema $p) })
  let required = ($params | where {|p| not $p.optional } | each {|p| $p.name })
  if ($required | is-empty) {
    {type: object, properties: $props}
  } else {
    {type: object, properties: $props, required: $required}
  }
}

# outputSchema from a declared output type. Records map directly; other
# structured types are wrapped as {result: ...}, as structuredContent must be
# an object. Unannotated, string and binary outputs get no schema.
export def output-schema [shape: any]: nothing -> record {
  if $shape == null {
    return {schema: null, wrap: false}
  }
  let t = (parse-shape $shape)
  match $t.kind {
    'record' => { {schema: (json-schema $t), wrap: false} }
    'any' | 'nothing' | 'string' | 'binary' | 'closure' | 'glob' | 'path' | 'directory' => { {schema: null, wrap: false} }
    _ => {
      {
        schema: {type: object, properties: {result: (json-schema $t)}, required: [result], x-fastmcp-wrap-result: true}
        wrap: true
      }
    }
  }
}

def with-optional [key: string, value: any]: record -> record {
  if $value == null or $value == '' { $in } else { $in | upsert $key $value }
}

def tool-entry [cmd: record, opts: record]: nothing -> record {
  let params = (params-of $cmd)
  let output_shape = (signature-rows $cmd | where parameter_type == 'output' | get 0?.syntax_shape)
  let out = (output-schema $output_shape)
  let spec = (
    {name: ($opts.name? | default (mcp-name $cmd.name))}
    | with-optional title $opts.title?
    | with-optional description ($opts.description? | default (command-description $cmd))
    | insert inputSchema (input-schema $params)
    | with-optional outputSchema $out.schema
    | with-optional annotations $opts.annotations?
    | with-optional _meta $opts._meta?
  )
  {spec: $spec, command: $cmd.name, params: $params, wrap: $out.wrap}
}

def escape-regex []: string -> string {
  $in | str replace --all --regex '([\\.+*?()|\[\]{}^$])' '\$1'
}

# Compile an RFC 6570 level-2 URI template ({var}, {+var}) to an anchored
# regex with positional named groups v0, v1, ...
export def template-regex [template: string]: nothing -> record {
  let parts = ($template | parse --regex '(?<lit>[^{]*)(?:\{(?<expr>[^}]*)\})?')
  mut regex = '^'
  mut vars = []
  for part in $parts {
    $regex = $regex + ($part.lit | escape-regex)
    let expr = ($part.expr? | default '')
    if $expr != '' {
      let reserved = ($expr | str substring 0..0) in ['+' '#']
      let name = (if $reserved { $expr | str substring 1.. } else { $expr })
      let group = 'v' + ($vars | length | into string)
      $regex = $regex + '(?<' + $group + (if $reserved { '>.+)' } else { '>[^/?#]+)' })
      $vars = ($vars | append $name)
    }
  }
  {regex: ($regex + '$'), vars: $vars}
}

def resource-entry [cmd: record, opts: record]: nothing -> record {
  let uri = $opts.uri?
  if $uri == null {
    error make {msg: $"@mcp-resource on '($cmd.name)' needs a URI, e.g. @mcp-resource \"config://app\""}
  }
  let params = (params-of $cmd)
  let base = (
    {name: ($opts.name? | default (mcp-name $cmd.name))}
    | with-optional title $opts.title?
    | with-optional description ($opts.description? | default (command-description $cmd))
    | with-optional mimeType ($opts.mimeType? | default $opts.mime_type?)
    | with-optional annotations $opts.annotations?
  )
  if ($uri | str contains '{') {
    let tpl = (template-regex $uri)
    let names = ($params | each {|p| $p.name })
    let unknown = ($tpl.vars | where {|v| $v not-in $names })
    if ($unknown | is-not-empty) {
      error make {msg: $"@mcp-resource on '($cmd.name)': template variables ($unknown | str join ', ') are not parameters of the command"}
    }
    let unfilled = ($params | where {|p| not $p.optional and $p.name not-in $tpl.vars } | each {|p| $p.name })
    if ($unfilled | is-not-empty) {
      error make {msg: $"@mcp-resource on '($cmd.name)': required parameters ($unfilled | str join ', ') do not appear in ($uri)"}
    }
    {
      spec: ({uriTemplate: $uri} | merge $base)
      command: $cmd.name
      params: $params
      regex: $tpl.regex
      vars: $tpl.vars
    }
  } else {
    let required = ($params | where {|p| not $p.optional } | each {|p| $p.name })
    if ($required | is-not-empty) {
      error make {msg: $"@mcp-resource on '($cmd.name)': a static URI cannot fill required parameters ($required | str join ', '); use a URI template such as \"($uri)/{($required.0)}\""}
    }
    {spec: ({uri: $uri} | merge $base), command: $cmd.name, params: $params}
  }
}

def prompt-entry [cmd: record, opts: record]: nothing -> record {
  let params = (params-of $cmd)
  let arguments = (
    $params | each {|p|
      {name: $p.name} | with-optional description $p.description | insert required (not $p.optional)
    }
  )
  let spec = (
    {name: ($opts.name? | default (mcp-name $cmd.name))}
    | with-optional title $opts.title?
    | with-optional description ($opts.description? | default (command-description $cmd))
    | insert arguments $arguments
  )
  {spec: $spec, command: $cmd.name, params: $params}
}

def check-unique [entries: list, key: string, what: string]: nothing -> nothing {
  let dupes = ($entries | each {|e| $e.spec | get $key } | uniq --repeated)
  if ($dupes | is-not-empty) {
    error make {msg: $"duplicate ($what) names: ($dupes | str join ', ')"}
  }
}

# Build an MCP manifest from annotated commands.
#
# Reads `scope commands` at the call site unless --commands is given, so
# call it where the server module's commands are in scope.
export def discover [
  --commands: list      # Rows shaped like `scope commands` (defaults to the live scope)
  --info: record = {}   # serverInfo overrides: name, version, title
  --instructions: string  # Instructions returned from initialize
]: nothing -> record {
  let all = (if $commands == null { scope commands } else { $commands })
  let annotated = (
    $all | where {|c| $c.attributes? | default [] | any {|a| $a.name in $ATTRS } }
  )
  # `for`, not `each`: an error raised inside `each` reaches the user wrapped
  # as "Eval block failed with pipeline input", hiding the real message.
  mut tools = []
  mut resources = []
  mut templates = []
  mut prompts = []
  for c in $annotated {
    let tool = (attr-options $c 'mcp-tool' 'name')
    if $tool != null { $tools = ($tools | append (tool-entry $c $tool)) }
    let resource = (attr-options $c 'mcp-resource' 'uri')
    if $resource != null {
      let entry = (resource-entry $c $resource)
      if 'uri' in $entry.spec { $resources = ($resources | append $entry) } else { $templates = ($templates | append $entry) }
    }
    let prompt = (attr-options $c 'mcp-prompt' 'name')
    if $prompt != null { $prompts = ($prompts | append (prompt-entry $c $prompt)) }
  }
  check-unique $tools name 'tool'
  check-unique $prompts name 'prompt'
  check-unique $resources uri 'resource'
  {
    info: ({name: 'fastmcp-nu', version: '0.1.0'} | merge $info)
    instructions: $instructions
    tools: $tools
    resources: $resources
    templates: $templates
    prompts: $prompts
  }
}
