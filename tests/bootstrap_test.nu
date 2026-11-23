use std/assert
use fastmcp/bootstrap.nu [call-expr codegen]

export def "test call expression unpacks every parameter kind" [] {
  let params = [
    {name: city, kind: positional}
    {name: tags, kind: rest}
    {name: max-n, kind: named}
    {name: loud, kind: switch}
  ]
  assert equal (call-expr 'get weather' $params) 'get weather ($args."city"?) ...($args."tags"? | default []) --max-n=($args."max-n"?) --loud=($args."loud"? | default false)'
}

export def "test generated scripts dispatch each command once" [] {
  let entry = {command: hello, params: [{name: who, kind: positional}]}
  let manifest = {info: {name: t, version: '0'}, instructions: null, tools: [$entry], resources: [], templates: [], prompts: [$entry]}
  let stdio = (codegen /srv/hello.nu $manifest)
  assert str contains $stdio 'use "/srv/hello.nu" *'
  assert equal ($stdio | lines | where {|l| $l =~ '^\s+"hello" =>' } | length) 1
  assert str contains $stdio 'fastmcp serve stdio'
  let http = (codegen /srv/hello.nu $manifest --transport http --path /api --allow-origin [https://app.example])
  assert str contains $http 'fastmcp serve http $server --path "/api" --allow-origin ["https://app.example"]'
}
