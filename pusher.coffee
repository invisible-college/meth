feature_engine = require( './features')

require './shared'

dealers = {}
feature_engines = {}

global.open_positions = {}
global.all_positions = {}


dealer_defaults = 
  cooloff_period: 4 * 60
  max_open_positions: 1



register_strategy = (name, func, ensemble, budget) -> 
  console.log "Registered strategy #{name}"

  if name[0] != '/'
    name = "/#{name}"

  operation = fetch '/operation'
  if !(name in operation)
    operation[name] =       
      key: name
      budget: budget
      dealers: []
  else 
    operation[name].budget = budget 

  save operation

  for dealer_config in ensemble

    dealer_name = get_name name, dealer_config

    dealer_config = extend 
      frame_width: 5 * 60
      min_return: .2
    , dealer_config

    dealer = func dealer_config

    register_dealer dealer_name, dealer, dealer_config, operation[name], budget / ensemble.length / 2




register_dealer = (name, dealer, dealer_config, strategy, budget) -> 
  #console.log "\tRegistered dealer #{name}"
 
  if name[0] != '/'
    name = "/#{name}"

  dealers[name] = dealer


  dealer_data = fetch(name)
  if !dealer_data.positions # initialize
    dealer_data = extend dealer_data,
      parent: strategy.key 
      budget: budget 
      positions: []

  dealer_data.settings = dealer_config

  save dealer_data
  
  if !(dealer_data.key in strategy.dealers)
    strategy.dealers.push dealer_data.key 
    save strategy


  # create a feature engine that will generate features with trades quantized
  # by frame_width seconds
  frame_width = dealer_data.settings.frame_width
  if !feature_engines[frame_width]
    feature_engines[frame_width] = feature_engine.create frame_width

  feature_engines[frame_width].num_frames = Math.max dealer.frames, \
                                                (feature_engines[frame_width].num_frames or 0)

  feature_engines[frame_width].max_t2 = Math.max dealer.max_t2, \
                                                (feature_engines[frame_width].max_t2 or 0)

  dealer.feature_engine = feature_engines[frame_width]


init = (history, clear_positions) -> 

  for name in get_dealers() 
    dealer_data = fetch name 
    dealer_data.active = !!dealers[name]
    save dealer_data

  reset_open_and_all_positions clear_positions

  history.set_longest_requested_history(dealers)

reset_open_and_all_positions = (clear_positions) -> 
  global.open_positions = {}
  global.all_positions = {}
  for name in get_dealers()
    if clear_positions 
      positions = fetch(name)
      positions.positions = []
      save positions 
      
    all_positions[name] = fetch(name).positions
    open_positions[name] = (p for p in (all_positions[name] or []) when !p.closed)


find_opportunities = (trade_history, exchange_fee) -> 
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

  for name, dealer of dealers
    dealer_data = fetch(name)
    active = dealer_data.active 
    has_open_positions = open_positions[name]?.length > 0 
    continue if !active && !has_open_positions

    settings = dealer_data.settings

    features = feature_engines[settings.frame_width]

    yyy = Date.now()

    # A strategy can't have too many positions on the books at once...
    if settings.series || (active && open_positions[name].length < (settings.max_open_positions or dealer_defaults.max_open_positions))

      spec = dealer.evaluate_new_position features
      t_.eval_pos += Date.now() - yyy if t_?

      yyy = Date.now()
      position = create_position spec, name, exchange_fee
      t_.create_pos += Date.now() - yyy if t_?


      yyy = Date.now()      
      if position?.series_data || is_valid_position position
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
    if dealer.evaluate_open_position
      for pos in open_positions[name] when !pos.series_data

        opportunity = dealer.evaluate_open_position pos, features

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


execute_opportunities = (opportunities, exchange_fee) -> 
  return if !opportunities || opportunities.length == 0 

  for opportunity in opportunities
    pos = opportunity.pos 

    switch opportunity.action 
      when 'create'
        take_position pos

      when 'exit'
        exit_position pos, opportunity.rate, exchange_fee
        take_position pos

      when 'cancel_unfilled'
        cancel_unfilled pos


check_wallet = (opportunities, balances) -> 
  balances ||= fetch('/balances').balances

  required_BTC = required_ETH = 0 

  for opportunity in opportunities when !opportunity.pos.series_data && opportunity.required
    required_BTC += opportunity.required.BTC 
    required_ETH += opportunity.required.ETH

  need_ETH = required_ETH > balances.ETH
  need_BTC = required_BTC > balances.BTC

  sufficient = !(need_ETH || need_BTC)

  sufficient


create_position = (spec, dealer, exchange_fee) -> 
  return null if !spec

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

  amount = fetch(dealer).budget

  key = "/position/#{dealer}-#{tick.time}"
  position = extend {}, spec,
    key: key
    dealer: dealer
    created: tick.time

    entry: extend((if buy?.entry then buy else sell), 
          amount: amount)

    exit: if simultaneous then extend((if sell.entry then buy else sell), 
          amount: amount)

  # predict returns if we place both at once
  if simultaneous
    set_expected_returns position, exchange_fee

  position

exit_position = (pos, rate, exchange_fee) -> 
  type = if pos.entry.type == 'buy' then 'sell' else 'buy'

  if isNaN(rate)
    console.log 'NAN!!', pos
  

  pos.exit = 
    amount: pos.entry.amount
    type: type
    rate: rate 

  set_expected_returns pos, exchange_fee
  pos




# Executes the position entry and exit, if they exist and it hasn't already been done. 
take_position = (pos) -> 
  if config.take_position
    config.take_position pos, (error) -> 
      took_position pos, error
  else 
    took_position pos

took_position = (pos, error) ->   

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

  if !all_positions[pos.dealer]
    throw "#{pos.dealer} not properly initialized with positions"

  if all_positions[pos.dealer].indexOf(pos) == -1
    all_positions[pos.dealer].push pos
    if !pos.series_data
      open_positions[pos.dealer].push pos


cancel_unfilled = (pos) ->
  if config.cancel_unfilled 
    config.cancel_unfilled pos, ->
      canceled_unfilled pos
  else 
    canceled_unfilled pos


# make all meta data updates after trades have potentially been canceled. 
canceled_unfilled = (pos) ->

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
    destroy_position pos



destroy_position = (pos) -> 
  positions = all_positions[pos.dealer]
  open = open_positions[pos.dealer]

  idx = positions.indexOf(pos)
  if idx == -1
    console.log "COULD NOT DESTROY position #{pos.key}...not found in positions"
  else 
    positions.splice idx, 1 

  idx = open.indexOf(pos)
  if idx == -1
    console.log 'CANT DESTROY POSITION THAT ISNT IN OPEN POSITIONS'
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

is_valid_position = (pos) ->  
  return false if !pos
  return true if pos.series_data

  
  settings = get_settings(pos.dealer)

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
  if open_positions[pos.dealer].length > (settings.max_open_positions or dealer_defaults.max_open_positions) - 1
    return false 
    failure_reasons.push "#{(settings.max_open_positions or dealer_defaults.max_open_positions)} POSITIONS ALREADY ON BOOKS"


  # Space positions from the same strategy out
  for other_pos in open_positions[pos.dealer]
    if tick.time - other_pos.created < (settings.cooloff_period or dealer_defaults.cooloff_period)
      return false 
      failure_reasons.push "TOO MANY POSITIONS IN LAST #{(settings.cooloff_period or dealer_defaults.cooloff_period)} SECONDS"
      break

  if settings.alternating_types
    buys = sells = 0 
    for other_pos in open_positions[pos.dealer]
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


hustle = (balance, trades) -> 

  yyy = Date.now()     
  opportunities = find_opportunities trades, balance.exchange_fee
  t_.hustle += Date.now() - yyy if t_?

  if opportunities.length > 0

    yyy = Date.now()
    sufficient_funds = check_wallet opportunities, balance.balances

    if sufficient_funds
      execute_opportunities opportunities, balance.exchange_fee
    t_.executing += Date.now() - yyy if t_?

module.exports = {init, hustle, register_strategy, destroy_position}



bus('/all_data').on_fetch = (key) ->

  dealers_data = {}
  for dealer in get_dealers(true)  
    dealers_data[dealer] = from_cache(dealer)

  return {
    key: key
    dealers: dealers_data
    strategies: from_cache '/operation'
    time: from_cache '/time'
    balances: from_cache '/balances'
  }
