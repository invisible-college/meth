require './shared'
fs = require 'fs'
path = require 'path'

default_features = require './features'

feature_engine = module.exports = 

  features: {}
  resolutions: {}
  

  define_feature: (name, func) ->
    feature_engine.features[name] = func 


  create: (resolution) ->
    global.feature_cache = 
      price: {}
      volume: {}
      min_price: {}
      max_price: {}
    if feature_engine.resolutions[resolution]
      engine = feature_engine.resolutions[resolution]
      created = false
      if engine.ticks > 0
        engine.reset() 
      return engine

    engine = 
      resolution: resolution
      ticked_at: []

      subscribe_dealer: (name, dealer, dealer_data) -> 

        for dep in dealer.dependencies 
          [resolution, feature, args] = dep
          if resolution == engine.resolution 

            frame_calc = default_features[feature].frames

            console.assert frame_calc, 
              message: "#{feature} has no frame calculation defined"

            frames_needed = frame_calc(args)

            if isNaN(frames_needed)
              console.assert false, {
                message: "There was a problem calculating frames for #{name}. Check the #{feature}.frames definition.",
                frame_calc
                args
              }
            
            if frames_needed > engine.num_frames
              #console.log 'SETTING', engine.resolution, frames_needed, engine.num_frames
              engine.num_frames = frames_needed

        engine.num_frames = Math.ceil engine.num_frames

      reset: ->
        engine = extend engine, 
          cache: {}
          next_cache: {}
          price_cache: {}
          pprice_cache: {}
          velocity_cache: {}
          acceleration_cache: {}
          volume_cache: {}
          vvolume_cache: {}
          min_price_cache: {}
          max_price_cache: {}
          frames: null
          ticks: 0 
          now: null
          last: null
          num_frames: 1
          ticked_at: []

        for name, func of feature_engine.features
          engine[name] = initialize_feature engine, name, func
          engine.cache[name] = {}
          engine.next_cache[name] = {}
        engine 

      # assumes trades is sorted newest first       
      tick: -> 
        return engine.enough_trades if engine.now == tick.time 
        engine.ticks++ 

        resolution = @resolution
        trade_idx = engine.trade_idx = history.trade_idx or 0

        # clear cache every once in awhile
        if !engine.cache? || engine.ticks % 10000 == 9999
          engine.cache = engine.next_cache
          engine.next_cache = {}
          engine.price_cache = {}
          engine.velocity_cache = {}
          engine.acceleration_cache = {}
          engine.volume_cache = {}
          engine.max_price_cache = {}
          for name, func of feature_engine.features
            engine.next_cache[name] = {} 

        # quantize trades into frames
        num_frames = engine.num_frames

        last_frame = null 
        start = 0 
        end = 0 
        
        tick_time = tick.time

        trades = history.trades
        num_trades = trades.length
        return false if !trades[trade_idx]

        if config.simulation && tick.time < trades[trade_idx].date 
          log_error true,
            message: 'Future trades pumped into feature engine'
            trade: trades[trade_idx] 
            time: tick.time


        last_frame_w = 100
        a = last_boundary = trade_idx 
        frame_boundaries = []
        #t1t = Date.now() if config.log_level > 1
        for frame_boundary in [0..num_frames - 1]
          if a >= num_trades - 1
            a = num_trades - 2
            if a < 0 
              a = 0 

          if !(trades[a]?)
            log_error true,
              message: "No trade history entry for #{a}"
              a: a 
              b: b 
              frame_boundaries: frame_boundaries
              num_trades: num_trades

          b = a + last_frame_w
          fr_a = ((tick_time - trades[a].date) / resolution) | 0  # faster Math.floor
          while b - a > 1
            if b >= num_trades
              b = num_trades - 1

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
        #t_.b += Date.now() - t1t if t_?

          
        # it is really bad for feature computation if the last frame is empty, 
        # especially in weighted features. 
        # e.g. what should price return if there are consecutive empty frames? 
        # We handle this case by backfilling a trade from the later frame.

        
        last_frame = frame_boundaries[frame_boundaries.length - 1]
        enough_trades = last_frame[1] - last_frame[0] > 0

        # if frames[num_frames - 1].length == 0 
        #   enough_trades = false
        #   # for i in [num_frames - 2..0] when i > -1 
        #   #   if frames[i].length > 0 
        #   #     enough_trades = true 
        #   #     frames[num_frames - 1].push frames[i][frames[i].length - 1]              
        #   #     break 

        engine.last = engine.now # deprecated
        engine.now = tick_time
        engine.ticked_at.push tick_time
        engine.trades = trades
        engine.frame_boundaries = frame_boundaries
        engine.frames = {}
        engine.enough_trades = enough_trades

        if engine.ticks % 15000 == 0
          global.feature_cache = 
            price: {}
            volume: {}
            min_price: {}
            max_price: {}
          

        if !engine.enough_trades 
          log_error true, {message: "not enough trades"}

        enough_trades
      
      frame: (i) ->
        if !engine.frames[i]?
          # t2t = Date.now() if config.log_level > 1
          boundary = engine.frame_boundaries[i]
          engine.frames[i] = engine.trades.slice(boundary[0], boundary[1])
          # t_.z += Date.now() - t2t if t_?
        engine.frames[i]

      frame_boundary: (i) -> 
        engine.frame_boundaries[i]

      trades_in_frame: (i) -> 
        boundary = engine.frame_boundaries[i]
        boundary[1] - boundary[0]

      earliest_trade: (i) -> 
        boundary = engine.frame_boundaries[i]
        engine.trades[boundary[1]]

      latest_trade: -> 
        engine.trades[engine.trade_idx]

      write_to_disk: -> 
        cache_dir = './.feature_cache'
        if !fs.existsSync cache_dir
          fs.mkdirSync cache_dir

        fname = "#{config.exchange}-#{config.c1}-#{config.c2}-#{bus.port}-#{engine.resolution}.json"
        fs.writeFileSync path.join(cache_dir, fname), JSON.stringify({next_cache: engine.next_cache, ticked_at: engine.ticked_at})

      load_from_disk: -> 
        cache_dir = './.feature_cache'
        if !fs.existsSync cache_dir
          fs.mkdirSync cache_dir

        fname = "#{config.exchange}-#{config.c1}-#{config.c2}-#{bus.port}-#{engine.resolution}.json"
        if fs.existsSync path.join(cache_dir, fname)
          try 
            from_file = fs.readFileSync(path.join(cache_dir, fname), 'utf8')
            data = JSON.parse(from_file)
            engine.cache = data.next_cache
            engine.ticked_at = data.ticked_at
          catch e 
            console.error {message: "Could not load cache from file", fname, e}

    
    feature_engine.resolutions[resolution] = engine
    engine.reset() 
    engine





global.by_feature = {}
initialize_feature = (engine, name, func) -> 
  all_engines = feature_engine.resolutions

  

  computer = (args) -> 
    # xxx = Date.now()

    e = engine
    if e.now != tick.time 
      yyy = Date.now()      
      e.tick()
      t_.feature_tick += Date.now() - yyy if t_?

    cache = e.cache[name]
    next_cache = e.next_cache[name]
    right_now = e.now
    resolution = e.resolution

    t = args?.t or 0
    t2 = args?.t2 or t
    weight = args?.weight or 1
    vel_weight = args?.vel_weight or ''
    short_resolution = args?.short_resolution or ''
    MACD_weight = args?.MACD_weight or ''
    MACD_feature = args?.MACD_feature or 'price'
    eval_entry_every_n_seconds = args?.eval_entry_every_n_seconds or ''
    confirm_weight = args?.confirm_weight or ''

    key = "#{right_now - t * resolution}-#{right_now - t2 * resolution}-#{weight}-#{vel_weight}-#{short_resolution}-#{MACD_weight}-#{eval_entry_every_n_seconds}-#{MACD_feature}-#{confirm_weight}"

    val = cache[key]

    if !val?
      
      args ?= {t: 0, t2: 0, weight: 1}
      args.t ?= 0
      args.t2 ?= args.t  
      args.weight ?= 1

      len = e.num_frames

      if args.t > len - 1
        flengths = (frame.length for idx, frame of e.frames)
        console.error false, {
          message: "WHA!?"
          resolution
          name
          args
          frames: len
          flengths
        }
      else 
        val = cache[key] = func e, args, all_engines

    if !(key of next_cache)
      next_cache[key] = val

    # t_.x += Date.now() - xxx if t_?
    val

  computer.past_result = (args, right_nowish) -> 
    e = engine

    idx = e.ticked_at.length - 1
    while idx > 0 
      right_now = e.ticked_at[idx]
      if Math.abs(right_now - right_nowish) < Math.abs(e.ticked_at[idx - 1] - right_nowish)
        break 
      idx -= 1

    if Math.abs(right_now - right_nowish) > pusher.tick_interval
      console.log "Not in cache: #{name}", {right_now, right_nowish, tick_interval: pusher.tick_interval, ticked_at: e.ticked_at, idx}  if config.log_level > 2
      return null

    cache = e.cache[name]
    next_cache = e.next_cache[name]
    resolution = e.resolution

    t = args?.t or 0
    t2 = args?.t2 or t
    weight = args?.weight or 1
    vel_weight = args?.vel_weight or ''    
    short_resolution = args?.short_resolution or ''
    MACD_weight = args?.MACD_weight or ''
    MACD_feature = args?.MACD_feature or 'price'
    eval_entry_every_n_seconds = args?.eval_entry_every_n_seconds or ''
    confirm_weight = args?.confirm_weight or ''

    key = "#{right_now - t * resolution}-#{right_now - t2 * resolution}-#{weight}-#{vel_weight}-#{short_resolution}-#{MACD_weight}-#{eval_entry_every_n_seconds}-#{MACD_feature}-#{confirm_weight}"

    val = cache[key]
    if !val?
      console.log "Not in cache: #{name} #{key}" if config.log_level > 2
      return null

    if !(key of next_cache)
      next_cache[key] = val

    val

  computer



for name, func of default_features
  feature_engine.define_feature name, func 
