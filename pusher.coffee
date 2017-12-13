require './shared'

feature_engine = require './feature_engine'

global.dealers = {}
global.open_positions = {}



learn_strategy = (name, teacher, strat_dealers) -> 

  console.assert uniq(strat_dealers), {message: 'dealers aren\'t unique!', dealers: strat_dealers}

  operation = from_cache 'operation'

  operation[name] =       
    key: name
    dealers: []

  save operation

  strategy = operation[name]

  needs_save = false 

  # name dealer names more space efficiently :)
  names = {}
  params = {}
  for dealer_conf,idx in strat_dealers
    for k,v of dealer_conf 
      params[k] ||= {}
      params[k][v] = 1

  differentiating_params = {}
  for k,v of params 
    if Object.keys(v).length > 1 
      differentiating_params[k] = 1 
  ###### 

  for dealer_conf,idx in strat_dealers

    dealer_conf = defaults dealer_conf,
      max_open_positions: 9999999
    
    if dealer_conf.max_open_positions > 1 && !dealer_conf.cooloff_period?
      dealer_conf.cooloff_period = 4 * 60

    dealer = teacher dealer_conf

    name = get_name strategy.key, dealer_conf, differentiating_params  
    if name == strategy.key 
      name = "#{strategy.key}-dealer"
    key = name 


    dealer_data = fetch key 

    if !dealer_data.positions # initialize
      dealer_data = extend dealer_data,
        parent: '/' + strategy.key 
        positions: []

    dealer_data.settings = dealer_conf

    console.assert dealer_data.settings.series || dealer.evaluate_open_position?, 
      message: 'Dealer has no evaluate_open_position method defined'
      dealer: name 

    dealers[key] = dealer 

    if ('/' + key) not in strategy.dealers
      strategy.dealers.push '/' + key
      needs_save = true 

    save dealer_data


  if needs_save
    save strategy



init = ({history, clear_all_positions, take_position, cancel_unfilled, update_exit}) -> 
  for name in get_dealers() 
    dealer_data = from_cache name
    save dealer_data

  reset_open()
  clear_positions() if clear_all_positions

  pusher.dealer_last_updated = {}

  for name in get_all_actors() 
    dealer_data = from_cache name
    dealer = dealers[name]
    has_open_positions = open_positions[name]?.length > 0


    # create a feature engine that will generate features with trades quantized
    # by resolution seconds

    for d in dealer.dependencies
      resolution = d[0]
      engine = feature_engine.create resolution

      engine.subscribe_dealer name, dealer, dealer_data
      dealer.features ?= {}
      dealer.features[resolution] = engine

    pusher.dealer_last_updated[name] = 0

  history_buffer = (e.num_frames * res + 1 for res, e of feature_engine.resolutions)
  history_buffer = Math.max.apply null, history_buffer

  history.set_longest_requested_history history_buffer

  pusher.take_position = take_position if take_position
  pusher.cancel_unfilled = cancel_unfilled if cancel_unfilled
  pusher.update_exit = update_exit if update_exit






clear_positions = -> 
  for name in get_all_actors() 
    dealer = fetch(name)
    dealer.positions = []
    save dealer 


reset_open = -> 
  global.open_positions = {}
  for name in get_dealers()
    dealer = fetch(name)
    open_positions[name] = (p for p in (dealer.positions or []) when !p.closed)




find_opportunities = (trade_history, exchange_fee, balance) -> 
  if trade_history.length == 0 
    return [] 

  console.assert tick?.time?,
    message: "tick.time is not defined!"
    tick: tick

  # identify new positions and changes to old positions (opportunities)
  opportunities = []

  for name in get_all_actors()
    dealer_data = from_cache name
    settings = dealer_data.settings

    update_every_n_minutes = settings.update_every_n_minutes or config.update_every_n_minutes

    if tick.time - pusher.dealer_last_updated < update_every_n_minutes * 60
      continue 

    pusher.dealer_last_updated[name] = tick.time

    dealer = dealers[name]

    yyy = Date.now()
    proceed = true 
    for resolution, engine of dealer.features when engine.now != tick.time
      proceed &&= engine.tick trade_history
    return if !proceed
    t_.feature_tick += Date.now() - yyy if t_?

    
    zzz = Date.now()

    # A strategy can't have too many positions on the books at once...
    if settings.series || settings.never_exits || open_positions[name].length < settings.max_open_positions

    
      yyy = Date.now()

      spec = dealer.evaluate_new_position  
        dealer: name
        open_positions: open_positions[name]
        balance: balance      
        
      t_.eval_pos += Date.now() - yyy if t_?

      #yyy = Date.now()
      if spec 
        position = create_position spec, name, exchange_fee
        #t_.create_pos += Date.now() - yyy if t_?

        yyy = Date.now()      
        valid = position && is_valid_position(position, balance[position.dealer])
        found_match = false 

        if valid
          

          if !position.series_data && settings.never_exits
            candidates = (p for p in open_positions[name] when !p.exit && p.entry.type != position.entry.type)

            if candidates.length > 1
              candidates.sort( (a,b) -> b.created - a.created )

            pos = candidates.pop()

            if pos 
              rate = position.entry.rate
              amount = position.entry.amount or pos.entry.amount
              total_available = if position.entry.type == 'buy' 
                                  balance[pos.dealer].balances.c1 / rate
                                else 
                                  balance[pos.dealer].balances.c2

              amount = Math.min amount, total_available

              opportunities.push
                pos: pos
                action: 'exit'
                rate: rate
                amount: amount
                required_c2: if position.entry.type == 'sell' then amount
                required_c1: if position.entry.type == 'buy'  then amount * rate
                market: if pos.entry.market then true 

              found_match = pos 


          if !found_match
            sell = if position.entry.type == 'sell' then position.entry else position.exit
            buy  = if position.entry.type == 'buy'  then position.entry else position.exit

            opportunities.push 
              pos: position
              action: 'create'
              required_c2: if sell then sell.amount
              required_c1: if  buy then buy.amount * buy.rate

    t_.handle_new += Date.now() - zzz if t_?

    continue if dealer_data.settings.series

    # see if any open positions want to exit
    yyy = Date.now()      

    for pos in open_positions[name] when !pos.series_data && found_match != pos
      opportunity = dealer.evaluate_open_position
        position: pos 
        dealer: name
        open_positions: open_positions[name]
        balance: balance 

      if opportunity
        if opportunity.action == 'exit'
          if pos.entry.type == 'buy'
            opportunity.required_c2 = opportunity.amount or pos.entry.amount
          else 
            opportunity.required_c1 = (opportunity.amount or pos.entry.amount) * opportunity.rate

        opportunity.pos = pos 
        opportunities.push opportunity

    t_.handle_open += Date.now() - yyy if t_?


  if !uniq(opportunities)
    msg = 
      message: 'Duplicate opportunities'
      opportunities: opportunities
    
    for opp,idx in opportunities
      msg["pos-#{idx}"] = opp.pos 

    console.assert false, msg

  opportunities




execute_opportunities = (opportunities, exchange_fee, balance) -> 
  return if !opportunities || opportunities.length == 0 

  for opportunity in opportunities
    pos = opportunity.pos 

    switch opportunity.action 
      when 'create'
        take_position pos

      when 'cancel_unfilled'
        cancel_unfilled pos

      when 'force_cancel'
        force_cancel pos

      when 'exit'
        exit_position {pos, rate: opportunity.rate, exchange_fee, market_trade: opportunity.market, amount: opportunity.amount or pos.entry.amount}
        take_position pos

      when 'update_exit'
        update_exit pos, opportunity.rate, exchange_fee





check_wallet = (opportunities, balance) -> 

  doable = []

  required_c1 = required_c2 = 0 

  by_dealer = {}
  ops_cnt = 0 
  for opportunity in opportunities
    if (!opportunity.required_c2 && !opportunity.required_c1) || opportunity.pos.series_data
      doable.push opportunity
      continue 

    by_dealer[opportunity.pos.dealer] ||= []
    by_dealer[opportunity.pos.dealer].push opportunity
    ops_cnt += 1

  return doable if ops_cnt == 0 


  all_avail_BTC = balance.balances.c1
  all_avail_ETH = balance.balances.c2

  for name, ops of by_dealer
    dbalance = balance[name].balances
    avail_BTC = dbalance.c1
    avail_ETH = dbalance.c2

    # console.log {message: 'yo', dealer: name, avail_ETH, avail_BTC, dealer_opportunities: by_dealer[name], balance: dbalance}
    console.assert avail_BTC >= 0 && avail_ETH >= 0, {message: 'negative balance', dealer: name, avail_ETH, avail_BTC, dealer_opportunities: by_dealer[name], balance: dbalance}
    for op in ops 
      r_ETH = op.required_c2 or 0
      r_BTC = op.required_c1 or 0
      if avail_ETH >= r_ETH && avail_BTC >= r_BTC && all_avail_ETH >= r_ETH && all_avail_BTC >= r_BTC
        doable.push op

        avail_ETH -= r_ETH
        avail_BTC -= r_BTC
        all_avail_ETH -= r_ETH
        all_avail_BTC -= r_BTC


  doable


create_position = (spec, dealer, exchange_fee) -> 
  return null if !spec

  buy = spec.buy 
  sell = spec.sell

  spec.buy = undefined; spec.sell = undefined

  simultaneous = buy && sell 

  if !buy?.entry && !sell?.entry 
    if simultaneous || buy 
      buy.entry = true 
    else
      sell.entry = true 

  if config.exchange == 'gdax' 
    for trade in [buy, sell] when trade
      if config.c1 == 'USD' # can't have fractions of cents (at least on GDAX!)
        trade.rate = parseFloat((Math.round(trade.rate * 100) / 100).toFixed(2))
      else 
        trade.rate = parseFloat((Math.round(trade.rate * 1000000) / 1000000).toFixed(6))
      trade.amount = parseFloat((Math.floor(trade.amount * 1000000) / 1000000).toFixed(6))

      if config.c2 == 'BTC' && trade.amount < .01
        trade.market = true

  if buy
    buy.type = 'buy'
    buy.to_fill ||= buy.amount

  if sell 
    sell.type = 'sell'
    sell.to_fill ||= sell.amount



  position = extend {}, spec,
    key: "position/#{dealer}-#{tick.time}" if !config.simulation
    dealer: dealer
    created: tick.time

    entry: if buy?.entry then buy else sell
    exit: if simultaneous then (if sell.entry then buy else sell)

  # predict returns if we place both at once
  if simultaneous
    set_expected_profit position, exchange_fee

  position

exit_position = ({pos, rate, exchange_fee, market_trade, amount}) ->
  console.assert pos.entry, {message: 'position can\'t be exited because entry is undefined', pos: pos, rate: rate} 
  type = if pos.entry.type == 'buy' then 'sell' else 'buy'
  amount = amount or pos.entry.amount
  pos.exit = 
    amount: amount
    type: type
    rate: rate
    to_fill: amount
    market: if market_trade then true 

  if config.exchange == 'gdax' 
    for trade in [pos.exit.rate] when trade
      if config.c1 == 'USD' # can't have fractions of cents (at least on GDAX!)
        trade.rate = parseFloat((Math.round(trade.rate * 100) / 100).toFixed(2))
      else 
        trade.rate = parseFloat((Math.round(trade.rate * 1000000) / 1000000).toFixed(6))
      trade.amount = parseFloat((Math.floor(trade.amount * 1000000) / 1000000).toFixed(6))


  set_expected_profit pos, exchange_fee
  pos


# Executes the position entry and exit, if they exist and it hasn't already been done. 
take_position = (pos) -> 

  if pusher.take_position && !pos.series_data
    pusher.take_position pos, (error) -> 
      took_position pos, error
  else 
    took_position pos

took_position = (pos, error) ->   

  if error && !config.simulation
    for trade in ['entry', 'exit'] when pos[trade]

      if !pos[trade].current_order
        pos.expected_profit = undefined if pos.expected_profit
        if !(pos[trade].orders?.length > 0)
          pos[trade] = undefined 
        else
          console.error  
            message: "We've partially filled a trade, but an update order occurred. I think Pusher will handle this properly though :p"
            pos: pos 
          pos[trade].created = pos.created # faster recovery

    if !trade.exit && !trade.entry
      return destroy_position pos 
    else 
      save pos

  for trade in [pos.entry, pos.exit] when trade && !trade.created
    trade.created = tick.time
    trade.fills = []

  if !from_cache(pos.dealer).positions
    throw "#{pos.dealer} not properly initialized with positions"

  if from_cache(pos.dealer).positions.indexOf(pos) == -1
    from_cache(pos.dealer).positions.push pos
    if !pos.series_data
      open_positions[pos.dealer].push pos


update_exit = (pos, rate, exchange_fee) ->

  # pay attention to case where both entry and exit are stuck b/c of partial fills

  if pos.exit.closed && !pos.entry.closed  
    p = pos.exit 
    pos.exit = pos.entry 
    pos.entry = p 

  if config.exchange == 'gdax'

    if config.c1 == 'USD' # can't have fractions of cents (at least on GDAX!)
      rate = parseFloat((Math.round(rate * 100) / 100).toFixed(2))
    else 
      rate = parseFloat((Math.round(rate * 1000000) / 1000000).toFixed(6))

  if isNaN(rate) || !rate || rate == 0
    console.assert false, 
      message: 'Bad rate for moving exit!',
      rate: rate 
      pos: pos 

  if !pos.entry 
    console.assert false, 
      message: 'position can\'t be exited because entry is undefined'
      pos: pos
      rate: rate

  if pos.exit.to_fill == 0
    console.assert false, 
      message: 'trying to move an exit on a trade that should already be closed'
      trade: pos.exit 
      fills: pos.exit.fills

  last_exit = pos.exit.rate 

  
  if pos.exit.type == 'buy'
    # we need to adjust the *amount* we're buying because our buying power has decreased
    amt_purchased = 0 
    total_sold = 0 
    for f in (pos.exit.fills or [])
      amt_purchased += f.amount
      total_sold += f.total

    amt_remaining = pos.exit.amount - amt_purchased    
    total_remaining = amt_remaining * pos.exit.rate 
    new_amount = total_remaining / rate 
  else 
    new_amount = pos.exit.to_fill


  if config.exchange == 'gdax' 
    new_amount = parseFloat((Math.floor(new_amount * 1000000) / 1000000).toFixed(6))


  cb = (error) -> 
    if !error 
      pos.last_exit = last_exit 
      if !pos.reset
        pos.original_exit = last_exit
        pos.reset = tick.time

      pos.exit.created = tick.time
      pos.exit.rate = rate
      if pos.exit.type == 'buy'
        pos.exit.amount = new_amount + amt_purchased
        pos.exit.to_fill = new_amount 

      set_expected_profit pos, exchange_fee

  if pusher.update_exit
    pusher.update_exit 
      pos: pos
      trade: pos.exit
      rate: rate 
      amount: new_amount
    , cb
  else 
    cb()



force_cancel = (pos) ->

  console.log 'FORCE CANCELED', pos

  cb = -> 
    for trade in [pos.entry, pos.exit] when trade && !trade.closed
      trade.amount = trade.amount - trade.to_fill
      trade.to_fill = 0 
      trade.force_canceled = true 

  if pusher.cancel_unfilled
    pusher.cancel_unfilled pos, cb
  else
    cb()



cancel_unfilled = (pos) ->
  if pusher.cancel_unfilled 
    pusher.cancel_unfilled pos, ->
      canceled_unfilled pos
  else 
    canceled_unfilled pos


# make all meta data updates after trades have potentially been canceled. 
canceled_unfilled = (pos) ->
  for trade in ['exit', 'entry'] when !pos[trade]?.closed
    if pos[trade] && !pos[trade].current_order
      pos.last_exit = pos[trade].rate
      pos.original_exit = pos[trade].rate if !pos.original_exit?
      pos.expected_profit = undefined if pos.expected_profit
      pos.reset = tick.time if !pos.reset
      if pos[trade].fills.length == 0 
        pos[trade] = undefined

  if pos.exit && !pos.entry 
    pos.entry = pos.exit 
    pos.exit = undefined

  else if !pos.entry && !pos.exit 
    destroy_position pos



destroy_position = (pos) ->
  positions = from_cache(pos.dealer).positions
  open = open_positions[pos.dealer]

  if !config.simulation
    console.assert pos.key?, {message: 'trying to destroy a position without a key', pos: pos}

  idx = positions.indexOf(pos)
  if idx == -1
    console.log "COULD NOT DESTROY position #{pos.key}...not found in positions", pos
  else 
    positions.splice idx, 1 

  idx = open.indexOf(pos)
  if idx == -1
    console.log 'CANT DESTROY POSITION THAT ISNT IN OPEN POSITIONS'
  else 
    open.splice idx, 1  

  if !config.simulation
    pos.key = undefined



set_expected_profit = (pos, exchange_fee) -> 
  entry = pos.entry
  exit = pos.exit
  if entry && exit && entry.rate > 0 && exit.rate > 0 
    eth = btc = 0 

    for trade in [entry, exit]

      if trade.type == 'buy'
        eth += trade.amount 
        if config.exchange == 'poloniex'
          eth -= if trade.fee? then trade.fee else trade.amount * exchange_fee
        else 
          btc -= if trade.fee? then trade.fee else (trade.total or trade.amount * trade.rate) * exchange_fee
        btc -= (trade.total or trade.amount * trade.rate)
      else
        eth -= trade.amount 
        btc += (trade.total or trade.amount * trade.rate)
        btc -= if trade.fee? then trade.fee else (trade.total or trade.amount * trade.rate) * exchange_fee

    pos.expected_profit = eth + btc / exit.rate
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

LOG_REASONS = false 
is_valid_position = (pos, balance) ->  
  return false if !pos
  return true if pos.series_data

  
  settings = get_settings(pos.dealer)


  if LOG_REASONS
    failure_reasons = []

  entry = pos.entry 
  exit = pos.exit

  # Non-zero rates
  if (entry && (entry.rate == 0 or isNaN(entry.rate))) || (exit && (exit.rate == 0 or isNaN(exit.rate)))
    # console.log "Can't have a zero rate"
    return false if !LOG_REASONS
    failure_reasons.push "Can't have a zero rate"

  if entry.amount <= 0 || exit?.amount <= 0 
    return false if !LOG_REASONS
    failure_reasons.push "Can't have a negative amount"

  # Position has to have good returns if simultaneous entry / exit...
  if entry && exit && settings.min_return?
    if 100 * pos.expected_profit / exit.amount < settings.min_return  
      # console.log "#{(pos.expected_return).toFixed(2)}% is not enough expected profit"
      return false if !LOG_REASONS 
      failure_reasons.push "#{(pos.expected_return).toFixed(2)}% is not enough expected profit"

  # A strategy can't have too many positions on the books at once...
  if !settings.never_exits && open_positions[pos.dealer].length > settings.max_open_positions - 1
    # console.log "#{settings.max_open_positions} POSITIONS ALREADY ON BOOKS"
    return false if !LOG_REASONS 
    failure_reasons.push "#{settings.max_open_positions} POSITIONS ALREADY ON BOOKS"


  # Space positions from the same strategy out
  position_set = if settings.never_exits then from_cache(pos.dealer).positions else open_positions[pos.dealer]
  for other_pos in position_set
    if tick.time - other_pos.created < settings.cooloff_period
      # console.log "TOO MANY POSITIONS IN LAST #{settings.cooloff_period} SECONDS"

      return false if !LOG_REASONS 
      failure_reasons.push "TOO MANY POSITIONS IN LAST #{settings.cooloff_period} SECONDS"
      break

  if settings.alternating_types
    buys = sells = 0 
    for other_pos in open_positions[pos.dealer]
      if other_entry.type == 'buy'
        buys++
      else 
        sells++

    if (entry.type == 'buy' && buys > sells) || (entry.type == 'sell' && sells > buys)
      return false if !LOG_REASONS 
      failure_reasons.push "Positions need to alternate"


  return true #failure_reasons.length == 0 


action_priorities =
  create: 0
  exit: 1
  update_exit: 2
  cancel_unfilled: 3
  force_cancel: 4

hustle = (balance, trades) -> 
  yyy = Date.now()     
  opportunities = find_opportunities trades, balance.exchange_fee, balance
  t_.hustle += Date.now() - yyy if t_?

  if opportunities.length > 0
    #yyy = Date.now()

    # prioritize exits & cancelations over new positions
    opportunities.sort (a,b) -> action_priorities[b.action] - action_priorities[a.action]

    if config.enforce_balance
      fillable_opportunities = check_wallet opportunities, balance
    else 
      fillable_opportunities = opportunities

    # if fillable_opportunities.length != opportunities.length
    #   console.log "Slimmed opportunities from #{opportunities.length} to #{fillable_opportunities.length}"
    #   # for op in opportunities
    #   #   if op not in fillable_opportunities
    #   #     console.log 'ELIMINATED:', op.pos.dealer
    if fillable_opportunities.length > 0 
      execute_opportunities fillable_opportunities, balance.exchange_fee, balance

    #t_.exec += Date.now() - yyy if t_?

pusher = module.exports = {init, hustle, learn_strategy, destroy_position, reset_open}


