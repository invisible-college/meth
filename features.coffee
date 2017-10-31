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

          if tick.time < trade.date
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
        console.assert false, {message: "WHA!?", name: name, args: args, frames: len}
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


  price_stddev: (engine, args) -> 
    rates = []
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        rates.push trade.rate 

    if rates.length > 0 
      Math.standard_dev rates 
    else 
      null 
    

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

    alpha = .2
    should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
    if should_continue
      rsi2 = engine.RSI
        t: args.t + 1
        weight: args.weight 
      RSI = Math.weighted_average RSI, rsi2, alpha 

    RSI

  # plus directional indicator
  # DI_plus: (engine, args) -> 
  #   plus = 0 

  #   periods = 1 #Math.ceil(1 / args.weight)
  #   p = 0

  #   #for p in [args.t..args.t + periods - 1]
  #   cur_high = engine.max_price({t: 0})
  #   prev_high = engine.max_price({t: 1})
  #   dir_high = cur_high - prev_high
  #   dir_high = 0 if dir_high < 0 

  #   cur_low = engine.min_price({t: p})
  #   prev_low = engine.min_price({t: p + 1})
  #   dir_low = prev_low - cur_low
  #   dir_low = 0 if dir_low < 0 

  #   plus += dir_high if dir_high > dir_low

  #   #plus /= periods * engine.ATR({t: args.t}) #args)

  #   # plus /= cur_high

  #   alpha = args.weight
  #   should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  #   if should_continue
  #     m2 = engine.DI_plus
  #       t: args.t + 1
  #       weight: args.weight 
  #     plus = alpha * plus + (1 - alpha) * m2 #Math.weighted_average plus, m2, alpha 
  #   plus


  # minus directional indicator
  # DI_minus: (engine, args) -> 
  #   minus = 0 

  #   periods = 1 #Math.ceil(1 / args.weight)
  #   p = 0

  #   # for p in [args.t..args.t + periods - 1]
  #   cur_high = engine.max_price({t: p})
  #   prev_high = engine.max_price({t: p + 1})
  #   dir_high = cur_high - prev_high
  #   dir_high = 0 if dir_high < 0 

  #   cur_low = engine.min_price({t: p})
  #   prev_low = engine.min_price({t: p + 1})
  #   dir_low = prev_low - cur_low
  #   dir_low = 0 if dir_low < 0 

  #   minus += dir_low if dir_low > dir_high

  #   #minus /= periods * engine.ATR({t: args.t})

  #   #minus /= cur_high

  #   alpha = args.weight
  #   should_continue = alpha != 1 && check_history_continuation(engine, args.t, alpha)
  #   if should_continue
  #     m2 = engine.DI_minus
  #       t: args.t + 1
  #       weight: args.weight 
  #     minus = alpha * minus + (1 - alpha) * m2 # Math.weighted_average minus, m2, alpha 
  #   minus


  DI_plus: (engine, args) -> 
    ATR = engine.ATR(args)
    v = 100 * engine.DM_plus(args)

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
    v = 100 * engine.DM_minus(args)

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
    v


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
    v    


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



