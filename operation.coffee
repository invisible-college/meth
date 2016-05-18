require './shared'
history = require './trade_history'
poloniex = require './poloniex'


global.config = {}

fetch('/all_data')

module.exports = (conf, pusher) ->
  global.pusher = pusher

  extend config,
    free_funds_if_needed: false
    tick_interval: 60
    market: 'BTC_ETH'
    take_position: take_position
    cancel_unfilled: cancel_unfilled
    take_position: take_position

  , conf

  start: ->
    # migrate_data()

    console.log 'STARTING METH'

    console.log "...updating deposit history"

    update_deposit_history ->

      update_fee_schedule -> 

        history_width = history.longest_requested_history()

        console.log "...loading past #{(history_width / 60 / 60 / 24).toFixed(2)} days of trade history"
        ts = now()

        history.load ts - history_width, ts, ->
          console.log "...connecting to Poloniex live updates"
          history.subscribe_to_poloniex()

          console.log "...updating account balances"

          update_account_balances ->
            console.log "...hustling!"

            one_tick()
            setInterval one_tick, config.tick_interval * 1000




##################
# Globals

all_positions = {}


laggy = false 
all_lag = []
LAGGY_THRESHOLD = 3
global.lag_logger = (lag) -> 
  all_lag.push lag
  laggy = all_lag.length == 0 || Math.max(lag) > LAGGY_THRESHOLD




#########################
# Main event loop

global.tick = 
  time: null 
  lock: false


one_tick = ->
  return if tick.lock


  tick.lock = true
  trades_to_execute = 0

  tick.time = now()

  if !laggy
    to_update = new_position = null 

    balance = fetch('/balances')

    open_positions = {}
    earliest = Infinity
    for name in get_strategies()
      all_positions[name] = fetch("/positions/#{name}")
      all_positions[name].positions ||= []
      open_positions[name] = (p for p in (all_positions[name].positions or []) when !p.closed)

      earliest = Math.min earliest, (Math.min.apply null, (p.created for p in all_positions[name].positions))

    pusher.hustle open_positions, all_positions, balance, history.trades


    for k,v of all_positions
      save v 

    time = fetch('/time')
    extend time, 
      earliest: earliest
      latest: tick.time
    save time


  # wait for the trades or cancelations to complete, then do accounting work
  i = setInterval ->
    if poloniex.all_clear()

      clearInterval i

      history.prune()

      update_position_status ->
        update_account_balances ->
          tick.lock = false  #...and now we're done with this tick
          all_lag = []
          if config.exposure && history.trades.length > 0
            pusher.set_exposure(config.exposure, history.trades[0].rate)

  , 10
 
 


######
# Helpers


update_position_status = (callback) ->

  poloniex.query_trading_api
    command: 'returnTradeHistory'
    currencyPair: config.market
    start: 0
    end: now()
  , (err, resp, trade_history) ->

    poloniex.query_trading_api
      command: 'returnOpenOrders'
      currencyPair: config.market
    , (err, resp, all_open_orders) ->

      if !trade_history || !all_open_orders || trade_history.error || all_open_orders.error
        callback?()
        return

      completed_trades = {}
      for trade in trade_history
        completed_trades[trade.orderNumber] ||= [] 
        completed_trades[trade.orderNumber].push trade

      open_orders = {}
      for trade in all_open_orders
        open_orders[trade.orderNumber] = trade

      # console.log completed_trades
      # console.log 'strange!', completed_trades['53294627173'], completed_trades['53289725080']

      for name, positions of all_positions 
        missing_id = []

        for pos in positions.positions
          found = true

          before = JSON.stringify(pos)


          for t in [pos.entry, pos.exit] when t
            found &&= !!(completed_trades[t.order_id] || open_orders[t.order_id])            


            if t.order_id && completed_trades[t.order_id] && !open_orders[t.order_id]
              total = 0
              fees = 0
              last = 0
              amount = 0

              for ct in completed_trades[t.order_id]
                total += parseFloat ct.total
                fees += parseFloat(ct.fee) * ct.amount * (if t.type == 'sell' then t.rate else 1)
                amount += parseFloat ct.amount

                d = Date.parse(ct.date + " +0000")
                if d > last 
                  last = d 

              t.amount = Math.round(100000 * amount) / 100000
              t.total = Math.round( 100000 * total) / 100000
              t.fee = fees
              t.closed = last / 1000
              save t 

          if found && pos.entry?.closed && pos.exit?.closed

            buy = if pos.entry.type == 'buy' then pos.entry else pos.exit
            sell = if pos.entry.type == 'buy' then pos.exit else pos.entry

            profit = (sell.total - buy.total - sell.fee) / pos.exit.rate + (buy.amount - sell.amount - sell.fee)

            extend pos,
              closed: Math.max pos.entry.closed, pos.exit.closed
              profit: profit
              returns: 100 * profit / sell.amount

          changed = JSON.stringify(pos) != before
          if changed || !pos.closed
            
            if changed
              console.log 'CHANGED!', pos
            save pos

            # for some reason, statebus isn't sending updates to individual positions
            # through to the dash. But new positions go through. So I'll update something
            # on the key that seems to work.
            positions.updated ||= 0
            positions.updated += 1
            save positions


          missing_id.push pos if (pos.exit && !pos.exit.order_id) || (pos.entry && !pos.entry.order_id)


        # These positions had something go wrong ... one or both of the trades don't have an order_id
        for pos in missing_id
          console.log "ADJUSTING FOR MISSING ID!", pos
          for trade in ['exit', 'entry']
            if pos[trade] && !pos[trade].order_id 
              pos.original_exit = pos[trade].rate if !pos.original_exit?
              delete pos[trade]
              delete pos.expected_profit if pos.expected_profit
              delete pos.expected_return if pos.expected_return    
              pos.reset = tick.time if !pos.reset 

          if pos.exit && !pos.entry 
            pos.entry = pos.exit 
            delete pos.exit
            save pos

          else if !pos.entry && !pos.exit 
            pusher.destroy_position(pos, positions, open_positions[pos.strategy])
            save positions

          else 
            save pos


        callback?()
     







############################
# Poloniex interface


# TODO: handle error case gracefully! 
take_position = (pos, callback) ->
  trades = (trade for trade in [pos.entry, pos.exit] when trade && !trade.created)

  error = false
  for trade, idx in trades

    poloniex.query_trading_api
      command: trade.type
      amount: trade.amount
      rate: trade.rate
      currencyPair: config.market
    , do (trade, idx) -> (err, resp, body) ->
      if body.error
        error = true 
        console.log "GOT ERROR TAKING POSITION: #{body.error}"
      else 
        trade.order_id = body.orderNumber
        trade.created = tick.time 

      if idx == trades.length - 1
        callback error
        save pos

      save trade


# TODO: test error state handling
cancel_unfilled = (pos, callback) ->
  trades= (trade for trade in [pos.exit, pos.entry] when trade && !trade.closed && trade.order_id)
  cancelations_left = trades.length 

  for trade in trades
    poloniex.query_trading_api
      command: 'cancelOrder'
      orderNumber: trade.order_id
    , do (trade) -> (err, resp, body) ->
      cancelations_left--

      if body.error == 'Invalid order number, or you are not the person who placed the order.'
        # this happens if the trade got canceled outside the system or on a previous run that failed
        delete body.error 

      if body.error
        console.log "GOT ERROR CANCELING POSITION: #{body.error}", pos
      else
        console.log 'CANCELED POSITION', {pos, cancelations_left, err, resp, body}
        delete trade.order_id
        save trade

      if cancelations_left == 0
        callback()
        save pos if pos.key




update_account_balances = (callback) ->
  poloniex.query_trading_api
    command: 'returnCompleteBalances'
  , (err, response, body) ->

    sheet = fetch '/balances'
    sheet.balances ||= {}
    sheet.on_order ||= {}

    for currency, balance of body
      if currency in config.market.split('_')
        sheet.balances[currency] = parseFloat balance.available
        sheet.on_order[currency] = parseFloat balance.onOrders

    save sheet

    if callback
      callback()

update_deposit_history = (callback) ->
  poloniex.query_trading_api
    command: 'returnDepositsWithdrawals'
    start: 0
    end: now()
  , (err, response, body) ->

    if body.error
      throw "COULD NOT UPDATE DEPOSIT HISTORY: #{body.error}"

    sheet = fetch '/balances'
    sheet.deposits = {}
    sheet.withdrawals = {}

    for deposit in (body.deposits or [])
      sheet.deposits[deposit.currency] ||= 0
      sheet.deposits[deposit.currency] += parseFloat(deposit.amount)

    for withdrawal in (body.withdrawals or [])
      sheet.withdrawals[withdrawal.currency] ||= 0
      sheet.withdrawals[withdrawal.currency] += parseFloat(withdrawal.amount)

    save sheet

    if callback
      callback()


update_fee_schedule = (callback) -> 
  poloniex.query_trading_api
    command: 'returnFeeInfo'
  , (err, response, body) ->
    balance = fetch '/balances'
    balance.exchange_fee = (parseFloat(body.makerFee) + parseFloat(body.takerFee)) / 2
    fee_schedule = fetch '/fee_schedule'
    extend fee_schedule, body 
    save balance
    save fee_schedule
    callback()
    

##################
# Accept commands from the client dash

# bus('/change_settings').on_pub = (settings) ->
 
#   if settings.settings
#     s = fetch("/strategies/#{settings.strategy}")
#     extend s.settings, settings.settings
#     delete settings.settings
#     delete settings.strategy
#     save settings
#     save s



