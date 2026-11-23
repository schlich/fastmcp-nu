# A small weather server: tools, a static resource, a resource template,
# and a prompt.
#
#   fastmcp-nu run examples/weather.nu
#   fastmcp-nu run examples/weather.nu --http :3001

use fastmcp ["attr mcp-tool" "attr mcp-resource" "attr mcp-prompt"]

export const MCP_SERVER = {
  name: weather
  version: '0.1.0'
  instructions: 'Weather lookups for any city. Temperatures are simulated.'
}

const CONDITIONS = [sunny cloudy rain snow fog]

# Deterministic fake reading so the example needs no network access.
def reading [city: string, day: int]: nothing -> record {
  let seed = ($city | hash md5 | str substring 0..5 | into int --radix 16) + $day
  let index = $seed mod ($CONDITIONS | length)
  {temp_f: (40 + $seed mod 50), condition: ($CONDITIONS | get $index)}
}

def convert [temp_f: int, units: string]: nothing -> float {
  if $units == 'metric' { ($temp_f - 32) * 5 / 9 | math round --precision 1 } else { $temp_f | into float }
}

# Get the current weather for a city
@mcp-tool {title: 'Current weather', annotations: {readOnlyHint: true, openWorldHint: false}}
export def get-weather [
  city: string                          # City name (e.g. "St. Louis")
  units?: string@[metric imperial]      # "metric" or "imperial"
]: nothing -> record<city: string, units: string, temp: float, condition: string> {
  let units = ($units | default imperial)
  let r = (reading $city 0)
  {city: $city, units: $units, temp: (convert $r.temp_f $units), condition: $r.condition}
}

# Forecast the next few days for a city
@mcp-tool {annotations: {readOnlyHint: true}}
export def forecast [
  city: string                          # City name
  --days: int = 3                       # Number of days, 1 to 7
  --units: string@[metric imperial] = imperial  # Temperature units
]: nothing -> table<day: int, temp: float, condition: string> {
  if $days < 1 or $days > 7 {
    error make {msg: $"days must be between 1 and 7, got ($days)"}
  }
  1..$days | each {|day|
    let r = (reading $city $day)
    {day: $day, temp: (convert $r.temp_f $units), condition: $r.condition}
  }
}

# Supported cities and their time zones
@mcp-resource {uri: 'weather://cities', mimeType: 'application/json'}
export def cities []: nothing -> table<city: string, tz: string> {
  [
    {city: 'St. Louis', tz: 'America/Chicago'}
    {city: 'Lisbon', tz: 'Europe/Lisbon'}
    {city: 'Osaka', tz: 'Asia/Tokyo'}
  ]
}

# A plain-text weather report for one city
@mcp-resource 'weather://report/{city}'
export def report [city: string]: nothing -> string {
  let w = (get-weather $city)
  $"Weather in ($w.city): ($w.temp)°F and ($w.condition)."
}

# Ask the model to plan an outfit for the day's weather
@mcp-prompt {title: 'Outfit planner'}
export def outfit [
  city: string                          # Where you are
  style?: string@[casual formal sporty]  # Dress code
]: nothing -> string {
  $"Look up the weather in ($city) with the get-weather tool, then suggest a ($style | default casual) outfit for it."
}
