require './shared'

module.exports = strategizer = 

  crossover: (from_below, o) -> 
    o.num_consecutive ||= 0 

    checks = o.num_consecutive * 2 + 2

    for t in [0..checks]

      if (from_below && t < checks / 2) || (!from_below && t >= checks / 2)
        return false unless o.f({weight: o.f_weight, t: t}) < (o.cross_at or o.f2?({weight: o.f2_weight, t: t}) or 0)
           
      else  
        return false unless o.f({weight: o.f_weight, t: t}) > (o.cross_at or o.f2?({weight: o.f2_weight, t: t}) or 0)


    return true

  in_percentile: (f, feature, depth, thresh) -> 
    past = (f[feature]({t:i}) for i in [0..depth])
    past.sort()

    idx = past.indexOf f[feature]()

    percentile = idx / past.length
    thresh[0] <= percentile <= thresh[1]    

  required_frames: (min_weight) -> 
    # console.log "required frames for #{min_weight}: ", Math.ceil( Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - min_weight))
    
    # the + 4 is for enabling derivative-based features like velocity and acceleration
    4 + Math.ceil( Math.log(MIN_HISTORY_INFLUENCE) / Math.log(1 - min_weight))


make_global module.exports

module.exports.series = 

  defaults: 
    resolution: 5
    series: true
    never_exits: true

  max_price: (v) -> 
    frames: 1

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < 1

        pos = 
          buy: 
            rate: f.max_price()
            entry: true 
          series_data: "max_price"
        pos

  min_price: (v) -> 
    frames: 1

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < 1

        pos = 
          buy: 
            rate: f.min_price()
            entry: true 
          series_data: "min_price"
        pos




  EMA_price: (v) -> 
    frames: required_frames(v.weight)

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < .5

        pos = 
          buy: 
            rate: f.price({weight: v.weight})
            entry: true 
          series_data: "EMA-#{v.resolution}"
        pos


  volume: (v) -> 
    frames: required_frames(v.weight or 1) + 1

    evaluate_new_position: (args) -> 

      f = args.features
      

      if !v.dummy
        pos = 
          buy: 
            rate: f.volume({weight: v.weight or 1})
            entry: true 
          series_data: "volume"

        pos

  logvolume: (v) -> 
    frames: required_frames(v.weight or 1) + 1

    evaluate_new_position: (args) -> 

      f = args.features
      

      if !v.dummy
        pos = 
          buy: 
            rate: Math.log f.volume({weight: v.weight or 1}) + 1
            entry: true 
          series_data: "volume"

        pos

  price: (v) -> 
    frames: required_frames(v.weight or 1) + 1


    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < 1
        pos = 
          buy: 
            rate: f.price() #f.price()
            entry: true 
          series_data: "price"
        pos


  last_price: (v) -> 
    frames: 1

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < .5
        
        pos = 
          buy: 
            rate: f.last_price() #f.price()
            entry: true 
          series_data: "last_price"
        pos


  velocity: (v) -> 
    frames: required_frames(Math.min(v.weight,.3)) + 2

    evaluate_new_position: (args) -> 
      f = args.features
      pos = 
        buy: 
          rate: f.velocity weight: Math.to_precision(v.weight, 1)
          entry: true 
        series_data: "velocity"
      pos

  acceleration: (v) -> 
    frames: required_frames(Math.min(v.accel_weight,.3)) + 2

    evaluate_new_position: (args) -> 

      f = args.features
      
      pos = 
        buy: 
          rate: f.acceleration weight: Math.to_precision(v.accel_weight, 1)
          entry: true 
        series_data: "acceleration"
      pos


  volatility: (v) -> 
    frames: 2

    evaluate_new_position: (args) -> 
      f = args.features 
      pos = 
        buy: 
          rate: f.volume_adjusted_price_stddev()
          entry: true 
        series_data: "volatility"
      pos

  volume_by_volatility: (v) -> 
    frames: 2

    evaluate_new_position: (args) -> 
      f = args.features 
      pos = 
        buy: 
          rate: f.stddev_by_volume()
          entry: true 
        series_data: "stddev_by_volume"
      pos

  downward_volatility: (v) -> 
    frames: 2

    evaluate_new_position: (args) -> 
      f = args.features 
      pos = 
        buy: 
          rate: f.downwards_volume_adjusted_price_stddev()
          entry: true 
        series_data: "down_vol"
      pos

  upward_volatility: (v) -> 
    frames: 2

    evaluate_new_position: (args) -> 
      f = args.features 
      pos = 
        buy: 
          rate: f.upwards_volume_adjusted_price_stddev()
          entry: true 
        series_data: "up_vol"
      pos
      
  up_vs_down: (v) -> 
    frames: required_frames(v.weight or 1) + 1

    evaluate_new_position: (args) -> 
      f = args.features 
      pos = 
        buy: 
          rate: f.upwards_vs_downwards_stddev {weight: (v.weight or 1)}
          entry: true 
        series_data: "upvsdown_vol"
      pos

          

  tug_sell: (v) -> 
    frames: required_frames(Math.min(v.vel_weight, v.accel_weight,.3)) + 2

    evaluate_new_position: (args) -> 

      f = args.features

      vel = f.velocity weight: Math.to_precision(v.vel_weight, 1)
      accel = f.acceleration weight: Math.to_precision(v.accel_weight, 1)

      if vel < 0 && accel > 0 
        min = f.min_price(); max = f.max_price(); last = f.last_price()

        spread = max - min 
        pos = 
          buy: 
            rate: max - min
            entry: true 
          series_data: "tug_sell"
      else 
        pos = 
          buy: 
            rate: 0
            entry: true 
          series_data: "tug_sell"

      pos

  tug_buy: (v) -> 
    frames: required_frames(Math.min(v.vel_weight, v.accel_weight,.3)) + 2

    evaluate_new_position: (args) -> 

      f = args.features

      vel = f.velocity weight: Math.to_precision(v.vel_weight, 1)
      accel = f.acceleration weight: Math.to_precision(v.accel_weight, 1)

      if vel > 0 && accel < 0 
        min = f.min_price(); max = f.max_price(); last = f.last_price()

        spread = max - min 
        pos = 
          buy: 
            rate: max - min
            entry: true 
          series_data: "tug_buy"
      else 
        pos = 
          buy: 
            rate: 0
            entry: true 
          series_data: "tug_buy"

      pos



  MACD: (v) -> 
    frames: required_frames(v.weight * 12/26) + 2
    max_t2: 100

    evaluate_new_position: (args) ->
      f = args.features
      MACD = f.MACD {weight: v.weight}

      pos = 
        buy: 
          rate: MACD
          entry: true 
        series_data: "MACD-#{1/v.weight}-#{v.resolution}"
      pos



  RSI: (v) -> 
    frames: required_frames(1 / v.periods) + 8
    max_t2: 30

    evaluate_new_position: (args) -> 
      f = args.features
      RSI = f.RSI {weight: 1 / v.periods, t: 0}

      pos = 
        buy: 
          rate: RSI
          entry: true 
        series_data: "RSI-#{v.periods}-#{v.resolution}"
      pos


  RSI_thresh: (v) -> 
    frames: required_frames(1 / v.periods) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      RSI = f.RSI {weight: 1 / v.periods, t: 0}
      rate =  if RSI > 100 - v.thresh 
                90 
              else if RSI < v.thresh 
                10
              else if RSI > 50
                60
              else
                40

      pos = 
        buy: 
          rate: rate
          entry: true 
        series_data: "RSI-thresh-#{v.periods}-#{v.resolution}-#{v.thresh}"
      pos



  ADX: (v) -> 
    frames: required_frames( v.weight ) + 2
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      ADX = f.ADX {weight: v.weight, t: 0}

      if v.thresh 
        p = f.DM_plus({weight: v.weight, t: 0})
        m = f.DM_minus({weight: v.weight, t: 0})

        adx = ADX
        if ADX > v.thresh
          if p > m 
            ADX = 55
          else 
            ADX = 45
        else 
          ADX = 50


      if !v.dummy
        pos = 
          buy: 
            rate: ADX
            entry: true 
          series_data: "ADX-#{100 * v.weight}-#{v.resolution}"
        pos


  DI_plus_vs_minus: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      m = f.DI_plus({weight: v.weight, t: 0}) - f.DI_minus({weight: v.weight, t: 0})

      pos = 
        buy: 
          rate: 200000000 * m
          entry: true 
        series_data: "DI_plus-minus-#{100 * v.weight}-#{v.resolution}"
      pos

  DI_plus: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < 1  

        m = f.DI_plus {weight: v.weight, t: 0}

        pos = 
          buy: 
            rate: 200000 * m
            entry: true 
          series_data: "DI_plus-#{100 * v.weight}-#{v.resolution}"
        pos

  DI_minus: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < 1

        m = f.DI_minus {weight: v.weight, t: 0}

        pos = 
          buy: 
            rate: 200 * m
            entry: true 
          series_data: "DI_minus-#{100 * v.weight}-#{v.resolution}"
        pos

  DM_plus: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      m = f.DM_plus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: 200 * m
          entry: true 
        series_data: "DM_plus-#{100 * v.weight}-#{v.resolution}"
      pos

  DM_minus: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      m = f.DM_minus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: 200 * m
          entry: true 
        series_data: "DM_minus-#{100 * v.weight}-#{v.resolution}"
      pos



  DM: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      p = f.DM_plus {weight: v.weight, t: 0}
      m = f.DM_minus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: if p > m then 75 else 25
          entry: true 
        series_data: "DM-#{100 * v.weight}-#{v.resolution}"
      pos


  DI: (v) -> 
    frames: required_frames(v.weight) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features

      p = f.DI_plus {weight: v.weight, t: 0}
      m = f.DI_minus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: if p > m then 75 else 25
          entry: true 
        series_data: "DI-#{100 * v.weight}-#{v.resolution}"
      pos

  ATR: (v) -> 
    frames: required_frames( v.weight ) + 8
    max_t2: 1

    evaluate_new_position: (args) -> 
      f = args.features
      if Math.random() < 1

        m = f.ATR {weight: v.weight, t: 0}

        pos = 
          buy: 
            rate: 50000 * m
            entry: true 
          series_data: "ATR-#{100 * v.weight}-#{v.resolution}"
        pos

