require './shared'

default_features = require './features'

feature_engine = module.exports = 

  features: {}
  resolutions: {}

  define_feature: (name, func) ->
    feature_engine.features[name] = func 


  create: (resolution) -> 
    if feature_engine.resolutions[resolution]
      engine = feature_engine.resolutions[resolution]
      created = false
      if engine.ticks > 0
        engine.reset() 
      return engine

    engine = 
      resolution: resolution

      subscribe_dealer: (name, dealer, dealer_data) -> 

        for dep in dealer.dependencies 
          [resolution, feature, args] = dep
          if resolution == engine.resolution 

            frame_calc = default_features[feature].frames

            console.assert frame_calc, 
              message: "#{feature} has no frame calculation defined"

            frames_needed = frame_calc(args)

            console.assert !isNaN(frames_needed), 
              message: "There was a problem calculating frames for #{name}. Check the #{feature}.frames definition."
            
            if frames_needed > engine.num_frames
              #console.log 'SETTING', engine.resolution, frames_needed, engine.num_frames
              engine.num_frames = frames_needed

        engine.num_frames = Math.ceil engine.num_frames

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
          num_frames: 1

        for name, func of feature_engine.features
          engine[name] = initialize_feature engine, name, func
          engine.cache[name] = {}
          engine.next_cache[name] = {}
        engine 

      # assumes trades is sorted newest first       
      tick: (trades) -> 
        return if engine.now == tick.time 

        engine.ticks++ 

        # clear cache every once in awhile
        if !engine.cache? || engine.ticks % 300 == 299
          engine.cache = engine.next_cache
          engine.next_cache = {}
          engine.price_cache = {}
          engine.velocity_cache = {}
          engine.acceleration_cache = {}
          engine.volume_cache = {}
          for name, func of feature_engine.features
            engine.next_cache[name] = {} 

        # quantize trades into frames
        num_frames = engine.num_frames

        frames = engine.frames = ([] for i in [0..num_frames - 1])

        last_frame = null 
        start = 0 
        end = 0 
        
        tick_time = tick.time

        num_trades = trades.length

        if config.simulation && (tick.time < trades[0].date || tick.time < trades[num_trades - 1].date)
          console.assert false, 
            message: 'Future trades pumped into feature engine'
            trade: trade 
            time: tick.time

        # this loop is super performance sensitive!!        
        t1t = Date.now() if config.log

        last_frame_w = 100
        a = last_boundary = 0 
        frame_boundaries = []
        for frame_boundary in [0..num_frames - 1]
          b = a + last_frame_w
          fr_a = ((tick_time - trades[a].date) / resolution) | 0  # faster Math.floor
          while b - a > 1
            if b >= num_trades
              b = num_trades - 1

            idx += 1
            fr_b = ((tick_time - trades[b].date) / resolution) | 0  # faster Math.floor

            if fr_a == fr_b 
              diff = b - a
              a = b 
              b += diff
              
            else 
              b -= ((b - a) / 2) | 0  # faster Math.floor

          if fr_a == fr_b 
            a = b
            b += 1 # sometimes happens from rounding issue with Math.floor

          frame_boundaries.push [last_boundary, b]
          last_frame_w = b - last_boundary
          last_boundary = b
          a = b + 1

        t_.b += Date.now() - t1t if t_?


        t2t = Date.now() if config.log
        for boundary,idx in frame_boundaries
          frames[idx] = trades.slice(boundary[0], boundary[1])
        t_.z += Date.now() - t2t if t_?


          
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

        engine.last = engine.now
        engine.now = tick_time

        enough_trades
    
    feature_engine.resolutions[resolution] = engine
    engine.reset() 
    engine


initialize_feature = (engine, name, func) -> 
  all_engines = feature_engine.resolutions

  (args) -> 
    xxx = Date.now()
    e = engine
    cache = e.cache[name]
    next_cache = e.next_cache[name]
    now = e.now
    resolution = e.resolution

    t = args?.t or 0
    t2 = args?.t2 or t
    weight = args?.weight or 1
    vel_weight = args?.vel_weight or ''

    ```
    key = `${now - t * resolution}-${now - t2 * resolution}-${weight}-${vel_weight}`
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
        val = cache[key] = func e, args, all_engines

    if !(key of next_cache)
      next_cache[key] = val

    t_.x += Date.now() - xxx if t_?
    val



for name, func of default_features
  feature_engine.define_feature name, func 