require './shared'
exchange = require './exchange'
progress_bar = require('progress')
fs = require('fs')



module.exports = history = 
  trades: []


  load_price_data: (start, end, callback, callback_empty) -> 
    granularity = config.price_data_granularity or 86400

    fs.mkdirSync "price_data/" if !fs.existsSync("price_data/") 
    fs.mkdirSync "price_data/#{config.exchange}" if !fs.existsSync("price_data/#{config.exchange}")

    proceed = true 
    cb_empty = (interval) -> 
      if callback_empty
        callback_empty(interval)
        proceed = false

    done = => 
      # now we're going to verify the integrity of the price data
      price_data = fetch 'price_data'

      patch = (idx, pair, min_date) -> 
        console.log "Patching #{pair} candle at index #{idx} of #{price_data[pair].length}" if config.log_level > 0

        copy_from_idx = if idx == 0 then 0 else idx - 1
        cpy = bus.clone(price_data[pair][copy_from_idx])
        if idx == 0
          cpy.date = min_date
        else 
          cpy.date += granularity
        price_data[pair].splice idx, 0, cpy 

      # first we'll look to see if there are the same number of candles for each currency pair
      if price_data.c1 && price_data.c2
        console.assert config.accounting_currency != config.c1 

        equal_lengths = -> 
          lengths = {}
          for k,v of price_data when k != 'key' && k != 'granularity'
            lengths[k] = v.length 

          equal = true
          for k,length of lengths 
            equal &= length == lengths.c1xc2
          equal

        if !equal_lengths()
          console.log "Price data needs patching" if config.log_level > 0

          if config.disable_price_patching
            console.log "retrying" if config.log_level > 0
            setTimeout load_history, 1000
            return
          else 

            i = 0 
            cnt = 0 
            while true
              c1_date = price_data.c1[i]?.date
              c2_date = price_data.c2[i]?.date 
              cx_date = price_data.c1xc2[i]?.date

              break if !c1_date && !c2_date && !cx_date

              patch_needed = !(c1_date == c2_date == cx_date)

              if i == 0 && patch_needed
                console.error "price data uneven at start. forward patching." if config.log_level > 0

              if c1_date > Math.min(c2_date, cx_date)
                patch i, 'c1', Math.min(c2_date, cx_date)
              if c2_date > Math.min(c1_date, cx_date)
                patch i, 'c2', Math.min(c1_date, cx_date)
              if cx_date > Math.min(c1_date, c2_date)
                patch i, 'c1xc2', Math.min(c1_date, c2_date)
            
              if !patch_needed            
                i += 1

              break if cnt > price_data.c1.length + price_data.c2.length + price_data.c1xc2.length # there is a bug where infinite loop possible
              cnt += 1

            console.error equal_lengths(), 
              msg: "patching price data failed"
              c1_len: price_data.c1?.length
              c2_len: price_data.c2?.length
              c1xc2_len: price_data.c1xc2?.length
              # price_data: price_data

      # second we'll look to see if the candles are equally spaced by the desired granularity
      for pair, data of price_data when pair != 'key' && pair != 'granularity'
        for candle, idx in data 
          continue if idx == 0

          console.assert candle.date != data[idx - 1].date, {
            idx, cur: candle, prev: data[idx-1], cur2: data[idx]
          }
          

          if candle.date != data[idx - 1].date + granularity 
            console.log "#{pair} has a missing candle at #{idx}" if config.log_level > 0
            if config.disable_price_patching
              console.log "retrying" if config.log_level > 0
              setTimeout load_history, 1000
              return
            # else 
            #   patch idx, pair 

      callback()

    load_history = => 
      @load_chart_history "c1xc2", config.c1, config.c2, start, end, => 
        return if !proceed
        if config.accounting_currency not in [config.c1, config.c2]
          @load_chart_history "c1", config.accounting_currency, config.c1, start, end, => 
            return if !proceed
            @load_chart_history "c2", config.accounting_currency, config.c2, start, end, done, if callback_empty then cb_empty
          , if callback_empty then cb_empty
        else 
          done()

      , if callback_empty then cb_empty

    load_history()

  load_chart_history: (name, c1, c2, start, end, cb, callback_empty) -> 
    console.assert c1 != c2, {message: 'why you loading price history for the same coin traded off itself?', c1: c1, c2: c2}

    price_data = fetch('price_data')

    granularity = config.price_data_granularity or 86400

    fname = "price_data/#{config.exchange}/#{c1}-#{c2}-#{start}-#{end}-#{granularity}"

    attempts = 0 
    store_chart = (price_history) ->
      price_data[name] = price_history
      price_data.granularity = granularity
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
            granularity: granularity 
          , data_callback

        data_callback = (price_history) =>
          price_history ||= []  
          try   
            price_history.sort (a,b) -> a.date - b.date
          catch err
            console.assert false, {err, price_history}

          error = price_history.length == 0 || price_history[0].date > start || price_history[price_history.length - 1].date + granularity < end

          if error 
            console.log "#{config.exchange} returned bad price history for #{c1}-#{c2}." if config.log_level > 0
            if price_history && price_history.length > 0 && price_history[0].date > 0 && price_history[price_history.length - 1].date > 0 
              
              if config.log_level > 1
                console.log 
                  first: price_history[0].date
                  target_start: start 
                  last: price_history[price_history.length - 1].date + granularity
                  target_end: end 
                  first_entry: price_history[0]
                  last_entry: price_history[price_history.length - 1]

              if callback_empty?
                callback_empty({start: price_history[0].date, end: price_history[price_history.length - 1].date + granularity})
                cb()
                console.log 'not retrying.' if config.log_level > 0
                return

            else if callback_empty?
              callback_empty()
              cb()
              console.log 'not retrying.' if config.log_level > 0
              return

            console.log "Trying again." if config.log_level > 0
            attempts += 1
            setTimeout load_chart, attempts * 100

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

    first_hour = Math.floor start / 60 / 60
    last_hour = Math.ceil end / 60 / 60

    if config.log_level > 0
      bar = new progress_bar '  loading history [:bar] :percent :etas :elapsed',
        complete: '='
        incomplete: ' '
        width: 40
        total: last_hour - first_hour 

    to_run = []
    for hour in [first_hour..last_hour]
      func = @load_hour hour, end
      if func && !config.history_loaded
        to_run.push func 
      else 
        bar.tick() if config.log_level > 0


    is_done = =>
      bar.tick() if config.log_level > 0
      if to_run.length == 0

        @trades.sort (a,b) -> b.date - a.date
        console.log "Done loading history! #{@trades.length} trades." if config.log_level > 0

        # duplicate detection
        if false 
          p = null 
          for t in @trades 
            if p && p.date == t.date && p.rate == t.rate && t.amount == p.amount && t.total == p.total && t.tradeID == p.tradeID
              console.log "DUPLICATES: ", p, t 
            p = t

        if false # save all trades onto statebus for visualization. usually too big!
          x = 
            key: 'all_trades'
            trades: @trades
          bus.save x


        complete()

      else 
        setImmediate ->
          f = to_run.pop()
          f is_done 

    is_done()

  set_longest_requested_history: (max_length) -> 
    # at least 10 minute frames, otherwise 
    # problems caused by not having enough trades
    @longest_requested_history = Math.max max_length, 0 #10 * 60

  latest: -> @trades[@trades.length - 1]

  # remove trades from history that will never be used by any strategy
  prune: (start_idx) ->
    console.assert @longest_requested_history, {message: 'requested history not set'}

    history_width = @longest_requested_history

    start_idx ||= 0 

    previous_len = @trades.length

    for idx in [start_idx..@trades.length - 1]
      if tick.time - @trades[idx].date > history_width
        @trades = @trades.slice 0, idx
        break

    previous_len - @trades.length

  disconnect_from_exchange_feed: ->
    if @ws_trades 
      @ws_trades.destroy()
      @ws_trades = null 

  subscribe_to_exchange_feed: (callback) ->
    return callback?() if config.disabled

    @disconnect_from_exchange_feed()

    exchange.subscribe_to_exchange_feed 
      new_trade_callback: (new_trade) => 
        @last_trade = @process_new_trade new_trade, true
    , (conn) => 
      @ws_trades = conn
      callback?()


  load_from_file: (fname, hour, end) -> 
    from_file = fs.readFileSync(fname, 'utf8')
    trades = JSON.parse from_file

    for trade in trades when trade.date <= end
      @trades.push trade

  load_hour: (hour, end) -> 
    fname = "trade_history/#{config.exchange}/#{config.c1}_#{config.c2}/#{hour}"

    if fs.existsSync fname
      @load_from_file fname, hour, end 
      return null 
    else
      if !config.offline
        f = (complete) => 
          if fs.existsSync fname 
            @load_from_file fname, hour, end 
            complete()
          else 
            exchange.get_trade_history
              c1: config.c1
              c2: config.c2
              start: hour * 60 * 60
              end: (hour + 1) * 60 * 60 - 1
            , (trades) => 

              console.assert trades, {message: "ABORT: #{config.exchange} returned empty trade history"}

              for trade in trades 
                @process_new_trade trade 

              if hour + 1 <= now() / 60 / 60 && !fs.existsSync(fname) # && trades.length > 0
                fs.writeFileSync fname, JSON.stringify(trades), 'utf8'

              #console.log "...loaded hour #{hour} with #{trades.length} trades from #{config.exchange}. Saved to #{fname}"
              complete()
        return f
      


  process_new_trade: (trade, preserve_sort) ->
    
    trade.rate   = parseFloat trade.rate
    trade.amount = parseFloat trade.amount 
    trade.total  = parseFloat trade.total

    if preserve_sort
      @trades.unshift trade 
    else 
      @trades.push trade # much much much faster

    if preserve_sort
      lag_logger?(now() - trade.date)

    trade






