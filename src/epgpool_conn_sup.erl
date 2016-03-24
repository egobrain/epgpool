-module(epgpool_conn_sup).
-behaviour(supervisor).

-export([
    start_link/0,
    start_sock/1,
    init/1
]).

-define(CHILD(I, Type),
    {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{simple_one_for_one, 1000, 1}, [
        ?CHILD(epgsql_sock, worker)
    ]}}.

-spec start_sock(epgpool_worker:opts()) -> {ok, pid()}.
start_sock(_Opts) ->
    {ok, _} = supervisor:start_child(?MODULE, []).
