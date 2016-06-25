progress_bar = require('progress')


require './shared'
history = require './trade_history'

global.pusher = require('./pusher')

global.config = {}
module.exports = (conf) -> 
  

  extend config,
    tick_interval: 60 # in seconds
    simulation_width: 12 * 24 * 60 * 60
    market: 'BTC_ETH'
    trade_lag: 20
    deposit:
      BTC: 35
      ETH: 1500
    exchange_fee: .0020

  , conf

  experiment: -> 
    console.log 'Prepping the lab'

    ts = config.end or now()

    pusher.init(history, true)
    history_width = history.longest_requested_history + config.simulation_width

    console.log "...loading #{ (history_width / 60 / 60 / 24).toFixed(2) } days of trade history, relative to #{ts}"
    history.load ts - history_width, ts, -> 
      console.log "...experimenting!"
      simulate ts


# try 
#   heapdump = require('heapdump')   
#   heapdump.writeSnapshot()
# catch e 
#   console.log 'Could not take snapshot'


##################
# Globals 

price_ranges = {}



#########################
# Main event loop

global.tick = 
  time: 0 

simulate = (ts) ->   
  ts = Math.floor(ts)
  time = fetch('/time')
  extend time, 
    earliest: ts - config.simulation_width
    latest: ts
  save time


  global.t_ = 
    qtick: 0 
    # feat_calc: 0 
    hustle: 0 
    feature_tick: 0 
    quant: 0 
    executing: 0 
    eval_pos: 0 
    create_pos: 0 
    handle_new: 0 
    handle_open: 0
    x: 0 
    y: 0 
    z: 0 

  balance = fetch('/balances')

  extend balance, 
    balances:
      ETH: config.deposit.ETH 
      BTC: config.deposit.BTC 
    deposits: 
      ETH: config.deposit.ETH 
      BTC: config.deposit.BTC 
    withdrawals: 
      ETH: 0
      BTC: 0
    accounted_for: 
      ETH: 0
      BTC: 0
    exchange_fee: config.exchange_fee

  save balance

  console.log "Deposited #{balance.deposits.ETH}ETH and #{balance.deposits.BTC}BTC"


  start = ts - config.simulation_width - history.longest_requested_history
  tick.time = ts - config.simulation_width

  start_idx = history.trades.length - 1
  end_idx = start_idx
  for end_idx in [end_idx..0] by -1
    break if history.trades[end_idx].date > tick.time 

  console.log "precomputing historical price ranges"
  precompute_price_ranges ts
       
  t = ':percent :etas :elapsed :ticks' 
  for k,v of t_
    t += " #{k}-:#{k}"

  bar = new progress_bar t,
    complete: '='
    incomplete: ' '
    width: 40
    total: end_idx 

  ticks = 0
    
  started_at = Date.now()

  while true 
    t = Date.now()

    if tick.time > ts - config.tick_interval * 10
      save balance
      for name in get_dealers()
        save from_cache name

      console.log "\nDone simulating! That took #{(Date.now() - started_at) / 1000} seconds"

      break

    if ticks % 10000 == 9999
      # history.prune()
      # start_idx = history.trades.length - 1
      # end_idx = start_idx
      # for end_idx in [end_idx..0] by -1
      #   break if history.trades[end_idx].date > tick.time 

      precompute_price_ranges ts, end_idx


    start += config.tick_interval
    tick.time += config.tick_interval

    # Find trades that we care about this tick. history.trades is sorted newest first
    zzz = Date.now()    
    for idx in [start_idx..0] by -1
      start_idx = idx
      break if history.trades[start_idx].date > start 

    prev = end_idx
    for idx in [end_idx..0] by -1
      end_idx = idx
      break if history.trades[end_idx].date > tick.time 

    continue if end_idx == start_idx

    trades = history.trades.slice(end_idx, start_idx)
    t_.z += Date.now() - zzz


    # evaluate our options 
    pusher.hustle balance, trades

    # check if any positions have subsequently closed
    yyy = Date.now()
    update_position_status end_idx, balance
    t_.x += Date.now() - yyy

    yyy = Date.now()
    update_balance balance
    t_.y += Date.now() - yyy

    t_.qtick += Date.now() - t

    bar.tick prev - end_idx, extend {ticks}, t_

    # console.log calls
    ticks++





update_balance = (balance) -> 

  btc = eth = btc_on_order = eth_on_order = 0

  for dealer, positions of open_positions
    continue if get_settings(dealer).series
    for pos in positions

      buy = get_buy(pos) 
      sell = get_sell(pos) 

      if buy
        # used or reserved for buying trade.amount eth
        btc_for_purchase = buy.amount * buy.rate
        btc -= btc_for_purchase
        if buy.closed
          # got the ETH!
          eth += buy.amount 
          eth -= buy.amount * balance.exchange_fee
        else 
          btc_on_order += btc_for_purchase

      if sell 
        eth -= sell.amount

        if sell.closed
          btc += sell.amount * sell.rate
          btc -= sell.amount * sell.rate * balance.exchange_fee
        else 
          eth_on_order += sell.amount

  extend balance, 
    balances:
      BTC: config.deposit.BTC + btc + balance.accounted_for.BTC
      ETH: config.deposit.ETH + eth + balance.accounted_for.ETH
    on_order: 
      BTC: btc_on_order
      ETH: eth_on_order


position_status = {}
update_position_status = (end_idx, balance) -> 

  for name, open of open_positions 
    closed = []
    for pos in open 
      for trade in [pos.entry, pos.exit] when trade && !trade.closed
        key = "#{pos.dealer}-#{trade.created}-#{trade.entry}"
        position_status[key] ||= predicted_exit trade, end_idx

        if tick.time >= position_status[key]
          trade.closed = position_status[key]
      if pos.entry?.closed && pos.exit?.closed
        pos.closed = Math.max pos.entry.closed, pos.exit.closed
        closed.push pos 

    for pos in closed 
      open.splice open.indexOf(pos), 1 

      for trade in [pos.entry, pos.exit]
        if trade.type == 'buy'
          balance.accounted_for.ETH += trade.amount 
          balance.accounted_for.ETH -= (trade.fee or (trade.amount * balance.exchange_fee))
          balance.accounted_for.BTC -= (trade.total or trade.amount * trade.rate)
        else
          balance.accounted_for.ETH -= trade.amount 
          balance.accounted_for.BTC += (trade.total or trade.amount * trade.rate)
          balance.accounted_for.BTC -= (trade.fee or (trade.amount * trade.rate * balance.exchange_fee))





segment_range = .0001
max_segment = 0 

precompute_price_ranges = (end, idx) ->
  price_ranges = {}
  idx ||= history.trades.length - 1

  current_segment = null 
  current_segment_start = null 
  max_segment = 0 

  zzz = Date.now()

  for idx in [idx..0] by -1
    break if history.trades[idx].date > end 

    segment = Math.floor history.trades[idx].rate * 1 / segment_range

    if segment != current_segment
      if current_segment
        price_ranges[current_segment] ||= []
        price_ranges[current_segment].push [current_segment_start, idx]
        max_segment = segment if segment > max_segment

      current_segment = segment
      current_segment_start = idx 

  t_.y += Date.now() - zzz

predicted_exit = (my_trade, end_idx) -> 

  zzz = Date.now()
  segment = Math.floor my_trade.rate * 1 / segment_range
  buy = my_trade.type == 'buy'
  amount = 0 

  while !my_trade.closed && segment >= 0 && segment <= max_segment
    if price_ranges[segment]
      for [start, end] in price_ranges[segment]

        if start > end_idx
          start = end_idx

        for idx in [start..end] by -1 
          trade = history.trades[idx]
          
          continue if trade.date < my_trade.created + config.trade_lag

          if ( buy && trade.rate < my_trade.rate) || \
             (!buy && trade.rate > my_trade.rate)

            amount += trade.amount 

            if amount >= my_trade.amount
              t_.z += Date.now() - zzz

              return trade.date
    
    if buy 
      segment--
    else 
      segment++

  t_.z += Date.now() - zzz

  null


# predicted_exit = (my_trade, end_idx) -> 
#   amount = 0 
#   xxx = Date.now()


#   for idx in [end_idx..0] by -1
#     trade = history.trades[idx]

#     continue if trade.date < my_trade.created + config.trade_lag

#     if (my_trade.type == 'buy'  && trade.rate < my_trade.rate) || \
#        (my_trade.type == 'sell' && trade.rate > my_trade.rate)

#       if config.trade_success_rate < 1
#         time_from_trade = trade.date - my_trade.created 

#         # higher liklihood the farther away from initial trade
#         chance_of_success = config.trade_success_rate + time_from_trade *  time_from_trade / (60 * 60 * 60 * 60)

#       if config.trade_success_rate == 1 || Math.random() < chance_of_success
#         amount += trade.amount 

#         if amount >= my_trade.amount
#           t_.z += Date.now() - xxx
#           return trade.date

#   t_.z += Date.now() - xxx

#   null 






