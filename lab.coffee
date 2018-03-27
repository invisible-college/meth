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
    earliest: ts - config.length
    latest: ts
  save time

  global.tick = tick = 
    time: 0 

  global.t_ = 
    qtick: 0 
    hustle: 0 
    exec: 0
    feature_tick: 0 
    eval_pos: 0 
    check_new: 0 
    check_exit: 0
    check_unfilled: 0
    balance: 0
    pos_status: 0
    # gc: 0
    # x: 0 
    # y: 0 
    # z: 0 
    # a: 0 
    # b: 0 
    # c: 0


  price_data = fetch('price_data')
  start = ts - config.length - history.longest_requested_history

  tick.time = ts - config.length
  tick.start = start 

  #start_idx = history.trades.length - 1
  end_idx = history.trades.length - 1
  for end_idx in [end_idx..0] by -1
    if history.trades[end_idx].date > tick.time
      end_idx += 1        
      break 

  start_idx = end_idx

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

  exchange.get_my_exchange_fee {}, (fees) -> 
    balance.maker_fee = fees.maker_fee
    balance.taker_fee = fees.taker_fee 


  dealers = get_dealers()
  $c2 = price_data.c2?[0].close or price_data.c1xc2[0].close
  $c1 = price_data.c1?[0].close or 1
  $budget_per_strategy = 100
  
  for dealer in dealers
    settings = from_cache(dealer).settings

    budget = settings.$budget or $budget_per_strategy

    if config.deposit_allocation == '50/50'
      c1_budget = budget * (1 - (settings.ratio or .5) ) / $c1
      c2_budget = budget * (settings.ratio or .5) / $c2
    else if config.deposit_allocation == 'c1'
      c1_budget = budget * .95 / $c1
      c2_budget = budget * .05 / $c2
    else if config.deposit_allocation == 'c2'
      c1_budget = budget * .05 / $c1
      c2_budget = budget * .95 / $c2


    balance[dealer] = 
      balances:
        c2: c2_budget
        c1: c1_budget
      deposits: 
        c2: c2_budget
        c1: c1_budget        
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

  t = ':perperper% :perbytrade% :etas :elapsed :ticks' 
  for k,v of t_
    t += " #{k}-:#{k}"

  bar = new progress_bar t,
    complete: '='
    incomplete: ' '
    width: 40
    renderThrottle: 500
    total: Math.ceil (time.latest - time.earliest) / (.0 * pusher.tick_interval_no_unfilled + 1.0 * pusher.tick_interval)

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
    for name in (get_all_actors() or [])
      d = from_cache name
      save d
    console.timeEnd('saving db')

    console.log "\nDone simulating! That took #{(Date.now() - started_at) / 1000} seconds" if config.log
    console.log config if config.persist
    console.log "PORT: #{bus.port}"
    callback?()

  one_tick = ->

    t = Date.now()

    has_unfilled = false 
    for dealer,positions of open_positions when positions.length > 0
      for pos in positions 
        if (pos.entry && !pos.entry.closed) || (pos.exit && ((!pos.exit.fill_to && !pos.exit.closed) || (pos.exit.fill_to && pos.exit.fill_to < pos.exit.to_fill)    ))
          has_unfilled = true 
          break 
      break if has_unfilled

    inc = if has_unfilled 
            pusher.tick_interval
          else 
            pusher.tick_interval_no_unfilled

    tick.time += inc
    start += inc
    ###########################
    # Find trades that we care about this tick. history.trades is sorted newest first
    zzz = Date.now()    
    while end_idx >= 0 
      if history.trades[end_idx].date > tick.time  || end_idx < 0 
        end_idx += 1 
        break
      end_idx -= 1

    t_.x += Date.now() - zzz
    console.assert end_idx < history.trades.length, {message: 'ending wrong!', end_idx: end_idx, trades: history.trades.length}
    history.last_trade = history.trades[end_idx]
    tick.trade_idx = end_idx
    ############################

    simulation_done = tick.time > ts - pusher.tick_interval * 10

    ######################
    #### Accounting
    dealers_with_open = (dealer for dealer,positions of open_positions when positions.length > 0)

    if dealers_with_open.length > 0 
      # check if any positions have subsequently closed
      yyy = Date.now()
      update_position_status end_idx, balance, dealers_with_open
      t_.pos_status += Date.now() - yyy

      yyy = Date.now()
      update_balance balance, dealers_with_open
      t_.balance += Date.now() - yyy
    #####################



    if !simulation_done

      ######################
      #### Main call. Where the action is. 
      #pusher.hustle balance, trades
      pusher.hustle balance
      ######################

    if simulation_done
      return end()


    ####################
    #### Efficiency measures
    # xxxx = Date.now()
    if ticks % 50000 == 1
      global.gc?()

    if ticks % 100 == 99
      purge_position_status()

    # t_.gc += Date.now() - xxxx
    ####################

    #####################
    #### Progress bar
    if config.log
      t_sec = {}
      for k,v of t_
        t_sec[k] = Math.round(v/1000)
      perperper = Math.round(100 * (tick.time - time.earliest) / (time.latest - time.earliest))
      perbytrade = Math.round(100 * (start_idx - end_idx) / start_idx )
      bar.tick 1, extend {ticks,perperper,perbytrade}, t_sec
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
  maker_fee = balance.maker_fee
  taker_fee = balance.taker_fee 

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
        for_purchase = if buy.flags?.market then buy.to_fill else buy.to_fill * buy.rate
        dbtc_on_order += for_purchase
        dbtc -= for_purchase

        if buy.fills?.length > 0           
          for fill in buy.fills
            x_fee = if fill.maker then maker_fee else taker_fee
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
            x_fee = if fill.maker then maker_fee else taker_fee
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

      console.log ''
      for pos in from_cache(dealer).positions 
        for t in [pos.entry, pos.exit] when t 
          # msg["#{pos.created}-#{t.type}"] = t
          amt = 0 
          tot = 0 
          for f,idx in (t.fills or [])
            # msg["#{pos.created}-#{t.type}-f#{idx}"] = f
            amt += f.amount 
            tot += f.total 

          # console.log
          #   type: t.type 
          #   amt: amt
          #   tot: tot 
          #   fills: (t.fills or []).length
          #   closed: t.closed

          console.log t

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
  maker_fee = balance.maker_fee
  taker_fee = balance.taker_fee

  for dealer in dealers_with_open
    open = open_positions[dealer]
    closed = []

    for pos in open 

      for trade in [pos.entry, pos.exit] when trade && !trade.closed

        ```
        key = `${pos.dealer}-${trade.created}-${trade.type}-${trade.rate}`
        ```

        status = global.position_status[key]

        if trade.to_fill > (trade.fill_to or 0) && (!status? || end_idx < status.idx + 100 )
          status = global.position_status[key] = fill_order trade, end_idx, status
          # console.log '\nFILLLLLLLL\n', key, end_idx, status?.idx, status?.fills?.length

        if status?.fills?.length > 0 
          filled = 0 

          for fill in (status.fills or [])
            if fill.date > tick.time 
              break 

            amt = fill.amount 
            rate = fill.rate

            if trade.flags?.market && trade.type == 'buy'
              to_fill = trade.to_fill - (trade.fill_to or 0)

              done = amt * rate >= to_fill
              fill.total  = if !done then amt * rate else to_fill
              fill.amount = if !done then amt        else to_fill / rate
              trade.to_fill -= fill.total 

            else 
              to_fill = trade.to_fill - (trade.fill_to or 0)
              done = fill.amount >= to_fill || trade.flags?.market
              fill.amount = if !done then amt        else to_fill 
              fill.total  = if !done then amt * rate else to_fill * rate
              trade.to_fill -= fill.amount 

            fill.type = trade.type
            fill.slippage = fill.amount * Math.abs(fill.rate - trade.original_rate) / trade.original_rate
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
          trade.closed = trade.fills[trade.fills.length - 1].date
          if trade.fill_to?
            delete trade.fill_to
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
        amount = 0
        total = 0 
        total_fees = 0 
        amount_fees = 0 

        for fill in trade.fills 
          total += fill.total 
          amount += fill.amount 

          xfee = if fill.maker then maker_fee else taker_fee

          if trade.type == 'buy' && config.exchange == 'poloniex'
            amount_fees += fill.fee or fill.amount * xfee
          else 
            total_fees += fill.fee or fill.total * xfee

        trade.total = total 
        trade.amount = amount 

        if trade.type == 'buy'

          balance.accounted_for.c2 += trade.amount 
          balance.accounted_for.c1 -= trade.total

          balance[name].accounted_for.c2 += trade.amount 
          balance[name].accounted_for.c1 -= trade.total


        else
          balance.accounted_for.c2 -= trade.amount 
          balance.accounted_for.c1 += trade.total 

          balance[name].accounted_for.c2 -= trade.amount 
          balance[name].accounted_for.c1 += trade.total 


        # original = trade.rate
        trade.rate = trade.total / trade.amount

        balance.accounted_for.c2 -= amount_fees 
        balance.accounted_for.c1 -= total_fees

        balance[name].accounted_for.c2 -= amount_fees
        balance[name].accounted_for.c1 -= total_fees




      delete pos.expected_profit

      pos.profit = (balance.accounted_for.c1 - cur_c1) / pos.exit.rate + (balance.accounted_for.c2 - cur_c2) 

      if pos.entry.type == 'sell' 
        actual_exit = pos.entry.rate / pos.exit.rate - 1
      else 
        actual_exit = pos.exit.rate / pos.entry.rate  - 1   


fill_order = (my_trade, end_idx, status) -> 

  status ||= {
    fills: []
    idx: false
    became_maker: false 
  }

  my_amount = my_trade.amount 
  my_rate = my_trade.rate
  is_sell = my_trade.type == 'sell'
  my_created = my_trade.created 
  order_placement_lag = config.order_placement_lag  
  is_market = my_trade.flags?.market

  if status.idx
    start_at = status.idx
  else 
    start_at = end_idx

  to_fill = my_trade.to_fill - (my_trade.fill_to or 0)

  console.assert to_fill > 0 

  status.fills ||= []
  fills = status.fills 

  init = false

  for idx in [start_at..0] by -1
    trade = history.trades[idx]

    if !init
      if trade.date < my_created + order_placement_lag
        continue
      else 
        init = true 

    if !status.became_maker
      status.became_maker = trade.date - (my_created + order_placement_lag) > 1 * 60 || (is_sell && trade.rate <= my_rate) || (!is_sell && trade.rate >= my_rate)
        

    if (!is_sell && trade.rate <= my_rate) || \
       ( is_sell && trade.rate >= my_rate) || is_market

      if is_market
        if (is_sell && trade.rate < my_rate) || (!is_sell && trade.rate > my_rate)
          rate = trade.rate 
        else 
          rate = my_rate 
      else 
        rate = my_rate 

      fill = 
        date: trade.date 
        rate: rate
        amount: trade.amount
        maker: status.became_maker && !is_market 

      fills.push fill

      if ((!is_market ||  is_sell) && trade.amount >= to_fill) || \
         ( (is_market && !is_sell) && trade.total  >= to_fill)
        status.idx = idx
        return status
      else 
        if is_market && !is_sell
          to_fill -= fill.amount * fill.rate
        else 
          to_fill -= fill.amount


    if !is_market && (!history.trades[end_idx] || trade.date > history.trades[end_idx].date + 30 * 60)
      status.idx = idx 
      return status



store_analysis = ->
  balance = from_cache 'balance'
  # analysis of positions
  fs = require('fs')
  if !fs.existsSync 'analyze'
    fs.mkdirSync 'analyze'  

  dir = "analyze/#{config.end - config.length}-#{config.end}"

  if !fs.existsSync dir  
    fs.mkdirSync dir  

  dealer_names = get_dealers()
  sample = null
  sample_dealer = null
  for name in dealer_names
    for pos in (from_cache(name).positions or [])
      sample = dealers[name].analyze pos, balance.maker_fee
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
      row = dealer.analyze(pos, balance.maker_fee)
      continue if !row
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

  KPI (all_stats) -> 

    row = [config.name, config.c1, config.c2, config.exchange, config.end - config.length, config.end]

    for measure, calc of dealer_measures(all_stats)
      row.push calc('all')

    console.log '\x1b[36m%s\x1b[0m', "#{row[0]} made #{row[10]} profit on #{row[11]} completed trades at #{row[6]} CAGR"

    if config.log_results

      fs = require('fs')
      if !fs.existsSync('logs') 
        fs.mkdirSync 'logs'  

      fname = "logs/#{config.log_results}.txt"

      if !fs.existsSync(fname)
        cols = ['Name', 'Currency1', 'Currency2', 'Exchange', 'Start', 'End']

        for measure, __ of dealer_measures(all_stats)
          cols.push measure
      else 
        cols = []

      rows = [cols]


      rows.push row

      out = fs.openSync fname, 'a'
      fs.writeSync out, (r.join('\t') for r in rows).join('\n')
      fs.closeSync out


reset = -> 
  global.config = {}

  KPI.initialized = false


  global.open_positions = {}

  history.trades = []

  pusher.init
    history: history 
    clear_all_positions: true 



lab = module.exports = 

  experiment: (conf, callback) -> 


    global.config = {}

    global.config = defaults global.config, conf, 
      key: 'config'
      exchange: 'poloniex'
      simulation: true
      eval_entry_every_n_seconds: 60
      eval_exit_every_n_seconds: 60
      eval_unfilled_every_n_seconds: 60
      length: 12 * 24 * 60 * 60
      c1: 'BTC'
      c2: 'ETH'
      accounting_currency: 'USDT'
      order_placement_lag: 1
      log: true
      enforce_balance: true
      persist: false
      analyze: false
      produce_heapdump: false
      offline: false
      auto_shorten_time: true
      deposit_allocation: '50/50'


    save config 

    # set globals
    global.position_status = {}

    ts = config.end or now()


    # history.load_chart_history "c1xc2", config.c1, config.c2, ts - 20 * 365 * 24 * 60 * 60, ts, -> 
    #   console.log 'use me to get earliest trade for pair', config.c1, config.c2
    #   process.exit()
    # return


    pusher.init
      history: history 
      clear_all_positions: true 

    console.assert !isNaN(history.longest_requested_history), 
      message: 'Longest requested history is NaN. Perhaps you haven\'t registered any dealers'

    # console.log 'longest requested history:', history.longest_requested_history
    history_width = history.longest_requested_history + config.length + 24 * 60 * 60

    earliest_trade_for_pair = exchange.get_earliest_trade {only_high_volume: config.only_high_volume, exchange: config.exchange, c1: config.c1, c2: config.c2, accounting_currency: config.accounting_currency}

    if ts > earliest_trade_for_pair
      if config.auto_shorten_time && ts - history_width < earliest_trade_for_pair
        shrink_by = earliest_trade_for_pair - (ts - history_width) + 24 * 60 * 60
        config.length -= shrink_by
        history_width = history.longest_requested_history + config.length + 24 * 60 * 60
        console.log "Shortened simulation", {shrink_by, end: ts, start: ts - history_width, history_width, earliest_trade_for_pair}


      if ts - history_width >= earliest_trade_for_pair        
        console.log "Running #{Object.keys(dealers).length} dealers" if config.log

        history.load_price_data ts - history_width, ts, ->
          console.log "...loading #{ (history_width / 60 / 60 / 24).toFixed(2) } days of trade history, relative to #{ts}" if config.log
          history.load ts - history_width, ts, -> 
            console.log "...experimenting!" if config.log
            simulate ts, callback
      else 
        console.log "Can't experiment during that time. The currency pair wasn't trading before the start date."
        callback()
    else 
      console.log "Can't experiment during that time. The currency pair wasn't trading before the end date."
      callback()

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
        backups: false

    global.save = bus.save 
    global.fetch = (key) ->
      bus.fetch deslash key 

    global.del = bus.del 

    if !no_client
      require 'coffee-script'
      require './shared'
      express = require('express')

      bus.http.use('/node_modules', express.static('node_modules'))
      bus.http.use('/node_modules', express.static('meth/node_modules'))
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

        console.log r.url


        prefix = ''
        server = "statei://localhost:#{bus.port}"

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


      bus.http.use('/node_modules', express.static('node_modules'))


