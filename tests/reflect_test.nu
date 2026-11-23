use std/assert
use fastmcp/reflect.nu [discover template-regex output-schema]

const ROOT = (path self | path dirname | path dirname)

def inspect-fixture []: nothing -> record {
  let r = (
    ^$nu.current-exe -n ($ROOT | path join bin fastmcp-nu) inspect ($ROOT | path join tests fixtures kitchen_sink.nu)
    | complete
  )
  assert equal $r.exit_code 0 $r.stderr
  $r.stdout | from json
}

# A row shaped like `scope commands` output, for discovery edge cases.
def fake-command [name: string, attr: string, value: any, params: list = []]: nothing -> record {
  let rows = ($params | each {|p|
    {
      parameter_name: $p.0
      parameter_type: positional
      syntax_shape: string
      is_optional: $p.1
      short_flag: null
      description: ''
      completion: null
      parameter_default: null
    }
  })
  {
    name: $name
    type: custom
    description: $"($name) command"
    extra_description: ''
    attributes: [{name: $attr, value: $value}]
    signatures: {nothing: $rows}
  }
}

export def "test discovers annotated commands only" [] {
  let m = (inspect-fixture)
  assert equal ($m.tools | get name | sort) [echo-all fails noisy picture shout]
  assert equal ($m.resources | get uri) [mem://bytes]
  assert equal ($m.resourceTemplates | get uriTemplate) ['file://{+path}']
  assert equal ($m.prompts | get name) [review]
  assert equal $m.serverInfo {name: sink, version: '9.9.9', title: 'Kitchen sink'}
}

export def "test input schema covers every parameter kind" [] {
  let tool = (inspect-fixture | get tools | where name == echo-all | first)
  let props = $tool.inputSchema.properties
  assert equal $tool.inputSchema.required [name]
  assert equal $props.name {type: string, description: 'Required positional'}
  assert equal $props.count {type: integer, description: 'Optional positional with a default', default: 2}
  assert equal $props.tags {type: array, items: {type: string}, description: 'Rest parameter'}
  assert equal $props.loud {type: boolean, description: Switch, default: false}
  assert equal $props.when.format date-time
  assert equal $props.point.required [x y]
  assert ($tool.description | str contains 'Covers positionals')
  assert equal $tool.outputSchema {type: object}
}

export def "test template regex" [] {
  let t = (template-regex 'weather://report/{city}')
  assert equal $t.vars [city]
  assert equal ('weather://report/St%20Louis' | parse --regex $t.regex | get v0.0) 'St%20Louis'
  assert ('weather://report/a/b' | parse --regex $t.regex | is-empty)
  let reserved = (template-regex 'file://{+path}')
  assert equal ('file:///etc/hosts' | parse --regex $reserved.regex | get v0.0) '/etc/hosts'
  assert equal (template-regex 'a.b://{x}?q').regex '^a\.b://(?<v0>[^/?#]+)\?q$'
}

export def "test output schema wraps non-record results" [] {
  assert equal (output-schema 'record<a: int>') {schema: {type: object, properties: {a: {type: integer}}, required: [a]}, wrap: false}
  assert equal (output-schema 'list<int>').schema.properties.result {type: array, items: {type: integer}}
  assert equal (output-schema 'list<int>').wrap true
  assert equal (output-schema 'string').schema null
  assert equal (output-schema null).schema null
}

export def "test attribute values" [] {
  let renamed = (discover --commands [(fake-command 'a b' mcp-tool 'custom')])
  assert equal $renamed.tools.0.spec.name custom
  let bare = (discover --commands [(fake-command 'a b' mcp-tool '')])
  assert equal $bare.tools.0.spec.name a_b
  assert equal $bare.tools.0.command 'a b'
}

export def "test rejects inconsistent resources" [] {
  let static_err = (try { discover --commands [(fake-command r mcp-resource 'x://y' [[id false]])]; '' } catch {|e| $e.msg })
  assert str contains $static_err 'cannot fill required parameters id'
  let unknown_err = (try { discover --commands [(fake-command r mcp-resource 'x://{nope}')]; '' } catch {|e| $e.msg })
  assert str contains $unknown_err 'nope are not parameters'
  let missing_err = (try { discover --commands [(fake-command r mcp-resource {})]; '' } catch {|e| $e.msg })
  assert str contains $missing_err 'needs a URI'
}

export def "test rejects duplicate tool names" [] {
  let err = (try { discover --commands [(fake-command a mcp-tool same) (fake-command b mcp-tool same)]; '' } catch {|e| $e.msg })
  assert str contains $err 'duplicate tool names: same'
}
