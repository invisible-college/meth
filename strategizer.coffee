require './shared'

series = module.exports = 

  defaults: 
    resolution: 5 * 60
    series: true
    never_exits: true

  volume: (v) -> 
    dependencies: [[v.resolution, 'volume', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 

      f = @features[v.resolution]
      

      if !v.dummy
        pos = 
          buy: 
            rate: f.volume({weight: v.weight or 1})
            entry: true 
          series_data: "volume"

        pos

  logvolume: (v) -> 
    dependencies: [[v.resolution, 'volume', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 

      f = @features[v.resolution]
      

      if !v.dummy
        pos = 
          buy: 
            rate: Math.log f.volume({weight: v.weight or 1}) + 1
            entry: true 
          series_data: "volume"

        pos

  hourly_USD_volume: (v) -> 
    dependencies: [[v.resolution, 'volume', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 

      f = @features[v.resolution]

      if !v.dummy
        granularity = from_cache('price_data').granularity
        idx = Math.floor((tick.time - tick.start) / granularity)
        $c2 = (bus.cache['price_data'].c2 or bus.cache['price_data'].c1xc2)[idx]?.close or 0

        pos = 
          buy: 
            rate: $c2 * f.volume({weight: v.weight or 1}) / (v.resolution) * 60 * 60
            entry: true 
          series_data: "volume"

        pos

  EMA_price: (v) -> 
    dependencies: [[v.resolution, 'price', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < .5

        pos = 
          buy: 
            rate: f.price({weight: v.weight})
            entry: true 
          series_data: "EMA-#{v.resolution}"
        pos

  price: (v) -> 
    dependencies: [[v.resolution, 'price', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      
      if Math.random() < 1

        pos = 
          buy: 
            rate: f.price() #f.price()
            entry: true 
          series_data: "price"
        pos

  max_price: (v) -> 
    dependencies: [[v.resolution, 'max_price', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < 1

        pos = 
          buy: 
            rate: f.max_price()
            entry: true 
          series_data: "max_price"
        pos

  min_price: (v) -> 
    dependencies: [[v.resolution, 'max_price', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < 1

        pos = 
          buy: 
            rate: f.min_price()
            entry: true 
          series_data: "min_price"
        pos

  last_price: (v) -> 
    dependencies: [[v.resolution, 'last_price', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < .5
        
        pos = 
          buy: 
            rate: f.last_price() #f.price()
            entry: true 
          series_data: "last_price"
        pos





  velocity: (v) -> 
    dependencies: [[v.resolution, 'velocity', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      pos = 
        buy: 
          rate: f.velocity weight: Math.to_precision(v.weight, 1)
          entry: true 
        series_data: "velocity"
      pos

  acceleration: (v) -> 
    dependencies: [[v.resolution, 'acceleration', {weight: v.accel_weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 

      f = @features[v.resolution]
      
      pos = 
        buy: 
          rate: f.acceleration weight: Math.to_precision(v.accel_weight, 1)
          entry: true 
        series_data: "acceleration"
      pos


  volatility: (v) -> 
    dependencies: [[v.resolution, 'volume_adjusted_price_stddev', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution] 
      pos = 
        buy: 
          rate: f.volume_adjusted_price_stddev()
          entry: true 
        series_data: "volatility"
      pos

  volume_by_volatility: (v) -> 
    dependencies: [[v.resolution, 'stddev_by_volume', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution] 
      pos = 
        buy: 
          rate: f.stddev_by_volume()
          entry: true 
        series_data: "stddev_by_volume"
      pos

  downward_volatility: (v) -> 
    dependencies: [[v.resolution, 'downwards_volume_adjusted_price_stddev', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution] 
      pos = 
        buy: 
          rate: f.downwards_volume_adjusted_price_stddev()
          entry: true 
        series_data: "down_vol"
      pos

  upward_volatility: (v) -> 
    dependencies: [[v.resolution, 'upwards_volume_adjusted_price_stddev', {}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution] 
      pos = 
        buy: 
          rate: f.upwards_volume_adjusted_price_stddev()
          entry: true 
        series_data: "up_vol"
      pos
      
  up_vs_down: (v) -> 
    dependencies: [[v.resolution, 'upwards_vs_downwards_stddev', {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution] 
      pos = 
        buy: 
          rate: f.upwards_vs_downwards_stddev {weight: (v.weight or 1)}
          entry: true 
        series_data: "upvsdown_vol"
      pos



  MACD: (v) -> 

    short_resolution = v.resolution * 60 * 60
    long_resolution  = v.resolution * v.long * 60 * 60
    MACD_feature = v.MACD_feature or 'price' 

    MACD_weight = v.MACD_weight or 1 
    dependencies: [[short_resolution, 'MACD_signal',  {weight: v.weight or 1, MACD_weight, MACD_feature}]
                   [long_resolution,  'MACD_signal',  {weight: v.weight or 1, MACD_weight, MACD_feature}]]

    eval_whether_to_enter_new_position: (args) ->
      f = @features[long_resolution]
      MACD = f.MACD {weight: (v.weight or 1), short_resolution, MACD_weight, eval_entry_every_n_seconds: v.eval_entry_every_n_seconds, MACD_feature}

      pos = 
        buy: 
          rate: MACD
          entry: true 
        series_data: "MACD-#{v.weight or 1}-#{v.resolution}"
      pos

  MACD_signal: (v) -> 
    short_resolution = v.resolution * 60 * 60
    long_resolution  = v.resolution * v.long * 60 * 60

    MACD_weight = v.MACD_weight or 1
    MACD_feature = v.MACD_feature or 'price' 

    dependencies: [[short_resolution, 'MACD_signal',  {weight: v.weight or 1, MACD_weight, MACD_feature}]
                   [long_resolution,  'MACD_signal',  {weight: v.weight or 1, MACD_weight, MACD_feature}]]

    eval_whether_to_enter_new_position: (args) ->
      f = @features[long_resolution]
      MACD = f.MACD_signal {weight: (v.weight or 1), short_resolution, MACD_weight, eval_entry_every_n_seconds: v.eval_entry_every_n_seconds, MACD_feature}

      pos = 
        buy: 
          rate: MACD
          entry: true 
        series_data: "signal-MACD-#{v.weight or 1}-#{v.resolution}"
      pos

  MACD_short: (v) -> 
    resolution = v.resolution * 60 * 60

    dependencies: [[resolution, 'price',  {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) ->
      f = @features[resolution]
      p = f.price {weight: v.weight or 1}

      pos = 
        buy: 
          rate: p
          entry: true 
        series_data: "short-MACD-#{v.weight or 1}-#{resolution}"
      pos

  MACD_long: (v) -> 
    resolution = v.resolution * v.long * 60 * 60
    dependencies: [[resolution, 'price',  {weight: v.weight or 1}]]

    eval_whether_to_enter_new_position: (args) ->
      f = @features[resolution]
      p = f.price {weight: v.weight or 1}

      pos = 
        buy: 
          rate: p
          entry: true 
        series_data: "long-MACD-#{v.weight or 1}-#{resolution}"
      pos




  RSI: (v) -> 
    dependencies: [[v.resolution, 'RSI', {weight: 1 / v.periods}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      RSI = f.RSI {weight: 1 / v.periods, t: 0}

      pos = 
        buy: 
          rate: RSI
          entry: true 
        series_data: "RSI-#{v.periods}-#{v.resolution}"
      pos


  RSI_thresh: (v) -> 
    dependencies: [[v.resolution, 'RSI', {weight: 1 / v.periods}]]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]

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
    resolution = v.resolution * 60 * 60

    dependencies: [
      [resolution, 'ADX', {weight: v.weight}]
      [resolution, 'DM_plus', {weight: v.weight}]
      [resolution, 'DM_minus', {weight: v.weight}]      
    ]


    eval_whether_to_enter_new_position: (args) -> 
      f = @features[resolution]

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
          series_data: "ADX-#{100 * v.weight}-#{resolution}"
        pos


  DI_plus_vs_minus: (v) -> 
    dependencies: [
      [v.resolution, 'DI_plus', {weight: v.weight}]
      [v.resolution, 'DI_minus', {weight: v.weight}]      
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]

      m = f.DI_plus({weight: v.weight, t: 0}) - f.DI_minus({weight: v.weight, t: 0})

      pos = 
        buy: 
          rate: 200000000 * m
          entry: true 
        series_data: "DI_plus-minus-#{100 * v.weight}-#{v.resolution}"
      pos

  DI_plus: (v) -> 
    dependencies: [
      [v.resolution, 'DI_plus', {weight: v.weight}]
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < 1  

        m = f.DI_plus {weight: v.weight, t: 0}

        pos = 
          buy: 
            rate: 200000 * m
            entry: true 
          series_data: "DI_plus-#{100 * v.weight}-#{v.resolution}"
        pos

  DI_minus: (v) -> 
    dependencies: [
      [v.resolution, 'DI_minus', {weight: v.weight}]      
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < 1

        m = f.DI_minus {weight: v.weight, t: 0}

        pos = 
          buy: 
            rate: 200 * m
            entry: true 
          series_data: "DI_minus-#{100 * v.weight}-#{v.resolution}"
        pos

  DM_plus: (v) -> 
    dependencies: [
      [v.resolution, 'DM_plus', {weight: v.weight}]
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]

      m = f.DM_plus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: 200 * m
          entry: true 
        series_data: "DM_plus-#{100 * v.weight}-#{v.resolution}"
      pos

  DM_minus: (v) -> 
    dependencies: [
      [v.resolution, 'DM_minus', {weight: v.weight}]      
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]

      m = f.DM_minus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: 200 * m
          entry: true 
        series_data: "DM_minus-#{100 * v.weight}-#{v.resolution}"
      pos



  DM: (v) -> 
    dependencies: [
      [v.resolution, 'DM_plus', {weight: v.weight}]
      [v.resolution, 'DM_minus', {weight: v.weight}]      
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]

      p = f.DM_plus {weight: v.weight, t: 0}
      m = f.DM_minus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: if p > m then 75 else 25
          entry: true 
        series_data: "DM-#{100 * v.weight}-#{v.resolution}"
      pos


  DI: (v) -> 
    dependencies: [
      [v.resolution, 'DI_plus', {weight: v.weight}]
      [v.resolution, 'DI_minus', {weight: v.weight}]      
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]

      p = f.DI_plus {weight: v.weight, t: 0}
      m = f.DI_minus {weight: v.weight, t: 0}

      pos = 
        buy: 
          rate: if p > m then 75 else 25
          entry: true 
        series_data: "DI-#{100 * v.weight}-#{v.resolution}"
      pos

  ATR: (v) -> 
    dependencies: [
      [v.resolution, 'ATR', {weight: v.weight}]
    ]

    eval_whether_to_enter_new_position: (args) -> 
      f = @features[v.resolution]
      if Math.random() < 1

        m = f.ATR {weight: v.weight, t: 0}

        pos = 
          buy: 
            rate: 50000 * m
            entry: true 
          series_data: "ATR-#{100 * v.weight}-#{v.resolution}"
        pos

