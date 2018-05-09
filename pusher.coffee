require './shared'

global.feature_engine = require './feature_engine'
exchange = require './exchange'

global.dealers = {}
global.open_positions = {}

global.log_error = (halt, data) -> 

  if !config.simulation
    errors = bus.fetch 'errors'
    errors.logs ||= []
    error = [tick.time, JSON.stringify(data), new Error().stack]
    errors.logs.push error
    bus.save errors 

    if config.mailgun
      try
        mailgun = require('mailgun-js') 
          apiKey: config.mailgun.apiKey
          domain: config.mailgun.domain

        send_email = ({subject, message, recipient}) ->
          mailgun.messages().send
            from: config.mailgun.from
            to: recipient or config.mailgun.recipient
            subject: subject
            text: message

      catch e 
        send_email = -> 
          console.error 'could not send message beecause mailgun failed to load'

      send_email 
        subject: "Error for #{config.exchange} #{config.c1}-#{config.c2} at #{tick.time}"
        message: """
                    Data: 
                    #{error[1]}


                    Trace: 
                    #{error[2]}
                 """


  if halt 
    bus.save {key: 'time_to_die', now: true}
    console.error "Halting because of:", data
  else 
    console.error data




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

    console.assert dealer_data.settings.series || dealer.eval_unfilled_trades?, 
      message: 'Dealer has no eval_unfilled_trades method defined'
      dealer: name 

    dealers[key] = dealer 

    if ('/' + key) not in strategy.dealers
      strategy.dealers.push '/' + key
      needs_save = true 

    save dealer_data


  if needs_save
    save strategy



init = ({history, clear_all_positions, take_position, cancel_unfilled, update_trade}) -> 
  global.history = history
  for name in get_dealers() 
    dealer_data = from_cache name
    save dealer_data

  reset_open()
  clear_positions() if clear_all_positions

  pusher.last_checked_new_position = {}
  pusher.last_checked_exit = {}
  pusher.last_checked_unfilled = {}

  tick_interval = null
  tick_interval_no_unfilled = null
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

    pusher.last_checked_new_position[name] = 0
    pusher.last_checked_exit[name] = 0
    pusher.last_checked_unfilled[name] = 0


    intervals = [   
      dealer_data.settings.eval_entry_every_n_seconds or config.eval_entry_every_n_seconds
    ]

    if !dealer_data.settings.never_exits
      intervals.push dealer_data.settings.eval_exit_every_n_seconds or config.eval_exit_every_n_seconds

    if !dealer_data.settings.series
      intervals.push dealer_data.settings.eval_unfilled_every_n_seconds or config.eval_unfilled_every_n_seconds

    if !tick_interval
      tick_interval = intervals[0]

    intervals.push tick_interval
    tick_interval = Math.greatest_common_divisor intervals

    if !dealer_data.settings.series
      intervals = [   
        dealer_data.settings.eval_entry_every_n_seconds or config.eval_entry_every_n_seconds
      ]

      if !dealer_data.settings.never_exits
        intervals.push dealer_data.settings.eval_exit_every_n_seconds or config.eval_exit_every_n_seconds

      if !tick_interval_no_unfilled
        tick_interval_no_unfilled = intervals[0]

      intervals.push tick_interval_no_unfilled
      tick_interval_no_unfilled = Math.greatest_common_divisor intervals

  history_buffer = (e.num_frames * res + 1 for res, e of feature_engine.resolutions)
  history_buffer = Math.max.apply null, history_buffer

  history.set_longest_requested_history history_buffer

  pusher.take_position = take_position if take_position
  pusher.cancel_unfilled = cancel_unfilled if cancel_unfilled
  pusher.update_trade = update_trade if update_trade

  pusher.tick_interval = tick_interval
  pusher.tick_interval_no_unfilled = tick_interval_no_unfilled




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




find_opportunities = (balance) -> 

  console.assert tick?.time?,
    message: "tick.time is not defined!"
    tick: tick

  # identify new positions and changes to old positions (opportunities)
  opportunities = []

  all_actors = get_all_actors()


  ################################
  ## 1. Identify new opportunities
  for name in all_actors
    dealer_data = from_cache name
    settings = dealer_data.settings
    dealer = dealers[name]


    eval_entry_every_n_seconds = settings.eval_entry_every_n_seconds or config.eval_entry_every_n_seconds

    if tick.time - pusher.last_checked_new_position[name] < eval_entry_every_n_seconds
      continue 

    if dealer_data.locked 
      locked_for = tick.time - dealer_data.locked
      console.log "Skipping #{name} because it is locked (locked for #{locked_for}s)"
      continue

    pusher.last_checked_new_position[name] = tick.time

    
    zzz = Date.now()

    # A strategy can't have too many positions on the books at once...
    if settings.series || settings.never_exits || open_positions[name]?.length < settings.max_open_positions

    
      yyy = Date.now()

      spec = dealer.eval_whether_to_enter_new_position  
        dealer: name
        open_positions: open_positions[name]
        balance: balance      
        
      t_.eval_pos += Date.now() - yyy if t_?

      #yyy = Date.now()
      if spec 
        position = create_position spec, name
        #t_.create_pos += Date.now() - yyy if t_?

        yyy = Date.now()      
        valid = position && is_valid_position(position)
        found_match = false 

        if valid
          sell = if position.entry.type == 'sell' then position.entry else position.exit
          buy  = if position.entry.type == 'buy'  then position.entry else position.exit

          opportunities.push 
            pos: position
            action: 'create'
            required_c2: if sell then sell.amount
            required_c1: if  buy then buy.amount * buy.rate

    t_.check_new += Date.now() - zzz if t_?

    continue if dealer_data.settings.series

  ##########################################
  ## 2. Handle positions that haven't exited

  for name in all_actors when open_positions[name]?.length > 0 
    dealer_data = from_cache name
    settings = dealer_data.settings
    dealer = dealers[name]

    continue if settings.series || settings.never_exits

    eval_exit_every_n_seconds = settings.eval_exit_every_n_seconds or config.eval_exit_every_n_seconds
    if tick.time - pusher.last_checked_exit[name] < eval_exit_every_n_seconds
      continue 

    if dealer_data.locked 
      locked_for = tick.time - dealer_data.locked
      if locked_for > 60 * 60 && locked_for < 68 * 60
        log_error false, {message: "#{name} locked an excessive period of time.", dealer_data, locked_for}
      continue


    pusher.last_checked_exit[name] = tick.time

    # see if any open positions want to exit
    yyy = Date.now()      

    for pos in open_positions[name] when !pos.series_data && !pos.exit 

      opportunity = dealer.eval_whether_to_exit_position
        position: pos 
        dealer: name
        open_positions: open_positions[name]
        balance: balance 

      if opportunity
        if opportunity.action == 'exit'
          type = if pos.entry.type == 'buy' then 'sell' else 'buy'

          if type == 'sell' 
            amt = opportunity.amount or pos.entry.amount
            if amt < exchange.minimum_order_size()
              opportunity.amount = 1.02 * exchange.minimum_order_size()
              #log_error false, {message: 'resizing order so it is above minimum', opportunity, amt}
            opportunity.required_c2 = opportunity.amount or pos.entry.amount
          else 
            total = (opportunity.amount or pos.entry.amount) * opportunity.rate
            if total < exchange.minimum_order_size(config.c1)
              opportunity.amount = 1.02 * exchange.minimum_order_size(config.c1) / opportunity.rate
              #log_error false, {message: 'resizing order so it is above minimum', opportunity, total}
            opportunity.required_c1 = (opportunity.amount or pos.entry.amount) * opportunity.rate            

            
        opportunity.pos = pos 
        opportunities.push opportunity

    t_.check_exit += Date.now() - yyy if t_?


  ##########################################
  ## 3. Handle unfilled orders
  for name in all_actors when open_positions[name]?.length > 0
    dealer_data = from_cache name
    settings = dealer_data.settings
    dealer = dealers[name]

    continue if settings.series

    eval_unfilled_every_n_seconds = settings.eval_unfilled_every_n_seconds or config.eval_unfilled_every_n_seconds
    if tick.time - pusher.last_checked_unfilled[name] < eval_unfilled_every_n_seconds
      continue 

    pusher.last_checked_unfilled[name] = tick.time


    yyy = Date.now()      

    for pos in open_positions[name] when (pos.entry && !pos.entry.closed) || \
                                         (pos.exit  && !pos.exit.closed)

      unfilled = if pos.entry.closed then pos.exit else pos.entry 

      if !config.simulation 
        continue if dealer_data.locked 
        continue if config.exchange == 'gdax' && \
                    unfilled.flags?.order_method > 1 && \
                    unfilled.latest_order > tick.started && \ # make sure trades don't get stuck if there's a restart
                    unfilled.current_order
                  # because we're in the midst of a dynamically-updating order

      opportunity = dealer.eval_unfilled_trades
        position: pos 
        dealer: name
        open_positions: open_positions[name]
        balance: balance 

      if opportunity
        opportunity.pos = pos 
        opportunities.push opportunity

    t_.check_unfilled += Date.now() - yyy if t_?





  if !uniq(opportunities)
    msg = 
      message: 'Duplicate opportunities'
      opportunities: opportunities
    
    for opp,idx in opportunities
      msg["pos-#{idx}"] = opp.pos 

    log_error true, msg
    return []

  opportunities




execute_opportunities = (opportunities) -> 
  return if !opportunities || opportunities.length == 0 


  for opportunity in opportunities
    pos = opportunity.pos 

    switch opportunity.action 
      when 'create'
        take_position pos

      when 'cancel_unfilled'
        cancel_unfilled pos

      when 'exit'
        exit_position {pos, opportunity} 
        take_position pos

      when 'update_exit'
        update_trade {pos, trade: pos.exit, opportunity}

      when 'update_entry'
        update_trade {pos, trade: pos.entry, opportunity}




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
    if avail_BTC < 0 || avail_ETH < 0
      out = if config.simulation then console.log else console.log

      out false, {message: 'negative balance', dealer: name, avail_ETH, avail_BTC, dealer_opportunities: by_dealer[name], balance: dbalance}
      continue 

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


create_position = (spec, dealer) -> 
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
      trade.rate = parseFloat trade.rate.toFixed(exchange.minimum_rate_precision())
      trade.amount = parseFloat((Math.floor(trade.amount * 1000000) / 1000000).toFixed(6))

  if buy
    buy.type = 'buy'
    buy.to_fill ||= if buy.flags?.market then buy.amount * buy.rate else buy.amount
  if sell 
    sell.type = 'sell'
    sell.to_fill ||= sell.amount


  position = extend {}, spec,
    key: if !config.simulation then "position/#{dealer}-#{tick.time}" 
    dealer: dealer
    created: tick.time

    entry: if buy?.entry then buy else sell
    exit: if simultaneous then (if sell.entry then buy else sell)

  for trade in [position.entry, position.exit] when trade 
    defaults trade, 
      created: tick.time
      fills: []
      original_rate: trade.rate
      original_amt: trade.amount


  position

exit_position = ({pos, opportunity}) ->
  if !pos.entry 
    log_error false, 
      message: 'position can\'t be exited because entry is undefined'
      pos: pos
      opportunity: opportunity
    return

  rate = opportunity.rate 
  market_trade = opportunity.flags?.market 
  amount = opportunity.amount or pos.entry.amount
  type = if pos.entry.type == 'buy' then 'sell' else 'buy'

  trade = pos.exit = 
    amount: amount
    type: type
    rate: rate
    to_fill: if market_trade && type == 'buy' then amount * rate else amount
    flags: if opportunity.flags? then opportunity.flags
    entry: false
    created: tick.time
    fills: []
    original_rate: rate
    original_amt: amount

  if config.exchange == 'gdax'
    trade.rate = parseFloat trade.rate.toFixed(exchange.minimum_rate_precision())
    trade.amount = parseFloat((Math.floor(trade.amount * 1000000) / 1000000).toFixed(6))

  pos


# Executes the position entry and exit, if they exist and it hasn't already been done. 
take_position = (pos) -> 

  if pusher.take_position && !pos.series_data
    pusher.take_position pos, (error, trades_left) -> 
      took_position(pos, error, trades_left == 0) 
  else 
    took_position pos

took_position = (pos, error, destroy_if_all_errored) -> 
  if !pos.series_data && config.log_level > 1
    console.log "TOOK POSITION", pos, {error, destroy_if_all_errored} 
  if error && !config.simulation
    for trade in ['entry', 'exit'] when pos[trade]

      if !pos[trade].current_order

        if !(pos[trade].orders?.length > 0)
          pos[trade] = undefined 
        else
          console.error  
            message: "We've partially filled a trade, but an update order occurred. I think Pusher will handle this properly though :p"
            pos: pos 

    if !pos.exit && !pos.entry && destroy_if_all_errored
      return destroy_position pos 

  bus.save pos if pos.key

  if !from_cache(pos.dealer).positions
    throw "#{pos.dealer} not properly initialized with positions"

  if from_cache(pos.dealer).positions.indexOf(pos) == -1
    from_cache(pos.dealer).positions.push pos
    if !pos.series_data
      open_positions[pos.dealer].push pos


update_trade = ({pos, trade, opportunity}) ->

  rate = opportunity.rate

  if config.exchange == 'gdax'
    rate = parseFloat rate.toFixed(exchange.minimum_rate_precision())

  if isNaN(rate) || !rate || rate == 0
    return log_error false, 
      message: 'Bad rate for updating trade!',
      rate: rate 
      pos: pos 

  if trade.to_fill == 0
    return log_error false, 
      message: 'trying to move a trade that should already be closed'
      pos: pos 
      trade: trade 
      fills: trade.fills


  if trade.flags?.market 
    return log_error true, 
      message: 'trying to move a market exit'
      trade: trade 

  if trade.type == 'buy'
    # we need to adjust the *amount* we're buying because our buying power has changed
    amt_purchased = 0 
    for f in (trade.fills or [])
      amt_purchased += f.amount
    amt_remaining = (trade.original_amt or trade.amount) - amt_purchased    
    total_remaining = amt_remaining * (trade.original_rate or trade.rate)

    dbalance = from_cache('balances')[pos.dealer]
    total_available = dbalance.balances.c1 + dbalance.on_order.c1


    dealer = from_cache(pos.dealer)
    total_amt_purchased = 0
    total_amt_sold = 0 
    for pos in (dealer.positions or []) 
      for t in [pos.entry, pos.exit] when t 
        for fill in (t.fills or []) 
          if t.type == 'buy'
            total_amt_purchased += fill.amount 
          else 
            total_amt_sold += fill.amount 
    total_diff = total_amt_purchased - total_amt_sold

    if total_remaining > .99 * total_available
      # console.error 'total remaining was too much!', {dealer: pos.dealer, total_diff, amt_remaining, amt_purchased, total_available, total_remaining, orig_amt: trade.original_amt, orig_rate: trade.original_rate, rate, balance: from_cache('balances')[pos.dealer]}
      total_remaining = .99 * total_available

    new_amount = total_remaining / rate 
  else 
    new_amount = trade.to_fill


  if config.exchange == 'gdax' 
    new_amount = parseFloat((Math.floor(new_amount * 1000000) / 1000000).toFixed(6))

  trade.rate = rate 
  if trade.type == 'buy'
    trade.amount = new_amount + amt_purchased
    trade.to_fill = new_amount 

  if pusher.update_trade
    pusher.update_trade 
      pos: pos
      trade: trade # orphanable
      rate: rate 
      amount: trade.to_fill




cancel_unfilled = (pos) ->
  if pusher.cancel_unfilled 
    dealer = from_cache(pos.dealer)
    dealer.locked = tick.time 
    bus.save dealer

    pusher.cancel_unfilled pos, ->
      dealer.locked = false 
      bus.save dealer
      canceled_unfilled pos
  else 
    canceled_unfilled pos


# make all meta data updates after trades have potentially been canceled. 
canceled_unfilled = (pos) ->
  for trade in ['exit', 'entry'] when !pos[trade]?.closed
    if pos[trade] && !pos[trade].current_order
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

  if !config.simulation && !pos.key 
    return log_error true, {message: 'trying to destroy a position without a key', pos: pos}

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
is_valid_position = (pos) ->  
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

  if entry.amount <= exchange.minimum_order_size() || exit?.amount <= exchange.minimum_order_size()
    return false if !LOG_REASONS
    failure_reasons.push "Can't have a negative amount"

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



global.close_trade = (pos, trade) -> 
  amount = total = 0
  c1_fees = c2_fees = 0
  last = null

  for fill in (trade.fills or [])
    total += fill.total
    amount += fill.amount

    if trade.type == 'buy' && config.exchange == 'poloniex'
      c2_fees += fill.fee
    else 
      c1_fees += fill.fee

    if fill.date? && fill.date > last 
      last = fill.date

  extend trade, {amount, total, c1_fees, c2_fees}
  trade.to_fill = 0 
  trade.closed = last or tick.time
  trade.rate = total / amount

  if trade.original_rate?
    original_rate = trade.original_rate
    original_amt = trade.original_amt or trade.amount

    rate_before_fee = total / amount
    rate_after_fee =  (total - c1_fees) / (amount - c2_fees)

    slipped = Math.abs( original_rate - rate_before_fee ) / original_rate
    slipped_amt = slipped * original_amt
    
    overhead = Math.abs(original_rate - rate_after_fee) / original_rate
    overhead_amt = original_amt * overhead

    extend trade, {slipped, slipped_amt, overhead, overhead_amt}




action_priorities =
  create: 0
  exit: 1
  update_exit: 2
  cancel_unfilled: 3

hustle = (balance) -> 
  yyy = Date.now()     
  opportunities = find_opportunities balance
  t_.hustle += Date.now() - yyy if t_?

  if opportunities.length > 0
    yyy = Date.now()

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
    if fillable_opportunities.length > 0 && !config.disabled && !global.no_new_orders
      execute_opportunities fillable_opportunities

    t_.exec += Date.now() - yyy if t_?

pusher = module.exports = {init, hustle, learn_strategy, destroy_position, reset_open}


