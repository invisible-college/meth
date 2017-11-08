
wait_for_bus ->
  bus.render_when_loading = false
  bus.disable_backup_cache = true 
  focus = fetch 'focus'
  focus.highlighted = null
  focus.params = []
  save focus


# bus.honk = false
# bus.dev_with_single_client = false

font = 'Bebas Neue'
mono = 'Roboto Mono'
special = 'Railway'

fonts = []
for f in [font, mono, special] when !(f in ['Courier new'])
  fonts.push f if fonts.indexOf(f) == -1

fetch '/balances'


dom.BODY = ->

 
  price_data = fetch '/price_data' 
  balances = fetch '/balances'
  time = fetch '/time'
  operation = fetch '/operation'
  config = fetch '/config'

  for name, strategy of operation when name != 'key'
    for dealer in strategy.dealers
      fetch(dealer)

  DIV
    style:
      fontFamily: font
      minHeight: window.innerHeight
      padding: 0
      margin: 0
      minWidth: 1400
      backgroundColor: 'black'
      #width: '100%'
      color: 'white'

    for f in fonts
      LINK
        key: f
        href: "http://fonts.googleapis.com/css?family=#{f}:200,300,400,500,700"
        rel: 'stylesheet'
        type: 'text/css'


    if !@local.ready 
      
      LOADING_METH
        status: if !@local.data_loaded
                  'downloading deals'
                else if !@local.ready 
                  'sorting it out'
                else 
                  'presenting the books'


    else 
      DIV
        key: 'main'
        style:
          padding: "20px 40px"

        SECTION 
          key: 'bank'
          name: 'Account Overview'
          show_by_default: true
          render: -> BANK key: 'bank'

        SECTION 
          key: 'performance'
          name: 'Dealer performance'
          show_by_default: true 
          render: -> PERFORMANCE key: 'performance'

        SECTION
          key: 'graphs' + md5(JSON.stringify(dealers_in_focus()))
          name: 'Time series'
          show_by_default: false
          render: -> TIME_SERIES() #GRAPHS key: 'graphs'

        SECTION 
          key: 'parameter selection'
          name: "Performance by variable"
          show_by_default: false
          render: -> PARAMETER_SELECTOR key: 'PARAMETER_SELECTOR'

        SECTION
          key: 'threevars'
          name: 'Variable Interactions'
          show_by_default: false
          render: -> PLOT_THREE_VAR_RELATIONS()

        SECTION 
          key: 'activity'
          name: 'All activity'
          show_by_default: false
          render: -> ACTIVITY key: 'table'

dom.BODY.refresh = ->


  if !@local.ready && !compute_stats?

    all_dealers_fetched = true
    for d in get_dealers()
      all_dealers_fetched &&= Object.keys( from_cache(d) ).length > 1

    if all_dealers_fetched && !@loading()

      if !@local.data_loaded
        @local.data_loaded = true
        save @local

      local = @local

      window.compute_stats = bus.reactive ->
        price_data = fetch '/price_data' 
        balances = fetch '/balances'
        time = fetch '/time'

        return if Object.keys(price_data).length == 1 || Object.keys(balances).length == 1 || Object.keys(time).length == 1
        
        try

          if Date.now() - started_computing_at < 100000 && last_time == JSON.stringify(time)
            return


          last_time = JSON.stringify(time)
          started_computing_at = Date.now()

          KPI (stats) ->
            console.log "COMPUTED in #{Date.now() - started_computing_at}"

            stats.key = 'stats'
            save stats

            if !local.ready
              local.ready = true 
              save local

        catch error 
          console.error error 

      setTimeout compute_stats, 500


started_computing_at = 0 
last_time = null 



dom.SECTION = ->
  tw = if !@local.show then 15 else 20
  th = if !@local.show then 20 else 15

  @local.show ?= @props.show_by_default

  DIV null,
    DIV 
      style: 
        fontSize: 44
        color: '#555'
        cursor: 'pointer'
        position: 'relative'

      onClick: => 
        @local.show = !@local.show 
        save @local 

      SPAN 
        style: cssTriangle (if !@local.show then 'right' else 'bottom'), '#777', tw, th,
          position: 'absolute'
          left: -tw - 12
          bottom: 23
          width: tw
          height: th
          display: 'inline-block'
          opacity: if @local.show then .5
      H1 
        style: 
          fontSize: 44
          marginBottom: 6

        @props.name

    if @local.show 
      @props.render()



dom.PRICE_CANDLESTICKS = -> 
  price_data = fetch '/price_data'  

  toggle = => 
    @local.showing = !@local.showing 
    save @local

  DIV null,
    BUTTON 
      onClick: toggle
      style: 
        backgroundColor: 'transparent'
        border: 'none' 
        color: attention_magenta
        cursor: 'pointer'
      "#{@props.name}"

    DIV 
      style: 
        display: if !@local.showing then 'none'
        margin: '40px 0'

      DIV 
        id: "candlestick"
        style: 
          position: 'relative'

dom.PRICE_CANDLESTICKS.refresh = ->
  price_data = fetch '/price_data'  
  config = fetch '/config'

  return if @local.initialized || !@local.showing || Object.keys(price_data).length == 1

  converted = config.c1 not in ['USD', 'USDT']

  @local.initialized = true 


  data = []
  layout = {}
  num_candles = if converted then Object.keys(price_data).length - 1 else 1

  candles = if converted then ['c1xc2', 'c1', 'c2'] else ['c1xc2']

  for pair in candles
    OHLC = price_data[pair]
    idx = data.length
    

    if idx > 0 
      num = idx + 1
    else 
      num = ""

    datum = 
      type: 'candlestick'
      
      x: KPI.dates #(o.date * 1000 for o in OHLC)
      close: (o.close for o in OHLC when o.date * 1000 >= KPI.dates[0])    
      high: (o.high for o in OHLC when o.date * 1000 >= KPI.dates[0]) 
      low: (o.low for o in OHLC when o.date * 1000 >= KPI.dates[0])    
      open: (o.open for o in OHLC when o.date * 1000 >= KPI.dates[0])    
      
      yaxis: "y#{num}"
      decreasing: 
        line: 
          color: bright_red
      increasing: 
        line: 
          color: ecto_green
      line: 
        color: 'rgba(31,119,180,1)'

      name: pair

    layout = extend layout, 
      "yaxis#{num}": 
        #autorange: true
        domain: [(if idx == 0 then 0 else idx / num_candles + .02), (if idx == num_candles - 1 then 1 else (idx + 1) / num_candles - .02)]
        type: 'linear'
        gridcolor: '#222'

    data.push datum


  layout = extend layout,
    dragmode: 'zoom'
    margin:
      r: 10
      t: 25
      b: 40
      l: 60
    showlegend: false

    height: 700
    paper_bgcolor: 'rgba(0,0,0,0)'
    plot_bgcolor: 'rgba(0,0,0,0)'
    font:
      family: mono
      size: 12
      color: '#888'

    xaxis: 
      #autorange: true
      domain: [0, 1]
      gridcolor: '#222'

      rangeselector:
        activecolor: '#333'
        bgcolor: '#111'
        bordercolor: '#333'

        buttons: [{
            step: 'month'
            stepmode: 'backward'
            count: 1
            label: '1m'
          }, {
            step: 'month'
            stepmode: 'backward'
            count: 6
            label: '6m'
          }, {
            step: 'year'
            stepmode: 'todate'
            count: 1
            label: 'YTD'
          }, {
            step: 'year'
            stepmode: 'backward'
            count: 1
            label: '1y'
          }, {
            step: 'all'
          }]

      rangeslider:  {}
      title: 'Date'
      type: 'date'

  Plotly.plot("candlestick", data, layout)



feature_settings = 
  '/price-dealer':
    name: 'Price' 

plot_settings = 
  trades: 
    name: 'Trades'

  equity: 
    name: 'Profit & Losses'
    metric: 'profit_index'
    tickformat: "+$,.0f"

  unit_profits: 
    name: 'Unit Profit & Losses'
    metric: 'profit_index_normalized'
    tickformat: "+$,.0f"


  ratio: 
    name: 'Pair Ratio'
    metric: 'ratio_compared_to_deposit'
    tickformat: ',.4%'

  trade_profit: 
    name: 'Position Profit'
    metric: 'trade_profit'
    tickformat: ',.2f'

  returns: 
    name: 'Return %'
    metric: 'returns'
    tickformat: ',.2%'
    y: (series) -> (p[1]/100 for p in series)

  open: 
    name: 'Open Positions'
    metric: 'open'
    tickformat: ','


dom.TIME_SERIES = -> 
  features = get_series()
  plots = Object.keys plot_settings
  diff = get_differentiating_parameters()

  params = Object.keys diff[Object.keys(diff)[0]].variables

  if !@local.enabled_features?
    @local.enabled_features = {}
    @local.enabled_features[features[0]] = true 

    @local.show_trades = false 

    @local.enabled_plots = {}
    @local.enabled_plots[plots[0]] = true 

    @local.enabled_params = {}



  option_label_style = 
    fontFamily: special 
    fontSize: 18
    color: '#414141'
    marginBottom: 12

  choice_style = 
    fontSize: 18
    display: 'inline-block'
    padding: '0px 8px'
    fontFamily: font
    cursor: 'pointer'

  DIV 
    style: 
      minHeight: 800

    DIV 
      style: option_label_style

      'features'

      UL 
        style: 
          listStyle: 'none'
          display: 'inline'

        for feature in features 
          do (feature) => 

            LI 
              style: extend {}, choice_style,
                color: if @local.enabled_features[feature] then ecto_green else '#616161'
              onClick: (e) => 
                @local.enabled_features[feature] = !@local.enabled_features[feature]
                @local.initialized = false
                save @local
              
              feature_settings[feature]?.name or feature.replace('-dealer', '').substring(1)

    DIV 
      style: option_label_style

      'plots'

      UL 
        style: 
          listStyle: 'none'
          display: 'inline'

        for plot in plots 
          do (plot) =>
            LI 
              style: extend {}, choice_style,
                color: if @local.enabled_plots[plot] then ecto_green else '#616161'
              onClick: (e) => 
                @local.enabled_plots[plot] = !@local.enabled_plots[plot]
                @local.initialized = false
                save @local

              plot_settings[plot].name or plot

    DIV 
      style: option_label_style

      'params'

      UL 
        style: 
          listStyle: 'none'
          display: 'inline'

        for param in params 
          do (param) =>
            LI 
              style: extend {}, choice_style,
                color: if @local.enabled_params[param] then ecto_green else '#616161'
              onClick: (e) => 
                @local.enabled_params[param] = !@local.enabled_params[param]
                @local.initialized = false
                save @local

              param



    DIV 
      style: 
        position: 'relative'

      DIV
        id: "time-series"
        ref: 'plotly'
        key: md5(JSON.stringify({plots: @local.enabled_plots, features: @local.enabled_features, params: @local.params}))
        style: 
          position: 'relative'


dom.TIME_SERIES.refresh = ->
  price_data = fetch '/price_data'  
  balances = fetch '/balances'
  all_stats = fetch 'stats'


  return if @local.initialized || Object.keys(price_data).length == 1 || \
            dealers_in_focus().length == 0 || \
            Object.keys(balances).length == 1 || Object.keys(all_stats).length == 1

  @local.initialized = true 


  
  active_params = []
  for param, active of @local.enabled_params when active
    active_params.push param

  if active_params.length == 0 
    if get_dealers().length == dealers_in_focus().length 
      name = 'all'
    else 
      name = md5 JSON.stringify(dealers_in_focus())
    lines = [ {name: name, dealers: dealers_in_focus()} ]
  else 
    lines = []

    ##################
    # iteratively build up dealer sets based from conjunctive params

    dealers_by_param_val = {}
    for param in active_params
      dealers_by_param_val[param] = {}

    for dealer in dealers_in_focus()
      for part,idx in dealer_params(dealer)
        continue if idx == 0 
        p = param_value(part)
        if p.var of dealers_by_param_val
          dealers_by_param_val[p.var][p.val] ?= []
          dealers_by_param_val[p.var][p.val].push dealer


    while active_params.length > 0 
      param = active_params.pop()

      # get all of the different values + dealers for this param 
      perms = dealers_by_param_val[param]

      # expand dealer_sets with each value of current param
      if lines.length > 0 
        expanded_dealer_sets = []
        for dealer_set in lines
          for val, dealers of perms 
            dealers_for_val = (d for d in dealers when d in dealer_set.dealers)
            if dealers_for_val.length > 0 
              expanded_dealer_sets.push 
                name: "#{dealer_set.name}   #{param}:#{val}"
                dealers: dealers_for_val

        lines = expanded_dealer_sets
      else 
        for val, dealers of perms 
          lines.push 
            name: "#{val}:#{param}"
            dealers: dealers        
    ################

  plots = []
  for k,v of @local.enabled_plots
    if v && k != 'trades'
      plots.push k 

  if @local.enabled_plots.trades 
    plots.push 'trades'


  data = []
  layout = {}

  axis_counter = 1

  axis_map = {}


  dates = undefined
  for feature, enabled of @local.enabled_features
    continue if !enabled

    series_dat = cached_positions[feature] or []
    dates = (p.created * 1000 for p in series_dat)
    series_dat = (p.entry.rate for p in series_dat)

    axdef = "yaxis#{axis_counter}"
    anchor = "y#{axis_counter}"
    axis_map[feature] = {axdef, anchor}

    data.push 
      name: feature
      type: 'scattergl'
      x: dates
      y: series_dat
      yaxis: anchor
      hoverinfo: "y+name"
      line: 
        width: 1


    layout[axdef] = 
      tickformat: ',.4r'
      anchor: 'x'
      overlaying: 'y'
      side: 'right'
      autorange: true
      showgrid: false
      zeroline: true
      showline: false
      autotick: true
      ticks: ''
      showticklabels: false

    axis_counter += 1




  for plot in plots
    series_settings = plot_settings[plot]

    if axis_counter == 1 
      axdef = 'yaxis'
      anchor = null
    else if plot == 'trades' && axis_map['/price-dealer']
      axdef = axis_map['/price-dealer'].axdef 
      anchor = axis_map['/price-dealer'].anchor
    else 
      axdef = "yaxis#{axis_counter}"
      anchor = "y#{axis_counter}"

    axis_map[plot] = {axdef, anchor}


    if !(axdef of layout)
      layout[axdef] = 
        tickformat: series_settings.tickformat or ''
        hoverformat: series_settings.hoverformat or series_settings.tickformat or ''
        gridcolor: '#555'
        showgrid: false 
        anchor: 'x'

      if axis_counter > 1
        extend layout[axdef], 
          overlaying: 'y'
          side: 'right'
          autorange: true
          showgrid: false
          zeroline: true
          showline: false
          autotick: true

        if axis_counter > 2
          extend layout[axdef], 
            ticks: ''
            showticklabels: false

    if plot == 'trades'
      x = []
      y = []
      colors = []
      size = []
      borderwidths = []
      opacities = []

      linesx = 
        buy: []
        sell: []
      linesy = 
        buy: []
        sell: []

      for dealer in dealers_in_focus()
        for p in cached_positions[dealer] when !p.rebalancing
          for trade in [p.entry, p.exit] when trade
            x.push 1000 * (trade.closed or trade.created)
            y.push trade.rate 
            if p.rebalancing
              colors.push .5
              size.push 4
            else 
              if trade.type == 'sell'
                colors.push 0
              else 
                colors.push 1

              if p.closed
                size.push 8
                opacities.push .5
                borderwidths.push 0
              else 
                opacities.push .9                
                size.push 12
                if !trade.closed
                  borderwidths.push 1
                else 
                  borderwidths.push 0


          if p.entry && p.exit 
            if Math.abs((p.entry.closed or p.entry.created) - (p.exit.closed or p.exit.created)) > 30 * 60
              linesx[p.entry.type].push 1000 * (p.entry.closed or p.entry.created)
              linesy[p.entry.type].push p.entry.rate 
              linesx[p.entry.type].push 1000 * (p.exit.closed or p.exit.created)
              linesy[p.entry.type].push p.exit.rate 
              linesx[p.entry.type].push null 
              linesy[p.entry.type].push null


      data.push 
        name: "Trades plot"
        type: 'scattergl'
        mode: 'markers'
        x: x
        y: y
        yaxis: anchor
        showlegend: false
        hoverinfo: 'skip'
        marker:         
          size: size
          color: colors
          opacity: opacities
          colorscale: [[0, attention_magenta], [.5, "#ffff00"], [1, ecto_green]]
          line: 
            width: borderwidths
            color: 'white'

      data.push 
        name: "Trades buy line"
        type: 'scattergl'
        mode: 'lines'
        x: linesx.buy
        y: linesy.buy
        yaxis: anchor
        showlegend: false
        hoverinfo: 'skip'
        opacity: .3
        line: 
          width: 1
          color: ecto_green

      data.push 
        name: "Trades sell line"
        type: 'scattergl'
        mode: 'lines'
        x: linesx.sell
        y: linesy.sell
        yaxis: anchor
        showlegend: false
        hoverinfo: 'skip'
        opacity: .3
        line: 
          width: 1
          color: attention_magenta


    else 
      for line in lines
        name = line.name
        dealers = line.dealers
        compute_KPI dealers, name 

        series = all_stats[name].metrics[series_settings.metric]

        data.push 
          name: "#{name}   ##{plot_settings[plot].name or plot}"
          type: 'scattergl'
          x: KPI.dates
          y: series_settings.y?(series) or (p[1] for p in series)
          yaxis: anchor
          showlegend: false
          hoverinfo: "y+name"
          hoverlabel: 
            namelength: 100
          
          line: 
            shape: 'linear' #'spline'
            width: 1
            # color: 'rgba(31,119,180,1)'

    axis_counter += 1





  layout = extend layout, 
    dragmode: 'zoom'
    margin:
      r: 10
      t: 25
      b: 40
      l: 60
      pad: 0
    showlegend: false #data.length < 25

    height: 700
    paper_bgcolor: 'rgba(0,0,0,0)'
    plot_bgcolor: 'rgba(0,0,0,0)'
    font:
      family: mono
      size: 12
      color: '#888'


    xaxis: 
      gridcolor: '#333'
      showgrid: false
      zeroline: true

      rangeselector:
        activecolor: '#333'
        bgcolor: '#111'
        bordercolor: '#333'

        buttons: [{
            step: 'month'
            stepmode: 'backward'
            count: 1
            label: '1m'
          }, {
            step: 'month'
            stepmode: 'backward'
            count: 6
            label: '6m'
          }, {
            step: 'year'
            stepmode: 'todate'
            count: 1
            label: 'YTD'
          }, {
            step: 'year'
            stepmode: 'backward'
            count: 1
            label: '1y'
          }, {
            step: 'all'
          }]

      rangeslider:  {}
      type: 'date'

  try 
    Plotly.purge(@refs.plotly.getDOMNode())
  catch e 
    console.log "Couldn't delete plotly trace before plotting"

  Plotly.plot(@refs.plotly.getDOMNode(), data, layout)




scalar_variables = -> 
  diff = get_differentiating_parameters()
  variables = {}

  for name, pieces of diff 
    for param in pieces.params 
      variable = param_value(param).var 
      variables[variable] ?= []
      variables[variable].push param_value(param).val

  variables

window.get_differentiating_parameters = (opts) ->
  focus = fetch 'focus'
  stats = fetch 'stats'
  instances = dealers_in_focus include_strategies: false 

  strategies = {}
  opts ?= {}

  for dealer in instances 
    params = {}
    #continue if stats[dealer].status.completed + stats[dealer].status.open == 0

    for part, idx in dealer_params(dealer)
      if idx == 0 
        name = part 
        strategies[name] ||=
          instances: []
          params: []
        strategies[name].instances.push dealer 

      else if strategies[name]?.params.indexOf(part) == -1
        strategies[name].params.push part

  # count instances of each parameter. we'll later filter out variables
  # that aren't actually variable
  for name, pieces of strategies 
    variables = {}
    for param in pieces.params 
      variable = param_value(param).var
      variables[variable] ?= 0
      variables[variable] += 1

    strategies[name].variables = variables

    # filter out variables that started with only a single value
    pieces.params = (param for param in pieces.params when variables[param_value(param).var] > 1 || (opts.keep_focused_params && param in (focus.params or []))  )


  strategies 


window.dealers_in_focus = (opts) ->
  opts ?= {}

  dealers_in_focus.cache ?= {}
  cache = dealers_in_focus.cache
  focus = from_cache('focus')
  key = JSON.stringify(focus) + JSON.stringify(get_dealers()) + JSON.stringify(opts)

  if key not of dealers_in_focus.cache

    if focus.highlighted
      dealers = [focus.highlighted]
    else 
      focus = fetch 'focus'
      if focus.params && focus.params.length > 0
        passes_param_filter = (dealer) -> 
          for param in focus.params
            if dealer.indexOf(param) == -1
              return false 
          true
      else 
        passes_param_filter = -> true

      dealers = (dealer for dealer in get_dealers() when passes_param_filter(dealer) )
    if opts.include_strategies
      dealers.shift 'all'

    cache[key] = dealers
  cache[key]


# dependent variables; independent (variable) is an indicator function 
get_3d_data = (opts) -> 
  dependent1 = opts.dependent1
  dependent2 = opts.dependent2
  independent = opts.independent
  stats = opts.stats
  aggregation = opts.aggregation
  variables = opts.variables


  
  # divide dealers into matrix of d1 x d2 values
  dealer_matrix = {}
  dealers = dealers_in_focus
              include_strategies: false 

  for dealer in dealers 
    params = {}
    continue if stats[dealer].status.completed + stats[dealer].status.open == 0

    d1 = undefined 
    d2 = undefined 

    for param, idx in dealer_params(dealer) when idx > 0 
      param = param_value(param)

      if param.var == dependent1
        d1 = param.val
      else if param.var == dependent2
        d2 = param.val

    if d1? && d2?
      if d1 not of dealer_matrix
        dealer_matrix[d1] = {}
        for param_val in variables[dependent2] # all unique values should be here, even if d2 is never
          dealer_matrix[d1][param_val] = []    # used for this d1. Otherwise our contour plots get messed up.
          
      dealer_matrix[d1][d2].push dealer

  # now compute KPI (independent) for the dealers in each cell, creating a list of points
  points = []
  for d1, d2s of dealer_matrix 
    for d2, dealers of d2s 
      if dealers.length > 0 
        if aggregation 
          points.push( [d1,d2,aggregation({independent, dealers})]  )
        else 
          for val in ( independent(dealer,stats) for dealer in dealers) 
            points.push( [d1,d2,val]  )
      else
        points.push [d1,d2,0]

  points 




dom.PARAMETER_SELECTOR = ->
  stats = fetch 'stats'
  return SPAN null if compute_stats.loading() || @loading()


  params_by_strategy = get_differentiating_parameters keep_focused_params: true

  DIV 
    style:
      marginTop: 20

    for strategy, params of params_by_strategy when strategy != 'all' && Object.keys(params.params).length > 0 
      SELECT_PARAMS
        key: strategy
        strategy: strategy
        instances: params.instances
        params: params.params
        stats: stats
        time: fetch('/time')



dom.PLOT_THREE_VAR_RELATIONS = -> 
  price_data = fetch '/price_data'  
  balances = fetch '/balances'
  stats = fetch 'stats'


  return if Object.keys(price_data).length == 1 || \
            dealers_in_focus().length == 0 || Object.keys(balances).length == 1 || \
            Object.keys(stats).length == 1

  variables = Object.keys(scalar_variables())

  return if variables.length < 2


  @local.independent ?= 'score'
  @local.chart_type ?= 'contour'
  @local.aggregation ?= 'median'

  @local.showing ?= true

  if !@local.dependent1 || @local.dependent1 not in variables
    @local.dependent1 = variables[0]
    @local.initialized = false
    save @local 

  heading = 
    fontSize: 42
    color: ecto_green
    fontWeight: 700
    display: 'inline-block'
    padding: '0 40px'
    display: 'inline-block'
    verticalAlign: 'top'


  option = (selected) =>
    fontSize: 12
    color: if selected then ecto_green else '#666'
    fontWeight: 400
    backgroundColor: 'transparent'
    padding: '2px 8px'
    margin: '2px 4px'
    borderRadius: 4
    border: if selected then "1px solid #{ecto_green}" else "1px solid #222"
    cursor: 'pointer  '

  select_option = (val, variable) =>
    @local[variable] = val 
    @local.initialized = false
    save @local 

  DIV 
    key: md5 'threevars' + JSON.stringify(dealers_in_focus({include_strategies: false}))

    DIV 
      key: 'header'
      style: 
        fontSize: 24

      INPUT
        id: 'global_scale' 
        type: 'checkbox'
        defaultChecked: @local.global_scale

        onChange: (e) => 
          @local.global_scale = !@local.global_scale
          @local.initialized = false
          save @local 

        @local.global_scale

      LABEL
        style: 
          color: 'white'
        htmlFor: 'global_scale'
        'global scale'

      SELECT 
        style: 
          marginLeft: 10
        value: @local.aggregation

        onChange: (e) => 
          @local.aggregation = e.target.value 
          @local.initialized = false
          save @local 
        OPTION 
          value: 'median'
          'median'

        OPTION 
          value: 'average'
          'average'

        OPTION 
          value: 'merged'
          'merged'




    DIV 
      key: 'variable switcher'

      H2 
        style: extend {}, heading,
          textAlign: 'right'
          maxWidth: '45%'

        capitalize @local.dependent1

        UL 
          style:
            listStyle: 'none'
            fontSize: 12

          for dependent in variables
            do (dependent) =>
              LI 
                style: 
                  display: 'inline-block'
                  
                BUTTON
                  style: option dependent == @local.dependent1
                  onClick: => select_option dependent, 'dependent1'

                  dependent




      SPAN 
        style: extend {}, heading,
          textAlign: 'right'
          display: 'inline-block'
          color: '#444'
        'by'

      H2 
        style: extend {}, heading,
          maxWidth: '45%'
        capitalize @local.independent

        UL 
          style:
            listStyle: 'none'
            fontSize: 12

          for indicator, func of indicators
            do (indicator) =>
              LI 
                style: 
                  display: 'inline-block'
                  fontSize: 12

                BUTTON
                  style: option indicator == @local.independent
                  onClick: => select_option indicator, 'independent'
                  indicator


    DIV 
      'data-key': "#{@local.independent}-#{@local.dependent1}-#{@local.chart_type}-#{@local.aggregation}-#{@local.global_scale}-#{variables.join('---')}"
      id: 'PLOT_THREE_VAR_RELATIONS'
      ref: 'plot'

dom.PLOT_THREE_VAR_RELATIONS.refresh = -> 
  price_data = fetch '/price_data'  
  balances = fetch '/balances'
  stats = fetch 'stats'

  key = @refs.plot.getDOMNode().getAttribute('data-key')
  
  return if (@local.initialized && @local.initialized == key) || !@local.showing || Object.keys(price_data).length == 1 || \
            dealers_in_focus().length == 0 || Object.keys(balances).length == 1 || \
            Object.keys(stats).length == 1


  @local.initialized = key

  dependent1 = @local.dependent1
  independent = indicators[@local.independent]
  chart_type = @local.chart_type

  aggregation = if @local.aggregation == 'median' 
                  (opts) -> Math.median(( opts.independent(dealer,stats) for dealer in opts.dealers))
                else if @local.aggregation == 'average'
                  (opts) -> Math.average(( opts.independent(dealer,stats) for dealer in opts.dealers))
                else if @local.aggregation == 'merged'
                  (opts) -> 
                    name = opts.dealers.join('_')
                    compute_KPI opts.dealers, name
                    val = opts.independent(name,stats)
                    if opts.independent.additive
                      val /= opts.dealers.length
                    val


  data = []

  layout = {}
  variables = scalar_variables()  

  # fit x plots into square
  num = Object.keys(variables).length - 1
  num_per_row = 4

  w = @getDOMNode().offsetWidth

  width_per = w / num_per_row - w / 20
  height_per = width_per
  cols = Math.floor(w / width_per) - 1
  rows = Math.ceil num / cols
  domains = []

  for row in [rows - 1..0] by -1
    for col in [0..cols - 1]

      if domains.length < num

        domains.push 
          x: [ (if col == 0 then 0 else col / cols + .03), (if col == cols - 1 then 1 else (col + 1) / cols - .03) ]
          y: [ (if row == 0 then 0 else row / rows + .05), (if row == rows - 1 then 1 else (row + 1) / rows - .05) ]


  # build plots
  idx = 0 
  for dependent2,vals of variables when dependent2 != dependent1
    threed = get_3d_data {dependent1, dependent2, independent, stats, aggregation, variables}

    continue if threed.length == variables[dependent2].length || threed.length == variables[dependent1].length
    data.push
      x: (p[1] for p in threed)
      y: (p[0] for p in threed)
      z: (p[2] for p in threed)
      showscale: false # hide colorbar
      name: ''

      type: @local.chart_type
      colorscale: [
                    ['0.0', bright_red]
                    ['0.5', '#222']
                    ['1.0', ecto_green]
                  ]
      xaxis: if idx > 0 then "x#{idx + 1}"
      yaxis: if idx > 0 then "y#{idx + 1}"

    layout = extend layout, 
      "xaxis#{if idx == 0 then '' else idx + 1}":
        title: dependent2   
        anchor: if idx > 0 then "y#{idx + 1}"
        domain: domains[idx].x

      "yaxis#{if idx == 0 then '' else idx + 1}":
        anchor: if idx > 0 then "x#{idx + 1}"
        domain: domains[idx].y

    idx += 1


  if @local.global_scale
    z_maxes = []
    z_mins = []
    for datum in data
      z_maxes.push Math.max.apply null, (Math.abs(zz) for zz in datum.z) 
      z_mins.push Math.min.apply null, datum.z

    max = Math.max.apply null, z_maxes
    min = Math.min.apply null, z_mins
  for datum in data
    if !@local.global_scale
      max = Math.max.apply null, (Math.abs(zz) for zz in datum.z) 
      min = Math.min.apply null, datum.z

    datum.zmin = if min < 0 then -max else 0
    datum.zmax = max 


  layout = extend layout,
    height: rows * height_per + 100
    paper_bgcolor: 'rgba(0,0,0,0)'
    plot_bgcolor: 'rgba(0,0,0,0)'
  

    font:
      family: mono
      size: 12
      color: '#888'

    margin:
      l: 40
      r: 0
      b: 80
      t: 20
      pad: 0

  Plotly.newPlot 'PLOT_THREE_VAR_RELATIONS', data, layout


param_value = (param) ->
  param_value.cache ?= {}
  v = param_value.cache[param]
  if !v 
    p = param.split('=')
    v = param_value.cache[param] =
      var: p[0]
      val: p[1]
  v

dealer_params = (dealer) ->
  dealer_params.cache ?= {}
  v = dealer_params.cache[dealer]
  if !v 
    v = dealer_params.cache[dealer] = dealer.split('&')
  v


dom.SELECT_PARAMS = ->
  stats = @props.stats
  time = @props.time
  @local.fixed_params ||= {}
  focus = fetch 'focus'

  data = =>


    performance_of = (param, additive, metric) => 
      p = param_value(param).var
      selected = @local.fixed_params[param]
      other_val_selected = @local.fixed_params[p] && !selected

      return '-' if other_val_selected

      to_match = (p for p,_ of @local.fixed_params when p.indexOf('=') > -1)
      to_match.push param if !selected

      does = [] 
      doesnt = []

      for dealer in @props.instances 

        matches = true 
        passes = true
        for p in to_match
          parts = dealer_params(dealer)
          matches &&= parts.indexOf(p) > -1
          if p != param || selected
            passes &&= parts.indexOf(p) > -1

        continue if !passes 

        if matches
          does.push dealer
        else 
          doesnt.push dealer


      if true 

        does_name = does.join('_')

        does_KPI = compute_KPI does, does_name
        q = parseFloat(metric(does_name)) #/ does.length
        if additive 
          q /= does.length
        if doesnt.length > 0
          doesnt_name = "not #{does_name}" 
          doesnt_KPI = compute_KPI doesnt, doesnt_name
          doesnt_val = parseFloat(metric(doesnt_name)) #/ doesnt.length
          if additive 
            doesnt_val /= doesnt.length
          q -= doesnt_val


      else 
        q = Math.average (parseFloat(metric(dealer)) for dealer in does)


        if doesnt.length > 0 
          q -= Math.average (parseFloat(metric(dealer)) for dealer in doesnt)
      
      q








    format = (p, flip, additive, func) => 
      val = performance_of p, additive, func

      param = param_value(p).var
      selected = @local.fixed_params[p]
      other_val_selected = @local.fixed_params[param] && !selected

      SPAN 
        style: 
          color: if (val > 0 && !flip) || (val < 0 && flip) then ecto_green else if val == 0 then '#888' else bright_red
          opacity: if other_val_selected then .2
          fontFamily: mono

        if val.toFixed
          "#{val.toFixed(2)}" 
        else 
          val

    cols = [
      ['Parameter', (p) => 
        param = param_value(p).var
        selected = @local.fixed_params[p]
        other_val_selected = @local.fixed_params[param] && !selected

        SPAN 
          style: 
            color: if selected then attention_magenta
            cursor: 'pointer'
            opacity: if other_val_selected then .2
          onClick: =>
            selected = @local.fixed_params[p]
            other_val_selected = @local.fixed_params[param] && !selected
            

            if other_val_selected
              for k,v of @local.fixed_params
                if k.indexOf(param) > -1
                  delete @local.fixed_params[k]

            if selected 
              delete @local.fixed_params[p]
              delete @local.fixed_params[param]
              idx = focus.params.indexOf(p)
              focus.params.splice idx, 1
            else 
              @local.fixed_params[p] = 1
              @local.fixed_params[param] = 1
              focus.params.push p

            save focus
            save @local

          p

      ]

      ['Sortino', (p) -> format p, false, false, (s) -> indicators.sortino(s, stats)]

      ['Score*',    (p) -> format p, false, false,  (s) -> indicators.score(s, stats)]
      ['Profit*',   (p) -> format p, false, true,  (s) -> indicators.profit(s,stats)]   
      # ['hTradeProf',(p) -> format p, false, (s) -> indicators.trade_profit(s,stats)]   

      # ['hOpen',     (p) -> format p, true,  (s) -> indicators.open(s, stats)]      
      # ['Power',     (p) -> format p, false, (s) -> indicators.power(s, stats)]      

      ['Completed', (p) -> format p, false, true,  (s) -> indicators.completed(s,stats) ]
      ['Success',   (p) -> format p, false, false,  (s) -> indicators.success(s,stats) ]     
      ['Not reset', (p) -> format p, false, false,  (s) -> "#{indicators.not_reset(s,stats)}"]            


      ['μ duration', (p) -> format p, true, false,  (s) -> indicators.avg_duration(s,stats)]      
      ['x͂ duration', (p) -> format p, true, false,  (s) -> indicators.median_duration(s,stats)]      

      ['In day', (p) -> format p, false, false, (s) -> indicators.in_day(s,stats) ]
      ['within hour', (p) -> format p, false, false, (s) -> indicators.in_hour(s,stats) ]

      ['μ return', (p) -> format p, false, false, (s) -> indicators.avg_return(s,stats)]      
      ['x͂ return', (p) -> format p, false, false, (s) -> indicators.median_return(s,stats)]      

      # ['μ loss',   (p) -> format p, false, false, (s) -> indicators.avg_loss(s,stats)]
      # ['x͂ loss',   (p) -> format p, false, false, (s) -> indicators.median_loss(s,stats)]

      # ['μ gain',   (p) -> format p, false, false, (s) -> indicators.avg_gain(s,stats)]
      # ['x͂ gain',   (p) -> format p, false, false, (s) -> indicators.median_gain(s,stats)]

      ]

    rows = @props.params
    rows.sort()

    {rows,cols}

  DIV 
    style:
      marginTop: 20

    METH_TABLE
      data: data
      header: "Parameters for #{@props.strategy}"
      dummy: focus



dom.PERFORMANCE = -> 
  stats = fetch 'stats'
  focus = fetch 'focus'
  time = fetch '/time'

  return SPAN(null, "Performance waiting for data") if compute_stats.loading() || @loading()


  data = -> 

    expanded = fetch 'expanded'

    if expanded.expanded 
      rows = dealers_in_focus
                include_strategies: true 
      rows.unshift 'all'
    else 
      rows = ['all']


    cols = [
      ['', (s) -> 
        SPAN 
          style: 
            color: if s == focus.highlighted then attention_magenta
            cursor: 'pointer'
            fontFamily: mono
          onClick: ->

            if s == 'all'
              expanded.expanded = !expanded.expanded
              save expanded
            else 
              if s == focus.highlighted 
                focus.highlighted = null
              else 
                focus.highlighted = s
              save focus 

          if s == 'all'
            SPAN
              style: 
                fontSize: 22
                display: 'inline-block'
              s 
          else 
            SPAN 
              style: 
                paddingLeft: 30
                display: 'inline-block'
                maxWidth: 600
                fontSize: 16

              s.replace(/&/g, ' ')
      ]]

    for name, calc of dealer_measures(stats)
      cols.push [name, calc]

    {cols,rows}

  
  DIV 
    style:
      marginTop: 20

    METH_TABLE
      data: data 
      header: 'Performance'
      dummy: focus.highlighted





dom.ACTIVITY = -> 
  focus = fetch 'focus'
  time = fetch '/time'

  @local.filter_to_incomplete ?= true

  return SPAN null if compute_stats.loading() || !cached_positions.all


  data = => 
    rows = []
    for dealer in dealers_in_focus()

      rows = (pos for pos in \
              cached_positions[dealer] when  (!@local.filter_to_incomplete || !pos.closed) \
                                        && ( (!@local.filter_to_rebalancing && !pos.rebalancing) || (@local.filter_to_rebalancing && pos.rebalancing)))

    rows = [].concat rows...

    for p in rows 
      p.__key ||= "#{p.dealer}-#{p.created}-#{p.closed}"

    rows.sort (a,b) -> (if b.closed then b.closed else b.created) - \
                       (if a.closed then a.closed else a.created)

    # rows.sort (a,b) -> b.created - a.created

    cols = [

      ['Strategy', (pos) -> ('/' + pos.dealer).replace(/_|&/g,' ')]
      ['Created', (pos) -> "#{pos.created}"] # prettyDate(pos.created) ]
      ['Time to enter', (pos) -> 
        SPAN 
          style: 
            textAlign: 'right'
          if pos.entry?.closed
            readable_duration(pos.entry.closed - pos.created)
      ]
      ['Duration', (pos) -> 
        SPAN 
          style: 
            textAlign: 'right'
          if pos.closed
            readable_duration(pos.closed - pos.created)
      ]
      ['Status', (pos) -> 
        if pos.closed
          SPAN null,
            SPAN 
              style: 
                color: 'green'
              prettyDate(pos.closed) 
        else if !pos.exit
          'open'
        else
          ''
      ]

      ['Entry', (pos) -> 
        SPAN 
          style: 
            color: if pos.rebalancing then feedback_orange
          if pos.entry?.closed then " #{prettyDate(pos.entry.closed)}" else ''
      ]
      ['', (pos) -> 
        SPAN 
          style: 
            fontFamily: mono
          if pos.entry then "#{pos.entry.type} #{pos.entry.amount?.toFixed(3)} @ #{pos.entry.rate?.toFixed(5)}" else '?'
      ]
      ['Exit', (pos) -> if pos.exit?.closed then " #{prettyDate(pos.exit.closed)}" else '-']
      ['', (pos) -> 
        SPAN 
          style: 
            fontFamily: mono
          if pos.exit 
            "#{pos.exit.type} #{pos.exit.amount.toFixed(3)} @ #{pos.exit.rate.toFixed(5)}"
      ]
      ['Earnings', (pos) -> 
        if pos.exit then "#{(pos.profit or pos.expected_profit)?.toFixed(3)} (#{(100 * (pos.profit or pos.expected_profit) / pos.exit.amount )?.toFixed(2)}%)" else '?']

    ]

    {rows, cols}

  DIV 
    style:
      marginTop: 20

    INPUT 
      id: 'incompletefilter'
      type: 'checkbox'
      defaultChecked: @local.filter_to_incomplete

      onChange: (e) =>
        @local.filter_to_incomplete = event.target.checked
        save @local
    LABEL 
      htmlFor: 'incompletefilter'
      'Filter to incomplete'


    INPUT 
      id: 'rebalancingfilter'
      type: 'checkbox'
      defaultChecked: @local.filter_to_rebalancing

      onChange: (e) =>
        @local.filter_to_rebalancing = event.target.checked
        save @local
    LABEL 
      htmlFor: 'rebalancingfilter'
      'Show rebalancing'


    METH_TABLE
      data: data 
      header: 'Activity'


dom.BANK = -> 
  balances = fetch '/balances'
  config = fetch '/config'
  price_data = fetch '/price_data'
  dealers = get_dealers()

  return SPAN null if Object.keys(balances).length == 1 || Object.keys(price_data).length == 1 || @loading()

  deposited = balances.deposits

  balance = balances.balances


  total_on_order = balances.on_order

  return SPAN null if !total_on_order

  currencies = [config.c1, config.c2] 

  data = ->
    balance_sum_from_dealers =
      c1: 0
      c2: 0


    last_period = price_data.c1xc2.length

    $c1 = price_data.c1?[last_period - 1].close or 1
    $c2 = price_data.c2?[last_period - 1].close or price_data.c1xc2?[last_period - 1].close



    balance_sum_from_positions = 
      c1: 0
      c2: 0


    for dealer in dealers
      positions = fetch(dealer).positions
      dealer = deslash(dealer)
      balance_sum_from_dealers.c2 += balances[dealer].balances.c2
      balance_sum_from_dealers.c1 += balances[dealer].balances.c1


      balance_sum_from_positions.c2 += balances[dealer].deposits.c2
      balance_sum_from_positions.c1 += balances[dealer].deposits.c1


      all_entries = (p.entry for p in positions when p.entry?.closed)
      all_exits = (p.exit for p in positions when p.exit?.closed) 

      all_trades = all_entries.concat all_exits

      xfee = balances.exchange_fee
      for trade in all_trades
        if trade.type == 'buy'
          for fill in (trade.fills or [])
            balance_sum_from_positions.c2 += fill.amount
            balance_sum_from_positions.c1 -= fill.total

            if config.exchange == 'poloniex'
              balance_sum_from_positions.c2 -= (if fill.fee? then fill.fee else fill.amount * xfee)
            else 
              balance_sum_from_positions.c1 -= (if fill.fee? then fill.fee else fill.total * xfee)

        else 
          for fill in (trade.fills or [])
            balance_sum_from_positions.c2 -= fill.amount
            balance_sum_from_positions.c1 += fill.total
            balance_sum_from_positions.c1 -= (if fill.fee? then fill.fee else fill.total * xfee)


      console.log 
        c1: balance_sum_from_positions.c1
        c2: balance_sum_from_positions.c2
        # c1_flat: btc 
        # c2_flat: eth
        # c1_on_order: btc_on_order
        # c2_on_order: eth_on_order
        c1_deposit: balances[dealer].deposits.c1
        c2_deposit: balances[dealer].deposits.c2


    checks = true 
    for currency in currencies
      checks &&= (balance_sum_from_positions[currency] or 0).toFixed(2) == (balance[currency] + total_on_order[currency]).toFixed(2) && \
              (balance_sum_from_dealers[currency] or 0).toFixed(2) == (balance[currency] or 0).toFixed(2)

    cols = [
      ['', (currency) -> config[currency]]
      ['In bank', (currency) -> "#{(balance[currency] + total_on_order[currency]).toFixed(2)}"]
      if !checks 
        ['Double check', (currency) -> ((balance_sum_from_positions[currency] or 0) - (balance[currency] + total_on_order[currency])  ).toFixed(2)]
      ['Available', (currency) -> (balance_sum_from_dealers[currency] or 0).toFixed(2)]
      # if !checks
      #   ['Double check', (currency) -> ((balance[currency] or 0) - (balance_sum_from_dealers[currency] or 0)).toFixed(2)]

      ['Deposited', (currency) -> (deposited[currency] or 0).toFixed(2)]
      ['Change', (currency) -> 

        val = (balance[currency] + total_on_order[currency]) - (deposited[currency] or 0)

        SPAN 
          style: 
            color: if val < 0 then bright_red else ecto_green
            fontFamily: mono
          val.toFixed(2)
      ]

      ['$ of holding', (currency) -> 
        if currency == 'c2'
          "$#{($c2 * deposited.c2).toFixed(2)}"
        else 
          "$#{($c1 * deposited.c1).toFixed(2)}"
      ]
      ['$ of trading', (currency) -> 
        if currency == 'c2'
          "$#{($c2 * balance_sum_from_positions.c2).toFixed(2)}"
        else 
          "$#{($c1 * balance_sum_from_positions.c1).toFixed(2)}"
      ]
      ['Gain', (currency) -> 
        if currency == 'c2'
          val = $c2 * balance_sum_from_positions.c2 - $c2 * deposited.c2
        else 
          val = $c1 * balance_sum_from_positions.c1 - $c1 * deposited.c1
        SPAN 
          style: 
            color: if val < 0 then bright_red else ecto_green
            fontFamily: mono
          "$#{val.toFixed(2)}"

      ]

    ]

    {
      cols: (c for c in cols when c)
      rows: ["c1", "c2"]
    }

  DIV 
    style: 
      display: 'inline-block'
      verticalAlign: 'top'

    METH_TABLE
      data: data


dom.METH_TABLE = -> 

  data = @props.data()
  cols = data.cols 
  rows = data.rows 

  DIV 
    style: 
      #paddingLeft: 14
      color: '#ccc'

    # PULSE
    #   key: 'pulse'
    #   public_key: fetch('ACTIVITY_pulse').key
    #   interval: 60 * 1000

    TABLE 
      style: 
        borderCollapse: 'collapse'

      TBODY null, 
        TR {},                

          for col, idx in cols 
            TD 
              style: 
                padding: '5px 8px'
                fontWeight: 600
                textAlign: if idx != 0 then 'right'
                #color: ecto_green
              col[0]

        for item, idx in rows 

          TR 
            key: item.key or item.__key or item
            style:
              backgroundColor: if idx % 2 && rows.length > 3 then '#222'

            for col, idx in cols 
              v = col[1](item)

              TD 
                style: 
                  padding: '5px 8px'
                  textAlign: if idx != 0 then 'right'
                  fontFamily: if v && Math.is_num(v) then mono

                v

    @props.more?()




# PULSE
# Any component that renders a PULSE will get rerendered on an interval.
# props: 
#   public_key: the key to store the heartbeat at
#   interval: length between pulses, in ms (default=1000)
dom.PULSE = ->   
  beat = fetch(@props.public_key)
  setTimeout ->    
    beat.beat = (beat.beat or 0) + 1
    save(beat)
  , (@props.interval or 1000)

  SPAN null



dom.LOADING_METH = -> 
  @local.pulses ?= 0 
  @local.pulses += 1

  DIV 
    style: 
      textAlign: 'center'
      paddingTop: 100
      paddingBottom: 200

    PULSE 
      public_key: fetch('logo-pulse').key
      interval: 100

    SVG 
      viewBox: '0 0 32 32'
      
      style: 
        display: 'block'
        margin: 'auto'
        width: 360
      
      G 
        id:"lab_1_"

        # beaker
        PATH
          d: "M20.682,3.732C20.209,3.26,19.582,3,18.914,3s-1.295,0.26-1.77,0.733l-1.41,1.412   C15.261,5.617,15,6.245,15,6.914c0,0.471,0.129,0.922,0.371,1.313L1.794,13.666c-0.908,0.399-1.559,1.218-1.742,2.189   c-0.185,0.977,0.125,1.979,0.834,2.687l12.72,12.58c0.548,0.548,1.276,0.859,2.045,0.877C15.669,32,15.711,32,15.729,32   c0.202,0,0.407-0.021,0.61-0.062c0.994-0.206,1.808-0.893,2.177-1.828l5.342-13.376c0.402,0.265,0.875,0.407,1.367,0.407   c0.67,0,1.297-0.261,1.768-0.733L28.4,15c0.477-0.474,0.738-1.103,0.738-1.773s-0.262-1.3-0.732-1.768L20.682,3.732z    M16.659,29.367c-0.124,0.313-0.397,0.544-0.727,0.612c-0.076,0.016-0.153,0.022-0.229,0.021c-0.254-0.006-0.499-0.108-0.682-0.292   L2.293,17.12c-0.234-0.233-0.337-0.567-0.275-0.893c0.061-0.324,0.279-0.598,0.582-0.73l6.217-2.49   c4.189,1.393,8.379,0.051,12.57,4.522L16.659,29.367z M26.992,13.58l-1.414,1.413c-0.195,0.196-0.512,0.196-0.707,0l-1.768-1.767   l-1.432,3.589l0.119-0.303c-3.01-3.005-6.069-3.384-8.829-3.723c-0.887-0.109-1.747-0.223-2.592-0.405l8.491-3.401l-1.715-1.715   c-0.195-0.195-0.195-0.512,0-0.707l1.414-1.415c0.195-0.195,0.512-0.195,0.707,0l7.725,7.727   C27.189,13.068,27.189,13.385,26.992,13.58z" 
          fill: "#333333"

        # big inside
        PATH 
          d: "M16.5,21c1.378,0,2.5-1.121,2.5-2.5S17.879,16,16.5,16c-1.379,0-2.5,1.121-2.5,2.5S15.122,21,16.5,21z    M16.5,17c0.828,0,1.5,0.672,1.5,1.5S17.328,20,16.5,20c-0.829,0-1.5-0.672-1.5-1.5S15.671,17,16.5,17z" 
          fill: "#333333"
        # big outside
        PATH
          d: "M29.5,0C28.121,0,27,1.121,27,2.5S28.121,5,29.5,5S32,3.879,32,2.5S30.879,0,29.5,0z M29.5,4   C28.672,4,28,3.328,28,2.5S28.672,1,29.5,1S31,1.672,31,2.5S30.328,4,29.5,4z" 
          fill: '#333'
        # small inside
        PATH 
          d: "M8,17c0,1.103,0.897,2,2,2s2-0.897,2-2s-0.897-2-2-2S8,15.897,8,17z M10,16c0.552,0,1,0.447,1,1   s-0.448,1-1,1s-1-0.447-1-1S9.448,16,10,16z" 
          fill: ecto_green

        #inside 
        CIRCLE 
          cx: "13" 
          cy: "23" 
          fill: "#FF700A" 
          r: "1"
        #outside
        CIRCLE
          cx: "29" 
          cy: "8" 
          fill: bright_red
          r: "1"

    DIV 
      style: 
        width: 175
        textAlign: 'center'
        margin: '60px auto'

      SVG 
        viewBox: "0 0 175 70" 
        
        style: 
          display: 'block'
          width: 175

        G null,
          PATH
            fill: "#70FF0A"
            d: "M27.7314453,20.1171875 L40.3554688,2.98242188 C40.880211,2.25585574 41.6067662,1.67057514 42.5351562,1.2265625 C43.4433639,0.782549863 44.4423774,0.540364785 45.5322266,0.5 C46.2991575,0.5 46.9954396,0.590819404 47.6210938,0.772460938 C48.4082071,0.974284863 49.1549444,1.32747144 49.8613281,1.83203125 C50.5878943,2.35677346 51.1227196,2.9723272 51.4658203,3.67871094 C51.6878266,4.16308836 51.8089192,4.66764061 51.8291016,5.19238281 L55.3710938,43.9423828 L55.3710938,44.09375 C55.3710938,45.0826872 54.9573609,45.9908813 54.1298828,46.8183594 C52.959304,48.0696677 51.385101,48.7356767 49.4072266,48.8164062 L49.2558594,48.8164062 C47.3183497,48.8164062 45.7441467,48.2109436 44.5332031,47 C43.6249955,46.1119747 43.1406253,45.1533255 43.0800781,44.1240234 L40.9609375,21.1767578 C34.9869493,29.9964634 30.5771627,34.40625 27.7314453,34.40625 C24.6031745,34.40625 20.1530237,29.9661902 14.3808594,21.0859375 L12.2617188,42.3076172 C12.2415364,43.3571016 11.7773483,44.3258419 10.8691406,45.2138672 C9.59764989,46.4046283 8.02344688,47 6.14648438,47 L5.99511719,47 C3.99706032,46.9192704 2.40267522,46.2532615 1.21191406,45.0019531 C0.404618359,44.1341102 0.0009765625,43.2057341 0.0009765625,42.2167969 L0.0009765625,42.15625 L3.63378906,5.19238281 C3.65397146,4.66764061 3.77506399,4.16308836 3.99707031,3.67871094 C4.34017099,2.9723272 4.86490532,2.35677346 5.57128906,1.83203125 C6.23730802,1.32747144 6.98404534,0.974284863 7.81152344,0.772460938 C8.41699521,0.590819404 9.10318627,0.5 9.87011719,0.5 C10.9801488,0.540364785 11.938798,0.762367773 12.7460938,1.16601562 C13.7552134,1.65039305 14.5423149,2.25585574 15.1074219,2.98242188 L27.7314453,20.1171875 Z M60.9716797,7.64453125 C60.3863903,6.99869469 60.09375,6.20150214 60.09375,5.25292969 C60.09375,4.22362767 60.6487575,3.16406795 61.7587891,2.07421875 C62.7880911,1.04491673 64.2815657,0.530273438 66.2392578,0.530273438 L92.4863281,0.530273438 C94.4440202,0.530273438 95.9374949,1.04491673 96.9667969,2.07421875 C98.0768285,3.16406795 98.6318359,4.23371871 98.6318359,5.28320312 C98.6318359,6.35286993 98.0768285,7.42252069 96.9667969,8.4921875 C95.9374949,9.52148952 94.4440202,10.0361328 92.4863281,10.0361328 L73.171875,10.0361328 L73.171875,24.8701172 L89.2167969,24.8701172 C91.1946713,24.8701172 92.698237,25.3948515 93.7275391,26.4443359 C94.8173883,27.5341851 95.3623047,28.5937449 95.3623047,29.6230469 C95.3623047,30.6927137 94.766933,31.8330018 93.5761719,33.0439453 C92.6477818,33.9723354 91.1946713,34.4365234 89.2167969,34.4365234 L73.0507812,34.4365234 L73.0507812,37.4335938 L92.8798828,37.4335938 C94.8375749,37.4335938 96.3310495,37.9583281 97.3603516,39.0078125 C98.4502008,40.0976617 98.9951172,41.1572214 98.9951172,42.1865234 C98.9951172,43.2360079 98.3997455,44.3662049 97.2089844,45.5771484 C96.2805943,46.5055385 94.8375749,46.9697266 92.8798828,46.9697266 L67.0869141,47 C65.9567001,47 65.0081419,46.8183612 64.2412109,46.4550781 C63.6962863,46.1725246 63.2522804,45.9101575 62.9091797,45.6679688 C61.6175066,44.6790315 60.9716797,43.5286524 60.9716797,42.2167969 L60.9716797,7.64453125 Z M125.575195,10.7021484 L125.575195,42.9736328 C125.555013,44.0432996 125.080734,45.0019489 124.152344,45.8496094 C122.901035,47.0403705 121.336923,47.6357422 119.459961,47.6357422 L119.308594,47.6357422 C117.330719,47.6155598 115.736334,46.9596419 114.525391,45.6679688 C113.697913,44.8203083 113.28418,43.9020232 113.28418,42.9130859 L113.28418,10.7021484 L105.927734,10.7021484 C103.970042,10.7021484 102.527023,10.2379604 101.598633,9.30957031 C100.407872,8.11880915 99.8125,6.99870316 99.8125,5.94921875 C99.8125,4.91991673 100.246415,3.96126746 101.114258,3.07324219 C102.365566,1.82193385 103.970042,1.19628906 105.927734,1.19628906 L132.205078,1.19628906 C134.16277,1.19628906 135.60579,1.66047713 136.53418,2.58886719 C137.724941,3.77962835 138.320312,4.88964329 138.320312,5.91894531 C138.320312,6.98861212 137.724941,8.11880915 136.53418,9.30957031 C135.60579,10.2379604 134.16277,10.7021484 132.205078,10.7021484 L125.575195,10.7021484 Z M149.279297,34.9814453 L149.279297,43.1552734 C149.279297,44.1845755 148.8252,45.1533158 147.916992,46.0615234 C146.645501,47.2522846 145.061207,47.8476562 143.164062,47.8476562 L142.982422,47.8476562 C141.02473,47.7669267 139.450527,47.1009177 138.259766,45.8496094 C137.432288,45.0019489 137.018555,44.0735728 137.018555,43.0644531 L137.018555,6.04003906 C137.058919,4.99055465 137.533199,4.02181434 138.441406,3.13378906 C139.712897,1.9430279 141.2871,1.34765625 143.164062,1.34765625 L143.254883,1.34765625 C145.232757,1.40820343 146.847324,2.06412135 148.098633,3.31542969 C148.885746,4.20345496 149.279297,5.14192214 149.279297,6.13085938 L149.279297,25.4453125 L162.024414,25.4453125 L162.024414,5.34375 C162.044596,4.2539008 162.518876,3.28516049 163.447266,2.4375 C164.698574,1.24673884 166.262686,0.651367188 168.139648,0.651367188 L168.291016,0.651367188 C170.248708,0.691731973 171.843093,1.34764989 173.074219,2.61914062 C173.901697,3.46680111 174.31543,4.39517725 174.31543,5.40429688 L174.31543,42.4589844 C174.295247,43.4882864 173.820968,44.4570267 172.892578,45.3652344 C171.621087,46.5559955 170.036793,47.1513672 168.139648,47.1513672 L167.988281,47.1513672 C166.010407,47.0706376 164.436204,46.4046287 163.265625,45.1533203 C162.438147,44.3056598 162.024414,43.3772837 162.024414,42.3681641 L162.024414,34.9814453 L149.279297,34.9814453 Z" 


          # PATH
          #   fill: "#424242"
          #   d: "M33.8320312,89.3203125 C33.4492168,88.9843733 33.2578125,88.5937522 33.2578125,88.1484375 L33.2578125,73.8164062 C33.2734376,73.4023417 33.4570295,73.0273454 33.8085938,72.6914062 C34.3007837,72.2304664 34.9101526,72 35.6367188,72 L35.671875,72 C36.4375038,72.0156251 37.0624976,72.273435 37.546875,72.7734375 C37.851564,73.1093767 38.0039062,73.4648419 38.0039062,73.8398438 L38.0039062,86.296875 L44.4492188,86.296875 C45.2226601,86.296875 45.8046855,86.499998 46.1953125,86.90625 C46.6250021,87.3281271 46.8398438,87.7382793 46.8398438,88.1367188 C46.8398438,88.5429708 46.6054711,88.9804664 46.1367188,89.4492188 C45.777342,89.8085955 45.2187538,89.9882812 44.4609375,89.9882812 L35.6484375,90 L35.5664062,90 C34.8554652,89.9687498 34.277346,89.7421896 33.8320312,89.3203125 Z M56.1679688,79.9921875 C55.910155,79.9374997 55.6484388,79.9101562 55.3828125,79.9101562 C54.7578094,79.9101562 54.1054721,80.0859357 53.4257812,80.4375 C52.3007756,81.0234404 51.7109378,81.8906193 51.65625,83.0390625 C51.6484375,83.1171879 51.6445312,83.1953121 51.6445312,83.2734375 C51.6445312,84.2578174 51.9531219,85.1171838 52.5703125,85.8515625 C53.0625025,86.4218779 53.5820285,86.7070312 54.1289062,86.7070312 L54.2695312,86.7070312 C55.5664127,86.6210933 56.460935,86.0117244 56.953125,84.8789062 C57.2343764,84.2148404 57.375,83.5234411 57.375,82.8046875 C57.375,82.4687483 57.3437503,82.128908 57.28125,81.7851562 C57.1015616,80.7226509 56.7304716,80.1250007 56.1679688,79.9921875 Z M54.6445312,90.1523438 C54.4648429,90.1679688 54.2851571,90.1757812 54.1054688,90.1757812 C52.0585835,90.1757812 50.3359445,89.4023515 48.9375,87.8554688 C47.7187439,86.5195246 47.109375,85.0078209 47.109375,83.3203125 C47.109375,83.1874993 47.1132812,83.050782 47.1210938,82.9101562 C47.2382818,80.7851456 48.3788954,79.0820377 50.5429688,77.8007812 C52.0742264,76.8867142 53.6640543,76.4296875 55.3125,76.4296875 C56.0156285,76.4296875 56.7148403,76.5117179 57.4101562,76.6757812 C59.8164183,77.222659 61.273435,78.6367073 61.78125,80.9179688 C61.9140632,81.4882841 61.9804688,82.0546847 61.9804688,82.6171875 C61.9804688,83.8515687 61.6718781,85.0898375 61.0546875,86.3320312 C59.8749941,88.6679804 57.7382967,89.9414052 54.6445312,90.1523438 Z M70.4765625,89.9882812 C70.3046866,89.9960938 70.1367196,90 69.9726562,90 C68.7929629,90 67.6953176,89.6992218 66.6796875,89.0976562 C65.6953076,88.5039033 64.9179716,87.70313 64.3476562,86.6953125 C63.8164036,85.7499953 63.5390626,84.7617239 63.515625,83.7304688 L63.515625,83.5898438 C63.515625,82.535151 63.7851536,81.554692 64.3242188,80.6484375 C64.980472,79.5468695 65.9140564,78.6445348 67.125,77.9414062 C68.3046934,77.2539028 69.6132741,76.8359382 71.0507812,76.6875 C71.4492207,76.6406248 71.8398418,76.6171875 72.2226562,76.6171875 C73.2539114,76.6171875 74.2421828,76.7695297 75.1875,77.0742188 C76.578132,77.5039084 77.7343704,78.1992139 78.65625,79.1601562 C78.9531265,79.4726578 79.1015625,79.808592 79.1015625,80.1679688 L79.1015625,80.203125 C79.09375,80.5703143 78.9335953,80.9101547 78.6210938,81.2226562 C78.3710925,81.464845 78.2460938,81.5976561 78.2460938,81.6210938 L78.2578125,81.6210938 L78.984375,88.1835938 C78.9921875,88.2382815 78.9960938,88.2890623 78.9960938,88.3359375 C78.9960938,88.632814 78.8867198,88.9179674 78.6679688,89.1914062 C78.2695293,89.6757837 77.7382846,89.9531246 77.0742188,90.0234375 C76.9648432,90.0468751 76.8437507,90.0585938 76.7109375,90.0585938 C76.0859344,90.0585938 75.5507835,89.8750018 75.1054688,89.5078125 C74.7226543,89.2031235 74.5078127,88.5820359 74.4609375,87.6445312 C73.7812466,88.9726629 72.4531349,89.7539051 70.4765625,89.9882812 Z M71.015625,80.2265625 C69.8593692,80.5156264 69.0078152,81.1171829 68.4609375,82.03125 C68.164061,82.52344 68.015625,83.042966 68.015625,83.5898438 C68.015625,84.1601591 68.1718734,84.7343721 68.484375,85.3125 C68.7187512,85.7656273 69.0078108,86.1054676 69.3515625,86.3320312 C69.5703136,86.4804695 69.781249,86.5546875 69.984375,86.5546875 L70.03125,86.5429688 C70.9921923,86.4648434 71.8085904,85.7500068 72.4804688,84.3984375 C73.0820343,83.1874939 73.4414057,81.7500083 73.5585938,80.0859375 C72.3554627,80.0859375 71.507815,80.132812 71.015625,80.2265625 Z M90.9257812,81.046875 C90.3242157,80.3593716 89.625004,80.015625 88.828125,80.015625 C88.5156234,80.015625 88.1835955,80.0624995 87.8320312,80.15625 C87.277341,80.2968757 86.7656273,80.562498 86.296875,80.953125 C85.7421847,81.4218773 85.3867195,81.9843717 85.2304688,82.640625 C85.1914061,82.8359385 85.171875,83.0390614 85.171875,83.25 C85.171875,83.3437505 85.1757812,83.4374995 85.1835938,83.53125 C85.3242195,84.6562556 85.7578089,85.4765599 86.484375,85.9921875 C87.0703154,86.3984395 87.8203079,86.6015625 88.734375,86.6015625 L88.7695312,86.6015625 C89.6835983,86.59375 90.4023411,86.4492202 90.9257812,86.1679688 L90.9257812,81.046875 Z M89.484375,90.046875 C89.2109361,90.0625001 88.9414076,90.0703125 88.6757812,90.0703125 C86.6835838,90.0703125 84.964851,89.5664113 83.5195312,88.5585938 C81.8554604,87.4101505 80.9062512,85.8281351 80.671875,83.8125 C80.6484374,83.609374 80.6367188,83.406251 80.6367188,83.203125 C80.6367188,82.8281231 80.6835933,82.4453145 80.7773438,82.0546875 C81.0585952,80.8515565 81.7265572,79.7773485 82.78125,78.8320312 C84.6718845,77.4413993 86.5078036,76.7460938 88.2890625,76.7460938 C89.1640669,76.7460938 90.0234333,76.9140608 90.8671875,77.25 L90.8671875,74.0625 C90.875,73.6953107 91.0468733,73.3515641 91.3828125,73.03125 C91.8359398,72.5859353 92.4179652,72.3632812 93.1289062,72.3632812 L93.1992188,72.3632812 C93.9101598,72.3945314 94.4960914,72.6406227 94.9570312,73.1015625 C95.2539077,73.4062515 95.4023438,73.7382795 95.4023438,74.0976562 L95.4023438,88.4296875 C95.3945312,88.8125019 95.2265641,89.1601547 94.8984375,89.4726562 C94.4296852,89.917971 93.8476597,90.140625 93.1523438,90.140625 L93.09375,90.140625 C92.0703074,90.1171874 91.4492198,89.8437526 91.2304688,89.3203125 C90.7539039,89.7265645 90.1718784,89.9687496 89.484375,90.046875 Z M103.242188,88.3359375 C103.242188,88.7031268 103.07422,89.0507796 102.738281,89.3789062 C102.269529,89.8164084 101.683597,90.0351562 100.980469,90.0351562 L100.933594,90.0351562 C100.191403,90.0117186 99.5976585,89.7656273 99.1523438,89.296875 C98.8554673,88.992186 98.7070312,88.6640643 98.7070312,88.3125 L98.7070312,78.140625 C98.7148438,77.7734357 98.8867171,77.4296891 99.2226562,77.109375 C99.6835961,76.6640603 100.265621,76.4414062 100.96875,76.4414062 L101.015625,76.4414062 C101.765629,76.4492188 102.363279,76.6953101 102.808594,77.1796875 C103.097658,77.4921891 103.242188,77.824217 103.242188,78.1757812 L103.242188,88.3359375 Z M103.371094,73.9335938 C103.324219,75.2773505 102.546883,75.9492188 101.039062,75.9492188 L100.980469,75.9492188 C99.4648362,75.9101561 98.7070312,75.2578188 98.7070312,73.9921875 L98.7070312,73.8867188 C98.7304689,73.5117169 98.9140608,73.1562517 99.2578125,72.8203125 C99.7421899,72.3984354 100.33984,72.1875 101.050781,72.1875 L101.097656,72.1875 C101.839847,72.1953125 102.398436,72.3906231 102.773438,72.7734375 C103.171877,73.1796895 103.371094,73.558592 103.371094,73.9101562 L103.371094,73.9335938 Z M110.542969,79.3710938 C111.886725,77.9101489 113.468741,77.1796875 115.289062,77.1796875 L115.382812,77.1796875 C116.398443,77.1875 117.328121,77.4296851 118.171875,77.90625 C120.09376,79.0000055 121.054688,80.9296737 121.054688,83.6953125 C121.054688,85.804698 120.222665,88.3320165 118.558594,91.2773438 C118.285155,91.7617212 117.828128,92.0898429 117.1875,92.2617188 C116.945311,92.3242191 116.69922,92.3554688 116.449219,92.3554688 C116.003904,92.3554688 115.574221,92.2460948 115.160156,92.0273438 C114.675779,91.7539049 114.375001,91.4023459 114.257812,90.9726562 C114.21875,90.8476556 114.199219,90.7265631 114.199219,90.609375 C114.199219,90.3984364 114.261718,90.1835948 114.386719,89.9648438 C115.808601,87.4492062 116.519531,85.3593833 116.519531,83.6953125 C116.519531,81.6562398 116.109379,80.6367188 115.289062,80.6367188 C114.171869,80.6367188 113.128911,81.437492 112.160156,83.0390625 C111.214839,84.6093829 110.675782,86.2929598 110.542969,88.0898438 C110.519531,88.4648456 110.328127,88.8124984 109.96875,89.1328125 C109.492185,89.531252 108.929691,89.7304688 108.28125,89.7304688 L108.164062,89.7304688 C107.421871,89.6835935 106.843752,89.4257836 106.429688,88.9570312 C106.148436,88.6601548 106.007812,88.3359393 106.007812,87.984375 L106.007812,78.2695312 C106.023438,77.8867168 106.203123,77.5351579 106.546875,77.2148438 C107.015627,76.7929666 107.605465,76.5820312 108.316406,76.5820312 C109.082035,76.5976563 109.683592,76.8476538 110.121094,77.3320312 C110.402345,77.6289077 110.542969,77.9531232 110.542969,78.3046875 L110.542969,79.3710938 Z M129.316406,85.40625 C130.121098,85.3515622 130.714842,85.0468778 131.097656,84.4921875 C131.542971,83.8515593 131.777344,82.9609432 131.800781,81.8203125 C131.652343,81.015621 131.289065,80.4882825 130.710938,80.2382812 C130.460936,80.1054681 130.203126,80.0390625 129.9375,80.0390625 C129.773437,80.0390625 129.566407,80.066406 129.316406,80.1210938 C128.644528,80.2773445 128.144533,80.6054662 127.816406,81.1054688 C127.51953,81.5351584 127.371094,82.027341 127.371094,82.5820312 C127.371094,82.7460946 127.386719,82.9140616 127.417969,83.0859375 C127.511719,83.7734409 127.777342,84.3593726 128.214844,84.84375 C128.54297,85.1953143 128.910154,85.3828124 129.316406,85.40625 Z M135.386719,91.078125 C135.808596,91.7343783 136.019531,92.3554658 136.019531,92.9414062 C136.019531,93.6445348 135.74219,94.3476527 135.1875,95.0507812 C134.156245,96.394538 132.73829,97.1953112 130.933594,97.453125 C130.527342,97.5078128 130.125002,97.5351562 129.726562,97.5351562 C127.710927,97.5351562 126.019538,96.7929762 124.652344,95.3085938 C123.972653,94.55859 123.515626,93.7187546 123.28125,92.7890625 C123.179687,92.3749979 123.128906,91.9609396 123.128906,91.546875 C123.128906,91.0156223 123.214843,90.4765652 123.386719,89.9296875 C123.511719,89.4765602 123.824216,89.121095 124.324219,88.8632812 C124.707033,88.6523427 125.128904,88.546875 125.589844,88.546875 C125.863283,88.546875 126.128905,88.5859371 126.386719,88.6640625 C126.996097,88.8437509 127.433592,89.1757788 127.699219,89.6601562 C127.800782,89.8789073 127.851562,90.0859365 127.851562,90.28125 C127.851562,90.3984381 127.832031,90.5195306 127.792969,90.6445312 C127.699218,90.9648454 127.652344,91.2773422 127.652344,91.5820312 C127.652344,92.2851598 127.898435,92.8906225 128.390625,93.3984375 C128.828127,93.8437522 129.292966,94.0664062 129.785156,94.0664062 C129.894532,94.0664062 130.019531,94.0546876 130.160156,94.03125 C130.394532,94.0078124 130.64453,93.9062509 130.910156,93.7265625 C131.246095,93.5156239 131.421875,93.257814 131.4375,92.953125 L131.4375,92.9296875 C131.4375,91.5546806 130.785163,90.562503 129.480469,89.953125 C128.16015,89.3515595 127.46875,88.730472 127.40625,88.0898438 C126.124994,88.0898438 125.058598,87.4257879 124.207031,86.0976562 C123.40234,85.0585886 122.960938,84.0156302 122.882812,82.96875 C122.867187,82.8203118 122.859375,82.6718757 122.859375,82.5234375 C122.859375,81.3671817 123.195309,80.3281296 123.867188,79.40625 C124.79688,78.101556 126.222647,77.2304709 128.144531,76.7929688 C128.761722,76.6445305 129.371091,76.5703125 129.972656,76.5703125 C131.191412,76.5703125 131.871093,76.6093746 132.011719,76.6875 C132.26172,76.0703094 133.312491,75.5312523 135.164062,75.0703125 C135.390626,74.9999996 135.624999,74.9648438 135.867188,74.9648438 C136.375003,74.9648438 136.785155,75.062499 137.097656,75.2578125 C137.652347,75.6015642 137.984374,75.9882791 138.09375,76.4179688 C138.117188,76.5273443 138.128906,76.6289058 138.128906,76.7226562 C138.128906,76.9492199 138.019532,77.2460919 137.800781,77.6132812 C137.589843,77.957033 137.164066,78.2070305 136.523438,78.3632812 C136.085935,78.4726568 135.867188,78.7421854 135.867188,79.171875 C135.867188,79.4375013 135.943359,79.7636699 136.095703,80.1503906 C136.248048,80.5371113 136.324219,81.0624967 136.324219,81.7265625 C136.324219,83.22657 135.957035,84.6054625 135.222656,85.8632812 C134.511715,87.0820373 132.964856,87.8437485 130.582031,88.1484375 C133.41017,89.5312569 135.011717,90.5078096 135.386719,91.078125 Z M143.976562,88.8164062 C143.9375,89.1992207 143.699221,89.539061 143.261719,89.8359375 C142.792966,90.1640641 142.257816,90.328125 141.65625,90.328125 C141.531249,90.328125 141.421875,90.3242188 141.328125,90.3164062 C140.453121,90.2304683 139.85547,89.9179714 139.535156,89.3789062 C139.386718,89.1367175 139.3125,88.8007834 139.3125,88.3710938 C139.3125,88.0195295 139.542966,87.6484395 140.003906,87.2578125 C140.386721,86.9218733 140.941403,86.7539062 141.667969,86.7539062 C142.371097,86.7539062 142.968748,86.9570292 143.460938,87.3632812 C143.835939,87.6835954 144.023438,88.0195295 144.023438,88.3710938 C144.023438,88.4882818 144.007813,88.6367179 143.976562,88.8164062 Z M151.980469,88.8164062 C151.941406,89.1992207 151.703127,89.539061 151.265625,89.8359375 C150.796873,90.1640641 150.261722,90.328125 149.660156,90.328125 C149.535156,90.328125 149.425782,90.3242188 149.332031,90.3164062 C148.457027,90.2304683 147.859377,89.9179714 147.539062,89.3789062 C147.390624,89.1367175 147.316406,88.8007834 147.316406,88.3710938 C147.316406,88.0195295 147.546873,87.6484395 148.007812,87.2578125 C148.390627,86.9218733 148.945309,86.7539062 149.671875,86.7539062 C150.375004,86.7539062 150.972654,86.9570292 151.464844,87.3632812 C151.839846,87.6835954 152.027344,88.0195295 152.027344,88.3710938 C152.027344,88.4882818 152.011719,88.6367179 151.980469,88.8164062 Z M159.984375,88.8164062 C159.945312,89.1992207 159.707033,89.539061 159.269531,89.8359375 C158.800779,90.1640641 158.265628,90.328125 157.664062,90.328125 C157.539062,90.328125 157.429688,90.3242188 157.335938,90.3164062 C156.460933,90.2304683 155.863283,89.9179714 155.542969,89.3789062 C155.394531,89.1367175 155.320312,88.8007834 155.320312,88.3710938 C155.320312,88.0195295 155.550779,87.6484395 156.011719,87.2578125 C156.394533,86.9218733 156.949215,86.7539062 157.675781,86.7539062 C158.37891,86.7539062 158.97656,86.9570292 159.46875,87.3632812 C159.843752,87.6835954 160.03125,88.0195295 160.03125,88.3710938 C160.03125,88.4882818 160.015625,88.6367179 159.984375,88.8164062 Z" 


      DIV 
        style: 
          fontSize: 14
          color: '#666'
          fontWeight: 700
          opacity: if (@local.pulses % 50) < 25 then 1 else .2
          transition: 'opacity 5s'

        @props.status



get_short_name = (full_name) -> 
  dealers = dealers_in_focus()
  attrs = {}

  myclss = dealer_params(full_name)[0]
  inclss = 0
  for dealer in dealers 
    clss = dealer_params(dealer)[0]

    continue if clss != myclss
    inclss += 1
    for attr, idx in dealer_params(dealer)
      continue if idx == 0 

      attrs[attr] ?= 0
      attrs[attr] += 1

  parts = dealer_params(full_name)
  short_name = (p for p,idx in parts when attrs[p] < inclss || idx == 0).join()
  short_name


capitalize = (string) -> string.charAt(0).toUpperCase() + string.substring(1)


# ######################
# # Style
# ######################

light_blue = 'rgba(139, 213, 253,1)'
feedback_orange = '#F19135'
attention_magenta = '#FF00A4'
bright_red = 'rgba(246, 36, 4, 1)'
ecto_green = "rgba(112, 255, 10, 1)"


window.css_reset = -> 
  style = document.createElement "style"
  style.innerHTML =   """
    * {box-sizing: border-box;}
    html, body {margin: 0; padding: 0;}
    .grab_cursor {
      cursor: move;
      cursor: grab;
      cursor: ew-resize;
      cursor: -webkit-grab;
      cursor: -moz-grab;
    } .grab_cursor:active {
      cursor: move;
      cursor: grabbing;
      cursor: ew-resize;
      cursor: -webkit-grabbing;
      cursor: -moz-grabbing;
    }

    input, textarea {
      line-height: 22px;
    }

    /**
     * Eric Meyer's Reset CSS v2.0 
    (http://meyerweb.com/
    eric/tools/css/reset/)
     * http://cssreset.com
     */
    html, body, div, span, applet, object, iframe,
    h1, h2, h3, h4, h5, h6, p, blockquote, pre,
    a, abbr, acronym, address, big, cite, code,
    del, dfn, em, img, ins, kbd, q, s, samp,
    small, strike, strong, sub, sup, tt, var,
    b, u, i, center,
    dl, dt, dd, ol, ul, li,
    fieldset, form, label, legend,
    table, caption, tbody, tfoot, thead, tr, th, td,
    article, aside, canvas, details, embed, 
    figure, figcaption, footer, header, hgroup, 
    menu, nav, output, ruby, section, summary,
    time, mark, audio, video,
    input, textarea {
      margin: 0;
      padding: 0;
      border: 0;
      font-size: 100%;
      font: inherit;
      vertical-align: baseline;
    }
    /* HTML5 display-role reset for older browsers */
    article, aside, details, figcaption, figure, 
    footer, header, hgroup, menu, nav, section {
      display: block;
    }
    body {
      line-height: 1.4;
    }
    ol, ul {
      list-style: none;
    }
    blockquote, q {
      quotes: none;
    }
    blockquote:before, blockquote:after,
    q:before, q:after {
      content: '';
      content: none;
    }
    table {
      border-collapse: collapse;
      border-spacing: 0;
      color: inherit;
    }
    """
  document.head.appendChild style


css_reset()

# Takes an ISO time and returns a string representing how
# long ago the date represents.
# from: http://stackoverflow.com/questions/7641791
window.prettyDate = (time) ->
  time *= 1000
  date = new Date(time) #new Date((time || "").replace(/-/g, "/").replace(/[TZ]/g, " "))
  diff = (((new Date()).getTime() - date.getTime()) / 1000)

  return if isNaN(diff) || diff < 0

  dur = readable_duration(diff) + ' ago'

  dur

readable_duration = (secs) -> 
  if secs < 60 
    return "#{secs.toFixed(0)} sec"
  mins = secs / 60 
  if mins < 60
    return "#{mins.toFixed(0)} min"
  hrs = mins / 60
  if hrs < 24
    return "#{hrs.toFixed(1)} hrs"
  days = hrs / 24
  return "#{days.toFixed(2)} days"




cssTriangle = (direction, color, width, height, style) ->
  style = style or {}

  switch direction
    when 'top'
      border_width = "0 #{width/2}px #{height}px #{width/2}px"
      border_color = "transparent transparent #{color} transparent"
    when 'bottom'
      border_width = "#{height}px #{width/2}px 0 #{width/2}px"
      border_color = "#{color} transparent transparent transparent"
    when 'left'
      border_width = "#{height/2}px #{width}px #{height/2}px 0"
      border_color = "transparent #{color} transparent transparent"
    when 'right'
      border_width = "#{height/2}px 0 #{height/2}px #{width}px"
      border_color = "transparent transparent transparent #{color}"

  style = extend
    width: 0
    height: 0
    borderStyle: 'solid'
    borderWidth: border_width
    borderColor: border_color
    boxSizing: 'border-box'
  , style

  style

# fixed saturation & brightness; random hue
# adapted from http://martin.ankerl.com/2009/12/09/how-to-create-random-colors-programmatically/
golden_ratio_conjugate = 0.618033988749895

getNiceRandomHues = (num, seed) -> 
  h = seed or .5

  hues = []
  i = num
  while i > 0
    hues.push h % 1
    h += golden_ratio_conjugate
    i -= 1
  hues


hsv2rgba = (h,s,v,a) -> 
  a ||= 1
  h_i = Math.floor(h*6)
  f = h*6 - h_i
  p = v * (1 - s)
  q = v * (1 - f*s)
  t = v * (1 - (1 - f) * s)
  [r, g, b] = [v, t, p] if h_i==0
  [r, g, b] = [q, v, p] if h_i==1
  [r, g, b] = [p, v, t] if h_i==2
  [r, g, b] = [p, q, v] if h_i==3
  [r, g, b] = [t, p, v] if h_i==4
  [r, g, b] = [v, p, q] if h_i==5

  "rgba(#{Math.round(r*256)}, #{Math.round(g*256)}, #{Math.round(b*256)}, #{a})"
