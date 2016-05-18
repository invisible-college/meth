
require './shared'

global.MIN_HISTORY_INFLUENCE = .1


default_features = 

  trades: (engine, args) ->
    sum = 0
    sum += engine.frames[i].length for i in [args.t..args.t2] when i < engine.frames.length
    sum 

  volume: (engine, args) -> 
    sum = 0
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        sum += trade.amount  
    sum 

  volume_median: (engine, args) -> 

    vols = []
    for i in [args.t..args.t2] when i < engine.frames.length
      vols.push engine.volume t: i 
      
    Math.median vols


  price: (engine, args) -> 
    args.weight ||= 1

    amount = 0
    total = 0
    for i in [args.t..args.t2] when i < engine.frames.length
      for trade in (engine.frames[i] or [])
        amount += trade.amount
        total += trade.total 


    if amount > 0 
      p = total / amount
    else 
      p = engine.price {t: args.t + 1, t2: args.t2 + 1, weight: args.weight}
    
    should_continue = args.weight != 1 && check_history_continuation(engine, args.t, args.weight)
    if should_continue
      p2 = engine.price
        t: args.t + 1
        weight: args.weight 

      p = Math.weighted_average p, p2, args.weight 

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
    engine.frames[args.t]?[0]?.rate or engine.last_price t: args.t + 1


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
    args.weight ||= 1

    p0 = engine.price t: args.t
    p1 = engine.price t: args.t + 1

    dy = Math.derivative p0, p1 

    # cut off recursing after the impact of calculating the previous time 
    # frame's velocity is negligible. Note that this method assumes the 
    # initial t = 0!
    should_continue = args.weight != 1 && check_history_continuation(engine, args.t, args.weight)
    if should_continue
      v2 = engine.velocity
        t: args.t + 1
        weight: args.weight 
      Math.weighted_average dy, v2, args.weight 
    else
      dy 

  velocity_median: (engine, args) -> 
    vels = []
    for i in [args.t..args.t2] when i < engine.frames.length
      vels.push Math.abs(engine.velocity({t: i, weight: args.weight}))
      
    Math.median vels


  acceleration: (engine, args) -> 
    args.weight ||= 1

    v0 = engine.velocity t: args.t
    v1 = engine.velocity t: args.t + 1

    dy = Math.derivative v0, v1 

    # cut off recursing after the impact of calculating the previous time 
    # frame's velocity is negligible. Note that this method assumes the 
    # initial t = 0!
    should_continue = args.weight != 1 && check_history_continuation(engine, args.t, args.weight)
    if should_continue
      a2 = engine.acceleration
        t: args.t + 1
        weight: args.weight 
      Math.weighted_average dy, a2, args.weight 
    else  
      dy 


  bullishness: (engine, args) -> 
    velocity = engine.velocity t: args.t, weight: args.weight
    acceleration = engine.acceleration t: args.t, weight: args.weight

    if velocity > 0 
      velocity + velocity * acceleration
    else 
      velocity - velocity * acceleration



check_history_continuation = (engine, depth, weight) -> 
  frames_required = Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - weight)

  
  if engine.frames.length < frames_required - 1
    if false 
      console.trace()
      throw """HISTORY NOT ENOUGH FOR ALPHA #{weight}...should have at least 
               #{Math.ceil(frames_required)}, but has #{engine.frames.length}"""

  MIN_HISTORY_INFLUENCE < Math.pow (1 - weight), depth



f = module.exports = 

  # don't want to have to define feature on all 
  features: {}

  define_feature: (name, func) ->
    f.features[name] = func 

  create: (frame_width) -> 
    ticks = 0 

    engine = 
      cache: {}
      cache_cache: {}
      frames: null
      frame_width: frame_width
      last_cleared: null
      ticks: 0 

      # assumes that trades is sorted newest first 
      tick: (trades) -> 
        engine.ticks++ 

        # clear cache every once in awhile
        if engine.ticks % 100 == 0
          engine.cache = engine.cache_cache
          engine.cache_cache = {}
          engine.last_cleared ||= engine.now

        # quantize trades into frames
        num_frames = engine.num_frames + engine.max_t2

        engine.now = tick.time 
        engine.last_cleared ||= engine.now

        engine.frames = ([] for i in [0..num_frames])

        last_frame = null 
        start = 0 
        end = 0 
        t1t = Date.now()
        for trade, idx in trades 
          frame = ((tick.time - trade.date) / frame_width) | 0 # faster Math.floor

          continue if frame > num_frames

          if frame != last_frame && idx != 0
            engine.frames[last_frame] = trades.slice(start, end + 1)
            start = idx

          end = idx 
          last_frame = frame 
        t_.quant += Date.now() - t1t if t_?


        # it is really bad for feature computation if the last frame is empty, 
        # especially in weighted features. 
        # e.g. what should price return if there are consecutive empty frames? 
        # We handle this case by backfilling a trade from a future frame.
        if engine.frames[num_frames].length == 0 
          for i in [num_frames - 1..0] when i > -1 
            if engine.frames[i].length > 0 
              engine.frames[num_frames].push engine.frames[i][engine.frames[i].length - 1]
              break 


    for name, func of f.features
      do (name, func) -> 
        engine[name] = (args) -> 
          args ||= {}
          args.t ||= 0
          args.t2 ||= args.t
          args.weight ||= 1

          if args.t > engine.frames.length - 1 # && false
            console.log "WHA!?", name, args, engine.frames.length
            # console.trace()
            0 
          else 
            key = "#{name}-#{engine.now - args.t * engine.frame_width}-#{engine.now - args.t2 * engine.frame_width}-#{args.weight}" 
            
            if !engine.cache[key]
              engine.cache[key] = func engine, args

            if !engine.cache_cache[key]
              engine.cache_cache[key] = engine.cache[key]

            engine.cache[key]

    engine 


for name, func of default_features
  f.define_feature name, func 



subarray = (arr, start, end) -> 
  a: arr
  start: start 
  end: end 
  get: (idx) -> 
    arr[this.start + idx]
  length: end - start

