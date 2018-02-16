Gdax = require('gdax')
fs = require('fs')



RATE_LIMIT = 3

GDAX_client = (opts) ->
  product_id = "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"
  if api_credentials?
    client = new Gdax.AuthenticatedClient api_credentials.key, api_credentials.secret, api_credentials.pass
    client.productID = product_id
  else 
    client = new Gdax.PublicClient()
  
  client  
    
write_trades = (hour, trades, c1, c2) -> 
  if hour + 1 <= current_hour && trades?.length > 0
    fname = "trade_history/gdax/#{c1}_#{c2}/#{hour}"    

    if !fs.existsSync(fname)
      fs.writeFileSync fname, JSON.stringify(trades), 'utf8' 



trade_ids = {}
times_sent = []

get_wait = -> 
  noww = Date.now()
  while times_sent.length > 0 && noww - times_sent[0] > 1000
    times_sent.shift()

  if times_sent.length < RATE_LIMIT
    return 0 
  else 
    earliest = times_sent[0]
    
    wait_for = earliest + 1000 - noww
    if wait_for < 0 
      wait_for = 0           
    return wait_for

get_trades = (client, c1, c2, hours, after, stop_when_cached, callback, stop_after_hour) -> 
  cb = (error, response, data) -> 
    i += 1 

    if Math.random() > .999
      RATE_LIMIT++
      console.log {RATE_LIMIT}

    # console.log {RATE_LIMIT}
    if error || !data || data.message || !response

      if data?.message == 'Rate limit exceeded'
        console.log '***'
      else 
        console.error {message: 'error downloading trades! trying again', error: error, data: data, c1, c2, after, stop_when_cached, callback, stop_after_hour}
      
      setTimeout ->
        if Math.random() > .9 && RATE_LIMIT > 1
          RATE_LIMIT--
          console.log {RATE_LIMIT}

        times_sent.push Date.now()
        client.getProductTrades client.productID, {after: after, limit: limit}, cb 
      , get_wait()
      return

    later_hour = null
    early_hour = null
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

        trade_ids[trade.trade_id] = 1

      if !later_hour
        later_hour = hour

      early_hour = hour


    process.stdout.clearLine()
    process.stdout.cursorTo 0
    process.stdout.write "Loading GDAX history: #{i}, #{early_hour}, #{after}, #{(100 * i * limit / latest_page).toPrecision(4)}%"


    continue_loading = true
    if stop_when_cached
      continue_loading = !fs.existsSync("trade_history/gdax/#{c1}_#{c2}/#{early_hour}") || !fs.existsSync("trade_history/gdax/#{c1}_#{c2}/#{early_hour - 1}")
    if stop_after_hour
      continue_loading = early_hour >= stop_after_hour

    continue_loading &&= i * limit < latest_page && ('cb-after' of response.headers)

    if continue_loading
      if later_hour != early_hour # done processing this hour
        hr = later_hour
        while hr > early_hour
          write_trades hr, hours[hr], c1, c2
          hr -= 1

      get_trades client, c1, c2, hours, response.headers['cb-after'], stop_when_cached, callback, stop_after_hour

    else 
      callback?(hours)

  setTimeout ->
    #RATE_LIMIT /= 2
    times_sent.push Date.now()
    client.getProductTrades client.productID, {after: after, limit: limit}, cb 
  , get_wait()

  





limit = 100
i = 0 
latest_page = null
current_hour = null


load_trades = (opts) -> 
  client = GDAX_client opts

  dir = "trade_history/gdax/#{opts.c1}_#{opts.c2}"
  if !fs.existsSync dir 
    fs.mkdirSync dir

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
    trade_ids = {}
    get_trades client, opts.c1, opts.c2, {}, latest_page, opts.stop_when_cached, opts.cb, opts.stop_after_hour
  
  client.getProductTrades client.productID, {limit: 1}, cb




_find_page_for_hour = (client, hour, current_page, previous_page, callback) -> 
  target_hour = hour + 1

  if hour >= current_hour
    return callback(current_page)
     
  cb = (error, response, data) -> 
    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data, hour, current_page, previous_page}
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



load_chart_data = (client, opts, callback) -> 

  granularity = opts.granularity
  chunk_size =  granularity * 300  # load at most 300 candles per

  all_data = []
  
  productID = "#{opts.c2 or config.c2}-#{opts.c1 or config.c1}"

  i = 0 
  next = -> 
    start_sec = opts.start + chunk_size * i 
    end_sec   = opts.start + chunk_size * (i + 1) - 1 

    start = new Date( start_sec * 1000                  ).toISOString()
    end   = new Date( Math.min(opts.end, end_sec) * 1000).toISOString()

    last = end_sec < opts.end

    cb = (error, response, data) ->
      #data = JSON.parse(data) if data

      if error || !data || data.message
        console.error {message: 'error getting chart data, trying again', error: error, message: data?.message}
        setTimeout -> 
          client.getProductHistoricRates productID, {start, end, granularity}, cb
        , 1000
        return 

      data = (d for d in data when (i == 0 || start_sec - 1 <= d[0]) && (last || d[0] < end_sec + 1))
        
      all_data.push data

      if last
        i += 1
        setTimeout -> 
          next()
        , 1000 / 3

        
      else  
        callback [].concat all_data...


    client.getProductHistoricRates productID, {start, end, granularity}, cb

  next()



waiting_to_execute = 0
outstanding_requests = 0

module.exports = gdax = 
  minimum_order: -> 
    mins = 
      BTC: .001
      ETH: .01
      BCH: .01
      LTC: .1
      USD: 10
      EUR: 10
      GBP: 10

    console.assert config.c2 of mins 
    mins[config.c2]

  minimum_rate_diff: -> 
    mins = 
      BTC: .00001
      USD: .01
      EUR: .01
      GBP: .01

    console.assert config.c1 of mins 
    mins[config.c1]



  all_clear: -> outstanding_requests == 0 && waiting_to_execute == 0 

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
      "BCH-USD": 1513728000

    # time after which a pair has sustained 1-week exponentially 
    # weighted moving average of hourly USD transacted > $50k
    high_volume = 
      "BTC-USD": 1422662400 # after 1/31/15
      "ETH-USD": 1487203200 # after 2/16/17
      "LTC-USD": 1491091200 # after 4/2/17
      "ETH-BTC": 1489449600 # after 3/14/17
      "LTC-BTC": 1493769600 # after 5/3/17
      "BCH-USD": 1513728000



    if opts.only_high_volume
      console.assert high_volume[pair],
        msg: "high_volume for #{pair} on not listed in GDAX's get_earliest_trade method" 

      return high_volume[pair]
    else
      console.assert earliest_trades[pair],
        msg: "earliest trade for #{pair} on not listed in GDAX's get_earliest_trade method" 

      return earliest_trades[pair]


  get_chart_data: (opts, callback) -> 
    client = GDAX_client opts
    opts.start = opts.start - 10000


    load_chart_data client, opts, (chart_data) -> 

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


  subscribe_to_trade_history: (opts, callback) -> 


    create_connection = -> 
      WS = require('ws')
      wsuri = "wss://ws-feed.gdax.com"

      try 
        connection = new WS(wsuri, [], {})
      catch
        console.error "Couldn't create connection, trying again"
        setTimeout create_connection, 500
        return

      reconnect = -> 
        try 
          if connection.keepAliveId
            clearInterval connection.keepAliveId
          connection.terminate()
        catch e 
          console.log "Couldn't terminate connection. Proceeding."

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
          try 
            connection.ping('keepalive')
          catch e
            console.log "Websocket ping failed!", e 
            reconnect()
        , 30000

        console.log '...engine is now receiving live updates'
        lag_logger?(99999)

        connection.send JSON.stringify({type: 'subscribe', product_ids: ["#{config.c2}-#{config.c1}"]}), (error) ->
          reconnect() if error 

        callback()

      connection.onmessage = (msg) ->
        if !msg || !msg.data 
          console.error '...empty data returned by gdax live update', msg 
          return

        data = JSON.parse(msg.data)

        if data.type == 'error'
          console.error "Websocket got an error", data

        if data.type != 'match'
          return 

        trade = 
          rate: parseFloat(data.price)
          amount: parseFloat(data.size)
          total: parseFloat(data.price) * parseFloat(data.size)
          date: new Date(data.time).getTime() / 1000

        opts.new_trade_callback trade 


          
      connection.onclose = (msg) -> 
        console.log '...lost connection to live feed from exchange',
          event: msg 
        
        reconnect()

      connection.onerror = (err) ->
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
        # stop_after_hour: hour - 1
        stop_when_cached: true
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

    args = 
      product_id: GDAX_client(opts).productID
      start: opts.start

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
      status: 'open'
      product_id: "#{opts.c2}-#{opts.c1}"

    depaginated_request 'getOrders', args, cb




  get_my_balance: (opts, callback) -> 
    client = GDAX_client opts

    cb = (error, response, data) ->
      if error || !data || data.message
        console.error {message: "error getting my balance, trying again", error: error, message: data?.message}
        
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
      console.log 'place order GOT', data
      callback order_id: data.id, error: data.error
    , (error, response, data) -> 
      if data.message?.indexOf('Order size is too small') > -1
        return false 
      else 
        return true # retry on error

  cancel_order: (opts, callback) -> 
    queued_request 'cancelOrder', opts.order_id, (data) -> 
      console.log 'cancel got', data
      callback data
    , (error, response, data) -> 
      if data.message == 'Order already done'
        return false 
      else 
        return true # retry

  move_order: (opts, callback) ->
    # GDAX doesn't have an atomic move_order function like Poloniex does

    gdax.cancel_order {order_id: opts.order_id}, (data) -> 
      if data?.message == 'Order already done'
        console.log 'Cannot cancel because order is already done'
        callback 
          error: 'Order already done'
      else 
        console.log 'Done canceling now placing:', opts
        gdax.place_order
          type: opts.type
          rate: opts.rate 
          amount: opts.amount
          c1: opts.c1
          c2: opts.c2
          market: opts.market
        , callback


queued_request = (method, opts, callback, error_callback) -> 
  client = GDAX_client opts

  ts = null 
  cb = (error, response, data) ->
    if error || !data || data.message
      console.error "error carrying out #{method}",
        error: error
        message: data?.message
      
      if error_callback?(error, response, data) || !error_callback
        console.log 'Trying again.'
        setTimeout -> 
          ts = now()
          client[method] opts, cb
        , 50
      else 
        console.log 'Not trying again. Returning to execution'
        callback {error: data.message}
    
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