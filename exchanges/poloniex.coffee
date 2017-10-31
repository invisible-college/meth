querystring = require('querystring')
crypto = require('crypto')
request = require('request')


queue = []
latest_requests = []
outstanding_requests = 0

RATE_LIMIT = 6  # no more than 6 API requests per second
                 # note: might be possible workarounds, see "Trading API Methods" 
                 #       of https://poloniex.com/support/api/



module.exports = poloniex = 
  all_clear: -> outstanding_requests == 0 && queue.length == 0 

  get_chart_data: (opts, callback) -> 
    poloniex.query_public_api
      command: 'returnChartData'
      currencyPair: "#{opts.c1}_#{opts.c2}"
      period: opts.period 
      start: opts.start - opts.period
      end: opts.end + opts.period
    , (__, _, price_history) -> 
      callback(price_history)

  get_trade_history: (opts, callback) -> 

    poloniex.query_public_api
      command: 'returnTradeHistory'
      currencyPair: "#{opts.c1}_#{opts.c2}"
      start: opts.start 
      end: opts.end
    , (__, _, trades) -> 
      callback(trades)

  subscribe_to_trade_history: (opts, callback) -> 
    WS = require('ws')
    wsuri = "wss://api2.poloniex.com"

    connection = new WS(wsuri, [], {})

    connection.onopen = (e) ->
      connection.keepAliveId = setInterval -> 
        connection.send('.')
      , 60000

      console.log '...engine is now receiving live updates'

      lag_logger?(99999)
         # record an initial laggy connection to give engine a little 
         # time to recalibrate history in case there was a reconnection
         # where we missed some trades. 

      connection.send JSON.stringify {command: 'subscribe', channel: "#{config.c1}_#{config.c2}"}

      callback()

    connection.onmessage = (msg) -> 
      if !msg || !msg.data 
        console.error '...empty data returned by poloniex live update', msg 
        return

      data = JSON.parse(msg.data)

      if data.error 
        console.error 'poloniex sent error in live update', data.error
        return

      for trade in (data[2] or []) when trade[0] == 't'
        opts.new_trade_callback 
          rate: trade[3]
          amount: trade[4]
          total: trade[3] * trade[4]
          date: new Date(parseInt(trade[5]) * 1000).toUTCString()


    connection.onclose = (e) -> 
      console.log '...lost connection to live feed from exchange',
        event: e 
         
      setTimeout ->
        console.log '...trying to reconnect'
        connection = new WS(wsuri, [], {})
      , 500

    connection.on 'unexpected-response', (request, response) ->
      console.error('error from poloniex', "unexpected-response (statusCode: #{response.statusCode}, #{}{response.statusMessage}")

    connection.onerror = (e) ->
      console.error('error from poloniex:', e)
    




  get_your_trade_history: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'returnTradeHistory'
      currencyPair: "#{opts.c1}_#{opts.c2}"
      start: opts.start
      end: opts.end
    , (err, resp, trade_history) ->
      trade_history ||= []
      for trade in trade_history
        trade.order_id = trade.orderNumber
        trade.amount = parseFloat trade.amount
        trade.total = parseFloat trade.total
        trade.rate = parseFloat trade.rate
        trade.fee = parseFloat(trade.fee) * (if trade.type == 'buy' then trade.amount else trade.total)
        trade.date = Date.parse(trade.date + " +0000")

      callback(trade_history)


  get_your_open_orders: (opts, callback) -> 

    poloniex.query_trading_api
      command: 'returnOpenOrders'
      currencyPair: "#{opts.c1}_#{opts.c2}"
    , (err, resp, all_open_orders) ->

      if !all_open_orders
        console.error "No response!", {err, resp, all_open_orders}

      for trade in all_open_orders
        trade.order_id = trade.orderNumber
        trade.amount = parseFloat trade.amount
        trade.total = parseFloat trade.total
        trade.rate = parseFloat trade.rate
        trade.date = Date.parse(trade.date + " +0000")
      callback(all_open_orders)

  get_your_balance: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'returnCompleteBalances'
    , (err, resp, body) -> callback(body)

  get_your_deposit_history: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'returnDepositsWithdrawals'
      start: opts.start
      end: opts.end
    , (err, resp, body) ->
     
      if !body
        callback
          error: err 
          response: resp 
          message: body.error 
      else 
        callback body    

  get_your_exchange_fee: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'returnFeeInfo'
    , (err, resp, body) -> callback(body)

  place_order: (opts, callback) -> 
    poloniex.query_trading_api
      command: opts.type
      amount: opts.amount
      rate: opts.rate
      currencyPair: opts.currency_pair
    , (err, resp, body) ->

      if !body
        callback
          error: err 
          response: resp 
          message: body.error 
      else 
        body.order_id = body.orderNumber
        callback body  

  cancel_order: (opts, callback) -> 

    poloniex.query_trading_api
      command: 'cancelOrder'
      orderNumber: opts.order_id
    , do (trade) -> (err, resp, body) ->

      if body?.error == 'Invalid order number, or you are not the person who placed the order.'
        # this happens if the trade got canceled outside the system or on a previous run that failed
        delete body.error 

      callback body 

      if !body
        callback
          error: err 
          response: resp 
          message: body.error 
      else 
        callback body


  move_order: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'moveOrder'
      orderNumber: opts.order_id
      rate: opts.rate
      amount: if opts.amount? then opts.amount
    , (err, resp, body) ->

      if body?.error == 'Invalid order number, or you are not the person who placed the order.'
        # this happens if the trade got canceled outside the system or on a previous run that failed
        delete body.error 

      if !body
        callback
          error: err 
          response: resp 
          message: body.error 

      else 
        body.order_id = body.orderNumber
        callback body       







  query_public_api: (params, callback) ->
    qs = querystring.stringify params

    request
      url: 'https://poloniex.com/public?' + qs
      method: 'GET'
      json: true
      headers:
        Accept: 'application/json'
        'X-Requested-With': 'XMLHttpRequest'

      (err, resp, body) ->
        #console.log "#{params.command} returned", (err or '') #, body

        if callback
          callback err, resp, body

  query_trading_api: (params, callback) ->
    

    if under_rate_limit() && poloniex.all_clear()
      trading_api_request params, callback 
    else 
      queue.push [params, callback]

      if !@queue_interval
        @queue_interval = setInterval ->
          while queue.length > 0 && outstanding_requests == 0 && under_rate_limit()
            job = queue.shift()
            trading_api_request job[0], job[1]

          if queue.length == 0 
            clearInterval @queue_interval
            @queue_interval = null 
        , 50


under_rate_limit = -> 
  old = []
  ts = (new Date()).getTime()
  for r in latest_requests
    if ts - r > 1100  # more than a second since request made (+ 100 just to be safer)
      old.push r 

  for r in old 
    latest_requests.splice latest_requests.indexOf(r), 1

  latest_requests.length < RATE_LIMIT


trading_api_request = (params, callback) ->

  ts = now()
  latest_requests.push (new Date()).getTime()

  params.nonce = nonce() if !params.nonce
  qs = querystring.stringify params

  outstanding_requests++

  request
    url: 'https://poloniex.com/tradingApi'
    form: params
    method: 'POST'
    json: true
    headers:
      Key: api_credentials.key
      Sign: crypto.createHmac('sha512', api_credentials.secret).update(qs).digest('hex')

    (err, resp, body) ->

      #TODO: if we get rate limited, submit again 
      
      outstanding_requests--

      lag_logger?(now() - ts)
      if params.command in ['buy', 'sell']
        console.log "#{params.command} returned", (err or ''), body

      callback?(err, resp, body)





nonce = ->
  ts = new Date().getTime()

  if ts != @last
    @nonce_inc = -1   

  @last = ts
  @nonce_inc++

  padding =
    if @nonce_inc < 10 then '000' else 
      if @nonce_inc < 100 then '00' else
        if @nonce_inc < 1000 then  '0' else ''

  "#{ts}#{padding}#{@nonce_inc}"