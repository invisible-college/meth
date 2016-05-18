feature_engine = require( './features')

require './shared'

strategies = {}
feature_engines = {}

all_strategies = fetch('/strategies')
all_strategies.strategies = []
save all_strategies


register_strategy = (name, strategy) -> 
  console.log "Registered strategy #{name}"
  strategies[name] = strategy

  # can be modified from statebus
  settings = fetch("/strategies/#{name}")
  settings.settings = extend 
    frame_width: 5 * 60
    frames: 60
    max_t2: 1
    max_open_positions: 5
    min_return: .2
    position_amount: 1
    minimum_separation: 0
    cooloff_period: 4 * 60
    retired: false 
    never_exits: false
    series: false
  , settings.settings, strategy.defaults

  save settings

  # create a feature engine that will generate features with trades quantized
  # by frame_width seconds
  frame_width = settings.settings.frame_width
  if !feature_engines[frame_width]
    feature_engines[frame_width] = feature_engine.create frame_width

  feature_engines[frame_width].num_frames = Math.max settings.settings.frames, \
                                                (feature_engines[frame_width].num_frames or 0)

  feature_engines[frame_width].max_t2 = Math.max settings.settings.max_t2, \
                                                (feature_engines[frame_width].max_t2 or 0)

  
  strategy.feature_engine = feature_engines[frame_width]

  # log this strategy
  all_strategies = fetch('/strategies')
  all_strategies.strategies ||= []
  if !(name in all_strategies.strategies)
    all_strategies.strategies.push name
    save all_strategies

find_opportunities = (open_positions, trade_history, exchange_fee) -> 
  return [[],[]] if trade_history.length == 0 

  if !tick?.time?
    throw "tick.time is not defined!"

  # prepare all features

  yyy = Date.now()
  for name, engine of feature_engines
    engine.tick trade_history
  t_.feature_tick += Date.now() - yyy if t_?

  # evaluate prospective positions from all strategies
  opportunities = []

  for name, strategy of strategies
    settings = get_settings(name)
    continue if settings.retired

    features = feature_engines[settings.frame_width]

    yyy = Date.now()

    # A strategy can't have too many positions on the books at once...
    if settings.series || open_positions[name].length < settings.max_open_positions

      spec = strategy.evaluate_new_position features, open_positions[name]
      t_.eval_pos += Date.now() - yyy if t_?

      yyy = Date.now()
      position = create_position spec, name, exchange_fee
      t_.create_pos += Date.now() - yyy if t_?


      yyy = Date.now()      
      if position?.series_data || is_valid_position open_positions[name], position
        found_match = false 
        if !position.series_data && settings.never_exits
          for pos, idx in open_positions[name] when !pos.exit 
            if pos.entry.amount == position.entry.amount && pos.entry.type != position.entry.type

              opportunities.push
                pos: pos
                action: 'exit'
                rate: position.entry.rate
                required:
                  ETH: if pos.entry.type == 'sell' then 0 else pos.entry.amount
                  BTC: if pos.entry.type == 'buy' then 0 else position.entry.amount * position.entry.rate

              # open_positions[name].splice idx, 1  
              found_match = true 
              break

        if !found_match

          sell = if position.entry.type == 'sell' then position.entry else position.exit
          buy = if position.entry.type == 'buy' then position.entry else position.exit

          opportunities.push 
            pos: position
            action: 'create'
            required: 
              ETH: if sell then sell.amount 
              BTC: if  buy then buy.amount * buy.rate

    t_.handle_new += Date.now() - yyy if t_?

    yyy = Date.now()      
    # see if any open positions want to exit
    if strategy.evaluate_open_position
      for pos in open_positions[name] when !pos.series_data

        opportunity = strategy.evaluate_open_position pos, features

        if opportunity
          if opportunity.action == 'exit'
            #console.log "EXITING", pos, opportunity.rate if pos.strategy == 'tug&frame=2.25&ret=0.525&backoff=0.475'

            extend opportunity,
              required:
                ETH: if pos.entry.type == 'sell' then 0 else pos.entry.amount
                BTC: if pos.entry.type == 'buy' then 0 else pos.entry.amount * opportunity.rate

          opportunities.push extend opportunity, {pos: pos}

    t_.handle_open += Date.now() - yyy if t_?
  
  opportunities


execute_opportunities = (opportunities, all_positions, open_positions, exchange_fee) -> 
  return if !opportunities || opportunities.length == 0 

  for opportunity in opportunities
    pos = opportunity.pos 

    switch opportunity.action 
      when 'create'
        take_position pos, open_positions, all_positions

      when 'exit'
        exit_position pos, opportunity.rate, exchange_fee
        take_position pos, open_positions, all_positions

      when 'cancel_unfilled'
        cancel_unfilled pos, open_positions, all_positions

    if pos.entry && pos.exit && pos.entry.type == pos.exit.type 
      console.log 'WOW IT HA', pos


check_wallet = (opportunities, opts) -> 
  balances = opts.balances || fetch('/balances').balances

  required_BTC = required_ETH = 0 

  for opportunity in opportunities when !opportunity.pos.series_data && opportunity.required
    required_BTC += opportunity.required.BTC 
    required_ETH += opportunity.required.ETH

  need_ETH = required_ETH > balances.ETH
  need_BTC = required_BTC > balances.BTC

  sufficient = !(need_ETH || need_BTC)

  # if we don't have enough, cancel some trades
  if !sufficient && opts.free_funds_if_needed
    opts.current_rate ||= fetch('/ticker').last
    if !opts.open_positions || !opts.current_rate
      throw "missing required options to check_wallet when canceling"

    free_funds opts.open_positions, need_ETH, need_BTC, opts.current_rate

  sufficient

free_funds = (open_positions, need_ETH, need_BTC, current_rate) ->
  current_rate ||= fetch('/ticker').last

  type = if need_ETH then 'sell' else 'buy'

  candidates = [] 
  for strategy, positions of open_positions
    for pos in positions when pos.exit
      for trade in [pos.entry, pos.exit] when trade?.type == type 
        if !trade.closed && \
           ((type == 'buy' && need_BTC) ||  (type == 'sell' && need_ETH))
          candidates.push pos

  # order candidates by distance from last price, higher distance first
  candidates.sort (a,b) ->
    t1 = if a.entry.type == type then a.entry else a.exit
    t2 = if b.entry.type == type then b.entry else b.exit
    Math.abs(t2.rate - current_rate) - Math.abs(t1.rate - current_rate)

  for candidate in candidates
    if ok_to_cancel candidate # cancel if criteria for cancelation met...
      cancel_unfilled candidate, open_positions
      break



ok_to_cancel = (pos) ->
  age = tick.time - pos.created
  return age > 24 * 60 * 60

  # we're ok with canceling position if it is beyond 75 percentile of completion time
  # for the given strategy, including cancelation times of canceled positions

  # positions = fetch("/positions/#{pos.strategy}").positions

  # # don't cancel positions by strategies that have less than 30 completed positions...still calibrating
  # if positions.length < 30
  #   return false

  # times = ( b.closed - b.created for b in positions \
  #            when (b.closed && !b.reset))

  # return age > Math.quartiles(times).q3


create_position = (spec, strategy, exchange_fee) -> 
  return null if !spec
  confidence = spec.confidence or 1

  settings = get_settings(strategy)

  buy = spec.buy 
  sell = spec.sell

  delete spec.buy; delete spec.sell

  simultaneous = buy && sell

  if !buy?.entry && !sell?.entry 
    if simultaneous || buy 
      buy.entry = true 
    else
      sell.entry = true 

  if buy
    buy.type = 'buy'
  if sell 
    sell.type = 'sell'

  amount = settings.position_amount * confidence

  key = "/position/#{strategy}-#{tick.time}"
  position = extend {}, spec,
    key: key
    strategy: strategy
    created: tick.time

    entry: extend((if buy?.entry then buy else sell), 
          key: "/trade/#{strategy}-#{tick.time}-entry"
          amount: amount)

    exit: if simultaneous then extend((if sell.entry then buy else sell), 
          key: "/trade/#{strategy}-#{tick.time}-exit"
          amount: amount)

  if spec.confidence
    pos.confidence = confidence


  # predict returns if we place both at once
  if simultaneous
    set_expected_returns position, exchange_fee

  position

exit_position = (pos, rate, exchange_fee) -> 
  type = if pos.entry.type == 'buy' then 'sell' else 'buy'

  if isNaN(rate)
    console.log 'NAN!!', pos
  

  key = "#{pos.key.replace('/position/', '/trade/')}-exit-reset-#{tick.time}"
  pos.exit = 
    key: key
    amount: pos.entry.amount
    type: type
    rate: rate 
    position: pos.key

  set_expected_returns pos, exchange_fee
  pos




# Executes the position entry and exit, if they exist and it hasn't already been done. 
take_position = (pos, open_positions, all_positions) -> 
  if config.take_position
    config.take_position pos, (error) -> 
      took_position pos, open_positions, all_positions, error
  else 
    took_position pos, open_positions, all_positions

took_position = (pos, open_positions, all_positions, error) ->   

  if error 
    for trade in ['entry', 'exit'] 
      if pos[trade] && !pos[trade].created && !pos[trade].order_id
        delete pos[trade]
        delete pos.expected_profit if pos.expected_profit
        delete pos.expected_return if pos.expected_return    

    if !trade.exit && !trade.entry
      delete pos.key
      return

  for trade in [pos.entry, pos.exit] when trade && !trade.created
    trade.created = tick.time

  all_positions[pos.strategy] ||= []
  if all_positions[pos.strategy].positions.indexOf(pos) == -1
    all_positions[pos.strategy].positions.push pos
    if !pos.series_data
      open_positions[pos.strategy].push pos


cancel_unfilled = (pos, open_positions, all_positions) ->
  if config.cancel_unfilled 
    config.cancel_unfilled pos, ->
      canceled_unfilled pos, open_positions, all_positions
  else 
    canceled_unfilled pos, open_positions, all_positions


# make all meta data updates after trades have potentially been canceled. 
canceled_unfilled = (pos, open_positions, all_positions) ->

  for trade in ['exit', 'entry']
    if pos[trade] && !pos[trade].closed && !pos[trade].order_id
      pos.last_exit = pos[trade].rate
      # if isNaN(pos[trade].rate)
      #   console.log pos
      pos.original_exit = pos[trade].rate if !pos.original_exit?
      delete pos[trade]
      delete pos.expected_profit if pos.expected_profit
      delete pos.expected_return if pos.expected_return    
      pos.reset = tick.time if !pos.reset 

  if pos.exit && !pos.entry 
    pos.entry = pos.exit 
    delete pos.exit

  else if !pos.entry && !pos.exit 
    destroy_position pos, all_positions[pos.strategy], open_positions[pos.strategy]



destroy_position = (pos, positions, open) -> 
  idx = positions.positions.indexOf(pos)
  if idx == -1
    throw "COULD NOT DESTROY position #{pos.key}...not found in positions"
  positions.positions.splice idx, 1 

  idx = open.indexOf(pos)
  if idx == -1
    throw 'CANT DESTROY POSITION THAT ISNT IN OPEN POSITIONS'
  else 
    open.splice idx, 1  

  # del pos 
  delete pos.key





set_expected_returns = (pos, exchange_fee) -> 
  if pos.entry && pos.exit && pos.entry.rate > 0 && pos.exit.rate > 0 

    btc = eth = 0 

    for trade in [pos.entry, pos.exit]
      if trade.type == 'buy'
        eth += trade.amount 
        eth -= (trade.fee or (trade.amount * exchange_fee))
        btc -= (trade.total or trade.amount * trade.rate)
      else
        eth -= trade.amount 
        btc += (trade.total or trade.amount * trade.rate)
        btc -= (trade.fee or (trade.amount * trade.rate * exchange_fee))

    pos.expected_profit = eth + btc / pos.exit.rate
    pos.expected_return = pos.expected_profit / pos.exit.amount
    pos.expected_return *= 100

  pos 


################
# Conditions for whether to open a position: 
#
# automatically applied: 
#     - cool off period
#     - trade closeness 
#     - max open positions
# automatically applied if entry & exit specified immediately: 
#     - profit threshold

is_valid_position = (open_positions, pos) ->  
  return false if !pos
  return true if pos.series_data

  
  settings = get_settings(pos.strategy)

  failure_reasons = []

  # Non-zero rates
  if pos.entry && pos.entry.rate == 0 || pos.exit && pos.exit.rate == 0 
    return false 
    failure_reasons.push "Can't have a zero rate"

  # Position has to have good returns if simultaneous entry / exit...
  if pos.entry && pos.exit
    if pos.expected_return < settings.min_return  
      return false 
      failure_reasons.push "#{(pos.expected_return).toFixed(2)}% is not enough expected profit"

  # A strategy can't have too many positions on the books at once...
  if open_positions.length > settings.max_open_positions - 1
    return false 
    failure_reasons.push "#{settings.max_open_positions} POSITIONS ALREADY ON BOOKS"


  # Buy rate and sell rate shouldn't be too close to another positions's buy or sell rate
  if settings.minimum_separation > 0
    for other_pos in open_positions
      for other_trade in [other_pos.entry, other_pos.exit] when other_trade && !other_trade.closed
        for trade in [pos.entry, pos.exit] when trade && !trade.closed && trade.type == other_trade.type

          diff = Math.abs(trade.rate - other_trade.rate) / other_trade.rate
          if diff < settings.minimum_separation
            return false 
            failure_reasons.push """
              TRADE #{trade.rate.toFixed(6)} TOO CLOSE (#{(100 * diff).toFixed(4)}%) 
              TO ANOTHER TRADE #{other_trade.rate.toFixed(6)}!"""

  # Space positions from the same strategy out
  for other_pos in open_positions  
    if tick.time - other_pos.created < settings.cooloff_period
      return false 
      failure_reasons.push "TOO MANY POSITIONS IN LAST #{settings.cooloff_period} SECONDS"
      break

  if settings.alternating_types
    buys = sells = 0 
    for other_pos in open_positions
      if other_pos.entry.type == 'buy'
        buys++
      else 
        sells++

    if (pos.entry.type == 'buy' && buys > sells) || (pos.entry.type == 'sell' && sells > buys)
      return false 
      failure_reasons.push "Positions need to alternate"


  # console.log "\tEvaluating #{pos.strategy} candidate position"
  # if failure_reasons.length > 0 
  #   for failure in failure_reasons 
  #     console.log "\t\t#{failure}"
  # else 
  #   console.log "\t...looks good"

  return true #failure_reasons.length == 0 


active_strategies = null 
set_exposure = (exposure, rate) -> 
  if !active_strategies
    active_strategies = []
    for name, strategy of strategies
      settings = bus.cache["/strategies/#{name}"]
      continue if settings.settings.retired
      active_strategies.push settings

  balance = bus.cache['/balances']
  holdings = (balance.balances.BTC * rate + balance.balances.ETH) / 2


  for settings in active_strategies
    s = settings.settings

    position_amount = Math.ceil holdings * exposure / active_strategies.length / s.max_open_positions

    if s.position_amount != position_amount
      # console.log 'SETTING POSITION AMOUNT', position_amount
      s.position_amount = position_amount



hustle = (open_positions, all_positions, balance, trades) -> 

  yyy = Date.now()     
  opportunities = find_opportunities open_positions, trades, balance.exchange_fee
  t_.hustle += Date.now() - yyy if t_?

  if opportunities.length > 0

    yyy = Date.now()
    sufficient_funds = check_wallet opportunities,
      balances: balance.balances
      free_funds_if_needed: config.free_funds_if_needed
      current_rate: trades[0].rate
      open_positions: open_positions

    if sufficient_funds
      execute_opportunities opportunities, all_positions, open_positions, balance.exchange_fee
    t_.executing += Date.now() - yyy if t_?

module.exports = {hustle, register_strategy, destroy_position, set_exposure}


from_cache = (key) -> bus.cache[key]

# move to pusher?
bus('/all_data').on_fetch = (key) ->

  data = {}
  strats = from_cache '/strategies'
  time = from_cache '/time'

  settings = {}
  for strat in strats.strategies  
    data[strat] = from_cache("/positions/#{strat}")
    settings[strat] = from_cache("/strategies/#{strat}")

  return {
    key: key
    data: data
    strategies: strats
    settings: settings
    time: time
    balances: from_cache '/balances'
  }
