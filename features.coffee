require './shared'

global.MIN_HISTORY_INFLUENCE = .001

check_history_continuation = (engine, depth, weight) -> 
  frames_required = Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - weight)
  
  console.assert engine.frames.length >= frames_required - 1, 
    message: """HISTORY NOT ENOUGH FOR ALPHA #{weight}...should have at least 
                #{Math.ceil(frames_required)}, but has #{engine.frames.length}"""

  should_continue = MIN_HISTORY_INFLUENCE < Math.pow (1 - weight), depth
  should_continue


f = module.exports = 

  # don't want to have to define feature on all 
  features: {}


  define_feature: (name, func) ->
    f.features[name] = func 

  create: (frame_width) -> 

    engine = 
      frame_width: frame_width

      reset: ->
        engine = extend engine, 
          cache: {}
          next_cache: {}
          price_cache: {}
          velocity_cache: {}
          acceleration_cache: {}
          volume_cache: {}
          frames: null
          ticks: 0 
          now: null
          last: null


        for name, func of f.features
          engine[name] = initialize_feature engine, name, func
          engine.cache[name] = {}
          engine.next_cache[name] = {}
        engine 

      # assumes trades is sorted newest first       
      tick: (trades) -> 
        engine.ticks++ 

        # clear cache every once in awhile
        if !engine.cache? || engine.ticks % 300 == 299
          engine.cache = engine.next_cache
          engine.next_cache = {}
          engine.price_cache = {}
          engine.velocity_cache = {}
          engine.acceleration_cache = {}
          engine.volume_cache = {}
          for name, func of f.features
            engine.next_cache[name] = {} 

        # quantize trades into frames
        num_frames = engine.num_frames + engine.max_t2

        frames = engine.frames = ([] for i in [0..num_frames - 1])

        last_frame = null 
        start = 0 
        end = 0 
        
        tick_time = tick.time

        # this loop is super performance sensitive!!        
        #t1t = Date.now() if config.log
        for trade, idx in trades 

          if config.simulation && tick.time < trade.date
            console.assert false, 
              message: 'Future trades pumped into feature engine'
              trade: trade 
              time: tick.time

          frame = ((tick_time - trade.date) / frame_width) | 0 # faster Math.floor

          break if frame > num_frames

          if frame != last_frame && idx != 0
            frames[last_frame] = trades.slice(start, end + 1)
            start = idx

          end = idx 
          last_frame = frame 

        #t_.quant += Date.now() - t1t if t_?

        
        # it is really bad for feature computation if the last frame is empty, 
        # especially in weighted features. 
        # e.g. what should price return if there are consecutive empty frames? 
        # We handle this case by backfilling a trade from the later frame.

        
        enough_trades = true 
        if frames[num_frames - 1].length == 0 
          enough_trades = false
          for i in [num_frames - 2..0] when i > -1 
            if frames[i].length > 0 
              enough_trades = true 
              frames[num_frames - 1].push frames[i][frames[i].length - 1]              
              break 

        engine.trades_loaded = enough_trades

        if engine.now != tick_time
          engine.last = engine.now
          engine.now = tick_time 


    engine.reset()
    engine


initialize_feature = (engine, name, func) -> 

  (args) -> 
    xxx = Date.now()
    e = engine
    cache = e.cache[name]
    next_cache = e.next_cache[name]
    now = e.now
    frame_width = e.frame_width

    t = args?.t or 0
    t2 = args?.t2 or t
    weight = args?.weight or 1
    vel_weight = args?.vel_weight or ''

    ```
    key = `${now - t * frame_width}-${now - t2 * frame_width}-${weight}-${vel_weight}`
    ```

    val = cache[key]

    if !val?

      args ?= {t: 0, t2: 0, weight: 1}
      args.t ?= 0
      args.t2 ?= args.t  
      args.weight ?= 1

      len = e.frames.length

      if args.t > len - 1
        flengths = (frame.length for frame in e.frames)
        console.assert false, {message: "WHA!?", name: name, args: args, frames: len, flengths: flengths}
      else 
        val = cache[key] = func e, args

    if !(key of next_cache)
      next_cache[key] = val


    t_.x += Date.now() - xxx if t_?
    val


default_features = 

  trades: (engine, args) ->
    sum = 0
    sum += engine.frames[i].length for i in [args.t..args.t2] when i < engine.frames.length
    sum 

  volume: (engine, args) -> 
    t = args.t
    t2 = args.t2 or t
    weight = args.weight or 1

    ```
    k = `${engine.now - t * engine.frame_width}-${weight}-${engine.now - t2 * engine.frame_width}`
    ```

    if k of engine.volume_cache
      return engine.volume_cache[k]
    else
      v = 0
      for i in [t..t2] when i < engine.frames.length
        for trade in (engine.frames[i] or [])
          v += trade.amount  

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



  volume_median: (engine, args) -> 

    vols = []
    for i in [args.t..args.t2] when i < engine.frames.length
      vols.push engine.volume t: i 
      
    Math.median vols


  price: (engine, args) -> 
    weight = args.weight or 1
    t = args.t or 0
    t2 = args.t2 or t

    ```
    k = `${engine.now - t * engine.frame_width}-${engine.now - t2 * engine.frame_width}`
    ```

    if !(k of engine.price_cache)
      amount = 0
      total = 0
      num = 0
      for i in [t..t2] when i < engine.frames.length
        for trade in (engine.frames[i] or [])
          amount += trade.amount
          total += trade.total 
          num++

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
      p = engine.price {t: t + 1, t2: t2 + 1, weight: weight}

    p 




  min_price: (engine, args) -> 

    min = Infinity
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        if min > trade.rate 
          min = trade.rate 

    if min == Infinity
      min = engine.last_price args

    min 

  max_price: (engine, args) -> 
    max = 0
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        if max < trade.rate 
          max = trade.rate 

    if max == 0
      max = engine.last_price args

    max 


  last_price: (engine, args) -> 
    args.t ||= 0

    if engine.frames[args.t]?[0]?
      engine.frames[args.t][0].rate
    else 
      engine.last_price t: args.t + 1

  first_price: (engine, args) -> 
    args.t ||= 0

    if engine.frames[args.t]?.length > 0 
      engine.frames[args.t][engine.frames[args.t].length - 1].rate
    else 
      engine.last_price t: args.t + 1



  price_stddev: (engine, args) -> 
    rates = []
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        rates.push trade.rate 

    if rates.length > 0 
      Math.standard_dev rates 
    else 
      null 

  volume_adjusted_price_stddev: (engine, args) -> 
    # https://tabbforum.com/opinions/quantifying-intraday-volatility?print_preview=true&single=true
    # http://www.itl.nist.gov/div898/software/dataplot/refman2/ch2/weightsd.pdf

    weighted_mean = engine.price {weight: 1, t: args.t, t2: args.t2}
    weighted_dev = 0
    observations = 0 
    total_volume = 0

    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        observations += 1
        weighted_dev += trade.amount * (trade.rate - weighted_mean) * (trade.rate - weighted_mean)
        total_volume += trade.amount 

    if observations > 1 
      weighted_variance = weighted_dev / ( (observations - 1) * total_volume / observations )
      weighted_dev = Math.sqrt weighted_variance
      weighted_dev / weighted_mean  
    else 
      null 

  upwards_vs_downwards_stddev: (engine, args) ->
    up = engine.upwards_volume_adjusted_price_stddev args 
    down = engine.downwards_volume_adjusted_price_stddev args 

    p = up - down
    t = args.t or 0 
    t2 = args.t2 or t
    weight = args.weight or 1

    should_continue = weight < 1 && check_history_continuation(engine, t, weight)
    if should_continue
      p2 = engine.price
        t: t + 1
        t2: t2 + 1
        weight: weight 

      p = Math.weighted_average p, p2, weight 

    p

  upwards_volume_adjusted_price_stddev: (engine, args) -> 


    opening_price = engine.first_price args


    amount = 0
    total = 0
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or []) when trade.rate >= opening_price
        amount += trade.amount
        total += trade.total 

    return 0 if amount == 0

    weighted_mean = total / amount


    weighted_dev = 0
    observations = 0 
    total_volume = 0

    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or []) when trade.rate >= opening_price
        observations += 1
        weighted_dev += trade.amount * (trade.rate - weighted_mean) * (trade.rate - weighted_mean)
        total_volume += trade.amount 

    if observations > 1 
      weighted_variance = weighted_dev / ( (observations - 1) * total_volume / observations )
      weighted_dev = Math.sqrt weighted_variance
      weighted_dev / weighted_mean  
    else 
      0 

  downwards_volume_adjusted_price_stddev: (engine, args) -> 

    opening_price = engine.first_price args

    amount = 0
    total = 0
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or []) when trade.rate <= opening_price
        amount += trade.amount
        total += trade.total 

    return 0 if amount == 0

    weighted_mean = total / amount

    weighted_dev = 0
    observations = 0 
    total_volume = 0

    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or []) when trade.rate <= opening_price
        observations += 1
        weighted_dev += trade.amount * (trade.rate - weighted_mean) * (trade.rate - weighted_mean)
        total_volume += trade.amount 

    if observations > 1
      weighted_variance = weighted_dev / ( (observations - 1) * total_volume / observations )
      weighted_dev = Math.sqrt weighted_variance
      weighted_dev / weighted_mean  
    else 
      0 

  stddev_by_volume: (engine, args) -> 
    volume = engine.volume args 
    stddev = engine.volume_adjusted_price_stddev args 

    stddev / (volume + 1)

  # velocity is derivative of price
  velocity: (engine, args) -> 

    weight = args.weight or 1
    t = args.t or 0

    ```
    k = `${engine.now - t * engine.frame_width}-${weight}`
    ```
    if k of engine.velocity_cache 
      return engine.velocity_cache[k]
    else 

      p0 = engine.price t: t
      p1 = engine.price t: t + 1
      
      #dy = Math.derivative p0, p1 
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

  velocity_median: (engine, args) -> 
    vels = []
    for i in [args.t..args.t2] when i < engine.frames.length
      vels.push Math.abs(engine.velocity({t: i, weight: args.weight}))
      
    Math.median vels


  acceleration: (engine, args) -> 


    weight = args.weight or 1
    vel_weight = args.vel_weight or 1
    t = args.t or 0

    ```
    k = `${engine.now - t * engine.frame_width}-${weight}-${vel_weight}`
    ```
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

  # relative strength index
  RSI: (engine, args) -> 
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

    # console.log '\n', {RS, RSI, gain, loss}

    # TODO: why the difference between alpha and weight??!?
    alpha = 1
    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if should_continue
      rsi2 = engine.RSI
        t: args.t + 1
        weight: args.weight 
      RSI = Math.weighted_average RSI, rsi2, alpha 

    RSI


  MACD_signal: (engine, args) -> 

    # MACD_line: (12-day EMA - 26-day EMA)
    # signal_line: 9-day EMA of MACD Line
    # calculated from MACD function: MACD_histogram = MACD Line - Signal Line

    short_weight = args.weight
    long_weight = args.weight * 12/26
    MACD_weight = Math.min 1, args.weight * 12/9

    day12_price = engine.price {t: args.t, weight: short_weight}
    day26_price = engine.price {t: args.t, weight: long_weight}

    MACD = day12_price - day26_price

    should_continue = MACD_weight != 1 && check_history_continuation(engine, args.t, MACD_weight)
    if should_continue
      MACD = MACD_weight * MACD + (1 - MACD_weight) * engine.MACD_signal({t: args.t + 1, weight: MACD_weight})

    MACD

  MACD: (engine, args) -> 
    short_weight = args.weight
    long_weight = args.weight * 12/26

    day12_price = engine.price {t: args.t, weight: short_weight}
    day26_price = engine.price {t: args.t, weight: long_weight}

    MACD = day12_price - day26_price
    signal = engine.MACD_signal args 

    MACD - signal 



  DI_plus: (engine, args) -> 
    ATR = engine.ATR(args)
    v = 100 * engine.DM_plus({t: args.t})

    if v / ATR == Infinity
      v = 0
    else 
      v /= ATR

    alpha = args.weight
    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if !should_continue
      v
    else 
      alpha * v + (1 - alpha) * engine.DI_plus({t: args.t + 1, weight: alpha})


  DI_minus: (engine, args) -> 
    ATR = engine.ATR(args)
    v = 100 * engine.DM_minus({t: args.t})

    if v / ATR == Infinity
      v = 0
    else 
      v /= ATR

    alpha = args.weight
    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if !should_continue
      v
    else 
      alpha * v + (1 - alpha) * engine.DI_minus({t: args.t + 1, weight: alpha})


  DM_plus: (engine, args) -> 

    p = args.t
    alpha = args.weight 

    cur_high = engine.max_price({t: p})
    prev_high = engine.max_price({t: p + 1})
    dir_high = cur_high - prev_high
    dir_high = 0 if dir_high < 0 

    cur_low = engine.min_price({t: p})
    prev_low = engine.min_price({t: p + 1})
    dir_low = prev_low - cur_low
    dir_low = 0 if dir_low < 0 

    v = if dir_high > dir_low && dir_high > 0 then dir_high else 0

    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if !should_continue
      v
    else 
      alpha * v + (1 - alpha) * engine.DM_plus({t: args.t + 1, weight: alpha})


  DM_minus: (engine, args) -> 
    p = args.t
    alpha = args.weight

    cur_high = engine.max_price({t: p})
    prev_high = engine.max_price({t: p + 1})
    dir_high = cur_high - prev_high
    dir_high = 0 if dir_high < 0 

    cur_low = engine.min_price({t: p})
    prev_low = engine.min_price({t: p + 1})
    dir_low = prev_low - cur_low
    dir_low = 0 if dir_low < 0 

    v = if dir_low > dir_high && dir_low > 0 then dir_low else 0 

    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if !should_continue
      v
    else 
      alpha * v + (1 - alpha) * engine.DM_minus({t: args.t + 1, weight: alpha})


  # average true range
  ATR: (engine, args) -> 
    p = args.t

    cur_high = engine.max_price({t: p})
    cur_low = engine.min_price({t: p})

    tr = Math.abs cur_high - cur_low

    alpha = args.weight
    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if should_continue
      m2 = engine.ATR
        t: args.t + 1
        weight: args.weight 
      tr = Math.weighted_average tr, m2, alpha 
    tr


  # average directional index
  ADX: (engine, args) -> 
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

for name, func of default_features
  f.define_feature name, func 



