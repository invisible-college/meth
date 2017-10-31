Gdax = require('gdax')
fs = require('fs')



RATE_LIMIT = 1000

write_trades = (hour, trades, c1, c2) -> 
  if hour + 1 <= current_hour && trades?.length > 0
    fname = "trade_history/gdax/#{c1}_#{c2}/#{hour}"    

    if !fs.existsSync(fname)
      fs.writeFileSync fname, JSON.stringify(trades), 'utf8' 



get_trades = (client, c1, c2, hours, after, stop_when_cached, callback, stop_after_hour) -> 
  cb = (error, response, data) -> 
    i += 1 

    next_page = response.headers['cb-after']

    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout ->
        client.getProductTrades {after: after, limit: limit}, cb 
      , 5000
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

    continue_loading &&= i * limit < latest_page

    if continue_loading
      if later_hour != early_hour # done processing this hour
        hr = later_hour
        while hr > early_hour
          write_trades hr, hours[hr], c1, c2
          hr -= 1

      setTimeout -> 
        get_trades client, c1, c2, hours, next_page, stop_when_cached, callback, stop_after_hour
      , 1000 / RATE_LIMIT
    else 
      callback?(hours)

  client.getProductTrades {after: after, limit: limit}, cb 





limit = 100
i = 0 
latest_page = null
current_hour = null


load_trades = (opts) -> 
  client = new Gdax.PublicClient("#{opts.c2}-#{opts.c1}")

  dir = "trade_history/gdax/#{opts.c1}_#{opts.c2}"
  if !fs.existsSync dir 
    fs.mkdirSync dir


  hour = (opts.start + 1) / 60 / 60 

  cb = (error, response, data) -> 

    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout ->
        client.getProductTrades {limit: 1}, cb 
      , 5000
      return

    i = 0 # used in recursion for get_trades
    current_hour = Math.floor(new Date(data[0].time).getTime() / 1000 / 60 / 60)

    latest_page = opts.starting_page or response.headers['cb-before'] 
    get_trades client, opts.c1, opts.c2, {}, latest_page, opts.stop_when_cached, opts.cb, opts.stop_after_hour
  
  client.getProductTrades {limit: 1}, cb




_find_page_for_hour = (client, hour, current_page, previous_page, callback) -> 
  target_hour = hour + 1

  if hour >= current_hour
    return callback(current_page)
     
  cb = (error, response, data) -> 
    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout -> 
        client.getProductTrades {after: current_page, limit: limit}, cb
      , 5000
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


  client.getProductTrades {after: current_page, limit: limit}, cb 







find_page_for_hour = (opts, callback) ->
  client = new Gdax.PublicClient("#{opts.c2}-#{opts.c1}")  
  cb = (error, response, data) -> 
    if error || !data || data.message
      console.error {message: 'error downloading trades! trying again', error: error, data: data}
      setTimeout ->
        client.getProductTrades {limit: 1}, cb 
      , 5000
      return

    current_hour = Math.floor(new Date(data[0].time).getTime() / 1000 / 60 / 60)
    _find_page_for_hour client, opts.hour, response.headers['cb-before'], 0, callback 

  client.getProductTrades {limit: 1}, cb




# this will currently only work when less then 200 candles are to be returned.
# e.g. when period is daily, this means 200 days of chart data.
# should be pretty easy to make work with more: 
load_chart_data = (client, opts, callback) -> 

  granularity = opts.period - 1
  chunk_size = granularity * 100  # load at most 20 candles per

  all_data = []
  
  i = 0 
  next = () -> 
    start_sec = opts.start + chunk_size * i 
    end_sec = opts.start + chunk_size * (i + 1) - 1 

    start = new Date(start_sec * 1000).toISOString()
    end = new Date( Math.min(opts.end, end_sec) * 1000).toISOString()

    cb = (error, response, data) ->
      if error || !data || data.message
        console.error {message: 'error getting chart data, trying again', error: error, response: response}
        setTimeout -> 
          client.getProductHistoricRates {start, end, granularity}, cb
        , 5000
        return 
        
      all_data.push data 

      if end_sec < opts.end
        i += 1
        setTimeout -> 
          next()
        , 1000 / 3

        
      else  
        callback [].concat all_data...


    client.getProductHistoricRates {start, end, granularity}, cb

  next()



queue = []
latest_requests = []
outstanding_requests = 0

module.exports = gdax = 
  all_clear: -> outstanding_requests == 0 && queue.length == 0 

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


  get_chart_data: (opts, callback) -> 
    client = new Gdax.PublicClient("#{opts.c2}-#{opts.c1}")
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

  get_your_trade_history: (opts, callback) -> 

  get_your_open_orders: (opts, callback) -> 

  get_your_balance: (opts, callback) -> 

  get_your_deposit_history: (opts, callback) -> 

  get_your_exchange_fee: (opts, callback) -> 

  place_order: (opts, callback) -> 

  cancel_order: (opts, callback) -> 




