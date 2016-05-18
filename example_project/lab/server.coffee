require('coffee-script')

# Start that statebus server, beep beep
global.bus = require('statebus/server')()
bus.serve {port: 9391}
bus.honk = false


pusher = require '../pusher' # require before strategies
my_strategies = require '../strategies'
strategizer = require '../meth/strategizer'


for name, strat of my_strategies
  pusher.register_strategy name, strat 


lab = require('../meth/lab')
  market: 'BTC_ETH'
  tick_interval: 60
  simulation_width: 7 * 24 * 60 * 60
  end: Date.now() / 1000 - 0 * 7 * 24 * 60 * 60  
  exchange_fee: .002  
  deposit:
    BTC: 10000
    ETH: 10000

, pusher

operation.start()
