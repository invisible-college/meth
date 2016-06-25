require '../shared'
strategizer = require '../strategizer'


module.exports =

  plateau: 
      
    frames: required_frames(.8)
    max_t2: 60

    evaluate_new_position: (f) ->

      vel = f.velocity weight: .8
      vel_median = f.velocity_median t: 0, t2: 50

      if Math.abs(vel) < vel_median

        min = f.min_price(); max = f.max_price(); last = f.last_price()

        sell_at = max - .3 * (max - last)
        buy_at = min + .3 * (last - min)

        pos = 
          sell: 
            rate: sell_at
            entry: vel < 0 
          buy: 
            rate: buy_at
            entry: vel > 0 

        pos

    evaluate_open_position: (pos, f) -> 
      v = get_settings pos.dealer

      cancel_unfilled = -> 
        abort_if_neither_trade_successful_within = 5 * 60
        cancel_incomplete_trades_after = 3 * 24 * 60 * 60 
        if (!pos.entry || !pos.entry.closed) && \
           (!pos.exit? || !pos.exit.closed) && \
           tick.time - pos.created > abort_if_neither_trade_successful_within

          return true

        for trade in [pos.exit, pos.entry] when trade && !trade.closed 
          return true if tick.time - trade.created > cancel_incomplete_trades_after

      if cancel_unfilled()      
        return {action: 'cancel_unfilled'}

      else if pos.entry.closed && !pos.exit 
        return {action: 'exit', rate: f.last_price()}
