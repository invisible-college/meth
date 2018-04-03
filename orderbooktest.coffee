Gdax = require('gdax')
BigNumber = require('bignumber.js')


refresh_every = 20 * 1000
print_every = 1 * 1000

market = "BTC-USD"

orderbook = new Gdax.OrderbookSync([market])

console.log "ORDER BOOK FOR #{market}"
setInterval -> 
  console.log "Refreshing orderbook"
  console.time('refresh')
  orderbook.disconnect()
  orderbook = new Gdax.OrderbookSync([market])
  orderbook.books[market].state()
  console.timeEnd('refresh')
, refresh_every

update_orderbook = ->
  ob = orderbook.books[market].state() 
  bids = ob.bids 
  asks = ob.asks 

  if !ob.bids || !ob.asks || ob.bids.length == 0 || ob.asks.length == 0
    return

  first_bid = BigNumber(bids[0].price).toNumber()
  first_ask = BigNumber(asks[0].price).toNumber()

  vbids = {}
  vasks = {}
  for bid in bids 
    price = BigNumber(bid.price).toNumber()
    size = BigNumber(bid.size).toNumber()
    vbids[price] ?= 0 
    vbids[price] += size 
    break if price < first_bid * .998
  for ask in asks 
    price = BigNumber(ask.price).toNumber()
    size = BigNumber(ask.size).toNumber()
    vasks[price] ?= 0 
    vasks[price] += size 
    break if price > first_ask * 1.002

  bids = ([price, size] for price, size of vbids)
  bids.sort (a,b) -> b[0] - a[0]

  asks = ([price, size] for price, size of vasks)
  asks.sort (a,b) -> b[0] - a[0]

  ob_state = {}
  ob_state.spread = first_ask - first_bid 
  ob_state.first_ask = 
    rate: first_ask
    amt: vasks[first_ask]
  ob_state.first_bid = 
    rate: first_bid 
    amt: vbids[first_bid]

  console.log "SPREAD: #{ob_state.first_ask.rate - ob_state.first_bid.rate} ||| #{ob_state.first_bid.rate.toFixed(4)} [#{ob_state.first_bid.amt.toFixed(2)}] <> #{ob_state.first_ask.rate.toFixed(4)} [#{ob_state.first_ask.amt.toFixed(2)}]"

  # for a in asks 
  #   console.log a

  # console.log '***********'

  # for b in bids 
  #   console.log b 

  # console.log "SPREAD: ", first_ask - first_bid


setInterval update_orderbook, print_every
