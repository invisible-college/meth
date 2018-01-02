# Trade live on an exchange 

series = require '../strategizer'
strategies = require './strategies'


exchange = 'poloniex'

if exchange == 'gdax'
  accounting_currency = 'USD'
  #global.api_credentials =   # trading on GDAX isn't supported yet
  #   key: ''
  #   secret: ''
  #   pass: ''
else if exchange == 'poloniex' 
  accounting_currency = 'USDT'
  global.api_credentials = 
    key: 'your api key'
    secret: 'your api secret'

db_name = "my_live_hustler.sqlite"

operation = require('../operation')

operation.setup
  port: 8000
  db_name: db_name 
  clear_old: false 


# run a bunch of variations of our rebalancing strategy
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




operation.start
  exchange: exchange
  eval_entry_every_n_seconds: 60
  eval_exit_every_n_seconds: 60
  eval_unfilled_every_n_seconds: 60
  c1: 'BTC'
  c2: 'ETH'
  c1_budget: 0.005    # set your budget!!!
  c2_budget: 0.1  
  accounting_currency: accounting_currency
  enforce_balance: true
