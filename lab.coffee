fs = require 'fs'
progress_bar = require('progress')
mathjs = require 'mathjs'

require './shared'
history = require './trade_history'
exchange = require './exchange'
global.pusher = require './pusher'
crunch = require './crunch'



global.position_status = {}


#########################
# Main event loop


simulate = (ts, callback) ->   
  ts = Math.floor(ts)
  time = from_cache('time')
  extend time, 
    earliest: ts - config.simulation_width
    latest: ts
  save time

  global.tick = tick = 
    time: 0 

  global.t_ = 
    qtick: 0 
    # feat_calc: 0 
    hustle: 0 
    feature_tick: 0 
    #quant: 0 
    #exec: 0 
    eval_pos: 0 
    #create_pos: 0 
    handle_new: 0 
    handle_open: 0
    balance: 0
    pos_status: 0
    gc: 0
    x: 0 
    y: 0 
    z: 0 
    a: 0 
    b: 0 
    c: 0


  price_data = fetch('price_data')
  start = ts - config.simulation_width - history.longest_requested_history

  tick.time = ts - config.simulation_width

  start_idx = history.trades.length - 1
  end_idx = start_idx
  for end_idx in [end_idx..0] by -1
    if history.trades[end_idx].date > tick.time
      end_idx += 1        
      break 

  for trade,idx in history.trades 
    console.assert trade, {message: 'trade is null!', trade: trade, idx: idx}

  balance = from_cache('balances')

  extend balance, 
    balances:
      c1: 0
      c2: 0
    deposits: 
      c1: 0 
      c2: 0 
    accounted_for: 
      c1: 0
      c2: 0
    on_order: 
      c1: 0
      c2: 0

    exchange_fee: config.exchange_fee

  dealers = get_dealers()
  $c2 = price_data.c2?[0].close or price_data.c1xc2[0].close
  $c1 = price_data.c1?[0].close or 1
  #$budget_per_strategy = 100000 / dealers.length
  $budget_per_strategy = 100
  
  for dealer in dealers
    settings = from_cache(dealer).settings

    balance[dealer] = 
      balances:
        c2: $budget_per_strategy * (settings.ratio or .5) / $c2
        c1: $budget_per_strategy * (1 - (settings.ratio or .5) ) / $c1
      deposits: 
        c2: $budget_per_strategy * (settings.ratio or .5) / $c2
        c1: $budget_per_strategy * (1 - (settings.ratio or .5) ) / $c1        
      accounted_for: 
        c1: 0
        c2: 0
      on_order: 
        c1: 0
        c2: 0
    balance.balances.c2 += balance[dealer].balances.c2 
    balance.balances.c1 += balance[dealer].balances.c1 
    balance.deposits.c2 += balance[dealer].deposits.c2 
    balance.deposits.c1 += balance[dealer].deposits.c1 


  save balance

  t = ':percent :etas :elapsed :ticks' 
  for k,v of t_
    t += " #{k}-:#{k}"

  bar = new progress_bar t,
    complete: '='
    incomplete: ' '
    width: 40
    total: Math.ceil (time.latest - time.earliest) / config.tick_interval
    renderThrottle: 500

  ticks = 0
    
  started_at = Date.now()

  price_idx = 0


  end = -> 


    history.trades = [] # free memory

    if global.gc
      global.gc()
    else
      console.log('Garbage collection unavailable.  Pass --expose-gc.');


    if config.produce_heapdump
      try   
        heapdump = require('heapdump')   
        heapdump.writeSnapshot()
      catch e 
        console.log 'Could not take snapshot'


    log_results()

    console.time('saving db')
    global.timerrrr = Date.now()
    save balance
    for name in get_all_actors()
      d = from_cache name
      for pos in (d.positions or [])
        delete pos.last_exit if pos.last_exit
        delete pos.original_exit if pos.original_exit
      save d
    console.timeEnd('saving db')

    console.log "\nDone simulating! That took #{(Date.now() - started_at) / 1000} seconds" if config.log
    console.log config if !config.multiple_times

    if config.multiple_times
      reset() 
    callback?()

  one_tick = ->

    t = Date.now()

    start += config.tick_interval
    tick.time += config.tick_interval

    ###########################
    # Find trades that we care about this tick. history.trades is sorted newest first
    #zzz = Date.now()    
    while start_idx >= 0
      if history.trades[start_idx].date > start 
        start_idx += 1
        break 

      start_idx -= 1

    while end_idx >= 0 
      if history.trades[end_idx].date > tick.time 
        end_idx += 1 
        break
      end_idx -= 1

    console.assert start_idx < history.trades.length, {message: 'starting wrong!', start_idx: start_idx, trades: history.trades.length}
    console.assert end_idx < history.trades.length, {message: 'ending wrong!', end_idx: end_idx, trades: history.trades.length}
    ############################


    simulation_done = tick.time > ts - config.tick_interval * 10


    ######################
    #### Accounting
    dealers_with_open = []
    for dealer, positions of open_positions when positions.length > 0 
      dealers_with_open.push dealer

    if dealers_with_open.length > 0 
      # check if any positions have subsequently closed
      yyy = Date.now()
      update_position_status end_idx, balance, dealers_with_open
      t_.pos_status += Date.now() - yyy

      yyy = Date.now()
      update_balance balance, dealers_with_open
      t_.balance += Date.now() - yyy
    #####################



    if !simulation_done && end_idx != start_idx

      ######################
      #### Get relevant trades
      trades = history.trades.slice(end_idx, start_idx)
      #t_.quant += Date.now() - zzz

      ######################
      #### Main call. Where the action is. 
      pusher.hustle balance, trades
      ######################




    if simulation_done
      return end()




    ####################
    #### Efficiency measures
    if ticks % Math.round(50000 / (config.tick_interval / 60)) == 1 && global.gc
      xxxx = Date.now()
      global.gc()
      t_.gc += Date.now() - xxxx

    if ticks % 100 == 99
      purge_position_status()
    ####################

    #####################
    #### Progress bar
    if config.log
      t_sec = {}
      for k,v of t_
        t_sec[k] = Math.round(v/1000)
      bar.tick 1, extend {ticks}, t_sec
    #####################

    ticks++

    t_.qtick += Date.now() - t


    if true || config.log
      setImmediate one_tick
    else 
      one_tick()

  setImmediate one_tick




update_balance = (balance, dealers_with_open) -> 


  btc = eth = btc_on_order = eth_on_order = 0
  x_fee = balance.exchange_fee

  for dealer in dealers_with_open
    positions = open_positions[dealer]

    dbtc = deth = dbtc_on_order = deth_on_order = 0

    for pos in positions

      if pos.entry.type == 'buy' 
        buy = pos.entry 
        sell = pos.exit
      else 
        buy = pos.exit
        sell = pos.entry

      
      if buy
        # used or reserved for buying trade.amount eth
        for_purchase = buy.to_fill * buy.rate
        dbtc_on_order += for_purchase
        dbtc -= for_purchase

        if buy.fills?.length > 0           
          for fill in buy.fills
            deth += fill.amount 
            dbtc -= fill.total

            if config.exchange == 'poloniex'
              deth -= fill.amount * x_fee
            else 
              dbtc -= fill.total * x_fee

      if sell 
        for_sale = sell.to_fill
        deth_on_order += for_sale
        deth -= for_sale

        if sell.fills?.length > 0 
          for fill in sell.fills 
            deth -= fill.amount
            dbtc += fill.total 
            dbtc -= fill.total * x_fee 
    
    btc += dbtc 
    eth += deth 
    btc_on_order += dbtc_on_order
    eth_on_order += deth_on_order

    dbalance = balance[dealer]
    dbalance.balances.c1 = dbalance.deposits.c1 + dbtc + dbalance.accounted_for.c1
    dbalance.balances.c2 = dbalance.deposits.c2 + deth + dbalance.accounted_for.c2
    dbalance.on_order.c1 = dbtc_on_order
    dbalance.on_order.c2 = deth_on_order

    if config.enforce_balance && (dbalance.balances.c1 < 0 || dbalance.balances.c2 < 0)

      msg =         
        message: 'negative balance!?!'
        balance: balance.balances
        dbalance: balance[dealer]
        positions: from_cache(dealer).positions
        dealer: dealer

      for pos in from_cache(dealer).positions 
        for t in [pos.entry, pos.exit] when t 
          msg["#{pos.created}-#{t.type}"] = t
          amt = 0 
          tot = 0 
          for f,idx in (t.fills or [])
            msg["#{pos.created}-#{t.type}-f#{idx}"] = f
            amt += f.amount 
            tot += f.total 

          console.log
            type: t.type 
            amt: amt
            tot: tot 
            fills: (t.fills or []).length

      console.assert false, msg


  balance.balances.c1 = balance.deposits.c1 + btc + balance.accounted_for.c1
  balance.balances.c2 = balance.deposits.c2 + eth + balance.accounted_for.c2
  balance.on_order.c1 = btc_on_order
  balance.on_order.c2 = eth_on_order


global.trades_closed = {}

purge_position_status = -> 
  new_position_status = {}
  for name, open of open_positions when open.length > 0
    for pos in open 
      for trade in [pos.entry, pos.exit] when trade && !trade.closed
        ```
        key = `${pos.dealer}-${trade.created}-${trade.type}-${trade.rate}`
        ```
        new_position_status[key] = global.position_status[key]

  for k,v of global.position_status 
    if k not of new_position_status
      delete global.position_status[k]



update_position_status = (end_idx, balance, dealers_with_open) -> 

  for dealer in dealers_with_open
    open = open_positions[dealer]
    closed = []

    for pos in open 

      for trade in [pos.entry, pos.exit] when trade && !trade.closed
        ```
        key = `${pos.dealer}-${trade.created}-${trade.type}-${trade.rate}`
        ```

        status = global.position_status[key]

        if trade.to_fill > 0 && (!status? || end_idx < status.idx + 100 )
          status = global.position_status[key] = fill_order trade, end_idx, status
          # console.log '\nFILLLLLLLL\n', key, end_idx, status?.idx, status?.fills?.length

        if status?.fills?.length > 0 && !trade.force_canceled
          filled = 0 
          my_rate = trade.rate 

          for fill in (status.fills or [])
            if fill.date > tick.time 
              break 

            done = fill.amount >= trade.to_fill

            fill.amount = if !done then fill.amount           else trade.to_fill 
            fill.total  = if !done then fill.amount * my_rate else trade.to_fill * my_rate

            trade.to_fill -= fill.amount 
            trade.fills.push fill
            filled += 1
          if filled > 0 
            status.fills = status.fills.slice(filled)

        if trade.to_fill < 0 
          console.assert false, 
            message: 'Overfilled!'
            trade: trade 
            fills: trade.fills

        if trade.to_fill == 0
          trade.closed = if trade.force_canceled then tick.time else trade.fills[trade.fills.length - 1].date
          global.position_status[key] = undefined

      if (pos.entry?.closed && pos.exit?.closed) || (dealers[dealer].never_exits && pos.entry?.closed)
        pos.closed = Math.max pos.entry.closed, (pos.exit?.closed or 0)
        closed.push pos 


    for pos in closed
      idx = open.indexOf(pos) 
      open.splice idx, 1 
      name = pos.dealer

      cur_c1 = balance.accounted_for.c1
      cur_c2 = balance.accounted_for.c2

      for trade in [pos.entry, pos.exit] when trade
        if !trade.total 
          total = 0 
          for fill in trade.fills 
            total += fill.total 
          trade.total = total 

        if trade.type == 'buy'

          balance.accounted_for.c2 += trade.amount 
          balance.accounted_for.c2 -= trade.amount * balance.exchange_fee
          balance.accounted_for.c1 -= trade.total

          balance[name].accounted_for.c2 += trade.amount 
          balance[name].accounted_for.c2 -= trade.amount * balance.exchange_fee
          balance[name].accounted_for.c1 -= trade.total

        else
          balance.accounted_for.c2 -= trade.amount 
          balance.accounted_for.c1 += trade.total 
          balance.accounted_for.c1 -= trade.total * balance.exchange_fee

          balance[name].accounted_for.c2 -= trade.amount 
          balance[name].accounted_for.c1 += trade.total 
          balance[name].accounted_for.c1 -= trade.total * balance.exchange_fee

      delete pos.expected_profit
      pos.profit = (balance.accounted_for.c1 - cur_c1) / pos.exit.rate + (balance.accounted_for.c2 - cur_c2) 

      if pos.dealer of slow_start_settings
        if (pos.profit or pos.expected_profit) >= 0
          slow_start_settings[pos.dealer] += .1
          slow_start_settings[pos.dealer] = Math.min 1, slow_start_settings[pos.dealer]
        else 
          slow_start_settings[pos.dealer] *= .5


fill_order = (my_trade, end_idx, status) -> 

  status ||= {}



  my_amount = my_trade.amount 
  my_rate = my_trade.rate
  is_sell = my_trade.type == 'sell'
  my_created = my_trade.created 
  trade_lag = config.trade_lag  

  if status.idx
    start_at = status.idx
  else 
    start_at = end_idx

  to_fill = my_trade.to_fill

  status.fills ||= []
  fills = status.fills 

  init = false
  for idx in [start_at..0] by -1
    trade = history.trades[idx]

    if !init
      if trade.date < my_created + trade_lag
        continue
      else 
        init = true 

    if (!is_sell && trade.rate <= my_rate) || \
       ( is_sell && trade.rate >= my_rate)

      fill = 
        date: trade.date 
        rate: my_rate 
        amount: trade.amount

      # console.log fill
      fills.push fill

      if trade.amount >= to_fill
        status.idx = idx
        return status
      else 
        to_fill -= fill.amount

    if trade.date > history.trades[end_idx].date + 30 * 60
      status.idx = idx 
      return status



store_analysis = ->

  # analysis of positions
  fs = require('fs')
  if !fs.existsSync 'analyze'
    fs.mkdirSync 'analyze'  

  dir = "analyze/#{config.end - config.simulation_width}-#{config.end}"

  if !fs.existsSync dir  
    fs.mkdirSync dir  

  dealer_names = get_dealers()
  sample = null
  sample_dealer = null
  for name in dealer_names
    for pos in (from_cache(name).positions or [])
      sample = dealers[name].analyze pos, config.exchange_fee
      sample_dealer = name
      break 
    break if sample 

  return if !sample 

  cols = Object.keys(sample.dependent).concat(Object.keys(get_settings(sample_dealer))).concat Object.keys(sample.independent)

  rows = []

  rows.push cols

  for name in dealer_names
    positions = from_cache(name).positions
    dealer = dealers[name]
    settings = get_settings(name) or {}

    for pos in positions
      row = dealer.analyze(pos, config.exchange_fee)
      independent = extend {}, row.independent, settings
      rows.push ( (if col of independent then independent[col] else row.dependent[col]) for col in cols)


  fname = "#{dir}/positions.txt"
  fs.writeFileSync fname, (r.join('\t') for r in rows).join('\n'), { flag : 'w' }

  # analysis of dealers 
  KPI (all_stats) -> 

    cols = ['Name']


    pieces = {}
    for name in get_dealers()
      for part, idx in name.split('&')
        if idx > 0
          [param,val] = part.split('=')
          pieces[param] ||= {} 
          pieces[param][val] = true
      
    params = (p for p,v of pieces when Object.keys(v).length > 1)

    cols = cols.concat params

    for measure, __ of dealer_measures(all_stats)
      cols.push measure

    rows = [cols]


    for name in get_dealers()
      stats = all_stats[name]

      my_params = {}
      for part, idx in name.split('&')
        if idx > 0
          [param,val] = part.split('=')
          my_params[param] = val 
        else 
          strat = part

      row = [strat]

      for param in params 
        if param of my_params
          row.push my_params[param]
        else 
          row.push ''

      for measure, calc of dealer_measures(all_stats)
        row.push calc(name)

      rows.push row


    fname = "#{dir}/dealers.txt"
    fs.writeFileSync fname, (r.join('\t') for r in rows).join('\n'), { flag : 'w' }


log_results = ->

  if config.analyze 
    console.log 'Exporting analysis'
    store_analysis()

  return if !config.log_results

  # analysis of positions
  fs = require('fs')
  if !fs.existsSync('logs') 
    fs.mkdirSync 'logs'  

  fname = "logs/#{config.log_results}.txt"

  KPI (all_stats) -> 
    if !fs.existsSync(fname)
      cols = ['Name', 'Currency1', 'Currency2', 'Exchange', 'Start', 'End']

      for measure, __ of dealer_measures(all_stats)
        cols.push measure
    else 
      cols = []

    rows = [cols]

    row = [config.name, config.c1, config.c2, config.exchange, config.end - config.simulation_width, config.end]

    for measure, calc of dealer_measures(all_stats)
      row.push calc('all')

    rows.push row


    console.log (r.join('\t') for r in rows).join('\n')
    # out = fs.createWriteStream fname, {flags:'a'}
    # out.write (r.join('\t') for r in rows).join('\n')
    # out.end()


    out = fs.openSync fname, 'a'
    fs.writeSync out, (r.join('\t') for r in rows).join('\n')
    fs.closeSync out


reset = -> 
  global.config = {}

  KPI.initialized = false


  global.open_positions = {}
  global.slow_start_settings = {}

  history.trades = []

  pusher.init
    history: history 
    clear_all_positions: true 



lab = module.exports = 

  experiment_multiple_times: (conf, times, callback) -> 
    next = ->
      if times.length == 0 
        callback?()
      else 
        time = times.pop()
                
        conf.simulation_width = time.simulation_width
        conf.end = time.end 
        conf.name = time.name 
        conf.multiple_times = true

        console.log "***********"
        console.log "Next experiment! (#{times.length} more remaining)"
        lab.experiment conf, next

    next()

  experiment: (conf, callback) -> 
    global.config = {}

    global.config = defaults global.config, conf, 
      key: 'config'
      exchange: 'poloniex'
      simulation: true
      tick_interval: 60 # in seconds
      simulation_width: 12 * 24 * 60 * 60
      c1: 'BTC'
      c2: 'ETH'
      accounting_currency: 'USDT'
      trade_lag: 20
      exchange_fee: .0020
      log: true
      enforce_balance: true
      persist: true
      analyze: false
      checks_per_frame: 2
      produce_heapdump: false
      offline: false
    save config 

    # set globals
    global.position_status = {}

    console.log "Prepping the lab to run #{Object.keys(dealers).length} dealers" if config.log

    ts = config.end or now()

    pusher.init
      history: history 
      clear_all_positions: true 

    console.assert !isNaN(history.longest_requested_history), 
      message: 'Longest requested history is NaN. Perhaps you haven\'t registered any dealers'


    # console.log 'longest requested history:', history.longest_requested_history
    history_width = history.longest_requested_history + config.simulation_width + 24 * 60 * 60


    history.load_price_data ts - history_width, ts, ->
      console.log "...loading #{ (history_width / 60 / 60 / 24).toFixed(2) } days of trade history, relative to #{ts}" if config.log
      history.load ts - history_width, ts, -> 
        console.log "...experimenting!" if config.log
        simulate ts, callback



  setup: ({persist, port, db_name, clear_old, no_client}) -> 
    global.pointerify = true
    global.upload_dir = 'static/'

    global.bus = require('statebus').serve 
      port: port
      file_store: false
      client: false

    bus.honk = false
    if persist
      if clear_old && fs.existsSync(db_name)
        fs.unlinkSync(db_name) 
      bus.sqlite_store
        filename: db_name
        use_transactions: true

    global.save = bus.save 
    global.fetch = (key) ->
      bus.fetch deslash key 

    global.del = bus.del 

    if !no_client
      require 'coffee-script'
      require './shared'
      express = require('express')


      bus.http.use('/node_modules', express.static('node_modules'))
      bus.http.use('/meth/vendor', express.static('meth/vendor'))


      # taken from statebus server.js. Just wanted different client path.
      bus.http_serve '/meth/:filename', (filename) -> 
        filename = deslash filename

        source = bus.read_file(filename)

        if filename.match(/\.coffee$/)

          try
            compiled = require('coffee-script').compile source, 
                                                          filename: filename
                                                          bare: true
                                                          sourceMap: true
          
          catch e
            console.error('Could not compile ' + filename + ': ', e)
            return ''


          compiled = require('coffee-script').compile(source, {filename: filename, bare: true, sourceMap: true})
          source_map = JSON.parse(compiled.v3SourceMap)
          source_map.sourcesContent = source
          compiled = 'window.dom = window.dom || {}\n' + compiled.js
          compiled = 'window.ui = window.ui || {}\n' + compiled

          btoa = (s) -> return new Buffer(s.toString(),'binary').toString('base64')

          # Base64 encode it
          compiled += '\n'
          compiled += '//# sourceMappingURL=data:application/json;base64,'
          compiled += btoa(JSON.stringify(source_map)) + '\n'
          compiled += '//# sourceURL=' + filename
          return compiled

        else return source


      bus.http.get '/*', (r,res) => 

        paths = r.url.split('/')
        paths.shift() if paths[0] == ''

        prefix = ''
        server = "statei://localhost:#{port}"

        html = """
          <!DOCTYPE html>
          <html>
          <head>
          <script type="coffeedom">
          bus.honk = false
            
          #</script>
          <script src="#{prefix}/node_modules/statebus/client.js" server="#{server}"></script>
          <script src="#{prefix}/meth/vendor/d3.js"></script>
          <script src="#{prefix}/meth/vendor/md5.js"></script>
          <script src="#{prefix}/meth/vendor/plotly.js"></script>


          <script src="#{prefix}/meth/shared.coffee"></script>
          <script src="#{prefix}/meth/crunch.coffee"></script>
          <script src="#{prefix}/meth/dash.coffee"></script>

          <link rel="stylesheet" href="#{prefix}/meth/vendor/fonts/Bebas Neue/bebas.css" type="text/css"/>
          
          </head>
          <body>
          </body>
          </html>
            """

        res.send(html)




