-module(epgpool_alive).
-behaviour(gen_server).

-export([
    start_link/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    fails = 0 :: non_neg_integer(),
    status :: atom(),
    connection :: epgpool:connection() | undefined,
    opts :: [{atom(), any()}]
}).

-define(FAILS, 3).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init(Opts) ->
    self() ! init,
    process_flag(trap_exit, true),
    {ok, #state{opts=Opts}}.

handle_call(_Request, _From, State) ->
    {noreply, State, timeout()}.

handle_cast(_Msg, State) ->
    {noreply, State, timeout()}.

handle_info(Msg, #state{fails=?FAILS, status=Status}=State) ->
    ok = lager:error("Network problem was detected: (~p)", [Status]),
    epgpool:kill_all_workers(),
    handle_info(Msg, State#state{fails=0, status=kill});
handle_info(init, #state{opts=Opts, fails=Fails}=State) ->
    StateR = try epgpool_worker:connect(Opts) of {ok, C} ->
        State#state{fails=0, connection=C, status=init}
    catch _C:_E ->
        State#state{connection=undefined, fails=Fails+1, status=no_init}
    end,
    {noreply, StateR, timeout()};
handle_info({pgsql, C, {notice, _Error}}, #state{connection=C, fails=Fails}=State) ->
    ok = epgsql:close(C),
    State2 = State#state{connection=undefined, fails=Fails+1, status=notice},
    handle_info(init, State2);
handle_info({'EXIT', C, _Error}, #state{connection=C, fails=Fails}=State) ->
    State2 = State#state{connection=undefined, fails=Fails+1, status=exit},
    handle_info(init, State2);
handle_info({'EXIT', _Pid, _Error}, State) ->
    {noreply, State, timeout()};
handle_info(timeout, #state{connection=undefined}=State) ->
    handle_info(init, State);
handle_info(timeout, #state{connection=C, fails=Fails}=State) ->
    try
        {ok, [], []} = gen_server:call(C, {squery, ""}),
        {noreply, State#state{fails=0, status=alive}, timeout()}
    catch _:_ ->
        true = exit(C, kill),
        State2 = State#state{
            connection=undefined,
            fails=Fails+1,
            status=timeout
        },
        {noreply, State2, timeout()}
    end;
handle_info(_Info, State) ->
    {noreply, State, timeout()}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal functions
%%===================================================================

-spec timeout() -> timeout().
timeout() ->
    {ok, Timeout} = application:get_env(epgpool, database_retry_sleep),
    Timeout.
