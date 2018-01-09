
global.MIN_HISTORY_INFLUENCE = .01

frames_for_weight = (weight) -> 
  Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - weight) + 1

global.check_history_continuation = (engine, depth, weight) -> 
  frames_required = frames_for_weight(weight) 
  
  if engine.num_frames < frames_required
    console.assert false, 
      message: """HISTORY NOT ENOUGH FOR ALPHA"""
      alpha: weight 
      frames_required: frames_required
      frames: engine.num_frames
      depth: depth


  should_continue = MIN_HISTORY_INFLUENCE < Math.pow( (1 - weight), depth)
  should_continue


module.exports = f = {}



f.volume = (engine, args) -> 
  t = args.t
  t2 = args.t2 or t
  weight = args.weight or 1

  k = "#{engine.now - t * engine.resolution}-#{weight}-#{engine.now - t2 * engine.resolution}"

  if k of engine.volume_cache
    return engine.volume_cache[k]
  else
    v = 0
    for i in [t..t2] when i < engine.num_frames

      fb = engine.frame_boundary(i)
      idx = fb[0]
      while idx < fb[1]
        trade = history.trades[idx] 
        v += trade.amount
        idx += 1

    # cut off recursing after the impact of calculating the previous time 
    # frame's velocity is negligible. Note that this method assumes the 
    # initial t = 0!
    should_continue = weight < 1 && check_history_continuation(engine, t, weight)
    if should_continue
      v2 = engine.volume
        t: t + 1
        t2: t2 + 1
        weight: weight 

      v = Math.weighted_average v, v2, weight
      
    engine.volume_cache[k] = v
    v 

f.volume.frames = (args) -> 
  t = args.t or 0
  t + frames_for_weight((args.weight) or 1) + (args.t2 or 0) + 1




f.price = (engine, args) -> 
  weight = args.weight or 1
  t = args.t or 0
  t2 = args.t2 or t


  k = "#{engine.now - t * engine.resolution}-#{engine.now - t2 * engine.resolution}"

  if !(k of engine.price_cache)

    amount = 0
    total = 0
    num = 0
    for i in [t..t2] when i < engine.num_frames

      fb = engine.frame_boundary(i)
      idx = fb[0]
      while idx < fb[1]
        trade = history.trades[idx] 
        amount += trade.amount
        total += trade.total 
        num++
        idx += 1

    engine.price_cache[k] = [amount, total]
  else 
    [amount, total] = engine.price_cache[k]


  if total > 0 
    p = total / amount

    should_continue = weight < 1 && check_history_continuation(engine, t, weight)

    if should_continue
      p2 = engine.price
        t: t + 1
        t2: t2 + 1
        weight: weight 

      p = Math.weighted_average p, p2, weight 
  else 

    p = engine.price 
      t: t + 1
      t2: t2 + 1
      weight: weight

  p 

f.price.frames = (args) -> 
  t = args.t or 0
  t + frames_for_weight((args.weight) or 1) + (args.t2 or 0) + 1



f.min_price = (engine, args) -> 
  t = args.t
  t2 = args.t2 or t
  min = Infinity
  for i in [t..t2] when i < engine.num_frames

    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      if min > trade.rate 
        min = trade.rate 
      idx += 1

  if min == Infinity
    min = engine.last_price args

  min 

f.max_price = (engine, args) -> 
  t = args.t
  t2 = args.t2 or t
  max = 0

  for i in [t..t2] when i < engine.num_frames

    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      if max < trade.rate 
        max = trade.rate 
      idx += 1

  #console.assert max == max2
  if max == 0
    max = engine.last_price args

  max

f.min_price.frames = f.max_price.frames = (args) -> f.last_price.frames(args) + (args.t2 or args.t)


f.last_price = (engine, args) -> 
  t = args.t or 0
  if engine.trades_in_frame(t) > 0
    engine.latest_trade(t).rate
  else 
    engine.last_price t: args.t + 1


f.first_price = (engine, args) -> 
  t = args.t or 0

  if engine.trades_in_frame(t) > 0
    engine.earliest_trade(t).rate
  else 
    engine.last_price t: args.t + 1

f.last_price.frames = f.first_price.frames = (args) -> args.t + 3


f.price_stddev = (engine, args) -> 
  rates = []
  for i in [args.t..args.t2] when i < engine.num_frames
    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      rates.push history.trades[idx].rate
      idx += 1

  if rates.length > 0 
    Math.standard_dev rates 
  else 
    null 

f.price_stddev.frames = (args) -> 
  (args.t or 0) + (args.t2 or 0) + 2

f.volume_adjusted_price_stddev = (engine, args) -> 
  # https://tabbforum.com/opinions/quantifying-intraday-volatility?print_preview=true&single=true
  # http://www.itl.nist.gov/div898/software/dataplot/refman2/ch2/weightsd.pdf

  weighted_mean = engine.price {weight: 1, t: args.t, t2: args.t2}
  weighted_dev = 0
  observations = 0 
  total_volume = 0

  for i in [args.t..args.t2] when i < engine.num_frames
    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      idx += 1
      observations += 1
      weighted_dev += trade.amount * (trade.rate - weighted_mean) * (trade.rate - weighted_mean)
      total_volume += trade.amount 

  if observations > 1 
    weighted_variance = weighted_dev / ( (observations - 1) * total_volume / observations )
    weighted_dev = Math.sqrt weighted_variance
    weighted_dev / weighted_mean  
  else 
    null 

f.volume_adjusted_price_stddev.frames = (args) -> 
  f.price.frames args

f.upwards_vs_downwards_stddev = (engine, args) ->
  up = engine.upwards_volume_adjusted_price_stddev args 
  down = engine.downwards_volume_adjusted_price_stddev args 

  p = up - down
  t = args.t or 0 
  t2 = args.t2 or t
  weight = args.weight or 1

  should_continue = weight < 1 && check_history_continuation(engine, t, weight)
  if should_continue
    p2 = engine.upwards_vs_downwards_stddev
      t: t + 1
      t2: t2 + 1
      weight: weight 

    p = Math.weighted_average p, p2, weight 

  p

f.upwards_vs_downwards_stddev.frames = (args) -> 
  t = args.t or 0
  t2 = args.t2 or t 
  weight = args.weight or 1

  f.upwards_volume_adjusted_price_stddev.frames
    t: frames_for_weight(weight) + t2 + 1



f.upwards_volume_adjusted_price_stddev = (engine, args) -> 

  opening_price = engine.first_price args


  amount = 0
  total = 0
  for i in [args.t..args.t2] when i < engine.num_frames
    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      idx += 1
      continue if trade.rate < opening_price
      amount += trade.amount
      total += trade.total 

  return 0 if amount == 0

  weighted_mean = total / amount


  weighted_dev = 0
  observations = 0 
  total_volume = 0

  for i in [args.t..args.t2] when i < engine.num_frames
    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      idx += 1
      continue if trade.rate < opening_price
      observations += 1
      weighted_dev += trade.amount * (trade.rate - weighted_mean) * (trade.rate - weighted_mean)
      total_volume += trade.amount 

  if observations > 1 
    weighted_variance = weighted_dev / ( (observations - 1) * total_volume / observations )
    weighted_dev = Math.sqrt weighted_variance
    weighted_dev / weighted_mean  
  else 
    0 

f.downwards_volume_adjusted_price_stddev = (engine, args) -> 

  opening_price = engine.first_price args

  amount = 0
  total = 0
  for i in [args.t..args.t2] when i < engine.num_frames
    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      idx += 1
      continue if trade.rate > opening_price
      amount += trade.amount
      total += trade.total 

  return 0 if amount == 0

  weighted_mean = total / amount

  weighted_dev = 0
  observations = 0 
  total_volume = 0

  for i in [args.t..args.t2] when i < engine.num_frames
    fb = engine.frame_boundary(i)
    idx = fb[0]
    while idx < fb[1]
      trade = history.trades[idx] 
      idx += 1
      continue if trade.rate > opening_price
      observations += 1
      weighted_dev += trade.amount * (trade.rate - weighted_mean) * (trade.rate - weighted_mean)
      total_volume += trade.amount 

  if observations > 1
    weighted_variance = weighted_dev / ( (observations - 1) * total_volume / observations )
    weighted_dev = Math.sqrt weighted_variance
    weighted_dev / weighted_mean  
  else 
    0 

f.upwards_volume_adjusted_price_stddev.frames = f.downwards_volume_adjusted_price_stddev.frames = (args) ->
  2 + Math.max(engine.first_price.frames(args), (args.t2 or args.t or 0))

f.stddev_by_volume = (engine, args) -> 
  volume = engine.volume args 
  stddev = engine.volume_adjusted_price_stddev args 

  stddev / (volume + 1)

f.stddev_by_volume.frames = (args) -> 
  Math.max engine.volume.frames(args), engine.volume_adjusted_price_stddev(args)


# velocity is derivative of price
f.velocity = (engine, args) -> 

  weight = args.weight or 1
  t = args.t or 0

  k = "#{engine.now - t * engine.resolution}-#{weight}"

  if k of engine.velocity_cache 
    return engine.velocity_cache[k]
  else 
    p0 = engine.price t: t
    p1 = engine.price t: t + 1
    
    dy = if !p1? || p1 == null then 0 else p0 - p1

    # cut off recursing after the impact of calculating the previous time 
    # frame's velocity is negligible. Note that this method assumes the 
    # initial t = 0!
    should_continue = weight != 1 && check_history_continuation(engine, t, weight)
    if should_continue
      v2 = engine.velocity
        t: t + 1
        weight: weight         
      dy = Math.weighted_average dy, v2, weight
      
    engine.velocity_cache[k] = dy
    dy 

f.velocity.frames = (args) -> 
  t = args.t or 0
  t2 = args.t2 or t 
  weight = args.weight or 1

  f.price.frames
    t: frames_for_weight(weight) + t2 + 1



f.acceleration = (engine, args) -> 

  weight = args.weight or 1
  vel_weight = args.vel_weight or 1
  t = args.t or 0

  k = "#{engine.now - t * engine.resolution}-#{weight}"

  if k of engine.acceleration_cache 
    return engine.acceleration_cache[k]
  else 

    v0 = engine.velocity t: t, weight: vel_weight
    v1 = engine.velocity t: t + 1, weight: vel_weight

    dy = if !v1? || v1 == null then 0 else v0 - v1

    # cut off recursing after the impact of calculating the previous time 
    # frame's velocity is negligible. Note that this method assumes the 
    # initial t = 0!
    should_continue = weight != 1 && check_history_continuation(engine, t, weight)
    if should_continue
      a2 = engine.acceleration
        t: t + 1
        weight: weight
        vel_weight: vel_weight
      dy = Math.weighted_average dy, a2, weight 

    engine.acceleration_cache[k] = dy
    dy

f.acceleration.frames = (args) -> 
  t = args.t or 0
  t2 = args.t2 or t 
  weight = args.weight or 1
  vel_weight = args.vel_weight or 1

  f.velocity.frames
    t: t + frames_for_weight(args.weight or 1) + t2 + 1
    weight: vel_weight


# relative strength index
f.RSI = (engine, args) -> 
  gain = 0 
  loss = 0 

  periods = Math.ceil(1 / args.weight)
  for p in [args.t..args.t + periods - 1]
    cur = engine.price({t: p})
    prev = engine.price({t: p + 1})
    if cur > prev 
      gain += cur - prev 
    else 
      loss += prev - cur 

  RS = gain / loss
  RSI = 100 - 100 / (1 + RS)

  # TODO: why the difference between alpha and weight??!?
  alpha = 1
  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if should_continue
    rsi2 = engine.RSI
      t: args.t + 1
      weight: args.weight 
    RSI = Math.weighted_average RSI, rsi2, alpha 

  RSI

f.RSI.frames = (args) -> 
  t = args.t + Math.ceil(1 / args.weight)
  alpha = 1
  f.price.frames({t: t + frames_for_weight(alpha), weight: args.weight}) + 1
           


f.MACD_signal = (engine, args) -> 

  # MACD_line: (12-day EMA - 26-day EMA)
  # signal_line: 9-day EMA of MACD Line
  # calculated from MACD function: MACD_histogram = MACD Line - Signal Line

  short_weight = args.weight
  long_weight = args.weight * 12/26
  MACD_weight = Math.min .9, args.weight * 12/9

  day12_price = engine.price {t: args.t, weight: short_weight}
  day26_price = engine.price {t: args.t, weight: long_weight}

  MACD = day12_price - day26_price

  should_continue = MACD_weight != 1 && check_history_continuation(engine, args.t, MACD_weight)
  if should_continue
    MACD = MACD_weight * MACD + (1 - MACD_weight) * engine.MACD_signal({t: args.t + 1, weight: MACD_weight})

  MACD

f.MACD = (engine, args) -> 
  short_weight = args.weight
  long_weight = args.weight * 12/26

  day12_price = engine.price {t: args.t, weight: short_weight}
  day26_price = engine.price {t: args.t, weight: long_weight}

  MACD = day12_price - day26_price
  signal = engine.MACD_signal args 

  MACD - signal 

f.MACD.frames = f.MACD_signal.frames = (args) -> 
  weight = args.weight * 12/26
  MACD_weight = Math.min .9, args.weight * 12/9
  t = (args.t or 0)

  frames = f.price.frames
    t: t + frames_for_weight(MACD_weight) + 1
    weight: weight

  frames 



f.DI_plus = (engine, args) -> 
  alpha = args.weight or 1

  # t2t = Date.now() if config.log
  ATR = engine.ATR({t: args.t, weight: alpha})
  v = 100 * engine.DM_plus({t: args.t})
  # by_feature.DI_plus ?= 0
  # by_feature.DI_plus -= Date.now() - t2t if t_?

  if v / ATR == Infinity
    v = 0
  else 
    v /= ATR

  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if !should_continue
    v
  else 
    alpha * v + (1 - alpha) * engine.DI_plus({t: args.t + 1, weight: alpha})

f.DI_minus = (engine, args) -> 
  alpha = args.weight or 1

  # t2t = Date.now() if config.log
  ATR = engine.ATR({t: args.t, weight: alpha})
  v = 100 * engine.DM_minus({t: args.t})
  # by_feature.DI_minus ?= 0
  # by_feature.DI_minus -= Date.now() - t2t if t_?

  if v / ATR == Infinity
    v = 0
  else 
    v /= ATR

  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if !should_continue
    v
  else 
    alpha * v + (1 - alpha) * engine.DI_minus({t: args.t + 1, weight: alpha})

f.DI_plus.frames = f.DI_minus.frames = (args) ->
  alpha = args.weight or 1
  t = (args.t or 0)

  Math.max(f.DM_plus.frames({t: t + frames_for_weight(alpha)}), \
           f.ATR.frames({t: t + frames_for_weight(alpha), weight: alpha})) + 1
           


f.DM_plus = (engine, args) -> 

  p = args.t
  alpha = args.weight or 1

  # t2t = Date.now() if config.log
  cur_high = engine.max_price({t: p})
  prev_high = engine.max_price({t: p + 1})
  cur_low = engine.min_price({t: p})
  prev_low = engine.min_price({t: p + 1})

  # by_feature.DM_plus ?= 0
  # by_feature.DM_plus -= Date.now() - t2t if t_?


  dir_high = cur_high - prev_high
  dir_high = 0 if dir_high < 0 

  dir_low = prev_low - cur_low
  dir_low = 0 if dir_low < 0 

  v = if dir_high > dir_low && dir_high > 0 then dir_high else 0

  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if !should_continue
    v
  else 
    alpha * v + (1 - alpha) * engine.DM_plus({t: args.t + 1, weight: alpha})


f.DM_minus = (engine, args) -> 
  p = args.t
  alpha = args.weight or 1

  # t2t = Date.now() if config.log
  cur_high = engine.max_price({t: p})
  prev_high = engine.max_price({t: p + 1})
  cur_low = engine.min_price({t: p})
  prev_low = engine.min_price({t: p + 1})

  # by_feature.DM_minus ?= 0
  # by_feature.DM_minus -= Date.now() - t2t if t_?


  dir_high = cur_high - prev_high
  dir_high = 0 if dir_high < 0 
  dir_low = prev_low - cur_low
  dir_low = 0 if dir_low < 0 

  v = if dir_low > dir_high && dir_low > 0 then dir_low else 0 

  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if !should_continue
    v
  else 
    alpha * v + (1 - alpha) * engine.DM_minus({t: args.t + 1, weight: alpha})


f.DM_plus.frames = f.DM_minus.frames = (args) -> 
  f.max_price.frames
    t: (args.t or 0) + 1 + frames_for_weight(args.weight or 1)
           


# average true range
f.ATR = (engine, args) -> 
  p = args.t

  # t2t = Date.now() if config.log

  cur_high = engine.max_price({t: p})
  cur_low = engine.min_price({t: p})

  # by_feature.ATR ?= 0
  # by_feature.ATR -= Date.now() - t2t if t_?


  tr = Math.abs cur_high - cur_low

  alpha = args.weight
  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if should_continue
    m2 = engine.ATR
      t: args.t + 1
      weight: args.weight 
    tr = Math.weighted_average tr, m2, alpha 
  tr

f.ATR.frames = (args) ->
  f.max_price.frames
    t: (args.t or 0) + frames_for_weight(args.weight or 1)



# average directional index
f.ADX = (engine, args) -> 
  dx = 0

  periods = Math.ceil(1 / args.weight)
  for p in [args.t..args.t + periods - 1]
    plus = engine.DI_plus({weight: args.weight, t: p})
    minus = engine.DI_minus({weight: args.weight, t: p})
    
    if plus + minus > 0 
      dx += Math.abs(plus - minus) / (plus + minus)

  ADX = 100 * dx / periods 
  alpha = 1
  should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  if should_continue
    adx2 = engine.ADX
      t: args.t + 1
      weight: args.weight 
    ADX = Math.weighted_average ADX, adx2, alpha 
  ADX

f.ADX.frames = (args) ->
  alpha = args.weight
  t = args.t or 0
  f.DI_plus.frames({t: t + frames_for_weight(alpha)}) + 1
           

