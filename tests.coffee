args = require('minimist')(process.argv.slice(2))

require './shared'

exchange = require './exchange'
global.config = {}

# Testing the websocket connection vs polling trades
test_trade_integrity = -> 

  global.config = defaults global.config, args, 
    c1: 'BTC'
    c2: 'ETH'
    exchange: 'poloniex'

  global.bus = require('statebus').serve 
    file_store: false
    client: false

  polled_history = require './trade_history'
  websocket_history = bus.clone(polled_history) 

  console.assert polled_history.trades != websocket_history.trades 

  start = now()

  websocket_history.subscribe_to_trade_history ->
    console.log 'subscribed to websocket'

  poll_trades = ->
    ts = now()
    polled_history.load start, ts, ->
      if ts - start > 4
        evaluate_integrity()
      setTimeout poll_trades, 1000

  evaluate_integrity = -> 
    polled_trades = polled_history.trades 
    websocket_trades = websocket_history.trades

    return if websocket_trades.length == 0 

    earliest_w = websocket_trades[websocket_trades.length - 1].date 

    phash = {}
    whash = {}

    normalize = (trade) ->
      return {
        rate: trade.rate.toFixed(4)
        type: trade.type
        date: trade.date 
        total: trade.total.toFixed(4)
        amount: trade.amount.toFixed(4)
      }

    #console.log 'polled'
    for pt in polled_trades when pt.date >= earliest_w
      phash[JSON.stringify(normalize(pt))] = 1 
      #console.log normalize(pt)
    #console.log 'websocket'
    for wt in websocket_trades
      #console.log normalize(wt)
      whash[JSON.stringify(normalize(wt))] = 1

    w_in_p = p_in_w = 0
    for k,v of phash 
      if k of whash
        p_in_w += 1

    for k,v of whash 
      if k of phash
        w_in_p += 1

    console.log 
      '% of polled trades in websocket history': (p_in_w / Object.keys(whash).length).toFixed(4)
      '% of websocket history in polled trades': (w_in_p / Object.keys(phash).length).toFixed(4)
      'total polled': Object.keys(phash).length
      'total websocket': Object.keys(whash).length
  poll_trades()


switch args.test 
  when 'trades'
    test_trade_integrity()



