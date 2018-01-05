Gdax = require('gdax')
fs = require('fs')



RATE_LIMIT = 1000

GDAX_client = (opts) ->
  if !gdax.client 
    product_id = "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"
    if api_credentials?
      client = new Gdax.AuthenticatedClient api_credentials.key, api_credentials.secret, api_credentials.pass
      client.productID = product_id
    else 
      client = new Gdax.PublicClient(product_id)
    gdax.client = client 
  gdax.client
  
    
write_trades = (hour, trades, c1, c2) -> 
  if hour + 1 <= current_hour && trades?.length > 0
    fname = "trade_history/gdax/#{c1}_#{c2}/#{hour}"    

    if !fs.existsSync(fname)
      fs.writeFileSync fname, JSON.stringify(trades), 'utf8' 



get_trades = (client, c1, c2, hours, after, stop_when_cached, callback, stop_after_hour) -> 
  cb = (error, response, data) -> 
    i += 1 
    if error || !data || data.message || !response
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout ->
        client.getProductTrades client.productID, {after: after, limit: limit}, cb 
      , 1000
      return

    later_hour = null
    early_hour = null
    for trade in (data or [])
      time = new Date(trade.time).getTime() / 1000
      hour = Math.floor(time / 60 / 60)

      hours[hour] ?= []
      hours[hour].push 
        date: time 
        rate: parseFloat(trade.price)
        amount: parseFloat(trade.size)
        total: parseFloat(trade.size) * parseFloat(trade.price)

      if !later_hour
        later_hour = hour
      early_hour = hour


    process.stdout.clearLine()
    process.stdout.cursorTo 0
    process.stdout.write "Loading GDAX history: #{i}, #{early_hour}, #{after}, #{(100 * i * limit / latest_page).toPrecision(4)}%"


    continue_loading = true
    if stop_when_cached 
      continue_loading = !fs.existsSync "trade_history/gdax/#{c1}_#{c2}/#{early_hour}"
    if stop_after_hour
      continue_loading = early_hour >= stop_after_hour

    continue_loading &&= i * limit < latest_page && ('cb-after' of response.headers)

    if continue_loading
      if later_hour != early_hour # done processing this hour
        hr = later_hour
        while hr > early_hour
          write_trades hr, hours[hr], c1, c2
          hr -= 1

      setTimeout -> 
        get_trades client, c1, c2, hours, response.headers['cb-after'], stop_when_cached, callback, stop_after_hour
      , 1000 / RATE_LIMIT
    else 
      callback?(hours)

  client.getProductTrades client.productID, {after: after, limit: limit}, cb 





limit = 100
i = 0 
latest_page = null
current_hour = null


load_trades = (opts) -> 
  client = GDAX_client opts

  dir = "trade_history/gdax/#{opts.c1}_#{opts.c2}"
  if !fs.existsSync dir 
    fs.mkdirSync dir


  hour = (opts.start + 1) / 60 / 60 

  cb = (error, response, data) -> 

    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout ->
        client.getProductTrades client.productID, {limit: 1}, cb 
      , 1000
      return

    i = 0 # used in recursion for get_trades
    current_hour = Math.floor(new Date(data[0].time).getTime() / 1000 / 60 / 60)

    latest_page = opts.starting_page or response.headers['cb-before'] 
    get_trades client, opts.c1, opts.c2, {}, latest_page, opts.stop_when_cached, opts.cb, opts.stop_after_hour
  
  client.getProductTrades client.productID, {limit: 1}, cb




_find_page_for_hour = (client, hour, current_page, previous_page, callback) -> 
  target_hour = hour + 1

  if hour >= current_hour
    return callback(current_page)
     
  cb = (error, response, data) -> 
    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout -> 
        client.getProductTrades client.productID, {after: current_page, limit: limit}, cb
      , 1000
      return

    early_hour = later_hour = null
    for trade in (data or [])
      time = new Date(trade.time).getTime() / 1000
      hr = Math.floor(time / 60 / 60)
      if !later_hour
        later_hour = hr
      early_hour = hr

    process.stdout.clearLine()
    process.stdout.cursorTo 0
    process.stdout.write "Finding GDAX history for #{hour}: #{early_hour}, #{later_hour}, #{current_page}"

    if early_hour <= target_hour && later_hour >= target_hour
      callback(current_page)
    else 
      if later_hour < target_hour
        next_page = Math.min(latest_page,current_page + Math.abs(current_page - previous_page) / 2)
      else 
        next_page = current_page - Math.abs(current_page - previous_page) / 2

      _find_page_for_hour client, hour, Math.round(next_page), current_page, callback


  client.getProductTrades client.productID, {after: current_page, limit: limit}, cb 







find_page_for_hour = (opts, callback) ->
  client = GDAX_client opts

  cb = (error, response, data) -> 
    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout ->
        client.getProductTrades client.productID, {limit: 1}, cb 
      , 1000
      return

    current_hour = Math.floor(new Date(data[0].time).getTime() / 1000 / 60 / 60)
    _find_page_for_hour client, opts.hour, response.headers['cb-before'], 0, callback 

  client.getProductTrades client.productID, {limit: 1}, cb




# this will currently only work when less then 200 candles are to be returned.
# e.g. when period is daily, this means 200 days of chart data.
# should be pretty easy to make work with more: 

getProductHistoricRates = ({start, end, granularity}, cb) ->
  request = require('request')
  request 
    qs: 
      start: start
      end: end
      granularity: granularity 
    method: 'GET'
    uri: 'https://api.gdax.com/products/BTC-USD/candles'
    headers:
       'User-Agent': 'gdax-node-client'
       Accept: 'application/json'
       'Content-Type': 'application/json' 
  , cb

load_chart_data = (client, opts, callback) -> 

  granularity = opts.period
  chunk_size = granularity * 10000  # load at most 20 candles per

  all_data = []
  
  i = 0 
  next = -> 
    start_sec = opts.start + chunk_size * i 
    end_sec = opts.start + chunk_size * (i + 1) - 1 

    start = new Date(start_sec * 1000).toISOString()
    end = new Date( Math.min(opts.end, end_sec) * 1000).toISOString()

    cb = (error, response, data) ->
      #data = JSON.parse(data) if data
      #console.log data
      if error || !data || data.message
        console.error {message: 'error getting chart data, trying again', error: error, message: data?.message}
        setTimeout -> 
          client.getProductHistoricRates client.productID, {start, end, granularity}, cb

        , 1000
        return 
        
      all_data.push data 

      if end_sec < opts.end
        i += 1
        setTimeout -> 
          next()
        , 1000 / 3

        
      else  
        callback [].concat all_data...

    client.getProductHistoricRates client.productID, {start, end, granularity}, cb

  next()



waiting_to_execute = 0
outstanding_requests = 0

module.exports = gdax = 
  all_clear: -> outstanding_requests == 0 && waiting_to_execute == 0 

  download_all_trade_history: (opts, callback) ->
    load_trades
      c1: opts.c1 
      c2: opts.c2
      stop_when_cached: true #opts.stop_when_cached
      #starting_page: 427580
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

    # time after which a pair has sustained 1-week exponentially 
    # weighted moving average of hourly USD transacted > $50k
    high_volume = 
      "BTC-USD": 1422662400 # after 1/31/15
      "ETH-USD": 1487203200 # after 2/16/17
      "LTC-USD": 1491091200 # after 4/2/17
      "ETH-BTC": 1489449600 # after 3/14/17
      "LTC-BTC": 1493769600 # after 5/3/17



    if opts.only_high_volume
      console.assert high_volume[pair],
        msg: "high_volume for #{pair} on not listed in POLONIEX's get_earliest_trade method" 

      return high_volume[pair]
    else
      console.assert earliest_trades[pair],
        msg: "earliest trade for #{pair} on not listed in POLONIEX's get_earliest_trade method" 

      return earliest_trades[pair]


  get_chart_data: (opts, callback) -> 
    client = GDAX_client opts
    opts.start = opts.start - 10000
    load_chart_data client, opts, (chart_data) -> 
      # transform to Poloniex-like format
      transformed = []
      for [time, low, high, open, close, volume] in chart_data
        transformed.push 
          date: new Date(time).getTime()
          high: parseFloat high 
          low: parseFloat low 
          open: parseFloat open
          close: parseFloat close
          volume: parseFloat volume 

      callback(transformed)

  subscribe_to_trade_history: (opts, callback) -> 


    create_connection = -> 
      WS = require('ws')
      wsuri = "wss://ws-feed.gdax.com"
      conn = new WS(wsuri, [], {})

      conn.onopen = (e) ->

        conn.keepAliveId = setInterval -> 
          conn.ping('keepalive')
        , 30000

        console.log '...engine is now receiving live updates'
        lag_logger?(99999)

        conn.send JSON.stringify {type: 'subscribe', product_ids: ["#{config.c2}-#{config.c1}"]}

        callback()

      conn.onmessage = (msg) ->
        if !msg || !msg.data 
          console.error '...empty data returned by gdax live update', msg 
          return

        data = JSON.parse(msg.data)

        return if data.type != 'match'

        trade = 
          rate: parseFloat(data.price)
          amount: parseFloat(data.size)
          total: parseFloat(data.price) * parseFloat(data.size)
          date: new Date(data.time).getTime() / 1000

        opts.new_trade_callback trade 


          
      conn.onclose = (msg) -> 
        console.log '...lost connection to live feed from exchange',
          event: msg 
           
        setTimeout ->
          console.log '...trying to reconnect'
          create_connection()
        , 500

      conn.onerror = (err) ->
        console.error('error from gdax:', err) 

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
        stop_after_hour: hour - 1
        cb: (hours) -> 
          trades = hours[hour] or []

          write_trades hour, trades, opts.c1, opts.c2

          if trades.length == 0 
            console.log()
            console.error "No trades for #{hour}"
          callback trades


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

    # depaginated_request 'getFills', 
    #   product_id: "#{opts.c2}-#{opts.c1}"
    #   start: opts.start
    # , cb 

    depaginated_request 'getFills', {
      product_id: GDAX_client(opts).productID
      start: opts.start
    }, cb



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

    depaginated_request 'getOrders', 
      status: 'open'
      product_id: "#{opts.c2}-#{opts.c1}"
    , cb 




  get_my_balance: (opts, callback) -> 
    client = GDAX_client opts

    cb = (error, response, data) ->
      if error || !data || data.message
        console.error {message: "error getting data for #{method}, trying again", error: error, message: data?.message}
        
        setTimeout -> 
          client.getAccounts cb
        , 50
      else  
        balances = {}
        for balance in data
          if balance.currency in opts.currencies
            balances[balance.currency] = 
              available: balance.available
              on_order: balance.hold

        outstanding_requests -= 1
        callback balances

    outstanding_requests += 1
    client.getAccounts cb


  get_my_exchange_fee: (opts, callback) -> 
    callback 
      maker_fee: 0
      taker_fee: 0.0025


  place_order: (opts, callback) -> 

    queued_request opts.type, 
      price: opts.rate
      size: if !(opts.market && opts.type == 'buy') then opts.amount
      funds: if opts.market && opts.type == 'buy' then parseFloat((Math.floor(opts.amount * opts.rate * 1000000) / 1000000).toFixed(6))
      product_id: "#{opts.c2}-#{opts.c1}"
      type: if opts.market then 'market' else 'limit'
    , (data) -> 
      callback order_id: data.id

  cancel_order: (opts, callback) -> 
    queued_request 'cancelOrder', opts.order_id, callback 

  move_order: (opts, callback) ->
    # GDAX doesn't have an atomic move_order function like Poloniex does

    gdax.cancel_order {order_id: opts.order_id}, -> 
      console.log 'Done canceling now placing:', opts
      gdax.place_order
        type: opts.type
        rate: opts.rate 
        amount: opts.amount
        c1: opts.c1
        c2: opts.c2
        market: opts.market
      , callback


queued_request = (method, opts, callback) -> 
  client = GDAX_client opts

  ts = null 
  cb = (error, response, data) ->
    if error || !data || data.message
      console.error "error carrying out #{method}, trying again",
        error: error
        message: data?.message
      
      setTimeout -> 
        ts = now()
        client[method] opts, cb
      , 50
    
    else
      outstanding_requests -= 1 
      lag_logger?(now() - ts)
      callback data

  xecute = -> 
    if outstanding_requests >= 10
      setTimeout xecute, 50
    else 
      outstanding_requests += 1
      waiting_to_execute -= 1
      ts = now()

      console.log 'EXECUTING', method, opts
      client[method] opts, cb 

  waiting_to_execute += 1
  xecute()





# currently assumes that method returns reverse-chronologically array of objects with a created_at field
depaginated_request = (method, opts, callback) -> 

  client = GDAX_client opts

  all_data = []

  cb = (error, response, data) ->
    if error || !data || data.message
      console.error "error getting data for #{method}, trying again", {error: error, message: data?.message}
      
      lag_logger?(now() - ts)
      setTimeout -> 
        ts = now()
        client[method] opts, cb
      , 50
    
    else  
      lag_logger?(now() - ts)
      all_data = all_data.concat data 

      opts.after = response.headers['cb-after']

      should_continue = (opts.after || opts.after == 0) && (!opts.start || opts.start <= new Date(data[data.length - 1].created_at).getTime() / 1000 )

      if should_continue 
        client[method] opts, cb 
      else
        outstanding_requests -= 1 
        callback all_data

  outstanding_requests += 1
  ts = now()
  client[method] opts, cb 