use std/assert
use fastmcp/shape.nu *

export def "test parse scalar and generic shapes" [] {
  assert equal (parse-shape 'int') {kind: int}
  assert equal (parse-shape 'list<string>') {kind: list, items: {kind: string}}
  assert equal (parse-shape 'record<lat: float, lon: float>') {
    kind: record
    fields: [{name: lat, type: {kind: float}}, {name: lon, type: {kind: float}}]
  }
  assert equal (parse-shape 'oneof<string, int>') {kind: oneof, types: [{kind: string}, {kind: int}]}
  assert equal (parse-shape 'closure(int, string)') {kind: closure}
  assert equal (parse-shape null) {kind: any}
}

export def "test render round-trips" [] {
  for shape in ['list<string>' 'record<a: list<record<b: int>>>' 'table<name: string, size: int>' 'oneof<string, int>'] {
    assert equal (render-type (parse-shape $shape)) $shape
  }
}

export def "test json schema mapping" [] {
  assert equal (json-schema (parse-shape int)) {type: integer}
  assert equal (json-schema (parse-shape 'list<float>')) {type: array, items: {type: number}}
  assert equal (json-schema (parse-shape 'record<a: int>')) {type: object, properties: {a: {type: integer}}, required: [a]}
  assert equal (json-schema (parse-shape 'table<n: string>')) {
    type: array
    items: {type: object, properties: {n: {type: string}}, required: [n]}
  }
  assert equal (json-schema (parse-shape 'oneof<string, bool>')) {anyOf: [{type: string}, {type: boolean}]}
  assert equal (json-schema (parse-shape datetime)) {type: string, format: date-time}
  assert equal (json-schema (parse-shape any)) {}
}

export def "test conform converts lossless and lenient values" [] {
  assert equal ('42' | conform {kind: int} x) {value: 42, errors: []}
  assert equal (3 | conform {kind: float} x | get value | describe) float
  assert equal ('TRUE' | conform {kind: bool} x | get value) true
  assert equal ('5min' | conform {kind: duration} x | get value) 5min
  assert equal ('10KB' | conform {kind: filesize} x | get value) 10KB
  assert equal ('3q2+7w==' | conform {kind: binary} x | get value) 0x[DEADBEEF]
  assert equal ('2026-01-02T03:04:05Z' | conform {kind: datetime} x | get value) ('2026-01-02T03:04:05Z' | into datetime)
}

export def "test conform reports the path of each error" [] {
  let t = (parse-shape 'record<p: list<int>>')
  assert equal ({p: [1 'x' 3]} | conform $t arg | get errors) ['arg.p[1]: expected int, got string']
  assert equal ({} | conform $t arg | get errors) ['arg.p: required field is missing']
  assert equal ('soon' | conform {kind: duration} arg | get errors) ['arg: expected duration, got string']
}

export def "test oneof prefers an exact match" [] {
  let t = (parse-shape 'oneof<string, int>')
  assert equal (5 | conform $t x | get value) 5
  assert equal ('5' | conform $t x | get value) '5'
}
