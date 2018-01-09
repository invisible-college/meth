require './shared'
exchange = require './exchange'
progress_bar = require('progress')
fs = require('fs')



module.exports = history = 
  trades: []


  load_price_data: (start, end, callback, callback_empty) -> 
    period = config.price_data_granularity or 86400

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

      patch = (idx, pair) -> 
        console.log "Patching #{pair} candle at index #{idx} of #{price_data[pair].length}" 
        cpy = bus.clone(price_data[pair][idx - 1])
        cpy.date += period
        price_data[pair].splice idx, 0, cpy 

      # first we'll look to see if there are the same number of candles for each currency pair
      if price_data.c1 && price_data.c2
        console.assert config.accounting_currency != config.c1 
        
        equal_lengths = -> 
          lengths = {}
          for k,v of price_data when k != 'key' 
            lengths[k] = v.length 

          equal_lengths = true
          for k,length of lengths 
            equal_lengths &= length == lengths.c1xc2
          equal_lengths

        if !equal_lengths()
          console.log "Price data needs patching"

          if config.disable_price_patching
            console.log "retrying"
            setTimeout load_history, 1000
            return
          else 

            i = 0 
            while true
              c1_date = price_data.c1[i]?.date
              c2_date = price_data.c2[i]?.date 
              cx_date = price_data.c1xc2[i]?.date

              break if !c1_date && !c2_date && !cx_date

              patch_needed = !(c1_date == c2_date == cx_date)
              if i == 0 && patch_needed
                console.log "price data unworkable, trying again", 
                  {c1_date, c2_date, cx_date}
                setTimeout => 
                  @load_price_data start, end, callback, callback_empty
                , 1000
                return

              if c1_date > Math.min(c2_date, cx_date)
                patch i, 'c1'    
              if c2_date > Math.min(c1_date, cx_date)
                patch i, 'c2'    
              if cx_date > Math.min(c1_date, c2_date)
                patch i, 'c1xc2' 
                  
              if !patch_needed            
                i += 1

            console.assert equal_lengths(), msg: "patching failed"

      # second we'll look to see if the candles are equally spaced by the desired granularity
      for pair, data of price_data when pair != 'key'
        for candle, idx in data when idx > 0
          if candle.date != data[idx - 1].date + period 
            console.log "#{pair} has a missing candle at #{idx}"
            if config.disable_price_patching
              console.log "retrying"
              setTimeout load_history, 1000
              return
            else 
              patch idx, pair 

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

    period = config.price_data_granularity or 86400

    fname = "price_data/#{config.exchange}/#{c1}-#{c2}-#{start}-#{end}-#{period}"

    attempts = 0 
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

        data_callback = (price_history) =>
          price_history ||= []  
          try   
            price_history.sort (a,b) -> a.date - b.date
          catch err
            console.assert false, {err, price_history}

          error = price_history.length == 0 || price_history[0].date > start || price_history[price_history.length - 1].date + period < end

          if error 
            console.log "#{config.exchange} returned bad price history for #{c1}-#{c2}."
            if price_history && price_history.length > 0 && price_history[0].date > 0 && price_history[price_history.length - 1].date > 0 
              console.log 
                first: price_history[0].date
                target_start: start 
                last: price_history[price_history.length - 1].date + period
                target_end: end 
                first_entry: price_history[0]
                last_entry: price_history[price_history.length - 1]

              if callback_empty?
                callback_empty({start: price_history[0].date, end: price_history[price_history.length - 1].date + period})
                cb()
                console.log 'not retrying.'
                return

            else if callback_empty?
              callback_empty()
              cb()
              console.log 'not retrying.'
              return

            console.log "Trying again."
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

    load_hours = => 
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
        func = @load_hour hour, end
        if func && !config.history_loaded
          to_run.push func 
        else 
          bar.tick() if config.log


      is_done = =>
        bar.tick() if config.log
        if to_run.length == 0

          @trades.sort (a,b) -> b.date - a.date

          console.log "Done loading history! #{@trades.length} trades." if config.log
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


  subscribe_to_trade_history: (callback) ->

    exchange.subscribe_to_trade_history 
      new_trade_callback: (new_trade) => 
        @process_new_trade new_trade, true
    , callback


  load_hour: (hour, end) -> 
    fname = "trade_history/#{config.exchange}/#{config.c1}_#{config.c2}/#{hour}"

    if fs.existsSync fname

      from_file = fs.readFileSync(fname, 'utf8')
      trades = JSON.parse from_file

      for trade in trades when trade.date <= end
        @trades.push trade

      # console.log "...loaded hour #{hour} via file"
      return null 

    else
      if !config.offline
        f = (complete) => 

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
      else 
        return null 
      


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






