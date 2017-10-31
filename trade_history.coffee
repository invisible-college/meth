require './shared'
exchange = require './exchange'
progress_bar = require('progress')
fs = require('fs')

module.exports = history = 
  trades: []


  load_price_data: (start, end, callback) -> 
    fs.mkdirSync "price_data/" if !fs.existsSync("price_data/") 
    fs.mkdirSync "price_data/#{config.exchange}" if !fs.existsSync("price_data/#{config.exchange}")

    done = -> 
      length = null
      k1 = null
      price_data = fetch('price_data')
      for k,v of price_data when k != 'key' 
        if length == null 
          length = v.length 
          k1 = k 
        else
          if v.length != length
            console.log k1, new Date(price_data[k1][0].date * 1000).toISOString(), new Date(price_data[k1][price_data[k1].length - 1].date * 1000).toISOString()
            console.log k, new Date(price_data[k][0].date * 1000).toISOString(), new Date(price_data[k][price_data[k].length - 1].date * 1000).toISOString()
            console.log {message: "Price data of different length!", c1: config.c1, c2: config.c2, accounting: config.accounting_currency, key1: k1, key2: k, len1: length, len2: v.length}

            setTimeout load_history, 1000
            return

      callback()

    load_history = -> 
      history.load_chart_history "c1xc2", config.c1, config.c2, start, end, -> 
        if config.accounting_currency not in [config.c1, config.c2]
          history.load_chart_history "c1", config.accounting_currency, config.c1, start, end, -> 
            history.load_chart_history "c2", config.accounting_currency, config.c2, start, end, done
        else 
          done()

    load_history()

  load_chart_history: (name, c1, c2, start, end, cb) -> 
    console.assert c1 != c2, {message: 'why you loading price history for the same coin traded off itself?', c1: c1, c2: c2}

    period = 86400
    price_data = fetch('price_data')

    fname = "price_data/#{config.exchange}/#{c1}-#{c2}-#{start}-#{end}-#{period}"

    store_chart = (price_history) ->
      price_data[name] = price_history
      bus.save price_data
      cb()

    if fs.existsSync fname
      fs.accessSync fname
      from_file = fs.readFileSync(fname, 'utf8')
      store_chart JSON.parse from_file
    else
      if !config.offline

        load_chart = -> 
          exchange.get_chart_data
            start: start 
            end: end 
            c1: c1 
            c2: c2
            period: period 
          , data_callback

        data_callback = (price_history) ->
          price_history ||= []          
          price_history.sort (a,b) -> a.date - b.date

          error = price_history.length == 0 || price_history[0].date > start || price_history[price_history.length - 1].date + period < end

          if error 
            console.log "#{config.exchange} returned bad price history for #{c1}-#{c2}."
            if price_history && price_history.length > 0 
              console.log 
                first: price_history[0].date
                target_start: start 
                last: price_history[price_history.length - 1].date + period
                target_end: end 

            else 
              console.log price_history 
            console.log "Trying again."
            load_chart()

          else 
            if !fs.existsSync fname 
              fs.writeFileSync fname, JSON.stringify(price_history), 'utf8' 
            store_chart(price_history)

        load_chart()

      else 
        cb()

  load: (start, end, complete) -> 
    @trades = []

    if !fs.existsSync('trade_history')
      fs.mkdirSync "trade_history"  

    if !fs.existsSync("trade_history/#{config.exchange}")
      fs.mkdirSync "trade_history/#{config.exchange}"  

    if !fs.existsSync("trade_history/#{config.exchange}/#{config.c1}_#{config.c2}")  
      fs.mkdirSync "trade_history/#{config.exchange}/#{config.c1}_#{config.c2}"  

    load_hours = -> 
      first_hour = Math.floor start / 60 / 60
      last_hour = Math.ceil end / 60 / 60

      if config.log
        bar = new progress_bar '  loading history [:bar] :percent :etas :elapsed',
          complete: '='
          incomplete: ' '
          width: 40
          total: last_hour - first_hour 

      to_run = []
      for hour in [first_hour..last_hour]
        func = load_hour hour, end
        if func && !config.history_loaded
          to_run.push func 
        else 
          bar.tick() if config.log


      is_done = ->
        bar.tick() if config.log
        if to_run.length == 0

          # history_hash = {}
          # for trade in history.trades 
          #   key = trade.date
          #   history_hash[key] ||= []
          #   history_hash[key].push trade 

          history.trades.sort (a,b) -> b.date - a.date

          console.log "Done loading history! #{history.trades.length} trades." if config.log
          complete()

        else 
          setImmediate ->
            f = to_run.pop()
            f is_done 

      is_done()

    if !config.offline
      exchange.download_all_trade_history {c1: config.c1, c2: config.c2, stop_when_cached: true}, load_hours
    else 
      load_hours()

  set_longest_requested_history: (dealers) -> 
    hist_lengths = []
    for key in get_all_actors() 
      dealer_data = from_cache(key)

      hist_length = (dealer_data.frames + (dealer_data.max_t2 or 0) + 1) * dealer_data.settings.frame_width

      console.assert hist_length && !isNaN(hist_length), 
        message: 'requested history for dealer is bad!'
        hist_length: hist_length
        dealer: key
        frames: dealer_data.frames
        max_t2: dealer_data.max_t2 or 0
        frame_width: dealer_data.settings.frame_width
      hist_lengths.push hist_length

    hist_lengths.push 10 * 60 # at least 10 minute frames, otherwise 
                              # problems caused by not having enough trades

    @longest_requested_history = Math.max.apply null, hist_lengths

  latest: -> @trades[@trades.length - 1]

  # remove trades from history that will never be used by any strategy
  prune: (start_idx) ->
    console.assert @longest_requested_history, {message: 'requested history not set'}

    history_width = @longest_requested_history

    start_idx ||= 0 

    previous_len = history.trades.length

    for idx in [start_idx..history.trades.length - 1]
      if tick.time - history.trades[idx].date > history_width
        history.trades = history.trades.slice 0, idx
        break

    previous_len - history.trades.length


  subscribe_to_trade_history: (callback) -> 
    exchange.subscribe_to_trade_history 
      new_trade_callback: (new_trade) -> 
        process_new_trade new_trade, true
    , callback


hours_loading = 0
# dups = 0
load_hour = (hour, end) -> 
  fname = "trade_history/#{config.exchange}/#{config.c1}_#{config.c2}/#{hour}"

  try 
    fs.accessSync fname

    from_file = fs.readFileSync(fname, 'utf8')
    trades = JSON.parse from_file

    for trade in trades when trade.date <= end
      history.trades.push trade

    # history_hash = {}
    # for trade in trades when trade.date <= end
    #   key = JSON.stringify(trade)
    #   history_hash[key] ||= []
    #   history_hash[key].push trade
    # dates = []
    # for k,v of history_hash
    #   if v.length > 1 
    #     dups += v.length
    #     dates.push trade.date

    # console.log "...loaded hour #{hour} via file"
    return null 

  catch e  
    if !config.offline
      f = (complete) -> 

        exchange.get_trade_history
          c1: config.c1
          c2: config.c2
          start: hour * 60 * 60
          end: (hour + 1) * 60 * 60 - 1
        , (trades) -> 

          console.assert trades, {message: "ABORT: #{config.exchange} returned empty trade history"}

          for trade in trades 
            process_new_trade trade 

          if hour + 1 <= now() / 60 / 60 && trades.length > 0 && !fs.existsSync(fname)
            fs.writeFileSync fname, JSON.stringify(trades), 'utf8'

          #console.log "...loaded hour #{hour} with #{trades.length} trades from #{config.exchange}. Saved to #{fname}"
          complete()
      return f
    else 
      return null 
    


process_new_trade = (trade, preserve_sort) ->
  
  delete trade.globalTradeID if trade.globalTradeID
  delete trade.tradeID if trade.tradeID
  delete trade.type if trade.type

  trade.rate   = parseFloat trade.rate
  trade.amount = parseFloat trade.amount 
  trade.total  = parseFloat trade.total

  trade.date = Date.parse(trade.date + " +0000") / 1000

  if preserve_sort
    history.trades.unshift trade 
  else 
    history.trades.push trade # much much much faster

  if preserve_sort
    lag_logger?(now() - trade.date)

  trade





