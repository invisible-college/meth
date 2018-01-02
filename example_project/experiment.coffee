# Backtest your strategies

series = require '../strategizer'
strategies = require './strategies'

lab = require('../lab') # defines pusher

exchange = 'gdax' # GDAX only works currently in backtesting

if exchange == 'gdax'
  accounting_currency = 'USD'
  xfee = .0005 
else if exchange == 'poloniex'
  accounting_currency = 'USDT'
  xfee = .002

resimulate = true 

lab.setup 
  port: 9391 # your lab server will run on this port
  db_name: "my_test_db.sqlite" 
  clear_old: resimulate
  persist: true


if resimulate

  # test across a bunch of parameters for our rebalancing strategy
  rebalancers = []
  for thresh in [.01,.05,.1]
    for hour in [.5, 24, 24 * 7]
      frequency = hour * 60 * 60
      for rebalance_to_threshold in [false]
        for mark_when_changed in [true]
          for period in [1]
            for resolution in [10]          
              rebalancers.push {thresh, frequency, rebalance_to_threshold, mark_when_changed, resolution, period}

  pusher.learn_strategy "balancer", strategies.pure_rebalance, rebalancers

  pusher.learn_strategy 'price', series.price, [series.defaults] # we'll also track the price feature

  lab.experiment
    c1: 'USD'
    c2: 'BTC'
    exchange: exchange
    accounting_currency: accounting_currency
    simulation_width:  24 * 7 * 24 * 60 * 60 # backtest over 24 week period
    end:  Date.now() / 1000 - 0 * 7 * 24 * 60 * 60 # ending now
    exchange_fee: xfee # exchange fee (adjust based on your estimate of maker/taker proportions)
    eval_entry_every_n_seconds: 60
    eval_exit_every_n_seconds: 60
    eval_unfilled_every_n_seconds: 60
    enforce_balance: true
    log: true
    offline: false


