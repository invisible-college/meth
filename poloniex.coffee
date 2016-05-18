querystring = require('querystring')
request = require('request')
crypto = require('crypto')


queue = []
latest_requests = []
outstanding_requests = 0


RATE_LIMIT = 6  # no more than 8 API requests per second



module.exports = poloniex = 
  all_clear: -> outstanding_requests == 0 && queue.length == 0 

  query_public_api: (params, callback) ->
    qs = querystring.stringify params

    request
      url: 'https://poloniex.com/public?' + qs
      method: 'GET'
      json: true
      headers:
        Accept: 'application/json'
        'X-Requested-With': 'XMLHttpRequest'

      (err, response, body) ->
        #console.log "#{params.command} returned", (err or '') #, body
        if callback
          callback err, response, body

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
      Key: config.key
      Sign: crypto.createHmac('sha512', config.secret).update(qs).digest('hex')

    (err, response, body) ->
      outstanding_requests--

      lag_logger now() - ts if lag_logger
      if params.command in ['buy', 'sell']
        console.log "#{params.command} returned", (err or ''), body

      if callback
        callback err, response, body





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
