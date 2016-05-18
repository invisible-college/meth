
bus.honk = false
bus.dev_with_single_client = false

font = 'Coda'
mono = 'Courier new'
special = 'Coda'

fonts = []
for f in [font, mono, special] when !(f in ['Courier new'])
  fonts.push f if fonts.indexOf(f) == -1

include '/code/meth/shared.coffee', null, codebus

loaded = false

fetch '/balances'

dom.DASH = ->
  fetch 'include'
  fetch '/all_data'

  downloading = @loading() || !extend? 

  if !downloading && !loaded
    strategy_filter()
    compute_stats()
    loaded = true

  computing = compute_stats.loading() || strategy_filter.loading() 

  DIV
    style:
      fontFamily: font
      minHeight: 1000
      padding: 0
      margin: 0
      backgroundColor: 'black'
      width: '100%'
      color: 'white'

    for f in fonts
      LINK
        key: f
        href: "http://fonts.googleapis.com/css?family=#{f}:200,300,400,500,700"
        rel: 'stylesheet'
        type: 'text/css'


    if downloading
      SPAN(null, "Downloading stuff!") 

    else if computing 
      SPAN(null, "Computing stuff!") 

    if !downloading
      DIV null, 
        HEADER key: 'header'

        DIV
          key: 'main'
          style:
            padding: "80px 40px"

          GRAPH_TIME_VS_RATE
            key: 'graphs'
            segment: 'all'

          PERFORMANCE key: 'performance'

          TUNING key: 'tuning'

          ACTIVITY key: 'table'


strategy_filter = bus.reactive -> 
  focus = fetch 'focus'

  strategies = fetch('/strategies')?.strategies

  inactive = (s for s in strategies when get_settings(s)?.retired )

  return if strategy_filter.loading()

  highlighted = focus.highlighted or []

  filtered = [] #inactive.concat ['bullish_indicator']

  params = focus.params or {}

  for strategy in strategies 
    parts = strategy.split('&')
    s = parts[0]
    params[s] ||= []    
    for param in params[s] 
      if s != strategy && parts.indexOf(param) == -1 && filtered.indexOf(strategy) == -1
        filtered.push strategy 

  if JSON.stringify(focus.highlighted) != JSON.stringify(highlighted) ||
     JSON.stringify(focus.filtered) != JSON.stringify(filtered) ||
     JSON.stringify(focus.params) != JSON.stringify(params)     
    extend focus, 
      highlighted: highlighted
      filtered: filtered
      params: params
    save focus


dom.STRATEGY_SELECTOR = -> 
  strategies = fetch('/strategies')?.strategies or []
  focus = fetch 'focus'
  stats = fetch 'stats'

  return SPAN null if compute_stats.loading() || strategy_filter.loading()


  DIV 
    style:
      padding: '5px 10px'
      maxHeight: 100
      overflow: 'scroll'

    DIV 
      style: 
        fontSize: 16
        paddingLeft: 12
        color: ecto_green
        fontWeight: 600
        fontStyle: 'italic'
      "Strategy selector"


    for strategy in strategies
      continue if strategy in (focus.filtered or [])
      do (strategy) =>
        DIV 
          style: 
            padding: '5px 12px'
            display: 'inline-block'
            cursor: 'pointer'
            fontSize: 16
            fontFamily: special          
            color: if strategy in (focus.highlighted or []) then attention_magenta else if @local.hover == strategy then 'white' else '#ccc'

          onClick: => 
            
            if strategy in (focus.highlighted or []) 
              focus.highlighted = []
            else 
              focus.highlighted = [strategy]
            save focus 

          onMouseEnter: => @local.hover = strategy; save @local 
          onMouseLeave: => @local.hover = null; save @local 

          "#{strategy.replace(/_|&/g, ' ')}"



dom.TUNING = ->
  stats = fetch 'stats'
  focus = fetch 'focus'

  return SPAN null if compute_stats.loading() || @loading() || strategy_filter.loading()

  instances = (s for s in Object.keys(stats) when s not in ['key','price'] && s not in focus.filtered)

  strategies = {}
  for i in instances 
    params = {}
    continue if stats[i].status.completed + stats[i].status.open == 0

    for part, idx in i.split('&')
      if idx == 0 
        name = part 
        strategies[name] ||=
          instances: []
          params: []
        strategies[name].instances.push i 

      else if strategies[name].params.indexOf(part) == -1
        strategies[name].params.push part

  DIV 
    style:
      marginTop: 20

    for strategy, params of strategies when strategy != 'all' && Object.keys(params.params).length > 0 
      TUNE_STRATEGY
        key: strategy
        strategy: strategy
        instances: params.instances
        params: params.params
        stats: stats
        time: fetch('/time')


dom.TUNE_STRATEGY = ->
  stats = @props.stats
  time = @props.time
  @local.fixed_params ||= {}
  focus = fetch 'focus'

  performance_of = (param, metric) => 

    p = param.split('=')[0]
    selected = @local.fixed_params[param]
    other_val_selected = @local.fixed_params[p] && !selected

    return '-' if other_val_selected

    to_match = (p for p,_ of @local.fixed_params when p.indexOf('=') > -1)
    to_match.push param if !selected

    does = [] 
    doesnt = []

    for instance in @props.instances 

      matches = true 
      passes = true
      for p in to_match
        parts = instance.split('&')
        matches &&= parts.indexOf(p) > -1
        if p != param || selected
          passes &&= parts.indexOf(p) > -1

      continue if !passes 

      if matches
        does.push parseFloat metric instance
      else 
        doesnt.push parseFloat metric instance

    q = Math.quartiles does
    if doesnt.length > 0 
      q2 = Math.quartiles doesnt 
      (q.q1 + q.q2 + q.q3 - q2.q1 - q2.q2 - q2.q3) / 3
    else 
      (q.q1 + q.q2 + q.q3) / 3

  format = (p, flip, func) => 
    val = performance_of p, func

    param = p.split('=')[0]
    selected = @local.fixed_params[p]
    other_val_selected = @local.fixed_params[param] && !selected

    SPAN 
      style: 
        color: if (val > 0 && !flip) || (val < 0 && flip) then ecto_green else if val == 0 then '#888' else bright_red
        opacity: if other_val_selected then .2

      if val.toFixed
        "#{val.toFixed(2)}" 
      else 
        val

  cols = [
    ['Parameter', (p) => 

      param = p.split('=')[0]
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
            idx = focus.params[@props.strategy].indexOf(p)
            focus.params[@props.strategy].splice idx, 1
          else 
            @local.fixed_params[p] = 1
            @local.fixed_params[param] = 1
            focus.params[@props.strategy].push p

          save focus
          save @local

        p

    ]

    ['hScore',    (p) -> format p, false, (s) -> indicators.score(s, stats)]
    ['hProfit',   (p) -> format p, false, (s) -> indicators.profit(s,stats)]   
    # ['hETH:BTC',  (p) -> format p, false, (s) -> indicators.ratio(s, stats)]     
    ['stability', (p) -> format p, false, (s) -> indicators.stability(s, stats)]   
    ['hOpen',     (p) -> format p, true,  (s) -> indicators.open(s, stats)]      
    ['Power',     (p) -> format p, false, (s) -> indicators.power(s, stats)]      

    ['Completed', (p) -> format p, false, (s) -> indicators.completed(s,stats) ]
    ['Success',   (p) -> format p, false, (s) -> indicators.success(s,stats) ]     
    ['Reset', (p) -> format p, true, (s) -> "#{indicators.reset(s,stats)}"]            
    ['In day', (p) -> format p, false,(s) -> indicators.in_day(s,stats) ]
    # ['In 12 hours', (p) -> format p, false, (s) -> indicators.in_12hrs(s,stats) ]
    ['within hour', (p) -> format p, false, (s) -> indicators.in_hour(s,stats) ]
  ]

  params = @props.params
  params.sort()

  DIV 
    style:
      marginTop: 20

    METH_TABLE
      cols: cols 
      rows: params
      header: "Tune #{@props.strategy}"
      show_by_default: false 
      dummy: time.start 
      dummy2: time.end 
      dummy3: focus.filtered




strand_name = (name, include_parent) -> 
  parts = name.split('&')
  parent = parts.shift()

  hierarchy = strategy_hierarchy()

  if Object.keys(hierarchy[name].params).length > 0 
    all_params = {}
    for strand in (hierarchy[parent].children or [])
      for param, val of hierarchy[strand].params 
        all_params[param] ||= {}
        all_params[param][val] = true 

    differentiating_params = ( "#{param}=#{val}" for param, val of hierarchy[name].params \
                                            when Object.keys(all_params[param]).length > 1 )


    "#{if include_parent then parent + ": " else ''}#{differentiating_params.join(' ')}"  
  else 
    name

deconstruct_strand = (name) -> 
  parts = name.split('&')
  parent = parts.shift()
  params = {}

  if parts.length > 0 
    for p in parts 
      param = p.split('=')
      params[param[0]] = param[1]

    
  else 
    parent = 'all'

  {name, parent, params}

strategy_hierarchy = -> 
  # construct the hierarchy of strategies like: 
  #    all
  #      tug
  #         frame 10 / backoff .3
  #         frame 4 / backoff .5
  #      meanie 
  #         frame 10 / return 1.1
  #         frame 5 / return .8

  #focus = fetch 'focus'

  strands =  (strat for strat in (fetch('/strategies').strategies or []) when !get_settings(strat).series)
  strategies = {}

  root = strategies.all =
    name: 'all'
    children: []

  for strand in strands 
    strand = deconstruct_strand strand 
    # continue if strand in focus.filtered


    if strand.parent != 'all' && !strategies[strand.parent]
      strategies[strand.parent] = 
        name: strand.parent
        parent: 'all'
        children: []
      root.children.push strand.parent

    strategies[strand.name] = strand
    strategies[strand.parent].children.push strand.name
  strategies


dom.PERFORMANCE = -> 
  stats = fetch 'stats'
  focus = fetch 'focus'
  time = fetch '/time'

  return SPAN(null, "Performance waiting for data") if compute_stats.loading() || @loading() || strategy_filter.loading()

  if focus.highlighted?.length > 0
    strat = focus.highlighted[0]
  else 
    strat = 'all'

  expanded = fetch 'expanded'
  expanded.expanded ||= {}

  hierarchy = strategy_hierarchy()

  rows = []
  # depth first traversal of strategy hierarchy...
  df = (strat) -> 
    if !(strat in focus.filtered)
      rows.push strat.name 
      if expanded.expanded[strat.name]
        for child in strat.children
          df hierarchy[child]

  df hierarchy.all 


  cols = [
    ['', (s) -> 
      SPAN 
        style: 
          color: if (s in focus.highlighted) then attention_magenta
          cursor: 'pointer'
          fontFamily: mono
        onClick: ->
          if s in focus.highlighted 
            focus.highlighted = []
          else 
            focus.highlighted = [s]
          save focus 

          if hierarchy[s].children 
            expanded.expanded[s] = s in focus.highlighted
            save expanded

        if s == 'all' || hierarchy[s].parent == 'all'
          SPAN
            style: 
              fontSize: 22
              paddingLeft: if hierarchy[s].parent then 20
              paddingTop: if hierarchy[s].parent then 8
              display: 'inline-block'
            s 
        else 
          SPAN 
            style: 
              paddingLeft: 30
              display: 'inline-block'
              maxWidth: 600
              fontSize: 16
            strand_name s, false 
    ]

    ['Profit*', (s) -> 
      if s of stats 
        (indicators.profit(s,stats) or 0).toFixed(0)] 

    ['Score*', (s) -> 
      if s of stats 
        (indicators.score(s,stats)).toFixed(1)]    

    # ['hETH:BTC', (s) -> (indicators.ratio(s,stats)).toFixed(2)]      
    ['Stability*', (s) -> 
      if s of stats
        (indicators.stability(s,stats)).toFixed(2)]

    ['Power*', (s) -> 
      if s of stats 
        (indicators.power(s,stats)).toFixed(2)]    

    ['Open*', (s) -> 
      if s of stats 
        (indicators.open(s,stats)).toFixed(2)]      

    ['Profit', (s) -> 
      if s of stats 
        series = stats[s].metrics.profit_index
        series[series.length - 1]?[1].toFixed(2) or 0 
    ]

    ['Return', (s) -> 
      if s of stats         
        "#{indicators.return(s, stats).toFixed(2)}%"
    ]

    ['Completed', (s) -> 
      if s of stats
        "#{indicators.completed(s,stats)}"]    
    ['Success', (s) -> 
      if s of stats 
        "#{(indicators.success(s,stats)).toFixed(1)}%"]        
    ['Reset', (s) -> 
      if s of stats 
        "#{indicators.reset(s,stats).toFixed(1)}%"]        

    ['Done in day', (s) -> 
      if s of stats 
        "#{( indicators.in_day(s,stats)).toFixed(1)}%"]

    ['within hour', (s) -> 
      if s of stats 
        "#{( indicators.in_hour(s,stats)).toFixed(1) }%"]

  ]

  
  DIV 
    style:
      marginTop: 20

    METH_TABLE
      cols: cols 
      rows: rows
      header: 'Performance'
      show_by_default: true 
      dummy: focus.highlighted
      dummy2: time.start 
      dummy3: time.end 

      more: =>  

        extras = [{
          label: "Profits over time"
          render: ->
            legend =
              ratio: 'ETH:BTC'
              profit_index: 'Profit'
              score: 'Score'
              open: 'Open'
              stability: 'Stability'

            DIV 
              key: 'series'
              style: 
                marginLeft: -50

              TIME_SERIES
                key: 'profit_index'
                series: {profit_index: stats[strat].metrics.profit_index}
                legend: legend
                width: 1300 
                height: 500 
                alpha: 1


              # for k,v of stats[strat].metrics
              #   s = {}
              #   s[k] = stats[strat].metrics[k]
              #   TIME_SERIES
              #     key: 'series' + k
              #     series: s                 
              #     legend: legend
              #     width: 1300 
              #     height: 500 
              #     alpha: 1 #.2

          }, 
        #   {
        #     label: "Strategy completion plots"
        #     render: -> 
        #       boxes = ([k, s.Math.quartiles_completion] for k,s of stats when k != 'key' && k not in focus.filtered && k != 'all')
        #       boxes.sort (a,b) -> 
        #         a[1].exit.q2 - b[1].exit.q2
        #       boxes.push ['all', stats.all.Math.quartiles_completion]
              
        #       BOX_WISKER
        #         data: boxes             
        # }
        ]

        DIV 
          style:
            marginLeft: 50
            marginTop: 20

          for extra, idx in extras 
            do (extra, idx) =>
              tw = if !@local["show#{idx}"] then 10 else 15
              th = if !@local["show#{idx}"] then 15 else 10

              DIV 
                style: 
                  fontSize: 24
                  fontWeight: 600
                  color: '#777'
                  cursor: 'pointer'
                  position: 'relative'

                onClick: => 
                  @local["show#{idx}"] = !@local["show#{idx}"]
                  save @local 

                SPAN 
                  style: cssTriangle (if !@local["show#{idx}"] then 'right' else 'bottom'), '#777', tw, th,
                    position: 'absolute'
                    left: -tw - 12
                    bottom: 11
                    width: tw
                    height: th
                    display: 'inline-block'

                extra.label

                if @local["show#{idx}"]
                  extra.render()





dom.ACTIVITY = -> 
  stats = fetch 'stats'
  focus = fetch 'focus'
  time = fetch '/time'

  return SPAN null if compute_stats.loading() || strategy_filter.loading() || !cached_positions.all

  in_range = (t) -> time.start <= t && t <= time.end

  positions = (pos for pos in cached_positions.all.all when  pos.strategy not in focus.filtered \
                                                          && (focus.highlighted.length == 0 || \
                                                              focus.highlighted[0] == 'all' || \ 
                                                              pos.strategy.indexOf(focus.highlighted[0]) > -1 || \
                                                              pos.strategy in focus.highlighted))

  positions.sort (a,b) -> (if b.closed && in_range(b.closed) then b.closed else b.created) - \
                          (if a.closed && in_range(a.closed) then a.closed else a.created)

  cols = [
    # ['', (pos) -> pos.key]

    ['Strategy', (pos) -> pos.strategy.replace(/_|&/g,' ')]
    ['Created', (pos) -> prettyDate(pos.created)]
    ['Duration', (pos) -> 
      SPAN 
        style: 
          textAlign: 'right'
        if pos.closed && in_range(pos.closed)
          "#{((pos.closed - pos.created) / 60).toFixed(0)} min"]   
    ['Status', (pos) -> 
      if pos.closed && in_range(pos.closed)
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

    ['Entry', (pos) -> if (pos.entry?.closed && in_range(pos.entry.closed)) then " #{prettyDate(pos.entry.closed)}" else '']
    ['', (pos) -> 
      SPAN 
        style: 
          fontFamily: mono
        if pos.entry then "#{pos.entry.type} #{pos.entry.amount?.toFixed(1)} @ #{pos.entry.rate?.toFixed(5)}" else '?'
    ]
    ['Exit', (pos) -> if (pos.exit?.closed && in_range(pos.exit.closed)) then " #{prettyDate(pos.exit.closed)}" else '-']
    ['', (pos) -> 
      SPAN 
        style: 
          fontFamily: mono
        if pos.exit 
          "#{pos.exit.type} #{pos.exit.amount.toFixed(1)} @ #{pos.exit.rate.toFixed(5)}"
    ]
    ['Earnings', (pos) -> 
      if pos.exit then "#{(pos.profit or pos.expected_profit)?.toFixed(3)} (#{(pos.returns or pos.expected_return)?.toFixed(2)}%)" else '?']

  ]

  DIV 
    style:
      marginTop: 20

    METH_TABLE
      cols: cols 
      rows: positions
      header: 'Activity'
      show_by_default: false 



dom.TIME_SLIDER = -> 
  size = @props.size or 12

  width = @props.style.width 
  DIV 
    style: extend {}, @props.style,
      borderBottom: '1px solid blue'

    for knob in [0, 1]
      do (knob) =>
        key = "knob-#{knob}"

        @local[key] ||= 
          pos: knob * width - size / 2
          value: knob

        DIV 
          style: 
            width: size
            height: size
            borderRadius: '50%'
            backgroundColor: 'purple'
            cursor: 'pointer'
            position: 'absolute'
            top: -size / 2 
            left: @local[key].temp_pos or @local[key].pos

          onMouseDown: (e) => 
            e.preventDefault()

            @local.mouse_positions = {x: e.pageX, y: e.pageY}
            @local.x_adjustment = @local[key].pos - @local.mouse_positions.x
            @local[key].temp_pos = @local[key].pos 

            save @local

            mousemove = (e) => 
              e.preventDefault()
              x = e.pageX

              @local.mouse_positions = {x: e.pageX, y: e.pageY}

              # Update position
              x = x + @local.x_adjustment
              x = if x < 0
                    0
                  else if x > width
                    width
                  else
                    x

              @local[key].temp_pos = x
              save @local

            window.addEventListener 'mousemove', mousemove

            mouseup = (e) => 
              window.removeEventListener 'mousemove', mousemove
              window.removeEventListener 'mouseup', mouseup
              @local.x_adjustment = @local.mouse_positions = null 

              @local[key].pos = @local[key].temp_pos 
              @local[key].value = @local[key].pos / width

              delete @local[key].temp_pos
              save @local

              time = fetch '/time'
              time.start = time.earliest + @local["knob-0"].value * (time.latest - time.earliest)
              time.end =  time.earliest + @local["knob-1"].value * (time.latest - time.earliest)
              save time

            window.addEventListener 'mouseup', mouseup




dom.GRAPH_TIME_VS_RATE = ->

  stats = fetch 'stats'
  focus = fetch 'focus'
  time = fetch '/time'

  return SPAN null if compute_stats.loading() || strategy_filter.loading()

  in_range = (t) -> time.start <= t && t <= time.end

  start = time.start
  end = time.end
  highest = 0
  lowest = Infinity

  return SPAN null if !cached_positions[@props.segment]

  all = cached_positions[@props.segment].all
  if cached_positions['price']
    all = all.concat cached_positions['price'].all

  all_positions = (b for b in all when b.series_data || (b.strategy not in focus.filtered))

  ticker = fetch '/ticker'

  for pos in all_positions

    if pos.exit 
      high = Math.max pos.entry.rate, pos.exit.rate
      low = Math.min pos.entry.rate, pos.exit.rate
    else 
      high = low = pos.entry.rate

    highest = high if high > highest && high > 0 
    lowest  = low if low < lowest && low > 0 

  price_range = [lowest - .0001, highest + .0001]

  height = 500
  size = 6
  width = 1300

  groups = []
  group_size = 10000
  i = 0 
  while i < all_positions.length 
    groups.push all_positions.slice(i, i + group_size)
    i += group_size


  hierarchy = strategy_hierarchy()

  DIV
    key: 'top'
    style:
      border: '1px solid #444'
      height: height + 2
      position: 'relative'
      width: width 
      #overflow: 'hidden'
      margin: "60px 0 20px 0"

    TIME_SLIDER  
      key: 'slider'
      style: 
        position: 'absolute'
        bottom: 0
        left: 0
        width: width

    if ticker.last 
      DIV
        key: 'last_price'
        style:
          height: 1
          borderBottom: "1px dashed #{feedback_orange}"
          width: '100%'
          position: 'absolute'
          left: 0
          top: height * (price_range[1] - ticker.last) / (price_range[1] - price_range[0])
          zIndex: 10

    SVG 
      key: "graph"
      style: 
        width: width
        height: height

      G 
        key: 'gggg'

        for group in groups 
          for pos in group
            hide = focus.highlighted?.length > 0 && !(pos.strategy in focus.highlighted || 'all' in focus.highlighted || pos.strategy in (hierarchy[focus.highlighted[0]]?.children or [])  ) && !pos.series_data 
            continue if hide #|| (!pos.reset && !pos.series_data)

            pnts = []
            color = 'white'


            G 
              key: pos.key 



              for trade in [pos.entry, pos.exit] when trade && in_range(trade.created)
                x = if !trade.entry && trade.closed && in_range(trade.closed) then trade.closed else trade.created
                x = width * ( (x - start) / (end - start))
                y = height * (price_range[1] - trade.rate) / (price_range[1] - price_range[0])
                pnts.push [x,y]

                # continue if trade.closed && !trade.originally_created
                
                bord = null

                if trade.originally_created
                  color = bright_red
                # else if trade.closed && in_range(trade.closed)
                #   color = 'white' #light_blue
                # else if !pos.exit 
                #   color = ecto_green
                # else  
                #   color = attention_magenta
                else if trade.type == 'buy'
                  color = ecto_green
                else if trade.type == 'sell'
                  color = feedback_orange

                z = if !pos.exit then 1 else 0
                bgcolor = if (!pos.closed || !in_range(pos.closed)) then 'transparent' else color
                opacity = if (pos.closed && in_range(pos.closed)) then .5 else .8

                # if !trade.entry
                #   opacity = 0 

                s = size
                if (!pos.closed || !in_range(pos.closed))
                  s *= 1.5
                  bord = color 

                if !trade.entry 
                  s /= 2

                if pos.series_data

                  color = light_blue
                  s = 1
                  hide = false
                  z = 0
                  bgcolor = color
                  opacity = 1
                  bord = null

                CIRCLE 
                  key: trade.key
                  cx: x
                  cy: y
                  r: s
                  fill: bgcolor
                  stroke: if bord then bord 
                  strokeWidth: 1
                  fillOpacity: opacity
                  strokeOpacity: opacity
                  style: 
                    zIndex: z # probably doesn't work for svg

              # draw a line between them 
              if pos.exit && pnts.length == 2 && !hide #&& false
                LINE
                  key: "#{pos.key}-line"
                  stroke: color
                  strokeOpacity: .5
                  width: 1
                  x1: pnts[0][0]
                  y1: pnts[0][1]
                  x2: pnts[1][0]
                  y2: pnts[1][1]
            





dom.BOX_WISKER = ->
 
  boxes = @props.data

  width = 1200
  height = 25

  q3_max = 0
  for [k,v] in boxes
    q3 = Math.max v.all.q3, v.entry.q3, v.exit.q3

    if q3_max < q3 && k not in ['preplat', 'bear_cross']
      q3_max = q3

  m = q3_max * 1.4

  DIV
    style:
      marginTop: 40


    TABLE 
      style: 
        borderSpacing: "0 30px"
        borderCollapse: 'separate'

      TBODY null, 


        for [name, v] in boxes
          TR
            style:
              height: height



            TD
              style:
                padding: '0px 20px 0px 0'
                textAlign: 'right'
                fontFamily: special
                fontSize: 24
                borderRight: '1px solid #f2f2f2'
                verticalAlign: 'middle'

              name.replace /_|&/g, ' '

            TD 
              style: {}

              for box in [v.all, v.entry, v.exit]
                DIV
                  style:
                    width: width
                    height: height
                    position: 'relative'
                    boxSizing: 'border-box'

                  DIV
                    style:
                      position: 'absolute'
                      width: (box.q2 - box.q1) / m * width
                      height: height - 10
                      left: box.q1 / m * width
                      backgroundColor: '#282'


                  DIV
                    style:
                      position: 'absolute'
                      width: (box.q3 - box.q2) / m * width
                      height: height - 10
                      left: box.q2 / m * width
                      backgroundColor: '#828'



dom.HEADER = -> 
  td_style = 
    verticalAlign: 'top'
    #borderRight: "1px solid #{ecto_green}"

  # b = fetch("/bullish")?.bullish
  #return SPAN null if @loading()


  DIV 
    style:
      # position: 'fixed'
      top: 0
      left: 0
      width: '100%'
      zIndex: 999
      backgroundColor: 'black'
      #borderBottom: "1px solid #{ecto_green}"
      #borderTop: "1px solid #{ecto_green}"
      #borderLeft: "1px solid #{ecto_green}"

    TABLE {}, TBODY {}, TR {}, 
      TD 
        style: extend {}, td_style,
          padding: '0px 10px'

        BANK key: 'bank'
      # TD
      #   style: extend {}, td_style,
      #     width: '100%'
      #   STRATEGY_SELECTOR key: 'selector'
      TD 
        style: extend {}, td_style
        TICKER key: 'ticker'


dom.BANK = -> 
  balances = fetch '/balances'
  return SPAN null if !balances.deposits

  ts = now()

  stats = fetch 'stats'

  return SPAN null if compute_stats.loading()

  deposited = balances.deposits
  withdrawn = balances.withdrawals

  balance = balances.balances

  total_on_order = balances.on_order

  cols = [
    ['', (currency) -> currency]
    ['In bank', (currency) -> "#{(balance[currency] + total_on_order[currency]).toFixed(2)}"]
    ['Available', (currency) -> (balance[currency] or 0).toFixed(2)]
    ['Deposited', (currency) -> (deposited[currency] or 0).toFixed(2)]
    ['Withdrawn', (currency) -> (withdrawn[currency] or 0).toFixed(2)]
    ['Change', (currency) -> 

      val = ((balance[currency] + total_on_order[currency]) - \
            (deposited[currency] or 0) + \
            (withdrawn[currency] or 0))

      SPAN 
        style: 
          color: if val < 0 then bright_red else ecto_green
        val.toFixed(2)
    ]

  ]


  DIV 
    style: 
      display: 'inline-block'
      verticalAlign: 'top'

    METH_TABLE
      cols: cols 
      rows: ["ETH", "BTC"]
      show_by_default: true



dom.TICKER = -> 
  ticker = fetch '/ticker'

  return SPAN null if !ticker.last

  keys = ['last', 'percentChange', 'baseVolume'] #, 'hr24Low']

  DIV 
    style: 
      color: '#ccc'
      #fontSize: 16
      textAlign: 'center'
      padding: '10px 30px'
      display: 'inline-block'
      
      verticalAlign: 'top'
      width: 225

    TABLE {}, TBODY {}, 
    
      for k in keys
        [label, val] = if k == 'percentChange'
            ["% change", (ticker[k] * 100).toFixed(2)]
          else if k == 'hr24Low'
            ["24hr range", "#{ticker[k].toFixed(4)} - #{ticker['hr24High'].toFixed(4)}"]
          else if k == 'baseVolume'
            ["24hr volume", ticker[k].toFixed(0)]
          else 
            [k, ticker[k].toFixed(5)]
        TR {},
          TD  
            style: 
              textAlign: 'right'
              paddingRight: 8
              fontStyle: 'italic'
              fontWeight: 600
            label 
          TD 
            style:
              textAlign: 'right'
              fontFamily: mono
              color: if val < 0 then bright_red else ecto_green
            val
              



window.cached_positions = {}

computing = 0 

at_least_one = false 

series_data = ['price']

computing_kpi = false 

last_time = null 

window.compute_stats = bus.reactive ->

  time = fetch '/time'
  if !at_least_one && (time.start != time.earliest || time.end != time.latest )
    time.start = time.earliest
    time.end = time.latest
    save time 

  if computing_kpi || compute_stats.loading() || (Date.now() - computing < 100000 && at_least_one && last_time == JSON.stringify(time))
    
    return

  strategies = (strat for strat in (fetch('/strategies').strategies or []) when !get_settings(strat).series)


  started_computing_at = Date.now()
  last_time = JSON.stringify(time)
  
  computing = Date.now()

  all_stats = bus.cache['stats'] or {key: 'stats'}

  if !at_least_one

    if !time.earliest 
      every_position = []
      for name in strategies #.concat series_data
        every_position = every_position.concat (fetch("/positions/#{name}").positions or [])

      mint = Infinity
      for p in every_position
        mint = p.created if p.created < mint 

      time.earliest = mint 

    time.latest ||= now()
    time.start = time.earliest
    time.end = time.latest
    save time

  ts = time.end 

  in_range = (t) -> time.start <= t && t <= time.end

  all_positions = []
  strat_positions = {}
  for name in strategies
    strat_positions[name] = (p for p in (fetch("/positions/#{name}").positions or []) when in_range(p.created))
    all_positions = all_positions.concat strat_positions[name]
  strat_positions.all = all_positions
  strategies.push 'all'  

  return if all_positions.length == 0

  hierarchy = strategy_hierarchy()
  for strat in hierarchy.all.children
    s = hierarchy[strat]
    if s.children 
      positions = []

      for child in s.children 
        positions = positions.concat (p for p in (fetch("/positions/#{child}").positions or []) when in_range(p.created))      

      strat_positions[s.name] = positions
      strategies.push s.name


  for name in series_data
    if bus.cache["/positions/#{name}"]
      cached_positions[name] = 
        all: (p for p in (fetch("/positions/#{name}").positions or []) when in_range(p.created))


  console.log 'starting to compute'


  for name in strategies
    positions = strat_positions[name] 
    all = positions

    open = (b for b in positions when !b.closed || !in_range(b.closed))
    closed = (b for b in positions when b.closed && in_range(b.closed))

    reset = (b for b in positions when b.reset)
    successful = closed

    # successful_last_day = (b for b in successful when ts - b.closed < 24 * 60 * 60)
    # successful_last_hour = (b for b in successful when ts - b.closed < 60 * 60)

    more_than_day = (p for p in open when ts - p.created > 24 * 60 * 60)
    more_than_day = more_than_day.concat (p for p in successful when p.closed - p.created > 24 * 60 * 60)

    # more_than_12hrs = (p for p in open when ts - p.created > 12 * 60 * 60)
    # more_than_12hrs = more_than_12hrs.concat (p for p in successful when p.closed - p.created > 12 * 60 * 60)

    more_than_hour = (p for p in open when ts - p.created > 60 * 60)
    more_than_hour = more_than_hour.concat (p for p in successful when p.closed - p.created > 60 * 60)

    # closed_last_day = (b for b in closed when ts - b.closed < 24 * 60 * 60)
    # closed_last_hour = (b for b in closed when ts - b.closed < 60 * 60)

    cached_positions[name] = {all, more_than_hour, more_than_day, closed, open, successful, reset}

    all_stats[name] ||= {}

  # subscribe to all changes to positions
  # fetched = (fetch(pos) for pos in cached_positions.all.all when !pos.closed)
  
  for k, stats of all_stats when k != 'key' 
    btc = 0
    eth = 0
    for pos in cached_positions[k].open
      buy = if pos.entry.type == 'buy' then pos.entry else pos.exit
      sell = if pos.entry.type == 'sell' then pos.entry else pos.exit

      if buy && in_range(buy.created)
        btc += buy.amount * buy.rate

      if sell && in_range(sell.created)
        eth += sell.amount

    stats.on_order =
      BTC: btc 
      ETH: eth

    stats.more_than_day = cached_positions[k].more_than_day.length / (cached_positions[k].all.length or 1)
    # stats.more_than_12hrs = cached_positions[k].more_than_12hrs.length / (cached_positions[k].all.length or 1)
    stats.more_than_hour = cached_positions[k].more_than_hour.length / (cached_positions[k].all.length or 1)

    # stats.earnings =
    #   total: Math.summation (b.profit or b.expected_profit for b in cached_positions[k].successful)
    #   last_day: Math.summation (b.profit or b.expected_profit for b in cached_positions[k].successful_last_day)
    #   last_hour: Math.summation (b.profit or b.expected_profit for b in cached_positions[k].successful_last_hour)

    # stats.medians =
    #   total: median_time_to_complete cached_positions[k].successful
    #   last_day: median_time_to_complete cached_positions[k].successful_last_day
    #   last_hour: median_time_to_complete cached_positions[k].successful_last_hour

    # stats.quartiles_completion =
    #   all: Math.quartiles (b.closed - b.created for b in cached_positions[k].successful)
    #   entry: Math.quartiles (b.entry.closed - b.entry.created for b in cached_positions[k].successful)
    #   exit: Math.quartiles (b.exit.closed - b.exit.created for b in cached_positions[k].successful)

    stats.status =
      open: (cached_positions[k].open or []).length
      completed: (cached_positions[k].successful or []).length
      reset: (cached_positions[k].reset or []).length

  computing_kpi = true 
  #setTimeout -> 
  console.log 'computing kpi'
  kpi strategies, all_stats, ->
    computing_kpi = false
    console.log "COMPUTED in #{Date.now() - started_computing_at}"
    at_least_one = true
    save all_stats

window.memoize = {}
last_completed_trade = null


kpi = (strategies, all_stats, callback) ->
  ####################  
  # now compute KPI

  EXCHANGE_FEE = fetch('/balances').exchange_fee
  
  value = (eth, btc, rate) -> eth + btc / rate 
  in_range = (t) -> time.start <= t && t <= time.end
  time = fetch '/time'

  trades = (pos.entry for pos in cached_positions.all.all when pos.entry && pos.entry.closed && in_range(pos.entry.closed))
  trades = trades.concat (pos.exit for pos in cached_positions.all.all when pos.exit && pos.exit.closed && in_range(pos.exit.closed))
  trades.sort (a,b) -> a.closed - b.closed 

  last_trade = trades[trades.length - 1]

  if last_completed_trade != last_trade

    last_day_rates = []
    i = trades.length - 1
    while i >= 0 && last_trade.closed - trades[i].closed < 24 * 60 * 60
      last_day_rates.push trades[i].rate 
      i--
    
    # would be nice to get actual market prices in last day
    quartiles = Math.quartiles last_day_rates 

    for strat in strategies

      trades = (pos.entry for pos in cached_positions[strat].all when pos.entry?.closed)
      trades = trades.concat (pos.exit for pos in cached_positions[strat].all when pos.exit?.closed)

      trades.sort (a,b) -> a.closed - b.closed 

      series = 
        profit_index: []
        profit_velocity: []
        # current_price: []
        # eth: []
        # btc: []
        ratio: []
        score: []
        open: []
        stability: []



      memoize[strat] ||= []

      successful = cached_positions[strat].successful.slice()
      successful.sort (a,b) -> a.closed - b.closed

      created_by = cached_positions[strat].all.slice()
      created_by.sort (a,b) -> a.created - b.created

      closed_by = cached_positions[strat].all.slice()
      closed_by.sort (a,b) -> (a.closed or Infinity) - (b.closed or Infinity)


      num_successful = successful.length
      num_all = created_by.length

      positive = 0
      for trade, idx in trades

        if memoize[strat][idx]
          mem = memoize[strat][idx]

        else 
          if idx == 0 
            mem = 
              btc: 0
              eth: 0
              success_idx: 0
              created_by_idx: 0
              closed_by_idx: 0
              transacted: 0
          else 
            mem = {}
            for k,v of memoize[strat][idx-1]
              mem[k] = v 

          if trade.type == 'buy'
            mem.eth += trade.amount 
            mem.eth -= (trade.fee or (trade.amount * EXCHANGE_FEE) )
            mem.btc -= (trade.total or trade.amount * trade.rate)
          else
            mem.eth -= trade.amount 
            mem.btc += (trade.total or trade.amount * trade.rate)
            mem.btc -= (trade.fee or (trade.amount * trade.rate * EXCHANGE_FEE))

          mem.transacted += trade.amount

          while mem.success_idx < num_successful
            pos = successful[mem.success_idx]
            break if pos.closed > trade.closed
            mem.success_idx++

          while mem.created_by_idx < num_all
            pos = created_by[mem.created_by_idx]
            break if pos.created > trade.created
            mem.created_by_idx++            

          while mem.closed_by_idx < num_all
            pos = closed_by[mem.closed_by_idx]
            break if !pos.closed || pos.closed > trade.closed
            mem.closed_by_idx++

          memoize[strat].push mem

        #series.current_price.push  [trade.closed, value(mem.eth, mem.btc, trade.rate)]
        
        #prof = (value(mem.eth,mem.btc,quartiles.q1) + value(mem.eth,mem.btc,quartiles.q2) + value(mem.eth,mem.btc,quartiles.q3) + value(mem.eth,mem.btc,trade.rate)) / 4
        
        prof = value(mem.eth, mem.btc, trade.rate)
        series.profit_index.push [trade.closed, prof]

        series.profit_velocity.push [trade.closed, (if idx == 0 then 0 else prof - series.profit_index[idx - 1][1])]

        if (idx > 0 && prof > series.profit_index[idx - 1][1]) || (idx == 0 && prof > 0)
          positive++ 

        # series.eth.push [trade.closed, mem.eth ]
        # series.btc.push [trade.closed, mem.btc ]

        if trades[0].rate > trade.rate 
          rat = mem.btc / trade.rate 
        else 
          rat = mem.eth

        rat = (rat / (mem.transacted / 2))
        series.ratio.push [trade.closed, rat]

        series.open.push [trade.closed, mem.created_by_idx - mem.closed_by_idx]

        stability = positive / (idx + 1)
        series.stability.push [trade.closed, stability]

        series.score.push [trade.closed, prof * stability]


        if idx == trades.length - 1
          # ...and cap it off with the metrics according to the latest price
          if fetch('/ticker').last
            last = {closed: now(), rate: fetch('/ticker').last}
          else 
            last = last_trade

          prof = value(mem.eth, mem.btc, last.rate)
          series.profit_index.push [last.closed, prof]

          series.profit_velocity.push [last.closed, (if idx == 0 then 0 else prof - series.profit_index[idx][1])]

          if (idx > 0 && prof > series.profit_index[idx][1]) || (idx == 0 && prof > 0)
            positive++ 

          # series.eth.push [last.closed, mem.eth ]
          # series.btc.push [last.closed, mem.btc ]

          if trades[0].rate > last.rate 
            rat = mem.btc / last.rate 
          else 
            rat = mem.eth

          rat = (rat / (mem.transacted / 2))
          series.ratio.push [last.closed, rat]

          series.open.push [last.closed, mem.created_by_idx - mem.closed_by_idx]

          stability = positive / (idx + 1)
          series.stability.push [last.closed, stability]

          series.score.push [last.closed, prof * stability]


      all_stats[strat].metrics = series

    last_completed_trade = last_trade

  callback()



median_time_to_complete = (positions) -> Math.median (b.closed - b.created for b in positions)



dom.TIME_SERIES = -> 
  height = @props.height 
  width = @props.width
  original_series = @props.series 
  legend = @props.legend

  alpha = @props.alpha

  series = {}
  for k,ser of original_series
    series[k] = (v.slice() for v in ser)

  if alpha 
    for k,s of series
      for val,idx in s when idx > 0 
        s[idx][1] = s[idx][1] * alpha + s[idx-1][1] * (1 - alpha)

  min = Infinity
  max = 0
  start = Infinity
  end = 0
  for k,data of series 
    continue if data.length == 0 
    ma = 0
    mi = Infinity
    for i in data 
      ma = i[1] if i[1] > ma 
      mi = i[1] if i[1] < mi 

    max = ma if ma > max 
    min = mi if mi < min

    start = data[0][0] if start > data[0][0]
    end = data[data.length - 1][0] if end < data[data.length - 1][0]


  adjust = if min < 0 then min * -1 else 0
  range = [min + adjust, max + adjust]

  s = 2

  colors = {}
  i = 0
  c = getNiceRandomHues(Object.keys(series).length)

  for k,v of series 
    colors[k] = hsv2rgba c[i], 1, 1
    i++  

  DIV
    style:
      border: '1px solid #444'
      height: height + 2
      position: 'relative'
      width: width 
      overflow: 'hidden'      

    if legend 
      DIV 
        position: 'absolute'
        top: 0
        left: 0 
        key: 'legend'

        for k,v of series 
          DIV 
            key: k 

            DIV 
              style: 
                height: 20
                width: 100
                backgroundColor: colors[k]
                display: 'inline-block'
            DIV 
              style: 
                display: 'inline-block'
                color: colors[k]
                paddingLeft: 5
              legend[k]
    DIV
      key: 'zero'
      style:
        height: 1
        borderBottom: "1px solid #{attention_magenta}"
        width: '100%'
        position: 'absolute'
        left: 0
        top: height * (range[1] - adjust) / (range[1] - range[0])
        zIndex: 10

    DIV 
      key: 'data'

      for k,v of series
        prev = 0

        for [t,val] in (v.data or v)

          x = width * ( (t - start) / (end - start))
          y = height * (range[1] - (val + adjust)) / (range[1] - range[0])

          if x - prev > 1
            prev = x
            DIV
              key: "#{k}-#{t}-#{val}-#{x}-#{y}"

              style:
                position: 'absolute'
                top: y
                left: x
                backgroundColor: colors[k]
                width: s
                height: s
                borderRadius: '50%'

dom.METH_TABLE = -> 


  if !@local.show? 
    @local.show = @props.show_by_default 

  DIV 
    style: 
      #paddingLeft: 14
      color: '#ccc'

    PULSE
      key: 'pulse'
      public_key: fetch('ACTIVITY_pulse').key
      interval: 60 * 1000

    if @props.header 
      tw = if !@local.show then 15 else 20
      th = if !@local.show then 20 else 15

      DIV 
        style: 
          fontSize: 36
          fontWeight: 600
          color: '#777'
          cursor: 'pointer'
          position: 'relative'

        onClick: => 
          @local.show = !@local.show 
          save @local 

        SPAN 
          style: cssTriangle (if !@local.show then 'right' else 'bottom'), '#777', tw, th,
            position: 'absolute'
            left: -tw - 12
            bottom: 17
            width: tw
            height: th
            display: 'inline-block'

        @props.header

    if @local.show 
      DIV 
        style: null 

        TABLE 
          style: 
            borderCollapse: 'collapse'

          TBODY null, 
            TR {},                

              for col, idx in @props.cols 
                TD 
                  style: 
                    fontStyle: 'italic'
                    padding: '5px 8px'
                    fontWeight: 600
                    textAlign: if idx != 0 then 'right'
                    #color: ecto_green
                  col[0]

            for item, idx in @props.rows 

              TR 
                key: item.key or item
                style:
                  backgroundColor: if idx % 2 && @props.rows.length > 3 then '#222'

                for col, idx in @props.cols 
                  v = col[1](item)

                  TD 
                    style: 
                      padding: '5px 8px'
                      textAlign: if idx != 0 then 'right'
                      fontFamily: if is_num(v) then mono

                    v

        @props.more?()


indicators = 
  score: (s, stats) -> 
    power = indicators.power(s,stats)
    # rat = indicators.ratio(s,stats)
    stability = indicators.stability(s,stats)
    #power * (rat + 1) * (rat + 1) * 100 * Math.pow(stability,3)
    power * stability

  profit: (s, stats) -> 
    profs = Math.quartiles (v[1] for v in stats[s].metrics.profit_index)
    prof = (profs.q1 + profs.q2 + profs.q3) / 3 or 0 
    prof

  ratio: (s, stats) ->
    rats = Math.quartiles (v[1] for v in stats[s].metrics.ratio)
    rat = rats.q1 or 0
    rat

  stability: (s, stats) -> 
    deltas = (v[1] for v in stats[s].metrics.profit_velocity)
    sum_negative = 0
    sum_positive = 0 
    for vel in deltas
      if vel > 0 
        sum_positive += vel 
      else 
        sum_negative += vel 
    sum_negative *= -1 

    sum_positive / (sum_negative + sum_positive)

  open: (s, stats) -> 
    o = Math.quartiles (v[1] for v in stats[s].metrics.open)
    (o.q3 + o.max) / 2 or 0

  power: (s, stats) -> 
    o = indicators.open(s,stats)
    prof = indicators.profit(s,stats)
    prof / o     

  return: (s, stats) -> 
    open = Math.quartiles( (v[1] for v in stats[s].metrics.open)).max 
    profit = stats[s].metrics.profit_index   #indicators.profit(s,stats)
    profit = profit[profit.length - 1]?[1] or indicators.profit(s,stats)

    settings = get_settings(s)
    if !settings
      hierarchy = strategy_hierarchy()
      h = hierarchy[s]
      while h.children 
        h = hierarchy[h.children[0]]
      settings = get_settings(h.name)
    
    invested = 2 * settings.position_amount * open

    100 * profit / invested 

  completed: (s, stats) -> stats[s].status.completed
  reset: (s, stats) -> 100 * stats[s].status.reset  / ((stats[s].status.completed + stats[s].status.open) or 1)
  success: (s, stats) -> 100 * (stats[s].status.completed / ((stats[s].status.completed + stats[s].status.open) or 1))
  in_day: (s, stats) -> 100 * (1 - stats[s].more_than_day)
  in_12hrs: (s, stats) -> 100 * (1 - stats[s].more_than_12hrs)
  in_hour: (s, stats) -> 100 * (1 - stats[s].more_than_hour)


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



# ######################
# # Style
# ######################

focus_blue = '#2478CC'
light_blue = 'rgba(139, 213, 253,1)'
feedback_orange = '#F19135'
attention_magenta = '#FF00A4'
logo_red = "#B03A44"
bright_red = 'rgba(246, 36, 4, 1)'
light_gray = '#afafaf'
green = '#282'
purple = '#828'
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
  day_diff = Math.floor(diff / 86400)

  return if isNaN(day_diff) || day_diff < 0

  # TODO: pluralize properly (e.g. 1 days ago, 1 weeks ago...)
  r = \ # day_diff == 0 && (
    diff < 60 && "just now" ||
    diff < 120 && "1 minute ago" ||
    Math.floor(diff / 60) + " min ago"

    # diff < 3600 && Math.floor(diff / 60) + " min ago" ||
    # diff < 7200 && "1 hour ago" ||
    # diff < 86400 && Math.floor(diff / 3600) + " hours ago") ||
    # day_diff == 1 && "Yesterday" ||
    # day_diff < 7 && day_diff + " days ago" ||
    # day_diff < 31 && Math.ceil(day_diff / 7) + " weeks ago" ||
    # "#{date.getMonth() + 1}/#{date.getDay() + 1}/#{date.getFullYear()}"

  r = r.replace('1 days ago', '1 day ago').replace('1 weeks ago', '1 week ago').replace('1 years ago', '1 year ago')
  r

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
