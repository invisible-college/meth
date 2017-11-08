


# these methods must be implemented for any exchange
module.exports = exchange = 
  all_clear: -> 
    console.assert config.exchange, message: 'Exchange is not configured'
    exchange[config.exchange].all_clear()


  #####
  # PUBLIC API 

  # opts: 
  #  currency_pair, start, end, period, callback
  get_chart_data: (opts, callback) -> 
    exchange[config.exchange].get_chart_data opts, callback

  # opts: 
  #  currency_pair, start, end, callback
  get_trade_history: (opts, callback) -> 
    exchange[config.exchange].get_trade_history opts, callback

  download_all_trade_history: (opts, callback) -> 
    if exchange[config.exchange].download_all_trade_history 
      exchange[config.exchange].download_all_trade_history opts, callback 
    else 
      callback()

  # callsback for each new trade
  # opts: none
  subscribe_to_trade_history: (opts, callback) -> 
    exchange[config.exchange].subscribe_to_trade_history opts, callback

  #####
  # TRADING API

  # opts: 
  #  c1, c2, start, end, callback
  get_my_fills: (opts, callback) -> 
    exchange[config.exchange].get_my_fills opts, callback


  # opts: 
  #  c1, c2
  get_my_open_orders: (opts, callback) -> 
    exchange[config.exchange].get_my_open_orders opts, callback

  # opts: 
  #  c1, c2
  get_my_balance: (opts, callback) -> 
    exchange[config.exchange].get_my_balance 
      currencies: [opts.c1, config.c2]
    , callback


  # opts: 
  #  none
  get_my_exchange_fee: (opts, callback) -> 
    exchange[config.exchange].get_my_exchange_fee opts, callback


  # opts: 
  #  type (buy / sell)
  #  amount
  #  rate 
  #  c1
  #  c2
  place_order: (opts, callback) -> 
    exchange[config.exchange].place_order opts, callback

  # opts: 
  #  order_id
  cancel_order: (opts, callback) -> 
    exchange[config.exchange].cancel_order opts, callback


  # opts: 
  #  order_id
  #  amount
  #  rate 
  #  c1
  #  c2
  #  type
  move_order: (opts, callback) ->
    exchange[config.exchange].move_order opts, callback 



exchange.poloniex = require './exchanges/poloniex'
exchange.gdax = require './exchanges/gdax'