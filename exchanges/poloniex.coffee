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

  get_earliest_trade: (opts) ->

    pair = "#{opts.c2}-#{opts.c1}"

    earliest_trades = 
      "BTC-USDT": 1424304000
      "ETH-USDT": 1438992000
      "LTC-USDT": 1425686400 
      "DASH-USDT": 1424131200
      "XMR-USDT": 1424131200
      "XRP-USDT": 1424390400
      "BCH-USDT": 1502668800
      "ETC-USDT": 1469664000
      "ZEC-USDT": 1477612800
      "STR-USDT": 1426032000
      "REP-USDT": 1475539200

      "ETH-BTC": 1438992000
      "LTC-BTC": 1424304000
      "DASH-BTC": 1391731200
      "XRP-BTC": 1407974400
      "XMR-BTC": 1400457600
      "BCH-BTC": 1502668800
      "ZEC-BTC": 1477612800
      "NXT-BTC": 1390089600
      "EMC2-BTC": 1394928000
      "LSK-BTC": 1464048000
      "STR-BTC": 1407715200
      "REP-BTC": 1475539200
      "GNO-BTC": 1493596800

      "ETC-ETH": 1469318400
      "ZEC-ETH": 1477612800
      "BCH-ETH": 1502668800

    # time after which a pair has sustained 1-week exponentially 
    # weighted moving average of hourly USD transacted > $50k
    high_volume = 
      "BTC-USDT": 1482796800 # after 12/27/16 *
      "ETH-USDT": 1488499200 # after 3/3/17 * 
      "LTC-USDT": 1491091200 # after 4/2/17 * 
      "DASH-USDT": 1489276800 # after 3/12/17 this one is iffy
      "XMR-USDT": 1489190400 # after 3/11/17 * 
      "XRP-USDT": 1491004800 # after 4/1/17 *
      "BCH-USDT": 1502668800 # all * 
      "ETC-USDT": 1492905600 # after 4/23/17 *
      "ZEC-USDT": 1495497600 # after 5/23/17 *

      "ETH-BTC": 1438992000 # all *
      "LTC-BTC": 1489795200 # after 3/18/17 * 
      "DASH-BTC": 1487462400 # after 2/19/17 * 
      "XRP-BTC": 1489017600 # after 3/9/17 *
      "XMR-BTC": 1471737600 # after 8/21/16 * 
      "BCH-BTC": 1502668800 # all * 
      "ZEC-BTC": 1489536000 # after 3/15/17 * 

      "STR-BTC": 1491091200 # after 4/2/17
      "REP-BTC": 1489881600 # after 3/19/17

      "BCH-ETH": 1509580800 # after 11/2/17 *

    if opts.only_high_volume
      console.assert high_volume[pair],
        msg: "high_volume for #{pair} on not listed in POLONIEX's get_earliest_trade method" 
        high_volume: high_volume
        pair: pair 
        val: high_volume[pair]

      return high_volume[pair]
    else
      console.assert earliest_trades[pair],
        msg: "earliest trade for #{pair} on not listed in POLONIEX's get_earliest_trade method" 

      return earliest_trades[pair]


  get_chart_data: (opts, callback) -> 
    poloniex.query_public_api
      command: 'returnChartData'
      currencyPair: "#{opts.c1}_#{opts.c2}"
      period: opts.period 
      start: opts.start - opts.period
      end: opts.end + opts.period
    , (__, _, price_history) -> 
      if !price_history || price_history.constructor != Array
        console.error "Error getting price history. Retrying."
        setTimeout ->
          poloniex.get_chart_data opts, callback 
        , 200
      else 
        callback(price_history)

  get_trade_history: (opts, callback) -> 

    poloniex.query_public_api
      command: 'returnTradeHistory'
      currencyPair: "#{opts.c1}_#{opts.c2}"
      start: opts.start 
      end: opts.end
    , (__, _, trades) -> 

      if !trades
        console.error "Error getting trades. Retrying."
        setTimeout ->
          poloniex.get_trade_history opts, callback 
        , 200
      else 
        for trade in trades 
          trade.date = Date.parse(trade.date + " +0000") / 1000
        callback(trades)

  subscribe_to_trade_history: (opts, callback) -> 
    WS = require('ws')
    wsuri = "wss://api2.poloniex.com"

    create_connection = -> 
      connection = new WS(wsuri, [], {})

      reconnect = -> 
        connection.terminate()
        setTimeout ->
          console.log '...trying to reconnect'

          create_connection()
        , 500

      connection.onopen = (e) ->
        connection.keepAliveId = setInterval -> 
          connection.send('.', (error) -> reconnect() if error)
        , 60000

        console.log '...engine is now receiving live updates'

        lag_logger?(99999)
           # record an initial laggy connection to give engine a little 
           # time to recalibrate history in case there was a reconnection
           # where we missed some trades. 

        connection.send JSON.stringify({command: 'subscribe', channel: "#{config.c1}_#{config.c2}"}), (error) ->
          reconnect() if error 

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
            date: trade[5]
            type: if trade[2] == 1 then 'buy' else 'sell'


      connection.onclose = (e) -> 
        console.log '...lost connection to live feed from exchange',
          event: e 
        reconnect()

      connection.on 'unexpected-response', (request, response) ->
        console.error('error from poloniex', "unexpected-response (statusCode: #{response.statusCode}, #{}{response.statusMessage}")

      connection.onerror = (e) ->
        console.error('error from poloniex:', e)

    create_connection()




  get_my_fills: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'returnTradeHistory'
      currencyPair: "#{opts.c1}_#{opts.c2}"
      start: opts.start
      end: opts.end
    , (__, _, fills) ->
      if !fills 
        console.error "Error getting my fills. Retrying."
        setTimeout ->
          poloniex.get_my_fills opts, callback 
        , 200
      else  
        balance = from_cache('balance')

        my_fills = []
        for fill in fills 
          fee = parseFloat(fill.fee)
          amount = parseFloat fill.amount
          total = parseFloat fill.total
          my_fills.push 
            order_id: fill.orderNumber 
            fill_id: fill.tradeID 
            amount: amount
            total: total
            rate: parseFloat fill.rate
            fee: fee * (if fill.type == 'buy' then amount else total)
            date: Date.parse(fill.date + " +0000") / 1000
            maker: Math.abs(fee - balance.maker_fee) < Math.abs(fee - balance.taker_fee)
        callback(my_fills)



  get_my_open_orders: (opts, callback) -> 

    poloniex.query_trading_api
      command: 'returnOpenOrders'
      currencyPair: "#{opts.c1}_#{opts.c2}"
    , (err, resp, all_open_orders) ->

      if !all_open_orders
        console.error "Error getting my open orders. Retrying."
        setTimeout ->
          poloniex.get_my_open_orders opts, callback 
        , 200

      else 

        for trade in all_open_orders
          trade.order_id = trade.orderNumber
          trade.amount = parseFloat trade.amount
          trade.total = parseFloat trade.total
          trade.rate = parseFloat trade.rate
          trade.date = Date.parse(trade.date + " +0000") / 1000
        callback(all_open_orders)

  get_my_balance: (opts, callback) -> 
    poloniex.query_trading_api
      command: 'returnCompleteBalances'
    , (err, resp, body) -> 

      if !body || body.error
        console.error 
          message: 'Error getting balance, retrying'
          opts: opts
          error: body.error
          body: body

        poloniex.get_my_balance opts, callback
      else 
        for currency in opts.currencies 
          if !body[currency]
            console.error 
              message: 'Poloniex returned incomplete balance, retrying'
              opts: opts
              currency: currency
              body: body
            poloniex.get_my_balance opts, callback        
            return

        balances = {}
        for currency, balance of body
          if currency in opts.currencies
            balances[currency] = 
              available: balance.available
              on_order: balance.onOrders

        callback balances


  get_my_exchange_fee: (opts, callback) -> 

    if config.simulation
      callback 
        taker_fee: .0025
        maker_fee: .0015
    else       
      poloniex.query_trading_api
        command: 'returnFeeInfo'
      , (err, resp, body) -> 

        if !body || body.error 
          console.log 'Exchange fee returned error, retrying'
          poloniex.get_my_exchange_fee opts, callback 
          return

        callback
          taker_fee: parseFloat body.takerFee
          maker_fee: parseFloat body.makerFee

  place_order: (opts, callback) -> 
    if opts.market 
      return poloniex.market_order(opts, callback)

    poloniex.query_trading_api
      command: opts.type
      amount: opts.amount
      rate: opts.rate
      currencyPair: "#{opts.c1}_#{opts.c2}"
    , (err, resp, body) ->

      if !body
        callback
          error: err 
          response: resp 
          message: body.error 
      else 
        body.order_id = body.orderNumber
        callback body

  market_order: (opts, callback) -> 
    console.assert false, 
      message: 'market orders not yet supported on poloniex'
    amount = opts.amount 
    rate = opts.rate
    total = amount * rate
    is_buy = opts.type == 'buy'

    cb = (err, resp, body) ->
      if !body
        callback
          error: err 
          response: resp 
          message: body.error 
      else
        # todo: check for whether fill or kill was successful
        if false # fill or kill did not work
          if is_buy 
            rate *= 1.005
            amount = total / rate
          else 
            rate *= 0.995

          try_order()

        else 
          body.order_id = body.orderNumber
          callback body

    try_order = ->
      poloniex.query_trading_api
        command: opts.type
        amount: amount
        rate: rate
        currencyPair: "#{opts.c1}_#{opts.c2}"
        fillOrKill: 1
      , cb

    try_order()
   

  cancel_order: (opts, callback) -> 

    poloniex.query_trading_api
      command: 'cancelOrder'
      orderNumber: opts.order_id
    , do (trade) -> (err, resp, body) ->

      if body?.error == 'Invalid order number, or you are not the person who placed the order.'
        # this happens if the trade got canceled outside the system or on a previous run that failed
        delete body.error 

      callback body 



  move_order: (opts, callback) -> 
    console.assert !opts.market 

    poloniex.query_trading_api
      command: 'moveOrder'
      orderNumber: opts.order_id
      rate: opts.rate
      amount: opts.amount
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
        callback {order_id: body.orderNumber}       







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