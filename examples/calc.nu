# The closure-registry style: no attributes and no runner. Handlers are
# closures that receive the validated arguments as one record.
#
#   nu -n --stdin -I /path/to/fastmcp-nu examples/calc.nu

use fastmcp

def calc []: nothing -> record {
  fastmcp server new calc --instructions 'Exact arithmetic.'
  | fastmcp add tool add {|args| $args.a + $args.b } -d 'Add two numbers' -p {a: number, b: number}
  | fastmcp add tool divide {|args|
    if $args.b == 0 { error make {msg: 'cannot divide by zero'} }
    $args.a / $args.b
  } -d 'Divide a by b' -p {a: number, b: number}
  | fastmcp add resource 'calc://constants' {|args| {pi: 3.141592653589793, e: 2.718281828459045} } --mime-type 'application/json'
}

# serve stdio must be the first pipeline in main: Nushell passes a command's
# input (here, stdin) implicitly only to the first pipeline of its body.
def main []: any -> nothing {
  fastmcp serve stdio (calc)
}
