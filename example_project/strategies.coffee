# Your trading strategies

# This file has a bunch of trading strategies which don't work very well, but 
# may help you know what is possible. Apologies for lack of documentation
# beyond the code itself.

require '../shared'
strategizer = require '../strategizer'


module.exports = strats = {}

strats.plateau = (v) ->
      
  frames: required_frames(.8)
  max_t2: 60

  evaluate_new_position: (f) ->

    vel = f.velocity weight: .8
    vel_median = f.velocity_median t: 0, t2: 50

    if Math.abs(vel) < vel_median

      min = f.min_price(); max = f.max_price(); last = f.last_price()

      sell_at = max - .3 * (max - last)
      buy_at = min + .3 * (last - min)

      pos = 
        sell: 
          rate: sell_at
          entry: vel < 0 
        buy: 
          rate: buy_at
          entry: vel > 0 

      pos

  evaluate_open_position: (pos, f) -> 

    cancel_unfilled = -> 
      abort_if_neither_trade_successful_within = 5 * 60
      cancel_incomplete_trades_after = 3 * 24 * 60 * 60 
      if (!pos.entry || !pos.entry.closed) && \
         (!pos.exit? || !pos.exit.closed) && \
         tick.time - pos.created > abort_if_neither_trade_successful_within

        return true

      for trade in [pos.exit, pos.entry] when trade && !trade.closed 
        return true if tick.time - trade.created > cancel_incomplete_trades_after

    if cancel_unfilled()      
      return {action: 'cancel_unfilled'}

    else if pos.entry.closed && !pos.exit 
      return {action: 'exit', rate: f.last_price()}



strats.meanbot = (v) -> 
  
  name: 'meanie'
  frames: required_frames(v.long_weight) 

  # return a new position if this strategy determines it is a good time to do so
  evaluate_new_position: (args) ->
    f = args.features
    long = f.price weight: Math.to_precision(v.long_weight, 1)
    short = f.price weight: Math.to_precision(v.short_weight, 1)

    plateau = Math.abs(long - short) / long < v.plateau_thresh

    if !plateau
      trending_up = long < short

      min = f.min_price(); max = f.max_price(); last = f.last_price()

      if trending_up 
        sell_at = max - Math.to_precision(v.backoff, 1) * (max - short)
        buy_at = short
      else 
        buy_at = min + Math.to_precision(v.backoff, 1) * (short - min)
        sell_at = short

      buy_at = Math.min last, buy_at
      sell_at = Math.max last, sell_at

      if v.ratio # enforce trading within a ratio if desired
        args.buy = trending_up
        allowed = allowable_entries args, v.ratio
        return null if (!trending_up && !allowed.sell) || (trending_up && !allowed.buy)

      pos = 
        sell: 
          rate: sell_at
          entry: !trending_up
          amount: get_amount(args) 
        buy: 
          rate: buy_at
          entry: trending_up 
          amount: get_amount(args) 

      return pos   
    null

  evaluate_open_position: strats.evaluate_open_position


strats.pure_rebalance = (v) -> 

  # v has: 
  #   ratio: the ETH/BTC ratio to maintain
  #   thresh: the % threshold overwhich a rebalance is needed
  #   frequency: the number of minutes separating rebalancing can happen
  #   period: price aggregation to rebalance against
  #   mark_when_changed: if true, system considers a rebalancing event only to occur 
  #                      when system determines it is needed. If false, system considers
  #                      a rebalancing event to have occurred when it is checked just
  #                      after it is due. 
  #   rebalance_to_threshold: if true, rebalances the accounts just back to the ratio + thresh. 
  #                           if false, rebalances all the way back to ratio
  v = defaults v, 
    ratio: .5
    thresh: .04
    frequency: 24 * 60 * 60  # per day
    period: .5
    mark_when_changed: false
    rebalance_to_threshold: false
    never_exits: true
    exit_if_entry_empty_after: 60

  name: 'pure_rebalance'
  frames: required_frames(Math.min(v.period,(v.ADX_weight or 1), (v.velocity_weight or 1), (v.volume_weight or 1)))
  max_t2: 1



  # return a new position if this strategy determines it is a good time to do so
  evaluate_new_position: (args) ->
    f = args.features

    dealer = args.dealer 


    dealer_data = dealers[dealer]

    dealer_balance = args.balance[dealer].balances

    if !dealer_data.last_rebalanced || dealer_data.last_rebalanced < tick.time - v.frequency
      
      if !v.mark_when_changed
        dealer_data.last_rebalanced = tick.time

      price = f.price weight: Math.to_precision(v.period, 1)

      vETH = dealer_balance.c2
      vBTC = dealer_balance.c1 / price 

      if Math.abs(vETH / (vETH + vBTC) - v.ratio) > v.thresh 

        deth = v.ratio * (vETH + vBTC) - vETH

        buy = sell_enters = deth > 0 

        if v.mark_when_changed
          dealer_data.last_rebalanced = tick.time


        if buy # need to buy deth ETH
          if v.rebalance_to_threshold
            deth -= v.thresh * (vETH + vBTC)
          pos = 
            buy:
              rate: f.last_price() - .002 * f.last_price()
              entry: true 
              amount: deth 
        else 
          if v.rebalance_to_threshold
            deth += v.thresh * (vETH + vBTC)

          pos = 
            sell:
              rate: f.last_price() + .002 * f.last_price()
              entry: true 
              amount: -deth 


        return pos 
    null


  evaluate_open_position: (args) ->   
    pos = args.position

    v = get_settings(pos.dealer)

    # console.log pos.dealer, v.exit_if_entry_empty_after
    # try to get out of this position since it couldn't enter properly
    if v.exit_if_entry_empty_after? && v.exit_if_entry_empty_after < 9999 && \
       pos.entry.fills.length == 0 && pos.exit.fills.length == 0 && \
       tick.time - pos.created > v.exit_if_entry_empty_after * 60
      return {action: 'cancel_unfilled'}


strats.RSI = (v) ->  

  alpha = 1 / v.periods
    
  name: 'RSI'

  frames: Math.max(v.periods, required_frames(alpha)) + 2
  max_t2: 1

  evaluate_new_position: (args) ->
    f = args.features
    open = args.open_positions

    RSI = f.RSI {weight: alpha, t: 0}

    is_high = RSI > 100 - v.thresh 
    is_low = RSI < v.thresh

    previous_RSI = f.RSI {weight: alpha, t: 1}

    crossed_high = !is_high && previous_RSI > 100 - v.thresh
    crossed_low  = !is_low  && previous_RSI < v.thresh 

    crossed_into_high = RSI > 100 - v.thresh - v.opportune_thresh && previous_RSI < 100 - v.thresh - v.opportune_thresh
    crossed_into_low  = RSI < v.thresh + v.opportune_thresh && previous_RSI > v.thresh + v.opportune_thresh


    action = null 

    # overbought
    if crossed_high
      action = 'sell'

    # oversold
    else if crossed_low 
      action = 'buy'

    else if v.buy_in 
      if crossed_into_high
        action = 'buy'
      else if crossed_into_low
        action = 'sell'


    if action && (!v.clear_signal || open.length == 0 || open[open.length - 1].entry.type != action || open.length == 1 || open[open.length - 2].entry.type != action)
      pos = {}
      pos[action] = 
        entry: true
        rate: f.last_price()
        amount: get_amount(args)
      return pos 

  evaluate_open_position: (args) -> 
    pos = args.position
    f = args.features 

    if cancel_unfilled(v, pos)      
      return {action: 'cancel_unfilled'}


    if !v.never_exits

      exit = false 

      action = strats.RSI(v).evaluate_new_position(args)
      if action 

        entry = action.buy or action.sell 

        if action?.buy && pos.entry.type == 'sell' && \
           entry.rate + entry.rate * (v.greed or 0) < pos.entry.rate
          exit = true 
        if action?.sell && pos.entry.type == 'buy' && \
           entry.rate - entry.rate * (v.greed or 0) > pos.entry.rate
          exit = true 


      return {action: 'exit', rate: f.last_price()} if exit 






strats.RSIxADX = (v) ->  

  ADX_alpha = v.ADX_alpha
  RSI_alpha = v.RSI_alpha

  trending_thresh = v.trending_thresh
  opportune_thresh = v.opportune_thresh
  over_thresh = v.over_thresh

  name: 'RSIxADX'

  frames: required_frames(Math.min(ADX_alpha, RSI_alpha)) + 2
  max_t2: 1

  evaluate_new_position: (args) ->
    f = args.features
    open = args.open_positions

    action = null 

    RSI = f.RSI {weight: RSI_alpha, t: 0}
    prev_RSI = f.RSI {weight: RSI_alpha, t: 1}

    ADX = f.ADX({weight: ADX_alpha})
    trending = ADX > v.ADX_thresh
    if trending 
      trending_up = f.DI_plus({weight: ADX_alpha, t: 0}) > f.DI_minus({weight: ADX_alpha, t: 0})
    


    if trending && trending_up 
      # RSI goes over some lower thresh that is confirmed by ADX trending signal
      if RSI > 100 - trending_thresh && \
         prev_RSI < 100 - trending_thresh
        action = 'buy'

      # We might be slightly overbought, take a moment to sell off
      else if RSI < 100 - opportune_thresh &&
              prev_RSI > 100 - opportune_thresh
        action = 'sell'

    # No discernable trend and RSI is showing overbought         
    else if (!trending || !trending_up) && \
             RSI > 100 - over_thresh && \
             prev_RSI < 100 - over_thresh
        action = 'sell'      

    if trending && !trending_up 
      # RSI goes under some high thresh that is confirmed by ADX trending signal
      if RSI < trending_thresh && \
         prev_RSI > trending_thresh
        action = 'sell'

      # We might be slightly oversold, take a moment to sell off
      else if RSI > opportune_thresh &&
              prev_RSI < opportune_thresh
        action = 'buy'

    # # No discernable trend and RSI is showing overbought         
    else if (!trending || trending_up) && \
             RSI < over_thresh && \
             prev_RSI > over_thresh
        action = 'buy'      


    if action && (!v.clear_signal || open.length == 0 || open[open.length - 1].entry.type != action || open.length == 1 || open[open.length - 2].entry.type != action)
      pos = {}
      pos[action] = 
        entry: true
        rate: f.last_price()
        amount: get_amount(args)
      return pos 





strats.RSIxADX_up = (v) ->  

  ADX_alpha = v.ADX_alpha
  RSI_alpha = v.RSI_alpha

  trending_thresh = v.trending_thresh
  opportune_thresh = v.opportune_thresh
  over_thresh = v.over_thresh

  name: 'RSIxADX_up'

  frames: required_frames(Math.min(ADX_alpha, RSI_alpha)) + 2
  max_t2: 1

  evaluate_new_position: (args) ->
    f = args.features
    open = args.open_positions

    action = null 

    RSI = f.RSI {weight: RSI_alpha, t: 0}
    prev_RSI = f.RSI {weight: RSI_alpha, t: 1}

    ADX = f.ADX({weight: ADX_alpha})
    trending = ADX > v.ADX_thresh
    if trending 
      trending_up = f.DI_plus({weight: ADX_alpha, t: 0}) > f.DI_minus({weight: ADX_alpha, t: 0})
    


    if trending && trending_up 
      # RSI goes over some lower thresh that is confirmed by ADX trending signal
      if RSI > 100 - trending_thresh && \
         prev_RSI < 100 - trending_thresh
        action = 'buy'

      # We might be slightly overbought, take a moment to sell off
      else if RSI < 100 - opportune_thresh &&
              prev_RSI > 100 - opportune_thresh
        action = 'sell'

    # No discernable trend and RSI is showing overbought         
    else if (!trending || !trending_up) && \
             RSI > 100 - over_thresh && \
             prev_RSI < 100 - over_thresh
        action = 'sell'      



    if action && (!v.clear_signal || open.length == 0 || open[open.length - 1].entry.type != action || open.length == 1 || open[open.length - 2].entry.type != action)
      pos = {}
      pos[action] = 
        entry: true
        rate: f.last_price()
        amount: get_amount(args)
      return pos 




strats.RSIxADX_down = (v) ->  

  ADX_alpha = v.ADX_alpha
  RSI_alpha = v.RSI_alpha

  trending_thresh = v.trending_thresh
  opportune_thresh = v.opportune_thresh
  over_thresh = v.over_thresh

  name: 'RSIxADX_down'

  frames: required_frames(Math.min(ADX_alpha, RSI_alpha)) + 2
  max_t2: 1

  evaluate_new_position:  (args) ->
    f = args.features
    open = args.open_positions
    action = null 

    RSI = f.RSI {weight: RSI_alpha, t: 0}
    prev_RSI = f.RSI {weight: RSI_alpha, t: 1}

    ADX = f.ADX({weight: ADX_alpha})
    trending = ADX > v.ADX_thresh
    if trending 
      trending_up = f.DI_plus({weight: ADX_alpha, t: 0}) > f.DI_minus({weight: ADX_alpha, t: 0})
    


    if trending && !trending_up 
      # RSI goes under some high thresh that is confirmed by ADX trending signal
      if RSI < trending_thresh && \
         prev_RSI > trending_thresh
        action = 'sell'

      # We might be slightly oversold, take a moment to sell off
      else if RSI > opportune_thresh &&
              prev_RSI < opportune_thresh
        action = 'buy'

    # # No discernable trend and RSI is showing overbought         
    else if (!trending || trending_up) && \
             RSI < over_thresh && \
             prev_RSI > over_thresh
        action = 'buy'      


    if action && (!v.clear_signal || open.length == 0 || open[open.length - 1].entry.type != action || open.length == 1 || open[open.length - 2].entry.type != action)
      pos = {}
      pos[action] = 
        entry: true
        rate: f.last_price()
        amount: get_amount(args)
      return pos 




strats.RSIxDI = (v) ->  

  fast_alpha = 1 / v.fast_periods
  slow_alpha = 1 / v.slow_periods
    
  name: 'RSIxDI'

  frames: v.slow_periods + 2 #required_frames(slow_alpha) + 2
  max_t2: 1

  evaluate_new_position: (args) ->
    f = args.features
    open = args.open_positions

    DI_plus = f.DI_plus {weight: slow_alpha, t: 0}
    DI_minus = f.DI_minus {weight: slow_alpha, t: 0}

    prev_DI_plus = f.DI_plus {weight: slow_alpha, t: 1}
    prev_DI_minus = f.DI_minus {weight: slow_alpha, t: 1}

    RSI = f.RSI {weight: fast_alpha, t: 0}

    RSI_is_high = RSI > 100 - v.RSI_thresh 
    RSI_is_low = RSI < v.RSI_thresh

    DI_crossed_low = DI_plus < DI_minus && prev_DI_plus > prev_DI_minus     
    DI_crossed_up =   DI_plus > DI_minus && prev_DI_plus < prev_DI_minus 

    action = null 

    # let's buy into this emerging up trend!
    if DI_crossed_up && RSI_is_high
      action = 'buy'

    # let's sell into this emerging down trend!
    else if DI_crossed_low && RSI_is_low 
      action = 'sell'

    if action && (!v.clear_signal || open.length == 0 || open[open.length - 1].entry.type != action || open.length == 1 || open[open.length - 2].entry.type != action)
      pos = {}
      pos[action] = 
        entry: true
        rate: f.last_price()
        amount: get_amount(args)
      return pos 



strats.ADX_cross = (v) ->  

  ADX_alpha = v.alpha
    
  name: 'ADX_cross'

  frames: required_frames(ADX_alpha) + 2
  max_t2: 1

  evaluate_new_position: (args) ->
    f = args.features
    open = args.open_positions

    ADX = f.ADX({weight: ADX_alpha})
    prev_ADX = f.ADX({t: 1, weight: ADX_alpha})

    trending = ADX > v.ADX_thresh
    prev_trending = prev_ADX > v.ADX_thresh

    action = null 

    if trending || prev_trending

      trending_up = f.DM_plus({weight: ADX_alpha, t: 0}) > f.DM_minus({weight: ADX_alpha, t: 0})
      prev_trending_up = f.DM_plus({weight: ADX_alpha, t: 1}) > f.DM_minus({weight: ADX_alpha, t: 1})

      if trending && (!prev_trending || trending_up != prev_trending_up)
        action = if trending_up then 'buy' else 'sell'
      else if !trending && prev_trending
        action = if prev_trending_up then 'sell' else 'buy'



    if action && (!v.clear_signal || open.length == 0 || open[open.length - 1].entry.type != action || open.length == 1 || open[open.length - 2].entry.type != action)
      pos = {}
      pos[action] = 
        entry: true
        rate: f.last_price()
        amount: get_amount(args)
      return pos 


strats.DM_crossover = (v) ->  

  alpha = v.weight 


  name: 'DM_crossover'

  frames: required_frames(alpha) + 2
  max_t2: 1

  evaluate_new_position: (args) ->
    f = args.features

    cur = f.DM_plus({weight: alpha, t: 0}) - f.DM_minus({weight: alpha, t: 0})

    ```
    key = `${f.last}-${f.last}-${alpha}-`
    ```

    return if !f.cache.DM_plus[key]? || !f.cache.DM_minus[key]?

    prev  = f.cache.DM_plus[key] - f.cache.DM_minus[key]

    bear_cross  =  (cur > 0 && prev <= 0) || (cur == prev == 0 && 'buy'  in (p.entry.type for p in args.open_positions))
    bull_cross  =  (cur > 0 && prev <= 0) || (cur == prev == 0 && 'sell' in (p.entry.type for p in args.open_positions))

    action = null 

    # let's buy into this emerging up trend!
    if bull_cross # && RSI_is_high
      action = 'buy'

    # let's sell into this emerging down trend!
    else if bear_cross # && RSI_is_low 
      action = 'sell'

    if action && action not in (p.entry.type for p in args.open_positions)
      last = f.last_price()
      pos = {}
      pos[action] = 
        entry: true
        rate: last
        amount: if action == 'buy' then .4 * args.balance[args.dealer].balances.c1 / last else .4 * args.balance[args.dealer].balances.c2
        market: true

      return pos 

  evaluate_open_position: (args) -> null






strats.crossover = (v) -> 

  frames: required_frames(Math.min(v.long_weight, v.short_weight)) + 2
  max_t2: (v.num_consecutive or 0) + 1

  evaluate_new_position: (args) ->
    f = args.features
    open = args.open_positions

    last = f.last_price()

    opts = 
      f: f[v.feature]
      f_weight: v.short_weight
      num_consecutive: v.num_consecutive
      f2: f[v.feature]
      f2_weight: v.long_weight

    pos = null
    if v.predict_long
      act1 = 'buy'
      act2 = 'sell'
    else 
      act1 = 'sell'
      act2 = 'buy'

    if crossover(false , opts)

      if v.clear_signal
        duplicate = false 
        closer = false 
        for o in open 
          duplicate ||= o.entry.type == act1
          closer ||= o.entry.type != act1 && !o.exit


      if !v.clear_signal || !duplicate || closer
        pos = {}
        pos[act1] =
          rate: last  
          entry: true 
          amount: get_amount(args)
        return pos 

    else if crossover(true, opts)

      if v.clear_signal
        duplicate = false 
        closer = false 
        for o in open 
          duplicate ||= o.entry.type == act2
          closer ||= o.entry.type != act2 && !o.exit

      if !v.clear_signal || !duplicate || closer
        pos = {}
        pos[act2] = 
          rate: last  
          entry: true 
          amount: get_amount(args)

        return pos 


strats.gunslinger = (v) ->       

  defaults: 
    minimum_separation: 0
    resolution: v.frame * 60
    frames: required_frames(v.long_weight)

  position_amount: get_amount

  # return a new position if this strategy determines it is a good time to do so
  evaluate_new_position: (args) ->
    f = args.features

    long = f.price weight: v.long_weight
    short = f.price weight: v.short_weight

    plateau = Math.abs(long - short) / long < v.plateau_thresh

    if !plateau
      last = f.last_price()
      accel = f.acceleration weight: (Math.to_precision(v.accel_weight) or .8)
      vel = f.velocity weight: (Math.to_precision(v.vel_weight) or .8)

      if vel > 0 && accel > 0 && short > long
        sell_at = last + v.greed
        buy_at = last

        pos = 
          sell: 
            rate: sell_at
            amount: get_amount(args)
          buy: 
            rate: buy_at
            entry: true 
            amount: get_amount(args)


      else if vel < 0 && accel < 0 && short < long
        buy_at =  last - v.greed
        sell_at = last

        pos = 
          sell: 
            rate: sell_at
            entry: true
            amount: get_amount(args)
          buy: 
            rate: buy_at
            amount: get_amount(args)


  evaluate_open_position: strats.evaluate_open_position
