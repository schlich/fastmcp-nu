#!/usr/bin/env nu
# Run the test suite: every exported `test ...` command in tests/*_test.nu.
#
#   nu tests/run.nu              # every file
#   nu tests/run.nu protocol     # files whose name matches "protocol"
#
# Like the server runner, this discovers commands in one process and calls
# them from a generated script in another, since Nushell cannot call a
# command named in a runtime string.

const ROOT = (path self | path dirname | path dirname)

def error-text [err: record]: nothing -> string {
  let labels = ($err.details?.labels? | default [] | each {|l| $l.text? } | compact | where $it != '')
  [$err.msg? ...$labels] | compact | uniq | str join ': '
}

def run-file [file: string]: nothing -> list<record> {
  let found = (
    ^$nu.current-exe -n -I $ROOT -c $"use ($file | to nuon) *; scope commands | where name starts-with 'test ' | get name | to nuon"
    | complete
  )
  if $found.exit_code != 0 {
    return [{file: ($file | path basename), name: '(load)', ok: false, error: $found.stderr}]
  }
  let names = ($found.stdout | from nuon)
  let out = ($nu.temp-dir | path join $"fastmcp-tests-(random chars --length 8).nuon")
  let calls = ($names | each {|n| $"  {name: ($n | to nuon), run: {|| ($n) }}" } | str join "\n")
  let script = $"
use ($file | to nuon) *
def error-text [err: record] {
  let labels = \($err.details?.labels? | default [] | each {|l| $l.text? } | compact | where $it != '')
  [$err.msg? ...$labels] | compact | uniq | str join ': '
}
[
($calls)
] | each {|t|
  try { do $t.run; {name: $t.name, ok: true, error: null} } catch {|e| {name: $t.name, ok: false, error: \(error-text $e)} }
} | to nuon | save --force ($out | to nuon)
"
  let run = (^$nu.current-exe -n -I $ROOT -c $script | complete)
  if $run.exit_code != 0 or not ($out | path exists) {
    return [{file: ($file | path basename), name: '(run)', ok: false, error: $run.stderr}]
  }
  let results = (open $out | insert file ($file | path basename))
  rm --force $out
  $results
}

def main [filter: string = '']: nothing -> nothing {
  let files = (glob ($ROOT | path join tests '*_test.nu') | sort | where {|f| ($f | path basename) =~ $filter })
  let results = ($files | each {|f| run-file $f } | flatten)
  for r in $results {
    if $r.ok {
      print $"  ✓ ($r.file) ($r.name)"
    } else {
      print $"  ✗ ($r.file) ($r.name)\n      ($r.error | str replace --all "\n" "\n      ")"
    }
  }
  let failed = ($results | where not ok | length)
  print $"\n($results | length) tests, ($failed) failed"
  if $failed > 0 {
    exit 1
  }
}
