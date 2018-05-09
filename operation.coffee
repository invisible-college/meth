require './shared'
global.history = require './trade_history'
exchange = require './exchange'
crunch = require './crunch'

global.pusher = require('./pusher')

# Tracking lag
laggy = false 
all_lag = []
LAGGY_THRESHOLD = 3
global.lag_logger = (lag) -> 
  all_lag.push Math.max 0, lag
  laggy = all_lag.length == 0 || Math.max(lag) > LAGGY_THRESHOLD



#########################
# Main event loop

global.tick = 
  time: null 
  # lock: false


global.no_new_orders = false 


process.on 'SIGINT', ->
  bus.save {key: 'time_to_die', now: true}


log_tick = -> 
  time = fetch 'time'
  extend time, 
    earliest: if time.earliest? then time.earliest else tick.started
    latest: tick.time
  bus.save time


unfilled_orders = -> 
  for dealer,positions of open_positions when positions.length > 0
    for pos in positions 
      if (pos.entry && !pos.entry.closed) || (pos.exit && !pos.exit.closed) 
        return true 
  return false


one_tick = ->
  # if tick.lock
  #   console.log "Skipping tick because it is still locked"
  #   return 
     
  tick.time = now()
  time = fetch 'time'  
  
  # check if we need to tick
  has_unfilled = unfilled_orders() 

  inc = if has_unfilled 
          pusher.tick_interval
        else 
          pusher.tick_interval_no_unfilled

  needs_to_run = tick.time - time.latest >= inc 

  if !needs_to_run && time.earliest?
    return


  if config.log_level > 1
    console.log "TICKING @ #{tick.time}! #{all_lag.length} messages with #{Math.average(all_lag)} avg lag"
  # tick.lock = true

  history.load_price_data 
    start: (time.earliest or tick.started) - tick.history_to_keep
    end: now()
    callback: -> 
      if config.disabled
        console.log 'disabled'
        log_tick()

        # tick.lock = false
        KPI (stats) ->
          m = stats.all.metrics                
          m.key = 'stats' 
          bus.save m
        return    

      update_position_status ->
        update_account_balances false, ->

          setImmediate -> # free thread to process any last trades
            history.last_trade = history.trades[0]

            # tick.time = now()
            if !laggy
              balance = from_cache('balances')
              pusher.reset_open()
              pusher.hustle balance

            # wait for the trades or cancelations to complete
            i = setImmediate ->

              for name in get_all_actors()
                bus.save from_cache(name)


              all_lag = []

              log_tick()
              console.log "Tick (mostly) done" if config.log_level > 1

              KPI (stats) ->
                m = stats.all.metrics                
                m.key = 'stats' 
                bus.save m


              if config.reset_every && !unfilled_orders() && (  (tick.time - (tick.started or 0) > config.reset_every * 60 * 60) || global.restart_when_possible)
                
                setTimeout ->

                  # write feature cache to disk
                  for resolution, engine of feature_engine.resolutions
                    engine.write_to_disk()

                  dealer_is_locked = false 
                  for name in get_all_actors()
                    dealer = from_cache name 
                    dealer_is_locked ||= dealer.locked 
                  
                  if !exchange.all_clear()
                    if config.log_level > 1 
                      log_error false, {message: "Want to reset, but exchange has outstanding requests", time}
                  else if dealer_is_locked
                    if config.log_level > 1 
                      console.error {message: "Want to reset, but at least one dealer is locked", time}
                  else 
                    if config.log_level > 1
                      console.log 'Due for a reset. Assuming a monitoring process that will restart the app', {reset_every: config.reset_every, time: tick.time, started: tick.started, diff: tick.time - tick.started, should: (tick.time - (tick.started or 0) > config.reset_every * 60 * 60)}
                    
                    bus.save {key: 'time_to_die', now: true}

                , 100


              # noww = now()
              # history.disconnect_from_exchange_feed()
              # history.load noww - tick.history_to_keep, noww, -> 
              #   history.subscribe_to_exchange_feed -> 
              #     tick.lock = false  #...and now we're done with this tick








######
# Helpers


update_position_status = (callback) ->
  time = from_cache 'time'
  status = fetch 'position_status'

  exchange.get_my_open_orders
    c1: config.c1 
    c2: config.c2 
  , (all_open_orders) ->

    if !all_open_orders || all_open_orders.error
      console.error("Couldn't get open orders!", all_open_orders?.error)
      callback?()
      return

    open_orders = {}
    for trade in all_open_orders
      open_orders[trade.order_id] = trade

    if status.last_checked
      start_checking_at = status.last_checked
    else 
      # date of creation of earliest open trade
      earliest = Infinity
      for name in get_dealers()
        for pos in from_cache(name).positions when !pos.closed
          if pos.created < earliest 
            earliest = pos.created

      if earliest == Infinity # no open trades to check 
        callback?()
        return

      start_checking_at = earliest

    start_checking_at -= 60 * 1000 # request an extra minute of fills to be safe
    check_to = now()



    exchange.get_my_fills 
      c1: config.c1 
      c2: config.c2 
      start: start_checking_at
      end: check_to
    , (fills) ->

      if !fills || fills.error
        console.error("Couldn't get fills!", fills?.error)
        callback?()
        return

      order2fills = {}

      for fill in fills 
        order2fills[fill.order_id] ?= []
        order2fills[fill.order_id].push fill

      for name in get_dealers()
        dealer_data = from_cache(name)

        for pos in dealer_data.positions when !pos.closed

          before = JSON.stringify(pos)

          for t,idx in [pos.entry, pos.exit] when t && !t.closed && t.orders?.length > 0
            t.fills = []

            for order_id in t.orders when order_id
              if order_id of order2fills
                for new_fill in order2fills[order_id]
                  already_processed = false 
                  for old_fill in t.fills
                    already_processed = old_fill.fill_id == new_fill.fill_id
                    break if already_processed
                  continue if already_processed
                  new_fill.type = t.type
                  t.fills.push new_fill



            if t.fills.length > 0 
              if t.flags?.market && t.type == 'buy'
                t.to_fill = t.total - Math.summation (f.total for f in t.fills)
              else 
                t.to_fill = (t.original_amt or t.amount) - Math.summation (f.amount for f in t.fills)

              if t.to_fill < 0 
                t.to_fill = 0 


            if dealer_data.locked
              # log_error false, {message: "skipping status updating because dealer is locked", name}
              bus.save pos
              continue



            orders_completed = t.orders.length > 0 
            for order_id in t.orders
              orders_completed &&= !(order_id of open_orders)
              if order_id != t.current_order && (order_id of open_orders)
                if !t.current_order
                  t.current_order = order_id
                else 
                  log_error false, 
                    message: "Old order not marked as completed!"
                    order: order_id 
                    trade: t


            if t.to_fill == 0 && !orders_completed

              console.error {message: "Nothing to fill but orders not completed", trade: t, fills: t.fills, open_orders}

            if orders_completed 
              if (  (t.flags?.market && t.type == 'buy') &&    t.to_fill > exchange.minimum_order_size(config.c1)) || \
                 ( !(t.flags?.market && t.type == 'buy') && (  t.to_fill > exchange.minimum_order_size() && \
                                                               t.to_fill * t.rate > exchange.minimum_order_size(config.c1)) )


                # Our filled amount doesn't match. We might have to issue another order. However, sometimes the exchange has marked an order
                # as matched, but the fills aren't coming just yet. So we wait a little longer to make sure it is actually not completed yet.
                key = JSON.stringify(t.orders) 
                t.assessing_clear_order_since ?= {}
                t.assessing_clear_order_since[key] ||= tick.time

                if tick.time - t.assessing_clear_order_since[key] > 5 * 60
                  delete t.assessing_clear_order_since[key]
                  # this trade still needs more fills
                  t.current_order = null 

                  console.error
                    message: "#{config.exchange} thinks we\'ve completed the trade, but our filled amount does not match. We\'ll issue another order to make up the difference."
                    trade: t 
                    fills: t.fills 
                    to_fill: t.to_fill
                    pos: pos.key
                    was_locked: dealer_data.locked

                  if dealer_data.locked
                    dealer_data.locked = false 
                    bus.save dealer_data

              else

                if !(t.fills?.length > 0)
                  log_error false, {message: "Trade is closing but had no fills", trade: t, fills: t.fills, pos}

                close_trade(pos, t)

          if pos.entry?.closed && pos.exit?.closed
            buy = if pos.entry.type == 'buy' then pos.entry else pos.exit
            sell = if pos.entry.type == 'buy' then pos.exit else pos.entry

            pos.profit = (sell.total - buy.total - (sell.c1_fees + buy.c1_fees)) / \
                          pos.exit.rate + (buy.amount - sell.amount - (buy.c2_fees + sell.c2_fees))

            pos.closed = Math.max pos.entry.closed, pos.exit.closed
          

          changed = JSON.stringify(pos) != before
          if changed || !pos.closed
            if changed && config.log_level > 1 
              console.log 'CHANGED!', pos
            bus.save pos


      status.last_checked = check_to
      save status
      callback?()
       







############################
# Live trading interface

placed_order = ({result, pos, trade}) ->  
  trade = refresh pos, trade 

  if result.error
    console.error "GOT ERROR TAKING OR MOVING POSITION", {pos, trade, err: result.error, body: result.body}

  else if !result.order_id
    result.error = "no order_id returned from placed order"
    log_error true, 
      message: "no order_id returned from placed order"
      result: result 
      pos: pos 
      trade: trade 
  else 
    new_order = result.order_id
    trade.current_order = new_order
    trade.first_order ?= tick.time
    trade.latest_order = tick.time

    trade.fills ?= []
    trade.created ?= tick.now
    trade.original_rate ?= trade.rate 
    trade.original_amt ?= trade.amount

    trade.orders ?= []
    if new_order not in trade.orders 
      trade.orders.push new_order

    if result.info 
      trade.info ?= []
      trade.info.push result.info 

    console.log "ADDED #{result.order_id} to trade", trade if config.log_level > 1 

    bus.save pos



place_dynamic_order = ({trade, amount, pos}, placed_callback) ->
  console.log 'PLACING DYNAMIC ORDER' if config.log_level > 2
  exchange.dynamic_place_order
    type: trade.type
    amount: amount
    rate: trade.rate
    c1: config.c1 
    c2: config.c2
    flags: trade.flags
    trade: trade # orphanable
    pos: pos
  , (result) -> # placed callback
    # trade = refresh pos, trade    
    placed_order {result, pos, trade}
    placed_callback result 

    if result.error 
      dealer = from_cache pos.dealer
      dealer.locked = false 
      bus.save dealer
      
  , (result) -> # updated callback
    placed_order {result, pos, trade}
  , -> # finished callback
    console.log 'UNLOCKING DEALER' if config.log_level > 2
    dealer = from_cache pos.dealer
    dealer.locked = false 
    bus.save dealer  

update_dynamic_order = ({trade, pos}) ->
  console.log 'UPDATING DYNAMIC ORDER' if config.log_level > 2
  exchange.dynamic_move_order
    trade: trade # orphanable
    pos: pos      
  , (result) -> # updated callback
    placed_order {result, pos, trade}
  , -> # finished callback
    console.log 'UNLOCKING DEALER' if config.log_level > 2
    dealer = from_cache pos.dealer
    dealer.locked = false 
    bus.save dealer  




take_position = (pos, callback) ->
  dealer = from_cache(pos.dealer)
  dealer.locked = tick.time 
  bus.save dealer

  trades = (trade for trade in [pos.entry, pos.exit] when trade && !trade.current_order && !trade.closed)
  trades_left = trades.length 

  for trade, idx in trades
    if !(trade.amount?) || !(trade.rate?)
      log_error true, 
        message: 'Ummmm, you have to give an amount and a rate to place a trade...'
        trade: trade
      return 

  error = false
  for trade in trades
    amount =  trade.to_fill
    do (trade, amount) -> 

      if amount < exchange.minimum_order_size()
        log_error false, 
          message: "trying to place an order for less than minimum" 
          minimum: exchange.minimum_order_size()
          trade: trade 
          pos: pos 
        return callback(true, trades_left) 


      if config.exchange == 'gdax' && trade.flags?.order_method > 1

        place_dynamic_order
          pos: pos
          trade: trade
          amount: amount
        , (result) ->     
          trades_left--
          error = error or result.error
          console.log 'PLACED CALLBACK', {trades_left, error, trade, entry: pos.entry, exit: pos.exit} if config.log_level > 2
          callback error, trades_left

      else
        console.log 'PLACING STATIC ORDER', {config, trade} if config.log_level > 2
        exchange.place_order
          type: trade.type
          amount: amount
          rate: trade.rate
          c1: config.c1 
          c2: config.c2
          flags: trade.flags
        , (result) ->

          trades_left--
          placed_order {result, pos, trade}
          error = error or result.error
          if trades_left <= 0 
            dealer.locked = false 
            bus.save dealer

          callback error, trades_left


update_trade = ({pos, trade, rate, amount}, callback) -> 
  trade = refresh pos, trade

  console.assert !trade.flags?.market

  dealer = from_cache(pos.dealer)
  dealer.locked = tick.time 
  bus.save dealer

  if config.log_level > 2
    console.log 'UPDATING TRAAAAADE', 
      trade: trade
      exchange: config.exchange 
      order_method: trade.flags?.order_method

  if config.exchange == 'gdax' && trade.flags?.order_method > 1    
    if trade.current_order
      update_dynamic_order
        pos: pos
        trade: trade
    else 
      place_dynamic_order
        pos: pos
        trade: trade
        amount: amount
      , (result) ->         
        callback? result.error

  else 
    cb = (result) ->
      placed_order {result, pos, trade}
      dealer.locked = false 
      bus.save dealer    
      callback? result.error


    if trade.current_order
      exchange.move_order
        order_id: trade.current_order
        rate: rate
        amount: amount
        type: trade.type
        c1: config.c1 
        c2: config.c2
        flags: trade.flags
      , cb

    else 

      exchange.place_order
        type: trade.type
        amount: amount
        rate: rate
        c1: config.c1 
        c2: config.c2
        flags: trade.flags
      , cb


cancel_unfilled = (pos, callback) ->
  trades= (trade for trade in [pos.exit, pos.entry] when trade && !trade.closed && trade.current_order)
  cancelations_left = trades.length 

  for trade in trades
    do (trade) ->
      exchange.cancel_order
        order_id: trade.current_order
      , (result) -> 
        trade = refresh pos, trade
        cancelations_left--

        if result?.error && result?.error != 'order not found'
          console.log "GOT ERROR CANCELING POSITION", {pos, cancelations_left, err, resp, body}
        else
          console.log 'CANCELED POSITION'
          delete trade.current_order
          bus.save pos if pos.key

        if cancelations_left == 0
          callback()
          bus.save pos



update_account_balances = (halt_on_error, callback) ->
  sheet = from_cache 'balances'
  initialized = false # sheet.balances?
  dealers = get_dealers()


  exchange.get_my_balance {c1: config.c1, c2: config.c2}, (result) -> 

    x_sheet = 
      balances: {}
      on_order: {}

    for currency, balance of result
      if currency == config.c1
        x_sheet.balances.c1 = parseFloat balance.available
        x_sheet.on_order.c1 = parseFloat balance.on_order
      else if currency == config.c2 
        x_sheet.balances.c2 = parseFloat balance.available
        x_sheet.on_order.c2 = parseFloat balance.on_order

    if !initialized
      c1_deposit = config.c1_deposit or x_sheet.balances.c1
      c2_deposit = config.c2_deposit or x_sheet.balances.c2

      sheet.balances = 
        c1: c1_deposit
        c2: c2_deposit
      sheet.deposits = 
        c1: c1_deposit
        c2: c2_deposit        
      sheet.on_order = 
        c1: 0 
        c2: 0 
      sheet.xchange_total = 
        c1: x_sheet.balances.c1 + x_sheet.on_order.c1
        c2: x_sheet.balances.c2 + x_sheet.on_order.c2

      # initialize, assuming equal distribution of available balance
      # between dealers 
      num_dealers = dealers.length 
      for dealer in dealers
        sheet[dealer] = 
          deposits: 
            c1: c1_deposit / num_dealers 
            c2: c2_deposit / num_dealers 
          balances: 
            c1: c1_deposit / num_dealers 
            c2: c2_deposit / num_dealers 
          on_order:
            c1: 0 
            c2: 0 

    btc = eth = btc_on_order = eth_on_order = 0

    for dealer in dealers
      if !sheet[dealer]
        log_error true, 
          message: 'dealer has no balance'
          dealer: dealer 
          balance: sheet

      positions = from_cache(dealer).positions

      dbtc = deth = dbtc_on_order = deth_on_order = 0

      for pos in positions

        if pos.entry.type == 'buy' 
          buy = pos.entry 
          sell = pos.exit
        else 
          buy = pos.exit
          sell = pos.entry


        if buy
          # used or reserved for buying remaining eth
          for_purchase = if buy.flags?.market then buy.to_fill else buy.to_fill * buy.rate
          dbtc_on_order += for_purchase
          dbtc -= for_purchase

          if buy.fills?.length > 0           
            for fill in buy.fills
              deth += fill.amount 
              dbtc -= fill.total

              if config.exchange == 'poloniex'
                deth -= fill.fee
              else 
                dbtc -= fill.fee

        if sell 
          for_sale = sell.to_fill
          deth_on_order += for_sale
          deth -= for_sale

          if sell.fills?.length > 0 
            for fill in sell.fills 
              deth -= fill.amount
              dbtc += fill.total 
              dbtc -= fill.fee
      
      btc += dbtc
      eth += deth
      btc_on_order += dbtc_on_order
      eth_on_order += deth_on_order


      dbalance = sheet[dealer]
      dbalance.balances.c1 = dbalance.deposits.c1 + dbtc
      dbalance.balances.c2 = dbalance.deposits.c2 + deth
      dbalance.on_order.c1 = dbtc_on_order
      dbalance.on_order.c2 = deth_on_order

      if dbalance.balances.c1 + dbtc_on_order < 0 || dbalance.balances.c2 + deth_on_order < 0
        fills = []
        fills_out = []
        pos = null 
        for pos in positions
          for trade in [pos.entry, pos.exit] when trade 
            fills = fills.concat trade.fills
            console.log trade if config.log_level > 1
            for fill in trade.fills
              if fill.type == 'sell'
                fills_out.push "#{pos.key}\t#{trade.entry or false}\t#{trade.created}\t#{fill.order_id}\t#{fill.total}\t-#{fill.amount}\t#{fill.fee}"
              else 
                fills_out.push "#{pos.key}\t#{trade.entry or false}\t#{trade.created}\t#{fill.order_id}\t-#{fill.total}\t#{fill.amount}\t#{fill.fee}"

        if !config.disabled
          if pos.last_error != 'Negative balance' 
            log_error halt_on_error,
              message: 'negative balance!?!'
              dealer: dealer
              balance: sheet.balances
              dbalance: sheet[dealer]
              positions: positions
              last_entry: positions[positions.length - 1]?.entry
              last_exit: positions[positions.length - 1]?.exit
              fills: fills
              fills_out: fills_out
          else 
            console.error 
              message: 'negative balance!?!'
              dealer: dealer
              balance: sheet.balances
              dbalance: sheet[dealer]
              positions: positions
              last_entry: positions[positions.length - 1]?.entry
              last_exit: positions[positions.length - 1]?.exit
              fills: fills
              fills_out: fills_out

        pos.last_error = 'Negative balance'
        bus.save pos

    sheet.balances.c1 = sheet.deposits.c1 + btc
    sheet.balances.c2 = sheet.deposits.c2 + eth
    sheet.on_order.c1 = btc_on_order
    sheet.on_order.c2 = eth_on_order


    if !config.disabled 
      if sheet.on_order.c1 != btc_on_order || sheet.on_order.c2 != eth_on_order
        global.no_new_orders = true 
        log_error halt_on_error, 
          message: "Order amounts differ"
          c1_on_order: btc_on_order
          c2_on_order: eth_on_order
          on_order: sheet.on_order

    bus.save sheet

    if !config.disabled 
      if sheet.deposits.c1 + btc > x_sheet.balances.c1 || sheet.deposits.c2 + eth > x_sheet.balances.c2
        global.no_new_orders = true 
        log_error halt_on_error, 
          message: "Dealers have more balance than available"
          c1: btc
          c2: eth
          diff_c1: x_sheet.balances.c1 - (sheet.deposits.c1 + btc)
          diff_c2: x_sheet.balances.c2 - (sheet.deposits.c2 + eth)
          deposits: sheet.deposits
          exchange_balances: x_sheet.balances



    callback?()




update_fee_schedule = (callback) ->
  exchange.get_my_exchange_fee {}, (result) -> 

    balance = from_cache 'balances'
    balance.maker_fee = result.maker_fee
    balance.taker_fee = result.taker_fee 

    bus.save balance
    callback()


migrate_data = -> 
  migrate = bus.fetch('migrations')

  if !migrate.currency_specific_fee
    console.warn 'MIGRATING FEES!'

    for key, pos of bus.cache
      if key.match('position/') && key.split('/').length == 2 && !pos.series_data
        for trade in [pos.entry, pos.exit] when trade && trade.closed
          # we'll reclose it to update info
          close_trade(pos, trade)        

    migrate.currency_specific_fee = true
    bus.save migrate 

  else if !migrate.profit_calcsss
    console.warn 'MIGRATING profit_calc!'

    for key, pos of bus.cache
      if key.match('position/') && key.split('/').length == 2 && !pos.series_data && pos.closed && (pos.profit == null || !pos.profit? || isNaN(pos.profit))
        buy = if pos.entry.type == 'buy' then pos.entry else pos.exit
        sell = if pos.entry.type == 'buy' then pos.exit else pos.entry
        pos.profit = (sell.total - buy.total - (sell.c1_fees + buy.c1_fees)) / \
                      pos.exit.rate + (buy.amount - sell.amount - (buy.c2_fees + sell.c2_fees))
        console.log pos

        bus.save pos

    migrate.profit_calcsss = true
    bus.save migrate 






operation = module.exports =
  

  start: (conf) ->

    global.config = fetch 'config'

    global.config = defaults {}, conf, config, 
      exchange: 'poloniex'
      simulation: false
      eval_entry_every_n_seconds: 60
      eval_exit_every_n_seconds: 60
      eval_unfilled_every_n_seconds: 60
      c1: 'BTC'
      c2: 'ETH'
      accounting_currency: 'USDT'
      enforce_balance: true
      log_level: 1

    bus.save config

    migrate_data() 


    time = from_cache 'time'

    console.log 'STARTING METH' if config.log_level > 1
    console.error 'STARTING METH' if config.log_level > 1
    
    bus.save {key: 'time_to_die', now: false}
    bus('time_to_die').on_save = (o) ->
      if o.now
        setTimeout process.exit, 1

    bus('die die die').on_save = (o) ->
      global.restart_when_possible = true


    if config.disabled 
      console.log "This operation is abandoned. Nothing to see here."
      return

    pusher.init {history, take_position, cancel_unfilled, update_trade}

    # load feature cache to disk
    for resolution, engine of feature_engine.resolutions
      engine.load_from_disk()

    history_width = history.longest_requested_history

    console.log "...loading past #{(history_width / 60 / 60 / 24).toFixed(2)} days of trade history" if config.log_level > 1

    tick.started = ts = now()
    tick.history_to_keep = history_width

    for name in get_all_actors()
      dealer = from_cache name 
      if dealer.locked 
        dealer.locked = false 
        bus.save dealer 
        console.error {message: "Unlocked dealer on reset. Could have bad state.", name}


    history.load_price_data 
      start: (time.earliest or tick.started) - tick.history_to_keep
      end: ts
      callback: -> 
        history.load ts - history_width, ts, ->

          history.last_trade = history.trades[0]

          console.log "...connecting to #{config.exchange} live updates" if config.log_level > 1
          
          history.subscribe_to_exchange_feed ->

            console.log "...updating account balances" if config.log_level > 1 

            update_fee_schedule -> 
              update_position_status ->

                update_account_balances true, ->

                  console.log "...hustling!" if config.log_level > 1 

                  one_tick()
                  setInterval one_tick, pusher.tick_interval * 1000


  setup: ({port, db_name, clear_old}) -> 
    global.pointerify = true
    global.upload_dir = 'static/'

    global.bus = require('statebus').serve 
      port: port
      file_store: false
      client: false

    bus.honk = false

    if clear_old && fs.existsSync(db_name)
      console.log 'Destroying old db'
      fs.unlinkSync(db_name) 

    bus.sqlite_store
      filename: db_name
      use_transactions: false

    global.save = bus.save 
    global.fetch = (key) ->
      bus.fetch deslash key 

    global.del = bus.del 

    #save key: 'operation'


    require 'coffee-script'
    require './shared'
    express = require('express')


    bus.http.use('/node_modules', express.static('node_modules'))
    bus.http.use('/node_modules', express.static('meth/node_modules'))
    bus.http.use('/meth/vendor', express.static('meth/vendor'))


    # taken from statebus server.js. Just wanted different client path.
    bus.http_serve '/meth/:filename', (filename) -> 
      filename = deslash filename

      source = bus.read_file(filename)

      if filename.match(/\.coffee$/)

        try
          compiled = require('coffee-script').compile source, 
                                                        filename: filename
                                                        bare: true
                                                        sourceMap: true
        
        catch e
          console.error('Could not compile ' + filename + ': ', e)
          return ''


        compiled = require('coffee-script').compile(source, {filename: filename, bare: true, sourceMap: true})
        source_map = JSON.parse(compiled.v3SourceMap)
        source_map.sourcesContent = source
        compiled = 'window.dom = window.dom || {}\n' + compiled.js
        compiled = 'window.ui = window.ui || {}\n' + compiled

        btoa = (s) -> return new Buffer(s.toString(),'binary').toString('base64')

        # Base64 encode it
        compiled += '\n'
        compiled += '//# sourceMappingURL=data:application/json;base64,'
        compiled += btoa(JSON.stringify(source_map)) + '\n'
        compiled += '//# sourceURL=' + filename
        return compiled

      else return source

    bus.http.get '/*', (r,res) => 

      paths = r.url.split('/')
      paths.shift() if paths[0] == ''

      prefix = ''
      server = "statei://#{get_ip_address()}:#{port}"

      html = """
        <!DOCTYPE html>
        <html>
        <head>
        <script type="coffeedom">
        bus.honk = false
          
        #</script>
        <script src="#{prefix}/node_modules/statebus/client.js" server="#{server}"></script>
        <script src="#{prefix}/meth/vendor/d3.js"></script>
        <script src="#{prefix}/meth/vendor/md5.js"></script>
        <script src="#{prefix}/meth/vendor/plotly.js"></script>


        <script src="#{prefix}/meth/shared.coffee"></script>
        <script src="#{prefix}/meth/crunch.coffee"></script>
        <script src="#{prefix}/meth/dash.coffee"></script>

        <link rel="stylesheet" href="#{prefix}/meth/vendor/fonts/Bebas Neue/bebas.css" type="text/css"/>
        
        </head>
        <body>
        </body>
        </html>
          """

      res.send(html)

    bus.http.use('/node_modules', express.static('node_modules'))


