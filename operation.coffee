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
  all_lag.push Math.max 0, lag
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

  time = fetch 'time'

  console.log "TICKING! #{all_lag.length} queries with #{Math.average(all_lag)} avg lag"

  history.load_price_data (time.earliest or tick.started) - tick.history_to_keep, now(), ->
    update_position_status ->
      update_account_balances ->

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
        for pos in from_cache(name).positions when !pos.closed

          before = JSON.stringify(pos)

          for t in [pos.entry, pos.exit] when t && !t.closed && (t.orders?.length > 0 || t.force_canceled) 

            completed = true
            t.fills = []
            for order_id in t.orders when order_id
              if open_orders[order_id]
                completed = false 
                if t.force_canceled
                  console.assert false,
                    message: 'force cancel did not work'
                    pos: pos 
                    name: name 
                    trade: t
                    fills: t.fills

              if order_id of order2fills
                for new_fill in order2fills[order_id]
                  already_processed = false 
                  for old_fill in t.fills
                    already_processed = old_fill.fill_id == new_fill.fill_id
                    break if already_processed
                  continue if already_processed
                  t.fills.push new_fill


            if t.fills.length > 0 
              if t.force_canceled
                t.to_fill = 0 
                t.amount = Math.summation (f.amount for f in t.fills)
              else 
                t.to_fill = t.amount - Math.summation (f.amount for f in t.fills)


            for order_id in t.orders
              if order_id != t.current_order && (order_id of open_orders)
                console.assert false, 
                  message: "Old order not marked as completed!"
                  order: order_id 
                  trade: t


            if (t.current_order && !(t.current_order of open_orders)) || t.force_canceled 
              if t.to_fill > t.amount * .0001  #.0001 is arbitrary, meant to accommodate rounding issues
                
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

                for fill in (t.fills or [])
                  total += fill.total
                  fees += fill.fee
                  amount += fill.amount

                  if fill.date > last 
                    last = fill.date

                t.amount = amount
                t.total = total
                t.fee = fees
                t.closed = if t.force_canceled then tick.time else last

          if pos.entry?.closed && pos.exit?.closed
            buy = if pos.entry.type == 'buy' then pos.entry else pos.exit
            sell = if pos.entry.type == 'buy' then pos.exit else pos.entry

            if config.exchange == 'poloniex'
              pos.profit = (sell.total - buy.total - sell.fee) / pos.exit.rate + (buy.amount - sell.amount - buy.fee)
            else 
              pos.profit = (sell.total - buy.total - sell.fee - buy.fee) / pos.exit.rate + (buy.amount - sell.amount)
            pos.closed = Math.max pos.entry.closed, pos.exit.closed
          

          changed = JSON.stringify(pos) != before
          if changed || !pos.closed
            if changed
              console.log 'CHANGED!', pos
            bus.save pos


      status.last_checked = check_to
      save status
      callback?()
       







############################
# Live trading interface


take_position = (pos, callback) ->

  trades = (trade for trade in [pos.entry, pos.exit] when trade && !trade.current_order)
  trades_left = trades.length 

  for trade, idx in trades
    console.assert trade.amount? && trade.rate?, 
      message: 'Ummmm, you have to give an amount and a rate to place a trade...'
      trade: trade

  error = false
  for trade, idx in trades

    exchange.place_order
      type: trade.type
      amount: trade.to_fill
      rate: trade.rate
      c1: config.c1 
      c2: config.c2
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

        console.log "Placed order:", trade

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

      console.log 'MOVED POSITION', trade

    callback result.error

  if trade.current_order
    console.log 'MOVING POSITION', trade
    exchange.move_order
      order_id: trade.current_order
      rate: rate
      amount: amount
      type: trade.type
      c1: config.c1 
      c2: config.c2
    , cb

  else 

    exchange.place_order
      type: trade.type
      amount: amount
      rate: rate
      c1: config.c1 
      c2: config.c2
    , cb


cancel_unfilled = (pos, callback) ->
  trades= (trade for trade in [pos.exit, pos.entry] when trade && !trade.closed && trade.current_order)
  cancelations_left = trades.length 

  for trade in trades
    exchange.cancel_order
      order_id: trade.current_order
    , (result) -> 
      cancelations_left--

      if result?.error
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
          # used or reserved for buying remaining eth
          for_purchase = buy.to_fill * buy.rate
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




update_fee_schedule = (callback) ->
  exchange.get_my_exchange_fee {}, (result) -> 

    balance = from_cache 'balances'
    balance.maker_fee = result.maker_fee
    balance.taker_fee = result.taker_fee 

    balance.exchange_fee = .75 * balance.maker_fee + .25 * balance.taker_fee

    bus.save balance
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
      update_every_n_minutes: 20
      enforce_balance: true

    bus.save config 


    time = from_cache 'time'


    console.log 'STARTING METH'

    pusher.init {history, take_position, cancel_unfilled, update_exit}

    console.log "...updating deposit history"

    history_width = history.longest_requested_history

    console.log "...loading past #{(history_width / 60 / 60 / 24).toFixed(2)} days of trade history"

    tick.started = ts = now()
    tick.history_to_keep = history_width

    history.load_price_data (time.earliest or tick.started) - history_width, ts, ->

      history.load ts - history_width, ts, ->

        console.log "...connecting to #{config.exchange} live updates"
        
        history.subscribe_to_trade_history ->

          console.log "...updating account balances"

          # update_deposit_history ->
          update_fee_schedule -> 

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


