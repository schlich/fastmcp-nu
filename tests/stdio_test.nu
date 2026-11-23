use std/assert

const ROOT = (path self | path dirname | path dirname)

def run-stdio [server: string, messages: list, --flags: list<string> = []]: nothing -> record {
  $messages
  | each { to json --raw }
  | str join "\n"
  | ^$nu.current-exe -n ($ROOT | path join bin fastmcp-nu) run ($ROOT | path join $server) ...$flags
  | complete
}

def call [id: int, name: string, arguments: record = {}]: nothing -> record {
  {jsonrpc: '2.0', id: $id, method: 'tools/call', params: {name: $name, arguments: $arguments}}
}

export def "test weather example over stdio" [] {
  let r = (run-stdio examples/weather.nu [
    {jsonrpc: '2.0', id: 1, method: initialize, params: {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: t, version: '0'}}}
    {jsonrpc: '2.0', method: 'notifications/initialized'}
    (call 2 get-weather {city: Osaka, units: metric})
    (call 3 forecast {city: Osaka, days: 9})
    {jsonrpc: '2.0', id: 4, method: 'resources/read', params: {uri: 'weather://report/Osaka'}}
  ])
  assert equal $r.exit_code 0 $r.stderr
  let out = ($r.stdout | lines | each { from json })
  assert equal ($out | get id) [1 2 3 4]
  assert equal $out.0.result.serverInfo.name weather
  assert equal $out.1.result.structuredContent.units metric
  assert equal $out.2.result.isError true
  assert equal $out.2.result.content.0.text 'days must be between 1 and 7, got 9'
  assert str contains $out.3.result.contents.0.text 'Weather in Osaka'
}

export def "test every parameter kind reaches the command" [] {
  let args = {name: x, tags: [a b], ratio: 2, loud: true, when: '2026-01-02T03:04:05Z', wait: '5min', point: {x: 1, y: '2'}}
  let r = (run-stdio tests/fixtures/kitchen_sink.nu [(call 1 echo-all $args) (call 2 echo-all {name: y})])
  let out = ($r.stdout | lines | each { from json | get result.structuredContent })
  assert equal $out.0 {name: x, count: 2, tags: [a b], ratio: 2.0, loud: true, when: '2026-01-02T03:04:05+00:00', wait: 300000000000, point: {x: 1, y: 2}}
  assert equal $out.1 {name: y, count: 2, tags: [], ratio: null, loud: false, when: null, wait: 1000000000, point: null}
}

export def "test external output, content blocks and binary resources" [] {
  let r = (run-stdio tests/fixtures/kitchen_sink.nu [
    (call 1 shout {word: hello})
    (call 2 picture)
    {jsonrpc: '2.0', id: 3, method: 'resources/read', params: {uri: 'mem://bytes'}}
    (call 4 fails)
  ])
  let out = ($r.stdout | lines | each { from json | get result })
  assert equal $out.0.content [{type: text, text: HELLO}]
  assert equal $out.1.content [{type: image, data: 'iVBORw0KGgo=', mimeType: 'image/png'}]
  assert equal $out.2.contents [{uri: 'mem://bytes', mimeType: 'application/octet-stream', blob: '3q2+7w=='}]
  assert equal $out.3 {content: [{type: text, text: "kaboom\nhelp: do not call this"}], isError: true}
}

export def "test the stdout guard keeps stray output off the protocol stream" [] {
  let r = (run-stdio tests/fixtures/kitchen_sink.nu [(call 1 noisy)])
  let lines = ($r.stdout | lines)
  assert equal ($lines | length) 1
  assert equal ($lines.0 | from json | get result.content.0.text) 'clean result'
  assert str contains $r.stderr 'stray print'
  assert str contains $r.stderr 'stray external'
}

export def "test without the guard stray output corrupts stdout" [] {
  let r = (run-stdio tests/fixtures/kitchen_sink.nu [(call 1 noisy)] --flags [--no-guard])
  assert str contains $r.stdout 'stray print'
}

export def "test answers each request while stdin stays open" [] {
  if (which node | is-empty) {
    print --stderr 'skipped: node is not on PATH'
    return
  }
  let requests = ($nu.temp-dir | path join $"fastmcp-stream-(random chars --length 8).json")
  [
    {method: initialize, params: {protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {name: t, version: '0'}}}
    {method: 'notifications/initialized', notify: true}
    {method: 'tools/list'}
    {method: 'tools/call', params: {name: noisy}}
    {method: 'prompts/get', params: {name: review, arguments: {code: ls}}}
  ] | to json | save --force $requests
  let r = (
    ^node ($ROOT | path join tests stream_client.mjs) $requests -- $nu.current-exe -n ($ROOT | path join bin fastmcp-nu) run ($ROOT | path join tests fixtures kitchen_sink.nu)
    | complete
  )
  rm --force $requests
  assert equal $r.exit_code 0 $r.stderr
  let out = ($r.stdout | from json)
  assert equal $out.stray []
  assert equal ($out.responses | length) 4
  assert equal $out.responses.2.result.content.0.text 'clean result'
}
