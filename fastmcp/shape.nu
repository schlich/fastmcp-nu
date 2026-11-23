# Nushell type shapes: parse the `syntax_shape` strings that `scope commands`
# reports, map them to JSON Schema, and conform incoming JSON values to them.
#
# A parsed type is a record with a `kind` and, for container kinds, the parts:
#   {kind: int}
#   {kind: list, items: <type>}
#   {kind: record, fields: [{name: lat, type: <type>}]}
#   {kind: table, fields: [...]}
#   {kind: oneof, types: [<type> ...]}

# Split a shape string into identifier, quoted-name and punctuation tokens.
def tokenize [shape: string]: nothing -> list<string> {
  $shape
  | parse --regex r#'(?<t>"[^"]*"|'[^']*'|`[^`]*`|[A-Za-z_][\w-]*|[<>,:()\[\]]|\S)'#
  | get t
}

def unquote []: string -> string {
  let s = $in
  if ($s | str length) >= 2 and ($s | str substring 0..0) in ['"' "'" '`'] {
    $s | str substring 1..-2
  } else {
    $s
  }
}

# Parse the fields of `record<...>` or `table<...>`; tokens start after `<`.
def parse-fields [tokens: list<string>]: nothing -> record {
  mut toks = $tokens
  mut fields = []
  while ($toks | is-not-empty) and $toks.0 != '>' {
    if $toks.0 == ',' {
      $toks = ($toks | skip 1)
      continue
    }
    let name = ($toks.0 | unquote)
    $toks = ($toks | skip 1)
    if ($toks | get 0?) == ':' {
      let parsed = (parse-type ($toks | skip 1))
      $fields = ($fields | append {name: $name, type: $parsed.type})
      $toks = $parsed.rest
    } else {
      $fields = ($fields | append {name: $name, type: {kind: any}})
    }
  }
  {fields: $fields, rest: ($toks | skip 1)}
}

# Parse a comma separated list of types; tokens start after `<`.
def parse-types [tokens: list<string>]: nothing -> record {
  mut toks = $tokens
  mut types = []
  while ($toks | is-not-empty) and $toks.0 != '>' {
    if $toks.0 == ',' {
      $toks = ($toks | skip 1)
      continue
    }
    let parsed = (parse-type $toks)
    $types = ($types | append $parsed.type)
    $toks = $parsed.rest
  }
  {types: $types, rest: ($toks | skip 1)}
}

# Skip a balanced `( ... )` group, used for `closure(...)` shapes.
def skip-parens [tokens: list<string>]: nothing -> list<string> {
  mut toks = $tokens
  mut depth = 0
  loop {
    if ($toks | is-empty) { break }
    let t = $toks.0
    $toks = ($toks | skip 1)
    if $t == '(' { $depth += 1 }
    if $t == ')' { $depth -= 1 }
    if $depth <= 0 { break }
  }
  $toks
}

def parse-type [tokens: list<string>]: nothing -> record {
  if ($tokens | is-empty) {
    return {type: {kind: any}, rest: []}
  }
  let name = $tokens.0
  let rest = ($tokens | skip 1)
  let generic = (($rest | get 0?) == '<')
  match $name {
    'list' => {
      if $generic {
        let inner = (parse-types ($rest | skip 1))
        {type: {kind: list, items: ($inner.types | get 0? | default {kind: any})}, rest: $inner.rest}
      } else {
        {type: {kind: list, items: {kind: any}}, rest: $rest}
      }
    }
    'record' | 'table' => {
      if $generic {
        let inner = (parse-fields ($rest | skip 1))
        {type: {kind: $name, fields: $inner.fields}, rest: $inner.rest}
      } else {
        {type: {kind: $name, fields: []}, rest: $rest}
      }
    }
    'oneof' => {
      if $generic {
        let inner = (parse-types ($rest | skip 1))
        {type: {kind: oneof, types: $inner.types}, rest: $inner.rest}
      } else {
        {type: {kind: any}, rest: $rest}
      }
    }
    'closure' => {
      let after = (if ($rest | get 0?) == '(' { skip-parens $rest } else { $rest })
      {type: {kind: closure}, rest: $after}
    }
    'boolean' => { {type: {kind: bool}, rest: $rest} }
    'date' => { {type: {kind: datetime}, rest: $rest} }
    _ => { {type: {kind: $name}, rest: $rest} }
  }
}

# Parse a Nushell syntax shape string (as shown by `scope commands`).
export def parse-shape [shape: any]: nothing -> record {
  if $shape == null or $shape == '' {
    return {kind: any}
  }
  (parse-type (tokenize $shape)).type
}

# Render a parsed type back to Nushell's notation, for error messages.
export def render-type [t: record]: nothing -> string {
  match $t.kind {
    'list' => { $"list<(render-type $t.items)>" }
    'record' | 'table' => {
      if ($t.fields | is-empty) {
        $t.kind
      } else {
        let inner = ($t.fields | each {|f| $"($f.name): (render-type $f.type)" } | str join ', ')
        $"($t.kind)<($inner)>"
      }
    }
    'oneof' => { $"oneof<($t.types | each {|x| render-type $x } | str join ', ')>" }
    _ => { $t.kind }
  }
}

def object-schema [fields: list]: nothing -> record {
  if ($fields | is-empty) {
    return {type: object}
  }
  let props = ($fields | reduce --fold {} {|f, acc| $acc | insert $f.name (json-schema $f.type) })
  {type: object, properties: $props, required: ($fields | get name)}
}

# Map a parsed type to a JSON Schema fragment.
export def json-schema [t: record]: nothing -> record {
  match $t.kind {
    'string' | 'path' | 'directory' | 'glob' | 'cell-path' => { {type: string} }
    'int' => { {type: integer} }
    'float' | 'number' => { {type: number} }
    'bool' => { {type: boolean} }
    'datetime' => { {type: string, format: date-time} }
    'duration' => { {type: string, pattern: r#'^-?\d+(\.\d+)?(ns|us|µs|ms|sec|min|hr|day|wk)$'#, examples: ['30sec' '5min' '2hr']} }
    'filesize' => { {type: string, pattern: r#'^\d+(\.\d+)?\s*([KMGTPE]i?B|B)?$'#, examples: ['512B' '10KB' '4MiB']} }
    'binary' => { {type: string, contentEncoding: base64} }
    'nothing' => { {type: 'null'} }
    'list' => {
      if $t.items.kind == 'any' { {type: array} } else { {type: array, items: (json-schema $t.items)} }
    }
    'record' => { object-schema $t.fields }
    'table' => { {type: array, items: (object-schema $t.fields)} }
    'oneof' => { {anyOf: ($t.types | each {|x| json-schema $x })} }
    _ => { {} }
  }
}

def kind-of []: any -> string {
  $in | describe --detailed | get type
}

def fail [path: string, t: record, value: any]: nothing -> record {
  let got = ($value | describe)
  {value: $value, errors: [$"($path): expected (render-type $t), got ($got)"]}
}

def ok []: any -> record {
  {value: $in, errors: []}
}

def try-into [path: string, t: record, value: any, convert: closure]: nothing -> record {
  try {
    do $convert $value | ok
  } catch {
    fail $path $t $value
  }
}

# Conform a decoded JSON value to a parsed Nushell type.
#
# Converts losslessly where JSON cannot carry the Nushell type directly
# (datetimes, durations, file sizes, base64 binary) and leniently accepts
# numbers and booleans sent as strings. Returns `{value, errors}`; `errors`
# names each offending path, rooted at `path`.
export def conform [t: record, path: string = 'value']: any -> record {
  let v = $in
  let k = ($v | kind-of)
  match $t.kind {
    'any' | 'closure' => { $v | ok }
    'string' | 'path' | 'directory' | 'glob' | 'cell-path' => {
      if $k == 'string' { $v | ok } else if $k in ['int' 'float' 'bool'] { $v | into string | ok } else { fail $path $t $v }
    }
    'int' => {
      if $k == 'int' {
        $v | ok
      } else if $k == 'float' and ($v | math round) == $v {
        $v | into int | ok
      } else if $k == 'string' and ($v | str trim) =~ '^-?\d+$' {
        $v | str trim | into int | ok
      } else {
        fail $path $t $v
      }
    }
    'float' | 'number' => {
      if $k in ['int' 'float'] {
        if $t.kind == 'float' { $v | into float | ok } else { $v | ok }
      } else if $k == 'string' and ($v | str trim) =~ '^-?\d+(\.\d+)?([eE][-+]?\d+)?$' {
        $v | str trim | into float | ok
      } else {
        fail $path $t $v
      }
    }
    'bool' => {
      if $k == 'bool' {
        $v | ok
      } else if $k == 'string' and $v =~ '(?i)^(true|false)$' {
        $v =~ '(?i)^true$' | ok
      } else {
        fail $path $t $v
      }
    }
    'datetime' => {
      if $k == 'datetime' { $v | ok } else if $k == 'string' { try-into $path $t $v {|x| $x | into datetime } } else { fail $path $t $v }
    }
    'duration' => {
      if $k == 'duration' { $v | ok } else if $k in ['string' 'int'] { try-into $path $t $v {|x| $x | into duration } } else { fail $path $t $v }
    }
    'filesize' => {
      if $k == 'filesize' { $v | ok } else if $k in ['string' 'int'] { try-into $path $t $v {|x| $x | into filesize } } else { fail $path $t $v }
    }
    'binary' => {
      if $k == 'binary' { $v | ok } else if $k == 'string' { try-into $path $t $v {|x| $x | decode base64 } } else { fail $path $t $v }
    }
    'nothing' => {
      if $v == null { null | ok } else { fail $path $t $v }
    }
    'list' => {
      if $k not-in ['list' 'table'] {
        return (fail $path $t $v)
      }
      let items = ($v | enumerate | each {|it| $it.item | conform $t.items $"($path)[($it.index)]" })
      {value: ($items | get value), errors: ($items | get errors | flatten)}
    }
    'table' => {
      if $k not-in ['list' 'table'] {
        return (fail $path $t $v)
      }
      let row = {kind: record, fields: $t.fields}
      let items = ($v | enumerate | each {|it| $it.item | conform $row $"($path)[($it.index)]" })
      {value: ($items | get value), errors: ($items | get errors | flatten)}
    }
    'record' => {
      if $k != 'record' {
        return (fail $path $t $v)
      }
      mut out = $v
      mut errors = []
      for f in $t.fields {
        let child = ($v | get --optional $f.name)
        if $child == null {
          $errors = ($errors | append $"($path).($f.name): required field is missing")
        } else {
          let r = ($child | conform $f.type $"($path).($f.name)")
          $out = ($out | upsert $f.name $r.value)
          $errors = ($errors | append $r.errors)
        }
      }
      {value: $out, errors: $errors}
    }
    'oneof' => {
      let attempts = ($t.types | each {|alt| $v | conform $alt $path })
      let good = ($attempts | where ($it.errors | is-empty))
      # Prefer an alternative that accepts the value without converting it.
      let exact = ($good | where ($it.value | kind-of) == $k)
      if ($good | is-empty) { fail $path $t $v } else if ($exact | is-not-empty) { $exact.0 } else { $good.0 }
    }
    _ => { $v | ok }
  }
}
