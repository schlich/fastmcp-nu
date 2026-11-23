# Closure registry: define a server in-process from closures, without the
# codegen runner. Handlers receive the validated arguments as one record.
#
#   use fastmcp
#   def calc [] {
#     fastmcp server new calc
#     | fastmcp add tool add {|args| $args.a + $args.b } -d 'Add two numbers' -p {a: int, b: int}
#   }
#   def main [] { fastmcp serve stdio (calc) }  # run with: nu --stdin -I <lib> calc.nu
#
# Parameters are a record of name -> shape string ("int", "list<string>",
# "string?" for optional) or name -> {type, description, optional, enum, default}.

use shape.nu *
use reflect.nu [input-schema template-regex]

def with-optional [key: string, value: any]: record -> record {
  if $value == null or $value == '' { $in } else { $in | upsert $key $value }
}

def params-from [spec: record]: nothing -> list<record> {
  $spec | transpose name value | each {|row|
    let v = (if ($row.value | describe --detailed | get type) == 'string' { {type: $row.value} } else { $row.value })
    let shape = ($v.type? | default any)
    let suffixed = ($shape | str ends-with '?')
    {
      name: $row.name
      kind: named
      optional: ($v.optional? | default ($suffixed or $v.default? != null))
      type: (parse-shape ($shape | str trim --right --char '?'))
      description: ($v.description? | default '')
      default: $v.default?
      enum: $v.enum?
    }
  }
}

# Start an empty server definition.
export def "server new" [
  name: string
  --version: string = '0.1.0'
  --title: string
  --instructions: string
]: nothing -> record {
  {
    info: ({name: $name, version: $version} | with-optional title $title)
    instructions: $instructions
    tools: []
    resources: []
    templates: []
    prompts: []
    invoke: null
  }
}

# Register a closure as a tool.
export def "add tool" [
  name: string
  handler: closure            # {|args| ...}
  --description (-d): string
  --title: string
  --params (-p): record = {}  # name -> shape, e.g. {a: int, b: "int?"}
  --annotations: record       # readOnlyHint, destructiveHint, idempotentHint, openWorldHint
]: record -> record {
  let server = $in
  let params = (params-from $params)
  let spec = (
    {name: $name}
    | with-optional title $title
    | with-optional description $description
    | insert inputSchema (input-schema $params)
    | with-optional annotations $annotations
  )
  $server | upsert tools ($server.tools | append {spec: $spec, handler: $handler, params: $params, wrap: false})
}

# Register a closure as a resource, or a resource template when the URI
# contains {var} placeholders (each becomes a string argument).
export def "add resource" [
  uri: string
  handler: closure            # {|args| ...}
  --name: string
  --title: string
  --description (-d): string
  --mime-type: string
  --params (-p): record       # Types for template variables (default: string)
]: record -> record {
  let server = $in
  let base = (
    {name: ($name | default $uri)}
    | with-optional title $title
    | with-optional description $description
    | with-optional mimeType $mime_type
  )
  if ($uri | str contains '{') {
    let tpl = (template-regex $uri)
    let spec_params = ($tpl.vars | reduce --fold {} {|v, acc| $acc | insert $v 'string' } | merge ($params | default {}))
    let entry = {
      spec: ({uriTemplate: $uri} | merge $base)
      handler: $handler
      params: (params-from $spec_params)
      regex: $tpl.regex
      vars: $tpl.vars
    }
    $server | upsert templates ($server.templates | append $entry)
  } else {
    let entry = {spec: ({uri: $uri} | merge $base), handler: $handler, params: []}
    $server | upsert resources ($server.resources | append $entry)
  }
}

# Register a closure as a prompt.
export def "add prompt" [
  name: string
  handler: closure            # {|args| ...} returning a string or messages
  --description (-d): string
  --title: string
  --params (-p): record = {}  # name -> shape; prompt arguments arrive as strings
]: record -> record {
  let server = $in
  let params = (params-from $params)
  let arguments = (
    $params | each {|p| {name: $p.name} | with-optional description $p.description | insert required (not $p.optional) }
  )
  let spec = (
    {name: $name}
    | with-optional title $title
    | with-optional description $description
    | insert arguments $arguments
  )
  $server | upsert prompts ($server.prompts | append {spec: $spec, handler: $handler, params: $params})
}
