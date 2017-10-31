require './shared'
global.history = require './trade_history'
exchange = require './exchange'

global.pusher = require('./pusher')

global.config = {}

# Tracking lag
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
  tick.time = now()

  console.log 'TICKING!', all_lag

  update_position_status ->
    update_account_balances ->
      history.load_price_data tick.started - tick.history_to_keep, now(), ->

        setTimeout -> # free thread to process any last trades
          tick.time = now()
          if !laggy
            balance = from_cache('balances')
            pusher.reset_open()
            pusher.hustle balance, history.trades

          # wait for the trades or cancelations to complete
          i = setInterval ->

            if exchange.all_clear()

              clearInterval i

              history.prune()

              for name in get_all_actors()
                bus.save from_cache(name)


              tick.lock = false  #...and now we're done with this tick
              all_lag = []

              time = from_cache('time')
              extend time, 
                earliest: if time.earliest? then time.earliest else tick.started
                latest: tick.time
              bus.save time          
          , 10
  
 
 


######
# Helpers


update_position_status = (callback) ->
  time = from_cache 'time'

  exchange.get_your_trade_history 
    c1: config.c1 
    c2: config.c2 
    start: 0 # time.earliest
    end: now()
  , (trade_history) ->

    exchange.get_your_open_orders
      c1: config.c1 
      c2: config.c2 
    , (all_open_orders) ->

      if !trade_history || !all_open_orders || trade_history.error || all_open_orders.error
        callback?()
        return

      completed_trades = {}
      for trade in trade_history
        completed_trades[trade.order_id] ||= [] 
        completed_trades[trade.order_id].push trade

      open_orders = {}
      for trade in all_open_orders
        open_orders[trade.order_id] = trade

      for name in get_dealers()
        positions = from_cache(name).positions
        # missing_id = []

        for pos in positions when !pos.closed
          before = JSON.stringify(pos)

          for t in [pos.entry, pos.exit] when t && !t.closed && t.orders?.length > 0 

            completed = true
            t.fills = []
            for order_id in t.orders when order_id
              if completed_trades[order_id]
                t.fills = t.fills.concat completed_trades[order_id]
              else 
                completed = false

            if t.fills.length > 0 
              t.to_fill = t.amount - Math.summation (f.amount for f in t.fills)

            
            if t.current_order && completed_trades[t.current_order] && !open_orders[t.current_order] 
              if t.to_fill > t.amount * .0001
                
                console.error
                  message: 'Exchange thinks we\'ve completed the trade, but our filled amount does not seem to match'
                  trade: t 
                  fills: t.fills 
                  to_fill: t.to_fill
                  pos: pos.key

              else 

                total = 0
                fees = 0
                last = 0
                amount = 0

                for order_id in t.orders when order_id 
                  if !(order_id of completed_trades)
                    for fill in t.fills 
                      if fill.order_id == order_id
                        console.assert false, 
                          message: 'Order id not found in completed trades'
                          order_id: order_id
                          trade: t
                          order: t.orders 
                          fills: t.fills
                    continue

                  for ct in completed_trades[order_id]
                    total += parseFloat ct.total
                    fees += ct.fee
                    amount += parseFloat ct.amount

                    if ct.date > last 
                      last = ct.date

                t.amount = Math.round(100000 * amount) / 100000
                t.total = Math.round( 100000 * total) / 100000
                t.fee = fees
                t.closed = last / 1000

          if pos.entry?.closed && pos.exit?.closed
            buy = if pos.entry.type == 'buy' then pos.entry else pos.exit
            sell = if pos.entry.type == 'buy' then pos.exit else pos.entry
            pos.profit = (sell.total - buy.total - sell.fee) / pos.exit.rate + (buy.amount - sell.amount - buy.fee)
            pos.closed = Math.max pos.entry.closed, pos.exit.closed
          
          if pos.entry?.closed && pos.rebalancing
            pos.closed = pos.entry.closed

          changed = JSON.stringify(pos) != before
          if changed || !pos.closed
            if changed
              console.log 'CHANGED!', pos
            bus.save pos

          # if (pos.exit && !pos.exit.order_id) || (pos.entry && !pos.entry.order_id)
          #   missing_id.push pos 


        # # These positions had something go wrong ... one or both of the trades don't have an order_id
        # for pos in missing_id
        #   console.log "ADJUSTING FOR MISSING ID!", pos
        #   for trade in ['exit', 'entry']
        #     if pos[trade] && !pos[trade].order_id 
        #       pos.original_exit = pos[trade].rate if !pos.original_exit?
        #       delete pos[trade]
        #       delete pos.expected_profit if pos.expected_profit
        #       pos.reset = tick.time if !pos.reset 

        #   if pos.exit && !pos.entry 
        #     pos.entry = pos.exit 
        #     delete pos.exit
        #     save pos

        #   else if !pos.entry && !pos.exit 
        #     pusher.destroy_position pos
        #     save from_cache(pos.dealer)

        #   else 
        #     save pos


      callback?()
       







############################
# Live trading interface


take_position = (pos, callback) ->

  trades = (trade for trade in [pos.entry, pos.exit] when trade && !trade.current_order)
  trades_left = trades.length 

  for trade, idx in trades
    console.log trade
    console.assert trade.amount? && trade.rate?, 
      message: 'Ummmm, you have to give an amount and a rate to place a trade...'
      trade: trade

  error = false
  for trade, idx in trades

    exchange.place_order
      type: trade.type
      amount: trade.to_fill
      rate: trade.rate
      currency_pair: "#{config.c1}_#{config.c2}"
    , do (trade, idx) -> (result) ->

      trades_left--

      if result.error 
        error = true 
        err = result.error     
        console.log "GOT ERROR TAKING POSITION", {pos, trades_left, err}
        
      else 
        trade.current_order = result.order_id
        trade.orders ||= []
        if trade.current_order && trade.current_order not in trade.orders 
          trade.orders.push trade.current_order

      if trades_left == 0 
        callback error
        bus.save pos if pos.key


update_exit = (opts, callback) -> 
  {pos, trade, rate, amount} = opts 

  cb = (result) -> 
    if result.error
      err = result.error
      console.log "GOT ERROR MOVING POSITION", {pos, err}
    else

      new_order = result.order_id
      if new_order && new_order not in trade.orders 
        trade.orders.push new_order
      trade.current_order = new_order
      bus.save pos if pos.key

      console.log 'MOVED POSITION'

    callback result.error

  if trade.current_order
    exchange.move_order
      order_id: trade.current_order
      rate: rate
      amount: amount
    , cb

  else 
    exchange.place_order
      type: trade.type
      amount: amount
      rate: rate
      currency_pair: "#{config.c1}_#{config.c2}"
    , cb




cancel_unfilled = (pos, callback) ->
  trades= (trade for trade in [pos.exit, pos.entry] when trade && !trade.closed && trade.current_order)
  cancelations_left = trades.length 

  for trade in trades
    exchange.cancel_order
      order_id: trade.current_order
    , (result) -> 
      cancelations_left--

      if result.error
        console.log "GOT ERROR CANCELING POSITION", {pos, cancelations_left, err, resp, body}
      else
        console.log 'CANCELED POSITION'
        delete trade.current_order
        bus.save pos if pos.key

      if cancelations_left == 0
        callback()
        bus.save pos if pos.key



update_account_balances = (callback) ->
  sheet = from_cache 'balances'
  initialized = sheet.balances?
  dealers = get_dealers()

  exchange.get_your_balance {}, (result) -> 
    x_sheet = 
      balances: {}
      on_order: {}

    for currency, balance of result
      if currency == config.c1
        x_sheet.balances.c1 = parseFloat balance.available
        x_sheet.on_order.c1 = parseFloat balance.onOrders
      else if currency == config.c2 
        x_sheet.balances.c2 = parseFloat balance.available
        x_sheet.on_order.c2 = parseFloat balance.onOrders

    if !initialized
      c1_budget = config.c1_budget or x_sheet.balances.c1
      c2_budget = config.c2_budget or x_sheet.balances.c2

      sheet.balances = 
        c1: c1_budget
        c2: c2_budget
      sheet.deposits = 
        c1: c1_budget
        c2: c2_budget        
      sheet.on_order = 
        c1: 0 
        c2: 0 

      # initialize, assuming equal distribution of available balance
      # between dealers 
      num_dealers = dealers.length 
      for dealer in dealers
        sheet[dealer] = 
          deposits: 
            c1: c1_budget / num_dealers 
            c2: c2_budget / num_dealers 
          balances: 
            c1: c1_budget / num_dealers 
            c2: c2_budget / num_dealers 
          on_order:
            c1: 0 
            c2: 0 

    btc = eth = btc_on_order = eth_on_order = 0

    for dealer in dealers
      console.assert sheet[dealer], 
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
          # used or reserved for buying trade.amount eth
          btc_for_purchase = buy.amount * buy.rate
          dbtc -= btc_for_purchase
          dbtc_on_order += btc_for_purchase

          if buy.fills?.length > 0
            for fill in buy.fills
              deth += fill.amount 
              deth -= fill.fee
              dbtc_on_order -= fill.total

        if sell 
          eth_for_purchase = sell.amount
          deth -= eth_for_purchase
          deth_on_order += eth_for_purchase

          if sell.fills?.length > 0 
            for fill in sell.fills 
              dbtc += fill.total 
              dbtc -= fill.fee
              deth_on_order -= fill.amount
      
      btc += dbtc 
      eth += deth 
      btc_on_order += dbtc_on_order
      eth_on_order += deth_on_order

      dbalance = sheet[dealer]
      dbalance.balances.c1 = dbalance.deposits.c1 + dbtc
      dbalance.balances.c2 = dbalance.deposits.c2 + deth
      dbalance.on_order.c1 = dbtc_on_order
      dbalance.on_order.c2 = deth_on_order

      console.assert dbalance.balances.c1 >= 0 && dbalance.balances.c2 >= 0, 
        message: 'negative balance!?!'
        dealer: dealer
        balance: sheet.balances
        dbalance: sheet[dealer]
        positions: positions
        dealer: from_cache(dealer).positions

    sheet.balances.c1 = sheet.deposits.c1 + btc
    sheet.balances.c2 = sheet.deposits.c2 + eth
    sheet.on_order.c1 = btc_on_order
    sheet.on_order.c2 = eth_on_order


    console.assert sheet.on_order.c1 == btc_on_order && sheet.on_order.c2 == eth_on_order, 
      message: "Order amounts differ"
      c1_on_order: btc_on_order
      c2_on_order: eth_on_order
      on_order: sheet.on_order

    console.assert sheet.deposits.c1 + btc <= x_sheet.balances.c1 && sheet.deposits.c2 + eth <= x_sheet.balances.c2,
      message: "Dealers have more balance than available"
      c1: sheet.deposits.c1 + btc
      c2: sheet.deposits.c2 + eth
      exchange_balances: x_sheet.balances


    bus.save sheet

    callback?()



# update_deposit_history = (callback) ->
#   exchange.get_your_deposit_history
#     start: 0
#     end: now()
#   , (result) -> 

#     console.assert !result.error, 
#       message: "COULD NOT UPDATE DEPOSIT HISTORY"
#       error: result.error 
#       response: result.response
#       error_message: result.message

#     sheet = from_cache 'balances'
#     sheet.deposits = {}
#     sheet.withdrawals = {}

#     for deposit in (result.deposits or [])
#       currency = deposit.currency
#       if currency == config.c1 
#         sheet.deposits.c1 ||= 0
#         sheet.deposits.c1 += parseFloat(deposit.amount)
#       else if currency == config.c2
#         sheet.deposits.c2 ||= 0
#         sheet.deposits.c2 += parseFloat(deposit.amount)

#     for withdrawal in (result.withdrawals or [])
#       currency = withdrawal.currency
#       if currency == config.c1 
#         sheet.withdrawals.c1 ||= 0
#         sheet.withdrawals.c1 += parseFloat(withdrawal.amount)
#       else if currency == config.c2
#         sheet.withdrawals.c2 ||= 0
#         sheet.withdrawals.c2 += parseFloat(withdrawal.amount)

#     bus.save sheet

#     if callback
#       callback()


update_fee_schedule = (callback) ->
  exchange.get_your_exchange_fee {}, (result) -> 
    console.assert !result.error, 
      error: result.error

    balance = from_cache 'balances'
    balance.exchange_fee = (parseFloat(result.makerFee) + parseFloat(result.takerFee)) / 2
    fee_schedule = from_cache 'fee_schedule'
    extend fee_schedule, result 
    bus.save balance
    bus.save fee_schedule
    callback()





operation = module.exports =
  

  start: (conf) ->
    global.config = defaults config, conf, 
      key: 'config'
      exchange: 'poloniex'
      simulation: false
      tick_interval: 60
      c1: 'BTC'
      c2: 'ETH'
      accounting_currency: 'USDT'
      checks_per_frame: 2
      enforce_balance: true

    bus.save config 


    time = from_cache 'time'


    console.log 'STARTING METH'

    pusher.init {history, take_position, cancel_unfilled, update_exit}

    console.log "...updating deposit history"

    # update_deposit_history ->
    update_fee_schedule -> 
      history_width = history.longest_requested_history

      console.log "...loading past #{(history_width / 60 / 60 / 24).toFixed(2)} days of trade history"

      tick.started = ts = now()
      tick.history_to_keep = history_width

      history.load_price_data (time.earliest or ts) - history_width, ts, ->

        history.load ts - history_width, ts, ->

          console.log "...connecting to #{config.exchange} live updates"
          
          history.subscribe_to_trade_history ->

            console.log "...updating account balances"

            update_account_balances ->
    
              update_position_status ->

                console.log "...hustling!"

                one_tick()
                setInterval one_tick, config.tick_interval * 1000

  setup: ({port, db_name, clear_old}) -> 
    global.pointerify = true
    global.upload_dir = 'static/'

    global.bus = require('statebus').serve 
      port: port
      file_store: false
      client: false

    bus.honk = false

    if clear_old && fs.existsSync(db_name)
      fs.unlinkSync(db_name) 

    bus.sqlite_store
      filename: db_name
      use_transactions: true

    global.save = bus.save 
    global.fetch = (key) ->
      bus.fetch deslash key 

    global.del = bus.del 

    save key: 'operation'


    require 'coffee-script'
    require './shared'
    express = require('express')


    bus.http.use('/node_modules', express.static('node_modules'))
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
      server = "statei://localhost:#{port}"

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


