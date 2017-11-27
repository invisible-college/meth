require './shared'

global.MIN_HISTORY_INFLUENCE = .001

check_history_continuation = (engine, depth, weight) -> 
  frames_required = Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - weight)
  
  console.assert engine.frames.length >= frames_required - 1, 
    message: """HISTORY NOT ENOUGH FOR ALPHA #{weight}...should have at least 
                #{Math.ceil(frames_required)}, but has #{engine.frames.length}"""

  should_continue = MIN_HISTORY_INFLUENCE < Math.pow (1 - weight), depth
  should_continue


feature_engine = module.exports = 

  features: {}
  resolutions: {}

  define_feature: (name, func) ->
    feature_engine.features[name] = func 

  create: (resolution) -> 
    if feature_engine.resolutions[resolution]
      engine = feature_engine.resolutions[resolution]
      created = false
    else 
      engine = 
        resolution: resolution

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

          for name, func of feature_engine.features
            engine[name] = initialize_feature engine, name, func
            engine.cache[name] = {}
            engine.next_cache[name] = {}
          engine 

        # assumes trades is sorted newest first       
        tick: (trades) -> 

          # check if this engine is due to tick
          last_updated = engine.now
          needs_update = !last_updated || tick.time - last_updated >= resolution / engine.checks_per_frame

          return false if !needs_update

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

            frame = ((tick_time - trade.date) / resolution) | 0 # faster Math.floor

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

          if engine.now != tick_time # why the if? isn't this always true?
            engine.last = engine.now
            engine.now = tick_time
          else 
            console.assert false, {msg: 'well I guess we do need this if statement'} 

          enough_trades
      
      created = true 
      feature_engine.resolutions[resolution] = engine

    if engine.ticks > 0 || created
      engine.reset() 
    engine



initialize_feature = (engine, name, func) -> 

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
        val = cache[key] = func e, args 

    if !(key of next_cache)
      next_cache[key] = val


    t_.x += Date.now() - xxx if t_?
    val


default_features = require './features'

for name, func of default_features
  feature_engine.define_feature name, func 



