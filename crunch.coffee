
if !module?
  module = {}

deposits = 
  all: 
    c1: 0
    c2: 0

cached_positions = {}
indicator_cache = {}

add_to_cache = (dealer_or_dealers, name) -> 
  balances = from_cache '/balances'

  if !Array.isArray(dealer_or_dealers)
    name = dealer_or_dealers
    cached_positions[name] = fetch(name).positions

    deposits[name] = 
      c1: balances[deslash(name)]?.deposits.c1 or 0
      c2: balances[deslash(name)]?.deposits.c2 or 0

  else 
    # console.time(name)
    dealers = dealer_or_dealers

    deposits[name] = 
      c1: 0
      c2: 0 

    positions = []

    for dealer in dealers 
      if !(dealer of cached_positions)
        add_to_cache(dealer)

      deposits[name].c1 += deposits[dealer].c1 
      deposits[name].c2 += deposits[dealer].c2 

      positions.push cached_positions[dealer]

    cached_positions[name] = [].concat positions...   #cached_positions[name].concat cached_positions[dealer]
    # console.timeEnd(name)

compute_KPI = (dealer_or_dealers, name) ->

  if name && bus?.cache.stats?[name] && config?.simulation
    return bus.cache.stats[name]

  price_data = from_cache '/price_data' 
  balances = from_cache '/balances'
  if !config?
    config = from_cache '/config'

    
  if Array.isArray(dealer_or_dealers)
    dealers = dealer_or_dealers
    console.assert name, {message: 'KPI group of dealers must be named'}

    if !cached_positions[name] || !deposits[name]
      add_to_cache dealer_or_dealers, name 

  else 
    name ?= dealer_or_dealers
    dealers = [dealer_or_dealers]
    if !cached_positions[name] || !deposits[name]
      add_to_cache name 

  positions = cached_positions[name]

  if name && bus?.cache.stats?[name] && config?.simulation
    return bus.cache.stats[name]


  # console.time(name)
  ts = KPI.ts
  period_length = KPI.period_length
  dates = KPI.dates

  more_than_day = 0
  more_than_hour = 0 
  open = 0 
  completed = 0 
  reset = 0 
  gains = 0 


  slippage = 0 
  slip_tracked = 0 
  all_slippage = []
  slippage2 = []
  for p in positions
    more_than_day  += 1 if (!p.closed && ts - p.created > 24 * 60 * 60) || ( p.closed && p.closed - p.created > 24 * 60 * 60)
    more_than_hour += 1 if (!p.closed && ts - p.created > 60 * 60) || ( p.closed && p.closed - p.created > 60 * 60)
     
    reset += 1 if p.reset 
    if !p.closed 
      open += 1 
    else 
      completed += 1

    gains += 1 if p.closed && (p.profit or p.expected_profit) > 0

    for trade in [p.entry, p.exit] when trade?.original_rate?
      original_rate = trade.original_rate
      slipped = Math.abs(original_rate - trade.rate) / original_rate

      if trade.flags?.order_method == 1        
        slippage += slipped

        slipped_amt = 0
        for fill in (trade.fills or [])
          slipped_amt += fill.slippage

        all_slippage.push 
          resets: trade.orders?.length or trade.resets
          slipped: slipped
          order_depth: trade.info 
          type: trade.type
          amt: trade.amount
          slipped_amt: slipped_amt
        slip_tracked += 1

      else if trade.flags?.order_method == 0     
        slippage2.push
          resets: trade.orders?.length or trade.resets
          slipped: slipped
          order_depth: trade.info 
          type: trade.type
          amt: trade.amount



  stats = 
    dealers: dealer_or_dealers
    more_than_day: more_than_day / (positions.length or 1)
    more_than_hour: more_than_hour / (positions.length or 1)
    slippage: 
      avg: if slip_tracked > 0 then slippage / slip_tracked else 0 
      all: all_slippage
      all2: slippage2
    status:
      open: open
      completed: completed
      reset: reset
      gains: gains

  fills = (pos.entry.fills for pos in positions when pos.entry?.fills?.length > 0)
  fills = fills.concat (pos.exit.fills for pos in positions when pos.exit?.fills?.length > 0)
  fills = [].concat fills... # flatten
  
  fills.sort (a,b) -> b.date - a.date 

  positions_by_closed = (p for p in positions when p.closed)
  positions_by_closed.sort (a,b) -> b.closed - a.closed
  positions_by_created = positions_by_closed.slice() #positions.slice()
  positions_by_created.sort (a,b) -> b.created - a.created
  active_positions = []
  
  taker_fee = balances.taker_fee
  maker_fee = balances.maker_fee

  baseline = deposits[name]
  cur_balance = 
    c2: deposits[name].c2
    c1: deposits[name].c1
  prev_balance = 
    c2: deposits[name].c2
    c1: deposits[name].c1

  profits_from_trades = 0

  series = 
    profit_index: []
    unit_profits: []
    fees: []
    volume: [] 
    fee_rate: []    
    c1_fees: []
    c2_fees: [] 
    trade_profit: []
    trade_profit_difference: []
    ratio_compared_to_deposit: []
    returns: []

    open: []
    start: dates[0] / 1000
    end: dates[dates.length - 1] / 1000

  start_idx = price_data.c1xc2.length - dates.length
  for period,idx in dates

    last_period = start_idx + idx
    $c1 = $c2 = BTC_2_ETH = null
    while !$c1 || !$c2 || !BTC_2_ETH
      if config.c1 == config.accounting_currency
        $c1 = 1 
        
        if !$c2 
          $c2 = price_data.c1xc2[last_period]?.close

      else 
        if !$c1
          $c1 = price_data.c1[last_period]?.close
        if !$c2
          $c2 = price_data.c2[last_period]?.close 

      if !BTC_2_ETH
        BTC_2_ETH = price_data.c1xc2[last_period].close 
      
      last_period -= 1


    # trade-level metrics
    c2_fees = c1_fees = volume = 0 

    while true 

      break if fills.length == 0 || fills[fills.length - 1].date > period / 1000 + period_length

      fill = fills.pop()
      xfee = if fill.maker then maker_fee else taker_fee
      volume += fill.amount 

      # console.log 'TRADE AMOUNT', trade.amount, trade.type
      if fill.type == 'buy'
        cur_balance.c1 -= fill.total
        cur_balance.c2 += fill.amount

        if config.exchange == 'poloniex'
          fee = if fill.fee? then fill.fee else fill.amount * xfee
          c2_fees += fee
          cur_balance.c2 -= fee
        else 
          fee = if fill.fee? then fill.fee else fill.total * xfee
          c1_fees += fee
          cur_balance.c1 -= fee

      else 
        cur_balance.c1 += fill.total
        cur_balance.c2 -= fill.amount
        fee = if fill.fee? then fill.fee else fill.total * xfee 
        c1_fees += fee
        cur_balance.c1 -= fee


    if (cur_balance.c2 < 0 || cur_balance.c1 < 0) && config.simulation 
      console.error 'negative balance!', cur_balance, name
      console.log config.c1, config.c2 #, fill, 
      process.exit()
    

    # position-level metrics
    while true 
      break if positions_by_closed.length == 0 || positions_by_closed[positions_by_closed.length - 1].closed > period / 1000 + period_length

      pos = positions_by_closed.pop()

      profits_from_trades += (pos.profit or pos.expected_profit)

    added_active = false 
    while true 
      break if positions_by_created.length == 0 || positions_by_created[positions_by_created.length - 1].created > period / 1000 + period_length
      active_positions.push positions_by_created.pop() 
      added_active = true 

    if added_active && active_positions.length > 1
      active_positions.sort (a,b) -> b.closed - a.closed

    while true 
      break if active_positions.length == 0 || active_positions[active_positions.length - 1].closed > period / 1000 + period_length
      active_positions.pop()


    series.trade_profit.push [period / 1000, profits_from_trades]

    trade_profit_difference = if idx == 0 then 0 else profits_from_trades - series.trade_profit[idx - 1][1]
    series.trade_profit_difference.push [period / 1000, trade_profit_difference]

    baseline_adjustment = $c2 * baseline.c2 + $c1 * baseline.c1

    profit = $c2 * cur_balance.c2 + $c1 * cur_balance.c1 - baseline_adjustment
    series.profit_index.push [period / 1000, profit]

    baseline_adjustment = baseline.c2 + baseline.c1 / BTC_2_ETH
    unit_profits = cur_balance.c2 + cur_balance.c1 / BTC_2_ETH - baseline_adjustment
    series.unit_profits.push [period / 1000, unit_profits]

    prev_volume = if idx == 0 then 0 else series.volume[idx - 1][1]
    series.volume.push [period / 1000, volume + prev_volume]

    previous_c1 = if idx == 0 then 0 else series.c1_fees[idx - 1][1]
    previous_c2 = if idx == 0 then 0 else series.c2_fees[idx - 1][1]
    fees = (c2_fees + previous_c2) + (c1_fees + previous_c1) / BTC_2_ETH

    series.fees.push [period / 1000, fees]
    series.c1_fees.push [period / 1000, c1_fees + previous_c1]
    series.c2_fees.push [period / 1000, c2_fees + previous_c2]

    series.fee_rate.push [period / 1000, series.fees[series.fees.length - 1][1] / series.volume[series.volume.length - 1][1]]
    
    # difference = if idx == 0 then 0 else profit - series.profit_index[idx - 1][1]
    # series.difference.push [period / 1000, difference]

    # use this for strategies that never exit
    # val = $c2 * cur_balance.c2 + $c1 * cur_balance.c1
    # prev_val = prev_balance.c2 * $c2 + prev_balance.c1 * $c1
    # # console.assert prev_val >= 0, message: 'previous value is not greater than 0!', prev_balance: prev_balance
    # ret = 100 * (val - prev_val) / baseline_adjustment
    # series.returns.push [period / 1000,ret]

    baseline_val_in_ETH = baseline.c2 + baseline.c1 / BTC_2_ETH 

    ret = trade_profit_difference / baseline_val_in_ETH
    series.returns.push         [period / 1000, 100 * ret ]

    


    original_ratio = baseline.c2 / (baseline.c1 + baseline.c2)
    cur_ratio = cur_balance.c2 / (cur_balance.c1 + cur_balance.c2)

    ratio_cp_deposit = cur_ratio - original_ratio
    series.ratio_compared_to_deposit.push [period / 1000, ratio_cp_deposit]

    if cur_balance.c2 < 0 || cur_balance.c1 < 0 
      console.error 'negative balance!', cur_balance, name

    series.open.push [period / 1000, active_positions.length]

    prev_balance.c2 = cur_balance.c2 
    prev_balance.c1 = cur_balance.c1   

  stats.metrics = series 

  if bus?.cache && 'stats' of bus.cache 
    from_cache('stats')[name] = stats

  # console.timeEnd(name)
  stats 


KPI = (callback) ->

  price_data = from_cache '/price_data' 
  balances = from_cache '/balances'

  if !KPI.initialized
    KPI.initialized = true 
    cached_positions = {}
    indicator_cache = {}

    add_to_cache get_dealers(), 'all'

    for name in get_series()        
      add_to_cache name

    time = from_cache '/time'
    if !time.earliest? || !time.latest?
      mint = Infinity
      for p in cached_positions.all
        mint = p.created if p.created < mint 

      time.earliest = mint 

      time.latest ||= now()
      save time
    KPI.ts = time.earliest

    dates = KPI.dates = (o.date * 1000 for o in price_data.c1xc2 when o.date >= time.earliest - price_data.granularity ) #&& o.date <= time.latest)
    dates.sort()
    KPI.period_length = (dates[1] - dates[0]) / 1000

  console.log '\n\nComputing KPIs'

  dealers = Object.keys(cached_positions)
  series_data = get_series()

  all_stats = {}
  try 

    for dealer in dealers when dealer not in series_data
      stats = compute_KPI dealer
      all_stats[dealer] = stats

  catch error 
    console.error error 

  callback all_stats


dealer_measures = (stats) ->
  'CAGR': (s) -> 
    if s of stats         
      "#{indicators.return(s, stats).toFixed(2)}%"

  'Sortino': (s) ->
    if s of stats 
      "#{indicators.sortino(s,stats).toFixed(2)}"


  'Profit*': (s) -> 
      if s of stats 
        "$#{(indicators.profit(s,stats) or 0).toFixed(0)}"

  'Score*': (s) -> 
      if s of stats 
        (indicators.score(s,stats)).toFixed(3)

  # 'Power*': (s) -> 
  #     if s of stats 
  #       (indicators.power(s,stats)).toFixed(2)  

  # 'Open*': (s) -> 
  #     if s of stats 
  #       (indicators.open(s,stats)).toFixed(2)   

  'Profit': (s) -> 
    if s of stats 
      series = stats[s].metrics.profit_index
      "$#{series[series.length - 1]?[1].toFixed(2) or 0 }"
  
  # 'Trade profit': (s) -> 
  #   if s of stats 
  #     series = stats[s].metrics.trade_profit
  #     "#{series[series.length - 1]?[1].toFixed(2) or 0 }"
  
  
  'Completed': (s) -> 
    if s of stats         
      "#{indicators.completed(s,stats)}"

  'Success': (s) -> 
    if s of stats 
      "#{(indicators.success(s,stats)).toFixed(1)}%" 

  'Not reset': (s) -> 
    if s of stats 
      "#{indicators.not_reset(s,stats).toFixed(1)}%"  

  'μ duration': (s) -> 
    if s of stats 
      "#{indicators.avg_duration(s,stats).toFixed(2)}"

  'x͂ duration': (s) -> 
    if s of stats 
      "#{indicators.median_duration(s,stats).toFixed(2)}"

  'Done in day': (s) -> 
    if s of stats 
      "#{( indicators.in_day(s,stats)).toFixed(1)}%"

  'within hour': (s) -> 
    if s of stats 
      "#{( indicators.in_hour(s,stats)).toFixed(1) }%"

  'μ return': (s) -> 
    if s of stats 
      "#{indicators.avg_return(s,stats).toFixed(2)}%"

  'x͂ return': (s) -> 
    if s of stats 
      "#{indicators.median_return(s,stats).toFixed(2)}%"

  # 'μ loss': (s) -> 
  #   if s of stats 
  #     "#{indicators.avg_loss(s,stats).toFixed(2)}%"

  # 'x͂ loss': (s) -> 
  #   if s of stats 
  #     "#{indicators.median_loss(s,stats).toFixed(2)}%"

  # 'μ gain': (s) -> 
  #   if s of stats 
  #     "#{indicators.avg_gain(s,stats).toFixed(2)}%"

  # 'x͂ gain': (s) -> 
  #   if s of stats 
  #     "#{indicators.median_gain(s,stats).toFixed(2)}%"



indicators =
  score: (s, stats) -> 
    indicator_cache.score ||= {}

    return indicator_cache.score[s] if s of indicator_cache.score 

    success = indicators.success(s,stats) / 100
    sortino = Math.max Math.abs(indicators.sortino(s,stats)), 0.01
    completed = (indicators.completed(s,stats) or 1) / stats[s].dealers.length

    avg_return = Math.average (r[1] for r in stats[s].metrics.returns when r != 0)

    sc = 100 *  Math.abs Math.log(completed + 1) * avg_return * success * Math.log(sortino + 1)
    if avg_return < 0
      sc *= -1
    indicator_cache.score[s] = sc
    sc

  # assumes 1 day periods
  sortino: (s, stats) ->
    indicator_cache.sortino ||= {}

    return indicator_cache.sortino[s] if s of indicator_cache.sortino 


    returns = (r[1] for r in stats[s].metrics.returns)
    if returns.length == 0 
      return 0 

    granularity = from_cache('/price_data').granularity
    periods_per_year = 365 * 24 * 60 * 60 / granularity

    yearly_return_target = 0.01 # 1% minimum yearly return goal. Treats not trading as slight negative.
    target_return = 100 * (Math.pow(1 + yearly_return_target, 1 / periods_per_year) - 1) # convert to per period return. Treats not trading as slight negative.
    avg_return = Math.average returns

    neg_diff = ( Math.pow(Math.min(0, (r - target_return)),2) for r in returns )
    downside_dev = Math.sqrt(Math.average(neg_diff))
    
    sortino = (avg_return - target_return) / downside_dev
    sortino *= Math.sqrt(periods_per_year) # annualize
    
    indicator_cache.sortino[s] = sortino
    sortino

  profit: (s, stats) -> 
    indicator_cache.profit ||= {}
    return indicator_cache.profit[s] if s of indicator_cache.profit 

    profs = Math.quartiles (v[1] for v in stats[s].metrics.profit_index)
    prof = (profs.q1 + profs.q2 + profs.q3) / 3 or 0 
    indicator_cache.profit[s] = prof
    prof

  unit_profits: (s, stats) -> 
    indicator_cache.unit_profits ||= {}
    return indicator_cache.unit_profits[s] if s of indicator_cache.unit_profits 

    profs = Math.quartiles (v[1] for v in stats[s].metrics.unit_profits)
    prof = (profs.q1 + profs.q2 + profs.q3) / 3 or 0 
    indicator_cache.unit_profits[s] = prof
    prof

  trade_profit:  (s, stats) -> 
    indicator_cache.trade_profit ||= {}
    return indicator_cache.trade_profit[s] if s of indicator_cache.trade_profit 

    nonzero = (v[1] for v in stats[s].metrics.trade_profit_difference when v[1] != 0 )
    if nonzero.length > 0
      prof = Math.average nonzero
    else 
      prof = 0 
    indicator_cache.trade_profit[s] = prof 
    prof

  fees:  (s, stats) -> 
    indicator_cache.fees ||= {}
    return indicator_cache.fees[s] if s of indicator_cache.fees 

    nonzero = (v[1] for v in stats[s].metrics.fees when v[1] != 0 )
    if nonzero.length > 0
      prof = Math.average nonzero
    else 
      prof = 0 
    indicator_cache.fees[s] = prof 
    prof

  open: (s, stats) -> 
    return 1
    indicator_cache.open ||= {}

    return indicator_cache.open[s] if s of indicator_cache.open 

    o = Math.quartiles (v[1] for v in stats[s].metrics.open)
    #(o.q3 + o.max) / 2 or 0
    open = o.max or 0
    indicator_cache.open[s] = open 
    open 

  power: (s, stats) ->
    indicator_cache.power ||= {}     
    return indicator_cache.power[s] if s of indicator_cache.power 

    o = indicators.open(s,stats) or 1
    prof = indicators.profit(s,stats)
    power = prof / o
    indicator_cache.power[s] = power 
    power

  return: (s, stats) -> 
    indicator_cache.return ||= {}      
    return indicator_cache.return[s] if s of indicator_cache.return 

    # TODO: update for live system


    # U$D value of baseline
    price_data = from_cache('/price_data')    

    $c2 = if !price_data.c2 then price_data.c1xc2[price_data.c1xc2.length - 1].close else price_data.c2[price_data.c2.length - 1].close
    $c1 = if !price_data.c1 then 1 else price_data.c1[price_data.c1.length - 1].close

    invested = deposits[s].c2 * $c2 + deposits[s].c1 * $c1

    idx = stats[s].metrics.profit_index.length - 1
    profit = stats[s].metrics.profit_index[idx][1]

    #annualize
    years = (stats[s].metrics.end - stats[s].metrics.start) / (365 * 24 * 60 * 60)
    ret = Math.pow((1 + profit / invested), 1 / years) - 1

    ret *= 100
    indicator_cache.return[s] = ret

    ret

  avg_return: (s, stats) ->
    indicator_cache.avg_return ||= {}      
    return indicator_cache.avg_return[s] if s of indicator_cache.avg_return 

    returns = (r[1] for r in stats[s].metrics.returns when r[1] != 0)

    avg_return = if returns.length > 0 then Math.average returns else 0
    indicator_cache.avg_return[s] = avg_return
    avg_return

  avg_loss: (s, stats) ->
    indicator_cache.avg_loss ||= {}      
    return indicator_cache.avg_loss[s] if s of indicator_cache.avg_loss 

    returns = (r[1] for r in stats[s].metrics.returns when r[1] < 0)
    avg_loss = if returns.length > 0 then Math.average returns else 0
    indicator_cache.avg_loss[s] = avg_loss
    avg_loss

  avg_gain: (s, stats) ->
    indicator_cache.avg_gain ||= {}      
    return indicator_cache.avg_gain[s] if s of indicator_cache.avg_gain 

    returns = (r[1] for r in stats[s].metrics.returns when r[1] > 0)
    avg_gain = if returns.length > 0 then Math.average returns else 0
    indicator_cache.avg_gain[s] = avg_gain
    avg_gain

  median_return: (s, stats) ->
    indicator_cache.median_return ||= {}      
    return indicator_cache.median_return[s] if s of indicator_cache.median_return 

    returns = (r[1] for r in stats[s].metrics.returns when r[1] != 0)
    median_return = if returns.length > 0 then Math.median returns else 0
    indicator_cache.median_return[s] = median_return
    median_return

  median_loss: (s, stats) ->
    indicator_cache.median_loss ||= {}      
    return indicator_cache.median_loss[s] if s of indicator_cache.median_loss 

    returns = (r[1] for r in stats[s].metrics.returns when r[1] < 0)
    median_loss = if returns.length > 0 then Math.median returns else 0
    indicator_cache.median_loss[s] = median_loss
    median_loss

  median_gain: (s, stats) ->
    indicator_cache.median_gain ||= {}      
    return indicator_cache.median_gain[s] if s of indicator_cache.median_gain 

    returns = (r[1] for r in stats[s].metrics.returns when r[1] > 0)
    median_gain = if returns.length > 0 then Math.median returns else 0
    indicator_cache.median_gain[s] = median_gain
    median_gain


  completed: (s, stats) -> stats[s].status.completed
  not_reset:    (s, stats) -> 100 - 100 * stats[s].status.reset / ((stats[s].status.completed + stats[s].status.open) or 1)

  success:  (s, stats) -> 
    if stats[s].status.completed > 0 
      100 * stats[s].status.gains / ((stats[s].status.completed + stats[s].status.open) or 1)
    else 
      pos_return = 0 
      for r in stats[s].metrics.returns
        if r[1] > 0 
          pos_return += 1
      100 * pos_return / stats[s].metrics.returns.length 

  in_day:   (s, stats) -> 100 * (1 - stats[s].more_than_day)
  in_hour:  (s, stats) -> 100 * (1 - stats[s].more_than_hour)


  avg_duration: (s, stats) ->
    indicator_cache.avg_duration ||= {}      
    return indicator_cache.avg_duration[s] if s of indicator_cache.avg_duration 

    durations = ( (p.closed - p.created) / 60 for p in cached_positions[s] when p.closed)
    avg_duration = if durations.length > 0 then Math.average durations else 0
    indicator_cache.avg_duration[s] = avg_duration
    avg_duration

  median_duration: (s, stats) ->
    indicator_cache.median_duration ||= {}      
    return indicator_cache.median_duration[s] if s of indicator_cache.median_duration 

    durations = ( (p.closed - p.created) / 60 for p in cached_positions[s] when p.closed)
    median_duration = if durations.length > 0 then Math.median durations else 0
    indicator_cache.median_duration[s] = median_duration
    median_duration


indicators.profit.additive = true 
indicators.completed.additive = true 
indicators.power.additive = true 
indicators.trade_profit.additive = true 
indicators.open.additive = true 
indicators.fees.additive = true


crunch = module.exports = 
  cached_positions: cached_positions
  compute_KPI: compute_KPI
  KPI: KPI
  dealer_measures: dealer_measures
  indicators: indicators


make_global crunch