The METH Cryptocurrency Trading Engine
------------------------------------------------------------

METH is for automated trading of cryptocurrencies. It provides a framework for anyone to define their own trading strategies, backtest them, and ultimately execute them on an exchange (currently just Poloniex). 

It is a ton of work to define your own trading strategies. METH isn't something that you can just get started and expect to be profitable quickly. 

About the name: 
------------------------------------------------------------

The name originally occurred to me because I have been listening to RatBOT's "Faces of Meth" (https://soundcloud.com/ratbot/sets/faces-of-meth), a track that has been oddly compelling to me. 

But then the multiple meanings of calling the engine METH struck me: I started working on METH because I wanted to create an investment vehicle that would Maximize my ETHereum. And perhaps unsurprisingly, it turned out to be addictive, leading me down a path of self-reflection and concern about neglecting Considerit. 

So, it is a cautionary name.

Installation
-------------------------
If you want to get METH up and running, contact me at travis@invisible.college. I don't have much motivation to package METH up nicely, but if I see demand, I'll have more motivation. Note that even if it is packaged up nicely, it takes a lot of work on your part to define and test a good market strategy. This isn't a plug and play tool. 


Overview: Running a METH operation
-----------------------------------------------------

Trading is about making predictions about where the market is moving. If you think that the market is going to go up, you want to buy now. Likewise, if you think the market is going to go down, you want to sell now. Sell high, buy low. 

* Positions * 

When you decide that you want to act on a prediction, you take a "position". Positions are the fundamental unit of METH. 

Each position has two trades (an "entry" and an "exit"), both of which transact the same amount of currency. An entry is your initial bet, such as "buy Y at X price"; an exit is when you close out your position and reap your profit (or loss), such as "sell Y at X+e price". If e is positive, then you've made e * Y profit; if it is negative, you've lost e * Y. 

* Trading strategies *

Each trading strategy you implement and run watches the market for different clues as to when it thinks it can make an accurate prediction, whereupon it can take a new position and/or exit out of open positions. 

Trading strategies are disciplined traders that wait for particular market conditions to pounce on an opportunity. Each strategy looks for particular market clues, or "features", to decide when to take a position (or exit out of open positions). 

METH provides market features to your strategies so they can make predictions. The METH feature engine:
  - defines some default features like price, velocity, acceleration, and volume, but you can add your own features
  - supports exponential moving averages of any feature
  - segments trade history into time-quantized chunks that are consumed by the features

* Hustling * 

METH provides a pusher to hustle on your behalf. All you have to do is create a Poloniex account, make an initial deposit, and define your strategies. 

The pusher periodically checks the market for new opportunities (I check every minute). Each tick, the pusher:
- Aggregates new trades from the exchange for feature consumption
- Gathers new positions by cycling through each trading strategy, sending each strategy the current market conditions. 
- Gives each open position for each strategy a chance to modify itself (e.g. canceling unfilled trades or exiting a position) 
- Executes each opportunity when there is enough money in your budget
- Does accounting; e.g. identifying when a trade has been successful, updating your budget.

Furthermore, your strategies can define non-market based policies that regulate their behavior. The pusher enforces these policies. Supported policies include: 
- Maximum open positions: The number of uncompleted positions that a strategy can have at any time. 
- Minimum return: Don't create new positions where the expected return is too small. 
- Cooloff period: Don't create a new position if the strategy has uncompleted positions that were created not too long ago. 
- Position spacing: Don't create new positions that are too similar to an existing uncompleted position. 

* Dashboard * 

You gotta keep track of your assets. Learn how your operation is performing. Gain insights into what might be going wrong. 

METH provides a dashboard to visualize what is happening with your operation. The dashboard includes:
  - Your budget (deposits / withdrawals / balances)
  - Ticker from the exchange
  - Time series of all your trades, with ability to zoom in on particular time period and/or filter to particular strategies. 
  - Ability to drill into performance of individual strategies, using a variety of performance indicators
  - A raw activity feed that helps you track the details of what is happening
  - Methods for comparing performance of different parameterizations of a strategy against the performance indicators


* Backtesting in your METHlab * 

You need a lab where you concoct new strategies, and tune your old. The lab enables you to simulate your strategies' performance over historical data, and analyze the results. You can specify the historical time frames over which you want to run, which helps improve the performance of your strategies during particular market conditions that you want your strategy to perform better in. 
