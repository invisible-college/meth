
if !module?
  module = {}
module.exports = 

  get_settings: (name) ->
    get_settings.cache ||= {}
    if name of get_settings.cache
      return get_settings.cache[name]

    if global? && name[0] == '/'
      name = deslash name

    if name == 'all' || deslash(name) in get_strategies()
      get_settings.cache[name] = null 

    else if fetch(name).settings?
      settings = fetch(name).settings
      get_settings.cache[name] = Object.freeze(bus.clone(settings))

    get_settings.cache[name]

  get_strategies: -> 
    key = if global? then 'operation' else '/operation'
    operation = fetch(key)
    strategies = []
    for name, strategy of operation when name != 'key'
      strategies.push name 
    strategies

  get_dealers: (load_from_cache) -> 

    if get_dealers.cache?
      return get_dealers.cache.slice()

    key = if global? then 'operation' else '/operation'
    operation = if load_from_cache then from_cache(key) else fetch key
    loaded = Object.keys(operation).length > 1

    dealers = []
    for name, strategy of operation when name != 'key'
      for dealer in strategy.dealers
        settings = get_settings(dealer)
        loaded &&= settings?
        if !settings? || !settings.series
          dealer = if global? then deslash(dealer) else dealer
          
          console.assert dealer != 'all', 
            message: 'NO WAY!'
            name: name 
            strategy: strategy
            dealer: dealer


          dealers.push dealer

    if loaded
      get_dealers.cache = dealers

    dealers.slice()

  get_series: (load_from_cache) ->
    if get_series.cache?
      return get_series.cache.slice()

    key = if global? then 'operation' else '/operation'
    operation = if load_from_cache then from_cache(key) else fetch key
    loaded = Object.keys(operation).length > 1

    series = []
    for name, strategy of operation when name != 'key'
      for dealer in strategy.dealers 
        settings = get_settings(dealer)
        loaded &&= settings?
        if settings?.series
          dealer = if global? then deslash(dealer) else dealer
          series.push dealer #from_cache(s).parent
    
    if loaded
      get_series.cache = series

    series.slice()

  get_all_actors: (load_from_cache) -> 
    if get_all_actors.cache?
      return get_all_actors.cache.slice()

    dealers = get_dealers(load_from_cache)
    series = get_series(load_from_cache)
    actors = dealers.slice().concat(series)
    if get_series.cache? && get_dealers.cache?    
      get_all_actors.cache = actors

    actors.slice()

  dealer_params: (name) ->
    dealer_params.cache ||= {}

    if name of dealer_params.cache
      return dealer_params.cache[name]

    parts = name.split('&')
    params = {}

    for p in (parts or [])
      param = p.split('=')
      params[param[0]] = param[1]

    dex = params
    dealer_params.cache[name] = params 
    dex

  dealer_name: (name) -> 

    dealer_name.cache ||= {}
    key = name

    if key of dealer_name.cache 
      dealer_name.cache[key]
    else if name == 'all'
      dealer_name.cache.all = 'all'
      'all'
    else 

      params_cache[name] ?= name.split('&')
      parts = params_cache[name]

      all_params = {}
      for dealer in get_dealers() 
        for param, val of dealer_params(dealer)
          all_params[param] ?= {}
          all_params[param][val] = true 

      differentiating_params = ( "#{param}=#{val}" for param, val of (dealer_params[name] or {}) \
                                              when Object.keys(all_params[param] or {}).length > 1 )

      name = differentiating_params.join(' ')

      dealer_name.cache[key] = name 
      name




  extend: (obj) ->
    obj ||= {}
    for arg, idx in arguments 
      if idx > 0
        for own name,s of arg
          if !obj[name]? || obj[name] != s
            obj[name] = s
    obj

  defaults: (o) ->
    obj = {}

    for arg, idx in arguments by -1      
      for own name,s of arg
        obj[name] = s
    extend(o, obj)

  uniq: (ar) -> 
    ops = {}
    for e in ar
      key = e.key or JSON.stringify(e)
      return false if key of ops 
      ops[key] = 1
    true


  make_global: (exports) -> 
    top = if window? then window else global

    for k,v of exports
      top[k] = v 

  now: -> Math.floor((new Date()).getTime() / 1000)

  get_buy:  (pos) -> 
    if pos.entry.type == 'buy' then pos.entry else pos.exit
  get_sell: (pos) -> 
    if pos.entry.type == 'buy' then pos.exit else pos.entry


  get_name: (base, params, differentiating_params) ->
    if !global? && base[0] != '/'
      name = "/#{base}" 
    else 
      name = base
    for k,v of params
      if differentiating_params && k not of differentiating_params
        continue
        
      if Math.is_num v
        if Math.abs(v) < 1
          v *= 100
        name += "&#{k}=#{v}"
      else
        if v.constructor == Array || v.constructor == Object
          v = JSON.stringify(v)
        name += "&#{k}=#{v}"
    name 

  from_cache: (key) -> 
    if global? && key[0] == '/'
      key = deslash key 
    bus.cache[key] || {key}

  deslash: (key) -> 
    if key?[0] == '/'
      key = key.substr(1)
    else 
      key


  wait_for_bus: (cb) -> 
    if !bus?
      setTimeout -> 
        wait_for_bus(cb)
    else 
      cb()

  get_ip_address: -> 
    ifaces = require('os').networkInterfaces()
    address = null
    for i, details of ifaces
      for detail in details 
        if detail.family == 'IPv4' && detail.internal == false 
          address = detail.address

    address or "localhost"




module.exports.make_global module.exports

extend Math, 

  is_num: (n) -> 
    if n[0] == '$'
      n = n.substring(1)
    f = parseFloat n 
    !isNaN(parseFloat(f)) && isFinite(f) && (n.indexOf && n.indexOf(' ') == -1)

  to_precision: (num, precision) -> 
    precision ||= 1
    parseFloat(num.toPrecision(precision))

  summation:  (data) -> 
    data.reduce((sum, value) ->
      sum + value
    , 0)

  standard_dev:  (values) ->
    avg = Math.average values
    variance = 0 
    for val in values 
      variance += (val - avg) * (val - avg)

    variance /= values.length

    Math.sqrt variance


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

  smma: (series, idx) -> 
    if idx == series.length - 1
      series[idx]
    else
      series[idx] + (1 - 1 / series.length) * Math.smma(series, idx + 1)


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

  greatest_common_divisor: (nums) -> 
    gcd2 = (a,b) -> if !b then a else gcd2(b, a % b)
  
    result = nums[0]
    for num,idx in nums when idx > 0
      result = gcd2 result, num

    result


