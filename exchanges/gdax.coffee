Gdax = require('gdax')
fs = require('fs')
BigNumber = require('bignumber.js')


MAX_RATE_LIMIT = RATE_LIMIT = 3

clients = 
  public: {}
  authenticated: {}

public_api = 
  getProducts: 1
  getProductOrderBook: 1
  getProductTicker: 1
  getProductTrades: 1
  getProductTradeStream: 1
  getProductHistoricRates: 1
  getProduct24HrStats: 1
  getCurrencies: 1
  getTime: 1



GDAX_client = (opts, method) ->
  product_id = "#{opts?.c2 or config.c2}-#{opts?.c1 or config.c1}"

  if !(method of public_api) && api_credentials?
    clients.authenticated[product_id] ?= new Gdax.AuthenticatedClient api_credentials.key, api_credentials.secret, api_credentials.pass
    client = clients.authenticated[product_id]
  else 
    clients.public[product_id] ?= new Gdax.PublicClient()
    client = clients.public[product_id]

  client.productID = product_id  
  client
    
write_trades = (hour, trades, c1, c2) -> 
  if hour + 1 <= current_hour && trades?.length > 0
    fname = "trade_history/gdax/#{c1}_#{c2}/#{hour}"    

    if !fs.existsSync(fname)
      fs.writeFileSync fname, JSON.stringify(trades), 'utf8' 





times_sent = []
path = require 'path'

api_call_dir = './.gdax_api_calls'
if !fs.existsSync api_call_dir
  fs.mkdirSync api_call_dir

get_wait = ->
  # console.time('get_wait')
  noww = Date.now()
  fname = "#{config.c1}_#{config.c2}_#{bus.port}"

  while times_sent.length > 0 && noww - times_sent[0] > 1000
    times_sent.shift()

  all_api_calls = times_sent.slice()

  for file in fs.readdirSync api_call_dir
    if file != fname
      try
        other_api_calls = JSON.parse fs.readFileSync(path.join(api_call_dir, file), 'utf8')
      catch e
        other_api_calls = []
      for time in other_api_calls
        if noww - time <= 1000
          all_api_calls.push time 

  if all_api_calls.length < RATE_LIMIT
    wait_for = 0 
  else 
    earliest = all_api_calls[0]
    
    wait_for = earliest + 1000 - noww
    if wait_for < 0 
      wait_for = 0

  # Log the time it *will be* called in the future.
  # This *assumes* the caller will wait for the given amount of time before issuing
  times_sent.push noww + wait_for

  fs.writeFileSync path.join(api_call_dir, fname), JSON.stringify(times_sent), 'utf8' 

  # console.timeEnd('get_wait')

  wait_for 




throttle = ({method, productID, opts, cb}) ->
  client = GDAX_client opts, method # todo: access either public or authenticated singleton client depending on method


  outstanding_requests += 1
  setTimeout -> 
    ts = now()

    callback = (err, response, data) -> 
      lag_logger? now() - ts 

      if data?.message == 'Rate limit exceeded'        
        if Math.random() > .9 && RATE_LIMIT > 1
          RATE_LIMIT--
          console.log "*-#{RATE_LIMIT}*" if config.log_level > 1
        else 
          console.log '***' if config.log_level > 1

      else if RATE_LIMIT < MAX_RATE_LIMIT && Math.random() > .95
        RATE_LIMIT++
        console.log "*+#{RATE_LIMIT}" if config.log_level > 1

      outstanding_requests -= 1
      cb err, response, data

    if !productID && !opts 
      client[method] callback 
    else if !productID && opts
      client[method] opts, callback 
    else 
      client[method] productID, opts, callback 
      
  , get_wait()


trade_ids = {}
get_trades = (c1, c2, hours, after, stop_when_cached, callback, stop_after_hour) -> 
  productID = "#{c2}-#{c1}"
  cb = (error, response, data) -> 
    get_trade_depth += 1 

    if error || !data || data?.message || !response

      if data?.message != 'Rate limit exceeded'
        console.error {message: 'error downloading trades! trying again', error: error, data: data, c1, c2, after, stop_when_cached, callback, stop_after_hour}
      
      throttle 
        method: 'getProductTrades' 
        productID: productID
        opts: {after, limit}
        cb: cb 
      return

    later_hour = early_hour = null
    for trade in (data or [])
      time = new Date(trade.time).getTime() / 1000
      hour = Math.floor(time / 60 / 60)

      hours[hour] ?= []
      if trade.trade_id not of trade_ids        
        hours[hour].push 
          date: time 
          rate: parseFloat(trade.price)
          amount: parseFloat(trade.size)
          total: parseFloat(trade.size) * parseFloat(trade.price)
          tradeID: trade.trade_id
          type: trade.side

        trade_ids[trade.trade_id] = 1

      if !later_hour
        later_hour = hour

      early_hour = hour

    try 
      process.stdout.clearLine()
      process.stdout.cursorTo 0
      process.stdout.write "Loading GDAX history #{c1}-#{c2}: #{get_trade_depth}, #{early_hour}, #{after}, #{(100 * get_trade_depth * limit / latest_page).toPrecision(4)}%"
    catch e 
      "probably in pm2"

    continue_loading = true
    if stop_when_cached
      continue_loading = !fs.existsSync("trade_history/gdax/#{c1}_#{c2}/#{early_hour}") || !fs.existsSync("trade_history/gdax/#{c1}_#{c2}/#{early_hour - 1}")
    if stop_after_hour
      continue_loading = early_hour >= stop_after_hour

    continue_loading &&= get_trade_depth * limit < latest_page && ('cb-after' of response.headers)

    if continue_loading
      if later_hour != early_hour # done processing this hour
        hr = later_hour
        while hr > early_hour
          write_trades hr, hours[hr], c1, c2
          hr -= 1

      get_trades c1, c2, hours, response.headers['cb-after'], stop_when_cached, callback, stop_after_hour

    else 
      callback?(hours)

  throttle 
    method: 'getProductTrades' 
    productID: productID
    opts: {after, limit}
    cb: cb   





limit = 100
get_trade_depth = 0 
latest_page = null
current_hour = null

load_trades = (opts) -> 
  productID = "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"

  dir = "trade_history/gdax/#{opts.c1}_#{opts.c2}"
  if !fs.existsSync dir 
    fs.mkdirSync dir

  cb = (error, response, data) -> 

    if error || !data || data.message || !response
      if data?.message != 'Rate limit exceeded'
        console.error {message: 'error downloading trades! trying again', error: error, data: data}
      
      throttle 
        method: 'getProductTrades' 
        productID: productID
        opts: {limit: 1}
        cb: cb 

    else 
      get_trade_depth = 0 # used in recursion for get_trades
      current_hour = Math.floor(new Date(data[0].time).getTime() / 1000 / 60 / 60)

      latest_page = opts.starting_page or response.headers['cb-before'] 
      trade_ids = {}
      get_trades opts.c1, opts.c2, {}, latest_page, opts.stop_when_cached, opts.cb, opts.stop_after_hour
  

  throttle 
    method: 'getProductTrades' 
    productID: productID
    opts: {limit: 1}
    cb: cb 




_find_page_for_hour = (productID, hour, current_page, previous_page, previous_previous_page, callback) -> 
  target_hour = hour + 1

  if hour >= current_hour
    return callback(current_page)

  if current_page == previous_page
    current_page -= 1
     
  cb = (error, response, data) -> 
    if error || !data || data.message

      if data?.message == 'Invalid value for pagination after'
        callback 0 
        return
      else if data?.message != 'Rate limit exceeded'
        console.error {message: 'error downloading trades! trying again', error, data, hour, current_page, previous_page}

      throttle 
        method: 'getProductTrades' 
        productID: productID
        opts: {after: current_page, limit}
        cb: cb

    else 

      early_hour = later_hour = null
      for trade in (data or [])
        time = new Date(trade.time).getTime() / 1000
        hr = Math.floor(time / 60 / 60)
        if !later_hour
          later_hour = hr
        early_hour = hr

      try 
        process.stdout.clearLine()
        process.stdout.cursorTo 0
        process.stdout.write "Finding GDAX history for #{config.c1}-#{config.c2} #{hour}: #{early_hour}, #{later_hour}, #{current_page}"
      catch e 
        "probably running in pm2"

      if early_hour <= target_hour && later_hour >= target_hour
        callback(current_page)
      else 
        if later_hour < target_hour
          next_page = Math.min(latest_page, current_page + Math.abs(current_page - previous_page) / 2)
        else 
          next_page = current_page - Math.abs(current_page - previous_page) / 2


        next_page = Math.round(next_page)

        if next_page == previous_page # in a cycle!
          callback(current_page)
        else 
          _find_page_for_hour productID, hour, next_page, current_page, previous_page, callback


  throttle 
    method: 'getProductTrades' 
    productID: productID
    opts: {after: current_page, limit}
    cb: cb




find_page_for_hour = (opts, callback) ->
  productID = "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"

  cb = (error, response, data) -> 
    if error || !data || data.message || !response
      if data?.message != 'Rate limit exceeded'
        console.error {message: 'error downloading trades! trying again', error: error, data: data}

      throttle 
        method: 'getProductTrades' 
        productID: productID
        opts: {limit: 1}
        cb: cb        
    else 
      current_hour = Math.floor(new Date(data[0].time).getTime() / 1000 / 60 / 60)
      _find_page_for_hour productID, opts.hour, response.headers['cb-before'], 0, -10, callback 

  throttle 
    method: 'getProductTrades' 
    productID: productID
    opts: {limit: 1}
    cb: cb



load_chart_data = (opts, callback) -> 

  granularity = opts.granularity
  chunk_size =  granularity * 300  # load at most 300 candles per

  all_data = []
  
  productID = "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"

  load_chart_depth = 0 
  next = -> 
    start_sec = opts.start + chunk_size * load_chart_depth 
    end_sec   = opts.start + chunk_size * (load_chart_depth + 1) - 1 

    start = new Date( start_sec * 1000                  ).toISOString()
    end   = new Date( Math.min(opts.end, end_sec) * 1000).toISOString()

    last = end_sec < opts.end

    cb = (error, response, data) ->
      #data = JSON.parse(data) if data

      if error || !data || data.message || !response
        if data?.message != 'Rate limit exceeded'
          console.error {message: 'error getting chart data, trying again', error: error, message: data?.message}

        throttle 
          method: 'getProductHistoricRates' 
          productID: productID
          opts: {start, end, granularity}
          cb: cb

      else 

        data = (d for d in data when (load_chart_depth == 0 || start_sec - 1 <= d[0]) && (last || d[0] < end_sec + 1))
          
        all_data.push data

        if last
          load_chart_depth += 1
          setTimeout next, 1000 / 3          
        else  
          callback [].concat all_data...

    throttle 
      method: 'getProductHistoricRates' 
      productID: productID
      opts: {start, end, granularity}
      cb: cb

  next()


orderbook_fails = 0
update_orderbook = (cb, print_status) ->
  market = "#{config.c2}-#{config.c1}"
  if !(orderbook?.books[market])
    # orderbook not ready yet!
    console.error "Orderbook not ready yet, waiting..."
    orderbook_fails += 1
    if orderbook_fails * 10 > 15 * 60 # subscribe_to_orderbook should take care of this, but sometimes...doesn't
      orderbook_fails = 0 
      gdax.subscribe_to_orderbook()
    else 
      setTimeout -> 
        update_orderbook cb, print_status
      , 100
    return

  orderbook_fails = 0 
  # orderbook is way stale, need to make another one. 
  # subscribe_to_orderbook should take care of this, but sometimes...doesn't
  if !syncing_orderbook && Date.now() - orderbook?.last_message > 30 * 60 * 1000 
    gdax.subscribe_to_orderbook()
    setTimeout -> 
      update_orderbook cb, print_status
    , 100
    return    

  ob = orderbook.books[market].state() 
  bids = ob.bids 
  asks = ob.asks 

  if !ob.bids || !ob.asks || ob.bids.length == 0 || ob.asks.length == 0 
    return cb?(null)

  first_bid = BigNumber(bids[0].price).toNumber()
  first_ask = BigNumber(asks[0].price).toNumber()

  vbids = {}
  vasks = {}
  for bid in bids 
    price = BigNumber(bid.price).toNumber()
    size = BigNumber(bid.size).toNumber()
    vbids[price] ?= 0 
    vbids[price] += size 
    break if price < first_bid * .998
  for ask in asks 
    price = BigNumber(ask.price).toNumber()
    size = BigNumber(ask.size).toNumber()
    vasks[price] ?= 0 
    vasks[price] += size 
    break if price > first_ask * 1.002

  bids = ([price, size] for price, size of vbids)
  bids.sort (a,b) -> b[0] - a[0]

  asks = ([price, size] for price, size of vasks)
  asks.sort (a,b) -> b[0] - a[0]

  ob_state = bus.fetch 'orderbook'
  ob_state.spread = first_ask - first_bid 
  ob_state.first_ask = 
    rate: first_ask
    amt: vasks[first_ask]
  ob_state.first_bid = 
    rate: first_bid 
    amt: vbids[first_bid]

  if print_status
    for a in asks 
      console.log a

    console.log '***********'

    for b in bids 
      console.log b 

    console.log "SPREAD: ", first_ask - first_bid

  if cb 
    cb ob_state





global.update_rate = (amt, type, post_only, order_method, cb) -> 

  update_orderbook (ob) -> 
    if type == 'buy'
      new_rate = ob.first_bid.rate
      if !post_only && order_method == 3 && ob.first_bid.amt < .25 * amt
        new_rate += gdax.minimum_rate_diff()
    else 
      new_rate = ob.first_ask.rate
      if !post_only && order_method == 3 && ob.first_ask.amt < .25 * amt
        new_rate -= gdax.minimum_rate_diff()        


    last_trade = history.last_trade
    if (last_trade.rate < ob.first_bid.rate || last_trade.rate > ob.first_ask.rate) && \
       (Date.now() - history.ws_trades.last_message > 1000 || Date.now() - global.orderbook.last_message > 1000)    
      console.error "Trade & orderbook discrepency: #{ob.first_bid.rate}  <#{last_trade.rate}>  #{ob.first_ask.rate}  (ob=#{Date.now() - global.orderbook.last_message} tr=#{Date.now() - history.ws_trades.last_message})"


    if ob.first_bid.rate >= ob.first_ask.rate 
      log_error false, {message: "Possible stale orderbook, one side is out of whack", ob, last_trade}

    cb 
      rate: new_rate
      order_book: ob


outstanding_requests = 0

module.exports = gdax = 
  minimum_order_size:  
    BTC: .001
    ETH: .01
    BCH: .01
    LTC: .1
    USD: 10
    EUR: 10
    GBP: 10

  minimum_rate_diff: -> 
    mins = 
      BTC: .00001
      USD: .01
      EUR: .01
      GBP: .01

    console.assert config.c1 of mins 
    mins[config.c1]

  minimum_rate_precision: (currency) ->
    currency ?= config.c1 
    mins = 
      BTC: 5
      USD: 2
      EUR: 2
      GBP: 2

    console.assert currency of mins 
    mins[currency]


  all_clear: -> outstanding_requests == 0 

  download_all_trade_history: (opts, callback) ->
    load_trades
      c1: opts.c1 
      c2: opts.c2
      stop_when_cached: true
      cb: (hours) -> 
        for hour, trades of hours
          write_trades parseInt(hour), trades, opts.c1, opts.c2
        callback()

  get_earliest_trade: (opts) ->

    pair = "#{opts.c2}-#{opts.c1}"

    earliest_trades = 
      "BTC-USD": 1417375595 
      "ETH-USD": 1464066000
      "LTC-USD": 1475690400 
      "ETH-BTC": 1463512661
      "LTC-BTC": 1475690400
      "BCH-USD": 1513792800
      "BCH-BTC": 1516190400

    # time after which a pair has sustained 1-week exponentially 
    # weighted moving average of hourly USD transacted > $50k
    high_volume = 
      "BTC-USD": 1422662400 # after 1/31/15
      "ETH-USD": 1487203200 # after 2/16/17
      "LTC-USD": 1491091200 # after 4/2/17
      "ETH-BTC": 1489449600 # after 3/14/17
      "LTC-BTC": 1493769600 # after 5/3/17
      "BCH-USD": 1513792800
      "BCH-BTC": 1516190400



    if opts.only_high_volume
      console.assert high_volume[pair],
        msg: "high_volume for #{pair} on not listed in GDAX's get_earliest_trade method" 

      return high_volume[pair]
    else
      console.assert earliest_trades[pair],
        msg: "earliest trade for #{pair} on not listed in GDAX's get_earliest_trade method" 

      return earliest_trades[pair]


  get_chart_data: (opts, callback) -> 
    opts.start = opts.start - opts.granularity

    load_chart_data opts, (chart_data) -> 
      # transform to Poloniex-like format
      chart_data.sort (a,b) -> a[0] - b[0]
      transformed = []
      t = []
      for c in chart_data 
        [time, low, high, open, close, volume] = c
        continue if opts.start - opts.granularity - 1 > time || time > opts.end + opts.granularity + 1  
        t.push [time, low, high, open, close, volume]
        transformed.push 
          date: time
          high: parseFloat high 
          low: parseFloat low 
          open: parseFloat open
          close: parseFloat close
          volume: parseFloat volume 

      callback(transformed)


  subscribe_to_orderbook: -> 

    handle = (ob) ->

      ob.destroy = -> 
        for intv in [ob.syncing_intv, ob.status_intv] when intv 
          clearInterval intv

        if ob == global.syncing_orderbook
          global.syncing_orderbook = null
        if ob == global.orderbook
          global.orderbook = null 

        ob.disconnect() if ob.socket

      ob.on 'close', ->
        ob.destroy()
        console.log "orderbook closed, restarting in a sec"
        setTimeout gdax.subscribe_to_orderbook, 1000

      ob.on 'error', (err) -> 
        log_error false, {message: "Orderbook #{ob.id} connection got an err:", ob, error_message: err.message, err}
        if err.message == 'unexpected server response (429)'
          process.exit()
        else 
          ob.destroy()
          setTimeout gdax.subscribe_to_orderbook, 1000

      ob.on 'message', (msg) -> ob.last_message = Date.now()

      ob.on 'open', -> 
        console.log "Orderbook #{ob.id} websocket opened ", Date.now()
        ob.last_message = Date.now()

        ob.status_intv = setInterval ->
          if !ob.socket || (ob != global.orderbook && ob != global.syncing_orderbook)
            ob.destroy()
            return 
          if Date.now() - ob.last_message > 5000 && !global.syncing_orderbook
            # We need to reconnect
            log_error false, "Restarting orderbook because #{ob.id} hasn't received messages in #{Date.now() - ob.last_message}ms"
            ob.destroy()
            setTimeout gdax.subscribe_to_orderbook, 1000
            return
          ob.status = ob._sequences[market]
        , 2500


    return if global.syncing_orderbook

    market = "#{config.c2}-#{config.c1}"
    try 
      on_deck = global.syncing_orderbook = new Gdax.OrderbookSync([market])
    catch e 
      console.error "Could not create a new orderbook. Will retry in 60 seconds", e
      return setTimeout -> 
        if !global.syncing_orderbook && (!global.orderbook || Date.now() - global.orderbook.last_message > 5000)
          subscribe_to_orderbook()
      , 60 * 1000


    on_deck.last_message = Date.now()
    on_deck.id = (global.orderbook?.id or 0) + 1
    console.log "Creating new orderbook #{on_deck.id}"

    on_deck.syncing_intv = setInterval -> 
      if !on_deck.status || on_deck.status < 0
        if Date.now() - on_deck.last_message > 5 * 60 * 1000 
          on_deck.destroy()
          gdax.subscribe_to_orderbook()
        return

      console.log "Orderbook synced #{on_deck.id}!"
      # ok! this orderbook is ready
      old = global.orderbook 
      global.orderbook = on_deck 
      global.syncing_orderbook = null 
      clearInterval on_deck.syncing_intv

      if old 
        old.destroy()
    , 100
    handle on_deck


  subscribe_to_exchange_feed: (opts, callback) -> 


    create_connection = -> 
      WS = require('ws')
      wsuri = "wss://ws-feed.gdax.com"

      try 
        connection = new WS(wsuri, [], {})
      catch
        console.error "Couldn't create connection, trying again"
        setTimeout create_connection, 500
        return

      connection.destroy = -> 
        try 
          connection.terminated_on_purpose = true
          if connection.keepAliveId
            clearInterval connection.keepAliveId
          connection.terminate()
        catch e 
          console.log "Couldn't terminate connection. Proceeding."

      connection.reset = reconnect = -> 
        return if connection.terminated_on_purpose
        connection.destroy()

        setTimeout ->
          console.log '...trying to reconnect'

          try 
            create_connection()
          catch e 
            console.error "Couldn't reconnect to websocket", e 
            setTimeout reconnect, 500
        , 500 

      connection.onopen = (e) ->

        connection.keepAliveId = setInterval -> 
          return if connection.terminated_on_purpose
          if Date.now() - connection.last_message > 10 * 60 * 1000
            log_error false, {message: "Trade feed unresponsive for too long, reconnecting!", last_msg: Date.now() - connection.last_message}
            global.restart_when_possible = true
            return reconnect()

          try 
            connection.ping('keepalive')
          catch e
            console.log "Websocket ping failed!", e 
            reconnect()
        , 10000

        # console.log '...engine is now receiving live updates'
        lag_logger?(99999)

        connection.send JSON.stringify({type: 'subscribe', channels: ['matches', 'heartbeat'], product_ids: ["#{config.c2}-#{config.c1}"]}), (error) ->
          reconnect() if error 

        callback(connection)

      connection.onmessage = (msg) ->
        if !msg || !msg.data 
          console.error '...empty data returned by gdax live update', msg 
          return

        data = JSON.parse(msg.data)

        if data.type == 'error'
          console.error "Websocket got an error", data


        if data.type == 'match'
          trade = 
            rate: parseFloat(data.price)
            amount: parseFloat(data.size)
            total: parseFloat(data.price) * parseFloat(data.size)
            date: new Date(data.time).getTime() / 1000
            tradeID: data.trade_id
            type: data.side

          opts.new_trade_callback trade 

        connection.last_message = Date.now()

      connection.onclose = (msg) -> 
        if !connection.terminated_on_purpose
          console.log '...lost connection to live feed from exchange',
            event: msg 
          
          reconnect()

      connection.onerror = (err) ->
        console.error('error from gdax:', err) 

    gdax.subscribe_to_orderbook()
    create_connection()



  get_trade_history: (opts, callback) -> 
    hour = Math.floor (opts.start + 1) / 60 / 60
    find_page_for_hour 
      c1: opts.c1 
      c2: opts.c2
      hour: hour
    , (starting_page) -> 
      load_trades
        starting_page: starting_page
        c1: opts.c1 
        c2: opts.c2
        # stop_after_hour: hour - 1
        stop_when_cached: true
        cb: (hours) -> 

          trades = hours[hour] or []

          write_trades hour, trades, opts.c1, opts.c2


          if trades.length == 0 
            console.error "No trades for #{hour}"
          callback trades

  get_order: (order_id, callback) -> 
    cb = (error, response, data) ->
      if error || !data || data.message

        if response?.statusCode == 404
          console.log {message: "getOrder got 404. Order probably was canceled with no fills", order_id}
          return callback {error: "Not found"}
        if data?.message != 'Rate limit exceeded'
          console.error {message: "error getting order, trying again", error: error, message: data?.message}

        throttle 
          method: 'getOrder' 
          opts: order_id
          cb: cb
      else  
        callback data

    throttle 
      method: 'getOrder' 
      opts: order_id
      cb: cb


  get_my_fills: (opts, callback) -> 
    fills = []

    cb = (data) -> 
      for fill in (data or []) 
        fills.push 
          order_id: fill.order_id 
          fill_id: fill.trade_id
          rate: parseFloat fill.price 
          amount: parseFloat fill.size 
          total: parseFloat(fill.price) * parseFloat(fill.size)
          fee: parseFloat(fill.fee)
          date: new Date(fill.created_at).getTime() / 1000
          maker: fill.liquidity == 'M'

      callback fills

    args = 
      product_id: "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"

    if opts.order_id?
      args.order_id = opts.order_id 

    if opts.start?
      args.start = opts.start 

    depaginated_request 'getFills', args, cb



  get_my_open_orders: (opts, callback) -> 
    open_orders = []

    cb = (data) -> 
      for order in (data or [])
        open_orders.push 
          order_id: order.id 
          rate: parseFloat order.price 
          amount: parseFloat order.size 
          total: parseFloat(order.price) * parseFloat(order.size)
          date: new Date(order.created_at).getTime() / 1000

      callback open_orders

    args = 
      # status: 'open' # defaults to [open, pending, active]
      product_id: "#{opts.c2}-#{opts.c1}"

    depaginated_request 'getOrders', args, cb




  get_my_balance: (opts, callback) -> 

    cb = (error, response, data) ->
      if error || !data || data.message

        if data?.message != 'Rate limit exceeded'
          console.error {message: "error getting my balance, trying again", error: error, message: data?.message}

        throttle 
          method: 'getAccounts' 
          cb: cb
      else  
        balances = {}
        for balance in data
          if balance.currency in opts.currencies
            balances[balance.currency] = 
              available: balance.available
              on_order: balance.hold

        callback balances


    throttle 
      method: 'getAccounts' 
      cb: cb


  get_my_exchange_fee: (opts, callback) -> 
    

    callback 
      maker_fee: 0.002
      taker_fee: 0.003


  place_order: (opts, callback) -> 
    params = 
      product_id: "#{opts.c2}-#{opts.c1}"
      type: if opts.flags?.market then 'market' else 'limit'
      post_only: if opts.flags?.post_only? then opts.flags.post_only

    place = ({rate, order_book}) -> 

      # reset amount based on new rate and old rate/amount if we're buying (can keep same amount if selling)
      rate = parseFloat rate.toFixed(gdax.minimum_rate_precision())
      if opts.type == 'buy' && opts.rate != rate 
        opts.amount = opts.amount * opts.rate / rate

      if !(opts.flags?.market && opts.type == 'buy')
        amount = params.size = parseFloat opts.amount.toFixed(8)
      else 
        amount = params.funds = parseFloat (Math.floor(opts.amount * rate * 1000000) / 1000000).toFixed(6)

      if (amount < gdax.minimum_order_size[config.c2]) && !opts.flags?.market
        return callback {error: "Too small of an order (#{amount}<#{gdax.minimum_order_size[config.c2]})"}

      params.price = rate
      
      cb = (error, response, data) ->
        console.log 'place order GOT', data if config.log_level > 2

        if error || !data || data.message || !response || data?.status == 'rejected'

          if data?.status == 'rejected'
            ob = from_cache 'orderbook'

            if config.log_level > 1
              console.log "Order was rejected. Either last trade or order book might be stale!", 
                last_trade: history.last_trade
                first_ask: ob.first_ask
                first_bid: ob.first_bid



          if data?.message != 'Rate limit exceeded' && config.log_level > 1
            console.error "error carrying out #{opts.type}",
              error: error
              message: data?.message
              status: data?.status
              opts: opts
          
          if data?.message?.indexOf('Order size is too small') > -1
            console.log 'Not trying again. Order size is too small.' if config.log_level > 1
            callback {error: data.message}

          else
            console.log 'Trying again.' if config.log_level > 1 
            return gdax.place_order opts, callback
          
        else 
          latest_trades = []
          idx = 0
          while idx < history.trades.length
            t = history.trades[idx]
            if tick.time - t.date > 10 * 60 * 60
              break
            idx += 1


          callback 
            order_id: data.id
            error: data.error
            info: 
              first_ask: 
                rate: order_book?.first_ask?.rate 
                amt: order_book?.first_ask?.amt 
              first_bid: 
                rate: order_book?.first_bid?.rate 
                amt: order_book?.first_bid?.amt
              latest_trades: latest_trades


      console.log 'PLACING ORDER', params if config.log_level > 1


      throttle 
        method: opts.type 
        opts: params 
        cb: cb 

    if opts.flags?.auto_adjust
      update_rate opts.amount, opts.type, params.post_only, opts.flags.order_method, place 
    else 
      place {rate: opts.rate}







  dynamic_place_order: (opts, placed_callback, updated_callback, finished_callback) -> 

    pos = opts.pos
    trade = refresh pos, opts.trade 


    gdax.place_order opts, ({order_id, error, info}) -> 
      placed_callback {order_id, error, info} # this should be the normal callback pipeline from operation / pusher place order
      
      if error
        console.log 'GOT ERROR PLACING DYNAMIC ORDER', {opts} if config.log_level > 1
      else 
        # At this point, we know that an order is on the books. 
        # Now we'll monitor it until it is complete, re-placing the order
        # as necessary

        trade = refresh pos, opts.trade
        if !(trade.current_order && trade.original_rate? && trade.original_amt? && trade.fills?)  
          console.assert false, {message: "trade doesn't have correct settings after placing", order_id, error, info, trade, pos} 
        console.log 'DYNAMIC ORDER: PLACED', {trade} if config.log_level > 2

        gdax.dynamic_move_order {trade, pos}, updated_callback, finished_callback

  dynamic_move_order: ({trade, pos}, updated_callback, finished_callback) -> 
    locked = false 
    victory = ->
      clearInterval intv
      console.log 'DYNAMIC ORDER: VICTORY!!!!' if config.log_level > 2
      finished_callback()

    intv = setInterval -> 
      return if locked
      locked = true

      update_rate trade.amount, trade.type, trade.flags?.post_only, trade.flags?.order_method, ({rate, order_book}) ->  
        trade = refresh pos, trade

        if trade.rate == rate 
          locked = false
        else
          #console.log 'DYNAMIC ORDER: RATE HAS CHANGED!', {rate}

          console.assert trade.current_order && trade.original_rate? && trade.original_amt? && trade.fills?, {message: "trade doesn't have correct settings before re-placing", order_id, trade, pos} 

          order_id = trade.current_order
          gdax.cancel_order {order_id}, (data) -> 

            trade = refresh pos, trade
            console.log 'DYNAMIC ORDER: CANCELED', data if config.log_level > 2

            if data?.error == 'Order already done'
              # console.log 'DYNAMIC ORDER: Cannot cancel because order is already done'
              return victory()
            else 
              console.log 'Done canceling now updating order info', data if config.log_level > 2
              trade.current_order = null 
              bus.save pos


            gdax.get_order order_id, (order_data) -> 
              # sometimes GDAX apparently doesn't return fills promptly, so we try to cross check 
              # it with the result of get_order, which has a "filled_size" property
              filled_size_from_order = if order_data.error == 'Not found' then 0 else order_data.filled_size
              attempts = 0 
              fills_callback = (fills) -> 
                filled_size = 0
                for new_fill in fills
                  filled_size += new_fill.amount 


                if Math.abs(filled_size - filled_size_from_order) > .001 * Math.abs(filled_size + filled_size_from_order)
                  console.error  
                    message: "Filled size from getFills does not match Filled Size from getOrder "
                    order_id: order_id 
                    filled_size: filled_size
                    filled_size_from_order: filled_size_from_order
                    order_data: order_data
                    fills: fills 

                  # try again
                  if attempts < 50
                    setTimeout -> 
                      attempts += 1
                      gdax.get_order order_id, (order_data) -> 
                        filled_size_from_order = if order_data.error == 'Not found' then 0 else order_data.filled_size
                        gdax.get_my_fills {order_id}, fills_callback
                    , 1000
                  else 
                    log_error false, 
                      message: "Filled size from getFills does not match Filled Size from getOrder. Giving up."
                      order_id: order_id 
                      filled_size: filled_size
                      filled_size_from_order: filled_size_from_order
                      order_data: order_data
                      fills: fills 
                    finished_callback()

                  return 

                trade = refresh pos, trade

                console.log 'DYNAMIC ORDER: GOT FILLS', fills if config.log_level > 2
                # add fills to trade
                for new_fill in fills
                  already_processed = false 
                  for old_fill in trade.fills
                    already_processed = old_fill.fill_id == new_fill.fill_id
                    break if already_processed
                  continue if already_processed
                  new_fill.type = trade.type
                  new_fill.slippage = new_fill.amount * Math.abs(new_fill.rate - trade.original_rate) / trade.original_rate
                  trade.fills.push new_fill
                
                bus.save pos 

                update_rate trade.amount, trade.type, trade.flags?.post_only, trade.flags?.order_method, ({rate, order_book}) ->
                  trade = refresh pos, trade

                  # TODO: validate whether rates that are detected as different are actually different!
                  r = rate 
                  rate = parseFloat rate.toFixed(gdax.minimum_rate_precision())
                  console.log 'DYNAMIC ORDER: new rates', {r, rate, tr: trade.rate, trade} if config.log_level > 2

                  # determine how much more I need to order
                  amt_purchased = 0 
                  for f in (trade.fills or [])
                    amt_purchased += f.amount

                  trade.to_fill = trade.original_amt - amt_purchased
                  if trade.type == 'buy'
                    # we need to adjust the *amount* we're buying because our buying power has changed
                        
                    total_remaining = trade.to_fill * trade.original_rate
                    new_amount = total_remaining / rate 
                    trade.amount = new_amount + amt_purchased
                    trade.to_fill = new_amount 
                    

                  trade.rate = rate 
                  bus.save pos 

                  if isNaN(trade.to_fill)
                    console.assert false, "DYNAMIC ORDER: NEW AMOUNT is NaN!", trade.to_fill, trade

                  if trade.to_fill < gdax.minimum_order_size[config.c2] || \
                     trade.to_fill * rate < gdax.minimum_order_size[config.c1]
                    return victory()


                  args = 
                    rate: rate
                    amount: trade.to_fill
                    type: trade.type
                    c1: config.c1 
                    c2: config.c2
                    flags: trade.flags

                  # console.log "DYNAMIC ORDER: Done canceling and updating order info, now placing:", args
                  gdax.place_order args, (result) -> 
                    locked = false
                    updated_callback result
              

              gdax.get_my_fills {order_id}, fills_callback






    , 100










  cancel_order: (opts, callback) -> 

    cb = (error, response, data) ->  

      if error || !data || data.message || !response

        if data?.message not in ['Rate limit exceeded', 'Order already done'] && config.log_level > 1
          console.error "error carrying out cancel",
            error: error
            message: data?.message
            opts: opts        

        if data?.message in ['Order already done', 'order not found']
          console.log 'Not trying again. Returning to execution' if config.log_level > 2
          callback {error: data.message}
        else # retry
          throttle 
            method: 'cancelOrder'
            opts: opts.order_id
            cb: cb 

      else
        console.log 'cancel got', data if config.log_level > 2
        callback data

    throttle 
      method: 'cancelOrder'
      opts: opts.order_id
      cb: cb 


  move_order: (opts, callback) ->
    # GDAX doesn't have an atomic move_order function like Poloniex does

    gdax.cancel_order {order_id: opts.order_id}, (data) -> 

      if data?.message == 'Order already done'
        console.log 'Cannot cancel because order is already done' if config.log_level > 2
        callback 
          error: 'Order already done'
      else 
        console.log 'Done canceling now placing:', opts if config.log_level > 2
        gdax.place_order opts, callback 



# currently assumes that method returns reverse-chronologically array of objects with a created_at field
depaginated_request = (method, opts, callback) -> 
  
  all_data = []

  cb = (error, response, data) ->
    if error || !data || data?.message || !response

      if data?.message != 'Rate limit exceeded'
        console.error "error getting data for #{method}, trying again", {error: error, message: data?.message}
      
      throttle {method, opts, cb}
    
    else  
      all_data = all_data.concat data 

      opts.after = response.headers['cb-after']

      should_continue = (opts.after || opts.after == 0) && (!opts.start || opts.start <= new Date(data[data.length - 1].created_at).getTime() / 1000 )

      if should_continue 
        throttle {method, opts, cb}
      else
        callback all_data

  throttle {method, opts, cb}

