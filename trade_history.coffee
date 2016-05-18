require './shared'
poloniex = require './poloniex'
progress_bar = require('progress')
fs = require('fs')

module.exports = history = 
  trades: []

  load: (start, end, complete) -> 
    try 
      fs.mkdirSync 'trade_history'  
    catch e 
      console.log 'trade_history dir already exists'

    first_hour = Math.floor start / 60 / 60
    last_hour = Math.ceil end / 60 / 60

    bar = new progress_bar '  loading history [:bar] :percent :etas :elapsed',
      complete: '='
      incomplete: ' '
      width: 40
      total: last_hour - first_hour 

    to_run = []
    for hour in [first_hour..last_hour]
      func = load_hour hour, end
      if func   
        to_run.push func 
      else 
        bar.tick()

    is_done = ->
      bar.tick()
      if to_run.length == 0
        history.trades.sort (a,b) -> b.date - a.date
        console.log "Done loading history! #{history.trades.length} trades."
        complete()
      else 
        f = to_run.pop()
        f is_done 

    is_done()


  longest_requested_history: ->
    hist_lengths = []
    for strat in get_strategies()
      settings = get_settings(strat)
      continue if settings.retired 
      hist_lengths.push (settings.frames + settings.max_t2) * settings.frame_width

    hist_lengths.push 60 * 10 # at least 25 minute frames, otherwise 
                              # problems caused by not having enough trades
    longest = Math.max.apply null, hist_lengths
    longest 

  # remove trades from history that will never be used by any strategy
  prune: ->
    history_width = history.longest_requested_history()

    for trade,idx in history.trades
      if tick.time - trade.date > history_width
        history.trades.slice 0, idx
        break


  subscribe_to_poloniex: -> 
    autobahn = require("autobahn")
    wsuri = "wss://api.poloniex.com"
    connection = new autobahn.Connection
      url: wsuri
      realm: "realm1"

    connection.onopen = (session) ->
      console.log '...engine is now receiving live updates'

      if lag_logger
        lag_logger 10 
             # record an initial laggy connection to give engine a little 
             # time to recalibrate history in case there was a reconnection
             # where we missed some trades. 

      session.subscribe "BTC_ETH", (arg) ->
        for item in arg when item.type == 'newTrade'
          process_new_trade item.data, true

      ticker = fetch '/ticker'
      session.subscribe "ticker", (update) ->
        return if update[0] != config.market

        ticker = extend ticker,
          last: parseFloat update[1]
          lowestAsk: parseFloat update[2]
          highestBid: parseFloat update[3]
          percentChange: parseFloat update[4]
          baseVolume: parseFloat update[5]
          quoteVolume: parseFloat update[6]
          isFrozen: update[7]
          hr24High: parseFloat update[8]
          hr24Low: parseFloat update[9]
        save ticker

    connection.open()



hours_loading = 0
load_hour = (hour, end) -> 
  fname = "trade_history/#{hour}"

  try 
    fs.accessSync fname

    from_file = fs.readFileSync(fname, 'utf8')
    trades = JSON.parse from_file

    for trade in trades when trade.date <= end
      history.trades.push trade

    # console.log "...loaded hour #{hour} via file"
    return null 

  catch e  
    f = (complete) -> 

      poloniex.query_public_api
        command: 'returnTradeHistory'
        currencyPair: config.market
        start: hour * 60 * 60
        end: (hour + 1) * 60 * 60 - 1
      , (__, _, trades) -> 

        if !trades 
          throw 'ABORT: Poloniex returned empty trade history' 

        for trade in trades 
          delete trade.globalTradeID
          delete trade.tradeID       
          process_new_trade trade 

        if hour + 1 <= now() / 60 / 60 && trades.length > 0
          fs.writeFile "trade_history/#{hour}", JSON.stringify(trades), 'utf8'

        #console.log "...loaded hour #{hour} with #{trades.length} trades from poloniex, took #{Date.now() - s}"
        complete()
    f


process_new_trade = (trade, preserve_sort) ->

  for prop in ['rate', 'amount', 'total']
    trade[prop] = parseFloat trade[prop] 
  trade.date = Date.parse(trade.date + " +0000") / 1000

  if preserve_sort
    history.trades.unshift trade 
  else 
    history.trades.push trade # much much much faster

  if preserve_sort && lag_logger
    lag_logger now() - trade.date

  trade






