cached_settings = {}

if !module?
  module = {}
module.exports = 

  get_settings: (name) ->
    if !cached_settings[name] && fetch("/strategies/#{name}").settings?
      cached_settings[name] = fetch("/strategies/#{name}").settings 
    cached_settings[name]

  extend: (obj) ->
    obj ||= {}
    for arg, idx in arguments 
      if idx > 0
        for own name,s of arg
          if !obj[name]? || obj[name] != s
            obj[name] = s
    obj

  is_num: (n) -> 
    f = parseFloat n 
    !isNaN(parseFloat(f)) && isFinite(f) && (n.indexOf && n.indexOf(' ') == -1)
    
  make_global: (exports) -> 
    top = if window? then window else global

    for k,v of exports
      top[k] = v 

  get_strategies: -> 
    all_strategies = fetch('/strategies')
    all_strategies.strategies ||= []
    (s for s in all_strategies.strategies) 

  now: -> Math.floor((new Date()).getTime() / 1000)




module.exports.make_global module.exports

extend Math, 

  summation:  (data) -> 
    data.reduce((sum, value) ->
      sum + value
    , 0)

  standard_dev:  (values) ->
    avg = average(values)
    squareDiffs = values.map((value) ->
      diff = value - avg
      sqrDiff = diff * diff
      sqrDiff
    )
    avgSquareDiff = average(squareDiffs)
    stdDev = Math.sqrt(avgSquareDiff)
    stdDev

  average:  (data) ->
    sum = data.reduce((sum, value) ->
      sum + value
    , 0)
    avg = sum / data.length
    avg

  weighted_average:  (current_val, previous_val, alpha) -> 
    alpha ||= .5

    if !previous_val? || previous_val == null 
      current_val
    else if current_val == null 
      previous_val 
    else 
      alpha * current_val + (1 - alpha) * previous_val


  derivative:  (cur, prev) -> 
    return 0 if !prev? || prev == null 
    cur - prev 

  median:  (values, already_sorted) -> 
    if !already_sorted
      values.sort (a, b) ->
        a - b
    half = Math.floor(values.length / 2)
    if values.length % 2
      values[half]
    else
      (values[half - 1] + values[half]) / 2.0


  quartiles: (data) -> 
    data.sort (a,b) -> a - b

    m = Math.median data, true

    split = Math.floor(data.length / 2)

    more = data.slice split, data.length
    less = data.slice 0, split

    data = 
      q1: if less.length == 0 then m else Math.median(less, true) 
      q2: m 
      q3: if more.length == 0 then m else Math.median(more, true) 
      max: data[data.length - 1]
      min: data[0]

    data 

