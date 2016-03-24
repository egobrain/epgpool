-module(epgpool_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(CHILD(I, Type, Opts),
    {I, {I, start_link, Opts}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, PoolSize} = application:get_env(epgpool, database_poolsize),
    Opts = [
        {name, {local, epgpool}},
        {worker_module, epgpool_worker},
        {max_overflow, 0},
        {strategy, fifo},
        {size, PoolSize + 1}
    ],
    {ok, {{rest_for_one, 1000, 1}, [
        ?CHILD(epgpool_conn_sup, worker, []),
        ?CHILD(epgpool_alive, worker, [Opts]),
        ?CHILD(poolboy, worker, [Opts])
    ]}}.
