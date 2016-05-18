key = 'MY POLONIEX KEY'
secret = 'MY POLONIEX SECRET'

require('coffee-script')

# Start that statebus server, beep beep
global.bus = require('statebus/server')()
bus.serve {port: 9390}
bus.honk = false


pusher = require '../pusher' # require before strategies
my_strategies = require './strategies'
strategizer = require '../strategizer'


for name, strat of my_strategies
  pusher.register_strategy name, strat 


operation = require('../operation')
  key: key
  secret: secret
  market: 'BTC_ETH'
  tick_interval: 60
, pusher

operation.start()
