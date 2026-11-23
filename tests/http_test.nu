use std/assert

const ROOT = (path self | path dirname | path dirname)

# Records are sent as JSON; a string is sent verbatim (to test parse errors),
# since `http post` would JSON-encode a string sent as application/json.
def post [url: string, body: any, --headers: record = {}]: nothing -> record {
  let raw = (($body | describe) == 'string')
  let payload = (if $raw { $body } else { $body | to json --raw })
  let headers = ({accept: 'application/json, text/event-stream'} | merge $headers)
  http post --full --allow-errors --content-type (if $raw { 'text/plain' } else { 'application/json' }) --headers $headers $url $payload
}

def checks [url: string]: nothing -> nothing {
  let init = (post $url {jsonrpc: '2.0', id: 1, method: initialize, params: {protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {name: t, version: '0'}}})
  assert equal $init.status 200
  assert equal $init.body.result.serverInfo.name weather

  let notified = (post $url {jsonrpc: '2.0', method: 'notifications/initialized'})
  assert equal $notified.status 202

  let called = (post $url {jsonrpc: '2.0', id: 2, method: 'tools/call', params: {name: get-weather, arguments: {city: Lisbon}}} --headers {mcp-protocol-version: '2025-11-25'})
  assert equal $called.body.result.structuredContent.city Lisbon

  assert equal (post $url '{nope').status 400
  assert equal (post $url {jsonrpc: '2.0', id: 3, method: ping} --headers {mcp-protocol-version: '1999-01-01'}).status 400
  assert equal (post $url {jsonrpc: '2.0', id: 4, method: ping} --headers {origin: 'https://evil.example'}).status 403
  assert equal (post $url {jsonrpc: '2.0', id: 5, method: ping} --headers {origin: 'http://localhost:6274'}).status 200
  assert equal (http get --full --allow-errors $url | get status) 405
  assert equal (http get --full --allow-errors ($url | str replace '/mcp' '/other') | get status) 404
}

export def "test streamable http via http-nu" [] {
  if (which http-nu | is-empty) {
    print --stderr 'skipped: http-nu is not on PATH'
    return
  }
  let port = (port)
  let url = $"http://127.0.0.1:($port)/mcp"
  let server = (job spawn {
    ^$nu.current-exe -n ($ROOT | path join bin fastmcp-nu) run ($ROOT | path join examples weather.nu) --http $"127.0.0.1:($port)" o+e>| ignore
  })
  mut ready = false
  for _ in 1..100 {
    if (try { http get --full --allow-errors $url | get status } catch { 0 }) == 405 {
      $ready = true
      break
    }
    sleep 100ms
  }
  let outcome = (
    try {
      if $ready { checks $url; null } else { 'http-nu did not start' }
    } catch {|e|
      [$e.msg ...($e.details?.labels? | default [] | each {|l| $l.text? } | compact)] | str join ': '
    }
  )
  job kill $server
  if $outcome != null {
    error make {msg: $outcome}
  }
}
