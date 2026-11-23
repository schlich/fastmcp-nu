use std/assert
use fastmcp

# A server built with the closure registry; it drives the same protocol core
# as generated servers, so these tests cover the core directly.
def calc []: nothing -> record {
  fastmcp server new calc --version 1.0.0 --instructions 'Do math'
  | fastmcp add tool add {|args| $args.a + $args.b } -d 'Add two numbers' -p {a: int, b: int}
  | fastmcp add tool div {|args| if $args.b == 0 { error make {msg: 'division by zero'} }; $args.a / $args.b } -p {a: float, b: float}
  | fastmcp add tool greet {|args| $"hi ($args.name)($args.punct)" } -p {
    name: {type: string, enum: [ann bob]}
    punct: {type: string, default: '!'}
  }
  | fastmcp add tool stats {|args| {n: ($args.xs | length), sum: ($args.xs | math sum)} } -p {xs: 'list<int>'}
  | fastmcp add resource 'calc://pi' {|args| 3.14159 } --mime-type 'text/plain'
  | fastmcp add resource 'calc://square/{n}' {|args| $args.n * $args.n } -p {n: int}
  | fastmcp add prompt explain {|args| $"Explain ($args.topic)" } -p {
    topic: string
    level: {type: 'string?', enum: [basic advanced]}
  }
}

def rpc [server: record, method: string, params: record = {}]: nothing -> any {
  {jsonrpc: '2.0', id: 1, method: $method, params: $params} | fastmcp handle $server
}

export def "test initialize negotiates the protocol version" [] {
  let s = (calc)
  let r = (rpc $s initialize {protocolVersion: '2025-03-26', capabilities: {}, clientInfo: {name: t, version: '0'}})
  assert equal $r.result.protocolVersion '2025-03-26'
  assert equal $r.result.serverInfo {name: calc, version: '1.0.0'}
  assert equal $r.result.instructions 'Do math'
  assert equal ($r.result.capabilities | columns | sort) [completions prompts resources tools]
  assert equal (rpc $s initialize {protocolVersion: '2099-01-01'}).result.protocolVersion '2025-11-25'
}

export def "test ping and unknown methods" [] {
  assert equal (rpc (calc) ping) {jsonrpc: '2.0', id: 1, result: {}}
  assert equal (rpc (calc) 'nope/nope').error.code (-32601)
}

export def "test notifications and responses get no reply" [] {
  assert equal ({jsonrpc: '2.0', method: 'notifications/initialized'} | fastmcp handle (calc)) null
  assert equal ({jsonrpc: '2.0', id: 9, result: {}} | fastmcp handle (calc)) null
}

export def "test malformed messages" [] {
  let s = (calc)
  assert equal ('{nope' | fastmcp handle json $s | from json) {jsonrpc: '2.0', id: null, error: {code: -32700, message: 'Parse error'}}
  assert equal ('[]' | fastmcp handle json $s | from json | get error.code) (-32600)
  assert equal ('"hi"' | fastmcp handle json $s | from json | get error.code) (-32600)
  assert equal ({jsonrpc: '1.0', id: 1, method: ping} | fastmcp handle $s | get error.code) (-32600)
  assert equal ({jsonrpc: '2.0', id: 1, method: ping, params: [1]} | fastmcp handle $s | get error.code) (-32602)
}

export def "test batches answer requests only" [] {
  let batch = [
    {jsonrpc: '2.0', id: 1, method: ping}
    {jsonrpc: '2.0', method: 'notifications/initialized'}
    {jsonrpc: '2.0', id: 2, method: ping}
  ]
  assert equal ($batch | fastmcp handle (calc) | get id) [1 2]
  assert equal ([{jsonrpc: '2.0', method: 'notifications/initialized'}] | fastmcp handle (calc)) null
}

export def "test tools list and call" [] {
  let s = (calc)
  let tools = (rpc $s 'tools/list').result.tools
  assert equal ($tools | get name) [add div greet stats]
  assert equal $tools.0 {
    name: add
    description: 'Add two numbers'
    inputSchema: {type: object, properties: {a: {type: integer}, b: {type: integer}}, required: [a b]}
  }
  assert equal (rpc $s 'tools/call' {name: add, arguments: {a: 2, b: '3'}}).result {content: [{type: text, text: '5'}], isError: false}
}

export def "test records become structured content" [] {
  let r = (rpc (calc) 'tools/call' {name: stats, arguments: {xs: [1 2 3]}}).result
  assert equal $r.structuredContent {n: 3, sum: 6}
  assert equal ($r.content.0.text | from json) {n: 3, sum: 6}
}

export def "test tool failures are results, not protocol errors" [] {
  let s = (calc)
  let err = (rpc $s 'tools/call' {name: div, arguments: {a: 1, b: 0}}).result
  assert equal $err.isError true
  assert str contains $err.content.0.text 'division by zero'
  let bad = (rpc $s 'tools/call' {name: add, arguments: {a: 1, c: 2}}).result
  assert equal $bad.isError true
  assert str contains $bad.content.0.text "missing required argument 'b'"
  assert str contains $bad.content.0.text "unknown argument 'c'"
  assert equal (rpc $s 'tools/call' {name: nope}).error.code (-32602)
}

export def "test enums and defaults" [] {
  let s = (calc)
  assert equal (rpc $s 'tools/call' {name: greet, arguments: {name: ann}}).result.content.0.text 'hi ann!'
  let r = (rpc $s 'tools/call' {name: greet, arguments: {name: cat}}).result
  assert equal $r.isError true
  assert str contains $r.content.0.text 'is not one of'
}

export def "test resources and templates" [] {
  let s = (calc)
  assert equal (rpc $s 'resources/list').result.resources [{uri: 'calc://pi', name: 'calc://pi', mimeType: 'text/plain'}]
  assert equal (rpc $s 'resources/templates/list').result.resourceTemplates.0.uriTemplate 'calc://square/{n}'
  assert equal (rpc $s 'resources/read' {uri: 'calc://square/7'}).result.contents [
    {uri: 'calc://square/7', mimeType: 'application/json', text: '49'}
  ]
  assert equal (rpc $s 'resources/read' {uri: 'calc://pi'}).result.contents.0.mimeType 'text/plain'
  assert equal (rpc $s 'resources/read' {uri: 'calc://nope'}).error.code (-32002)
  assert equal (rpc $s 'resources/read' {uri: 'calc://square/x'}).error.code (-32602)
}

export def "test prompts and completion" [] {
  let s = (calc)
  assert equal (rpc $s 'prompts/list').result.prompts.0.arguments [{name: topic, required: true}, {name: level, required: false}]
  assert equal (rpc $s 'prompts/get' {name: explain, arguments: {topic: monads}}).result.messages [
    {role: user, content: {type: text, text: 'Explain monads'}}
  ]
  assert equal (rpc $s 'prompts/get' {name: explain}).error.code (-32602)
  let c = (rpc $s 'completion/complete' {ref: {type: 'ref/prompt', name: explain}, argument: {name: level, value: 'ADV'}}).result
  assert equal $c.completion {values: [advanced], total: 1, hasMore: false}
}
