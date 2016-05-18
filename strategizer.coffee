require './shared'

module.exports = strategizer = 

  crossover: (from_negative, o) -> 
    o.num_consecutive ||= 0 

    checks = o.num_consecutive * 2 + 2

    for t in [0..checks]

      if (from_negative && t < checks / 2) || (!from_negative && t >= checks / 2)
        return false unless o.f({weight: o.f_weight, t: t}) < (o.f2?({weight: o.f2_weight, t: t}) or 0)
           
      else  
        return false unless o.f({weight: o.f_weight, t: t}) > (o.f2?({weight: o.f2_weight, t: t}) or 0)


    return true

  in_percentile: (f, feature, depth, thresh) -> 
    past = (f[feature]({t:i}) for i in [0..depth])
    past.sort()

    idx = past.indexOf f[feature]()

    percentile = idx / past.length
    thresh[0] <= percentile <= thresh[1]    

  frames: (min_weight) -> 
    console.log min_weight, Math.ceil( Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - min_weight))
    
    # the + 4 is for enabling derivative-based features like velocity and acceleration
    4 + Math.ceil( Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - min_weight))

  execute_combos: (strategies, func, base, vars) ->
    vars ||= {}
    _execute_combos strategies, base, vars, {}, func, vars 

  create_panel: (strategies, func, base, strands, deposit) ->
    for strand in strands
      strand.position_amount = deposit / strands.length / 2

      name = get_name base, strand
      strategies[name] = func name, strand
      strategies[name].defaults = strand


get_name = (base, params, all) -> 
  name = base
  for k,v of params when !all || all[k].length > 1
    if is_num v
      if Math.abs(v) < 1
        v *= 100
      name += "&#{k}=#{v}"
    else
      name += "&#{k}=#{v}"
  name 

_execute_combos = (strategies, base, vars, params, func, all) -> 
  if Object.keys(vars).length == 0
    name = get_name(base, params, all) 
    strategies[name] = func name, params 
    strategies[name].defaults = extend {}, params, strategies[name].defaults
  else 
    keys = Object.keys(vars)
    k = Object.keys(vars)[0]

    new_vars = {}
    for key, val of vars when key != k 
      new_vars[key] = val

    for v in vars[k]
      new_params = {}
      for key, val of params 
        new_params[key] = val
      new_params[k] = v

      _execute_combos strategies, base, new_vars, new_params, func, all



make_global module.exports

module.exports.series = 
  price:
    defaults:  
      frames: 1
      frame_width: 5 * 60
      cooloff_period: 0
      position_amount: 1
      series: true

    evaluate_new_position: (f) -> 
      if Math.random() < .5
        pos = 
          buy: 
            rate: f.last_price() #f.price()
            entry: true 
          series_data: "price"
        pos
