-module(epgpool_worker).
-behaviour(gen_server).
-behaviour(poolboy_worker).

-include_lib("epgsql/include/epgsql.hrl").

-export([
    start_link/1,
    checkout/1,
    checkin/2,
    connect/1,
    kill/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export_type([opts/0]).

-type opts() :: [{atom(), any()}].
-record(state, {
    connection :: epgpool:connection(),
    opts :: opts(),
    owner :: pid() | undefined,
    owner_ref :: reference()
}).

-define(INIT_TIMEOUT, 5000).
-define(KILL_TIMEOUT, 50).

%%===================================================================
%% API
%%===================================================================

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec checkout(pid()) -> {ok, epgpool:connection()} | error.
checkout(Pid) ->
    gen_server:call(Pid, checkout).

-spec checkin(pid(), ok | error) -> ok.
checkin(Pid, Status) ->
    gen_server:cast(Pid, {checkin, Status, self()}).

-spec kill(pid()) -> ok.
kill(Pid) ->
    Ref = monitor(process, Pid),
    gen_server:cast(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _Info} ->
            ok
    after ?KILL_TIMEOUT ->
        demonitor(Ref),
        receive
            {'DOWN', Ref, process, Pid, _Info} ->
                ok
        after 0 ->
            true = exit(Pid, brutal_kill),
            ok
        end
    end.

%%===================================================================
%% gen_server callbacks
%%===================================================================

init(Opts) ->
    self() ! init,
    erlang:process_flag(trap_exit, true),
    {ok, #state{opts=Opts}}.

handle_call(checkout, {Pid, _Ref}, #state{connection=C, owner=undefined}=State) ->
    OwnerRef = monitor(process, Pid),
    {reply, {ok, C}, State#state{owner=Pid, owner_ref=OwnerRef}};
handle_call(checkout, From, #state{connection=C, owner=_Owner}=State) ->
    ok = epgsql:close(C),
    gen_server:reply(From, error),
    {stop, conflict, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({checkin, ok, Owner}, #state{owner=Owner, owner_ref=OwnerRef}=State) ->
    true = demonitor(OwnerRef),
    {noreply, State#state{owner=undefined, owner_ref=undefined}};
handle_cast({checkin, error, Owner}, #state{owner=Owner, connection=C}=State) ->
    ok = epgsql:close(C),
    {stop, normal, State};
handle_cast(kill, #state{connection=C}=State) ->
    ok = epgsql:close(C),
    {stop, kill, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(init, #state{opts=Opts}=State) ->
    try
        {ok, C} = connect(Opts),
        {noreply, State#state{connection=C}}
    catch
        _:kill ->
            {stop, kill, State};
        _:_Error ->
            {ok, Sleep} = application:get_env(epgpool, database_retry_sleep),
            ok = timer:sleep(Sleep),
            handle_info(init, State)
    end;
handle_info({epgsql, C, {notice, Info}}, #state{connection=C}=State) ->
    lager:notice("PG notice: ~p", [Info]),
    {noreply, State};
handle_info({'DOWN', OwnerRef, process, Owner, _Info}, #state{owner=Owner, owner_ref=OwnerRef, connection=C}=State) ->
    ok = epgsql:close(C),
    {stop, down, State};
handle_info({'EXIT', C, Info}, #state{connection=C}=State) ->
    {stop, Info, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal functions
%%===================================================================

-define(WARN(Host, Port, Info),
    ok = lager:warning("PostgreSQL ~s:~p -> ~p", [Host, Port, Info])).

-spec connect(opts()) -> {ok, epgpool:connection()}.
connect(Opts) ->
    {ok, Host} = application:get_env(epgpool, database_host),
    {ok, Port} = application:get_env(epgpool, database_port),
    {ok, User} = application:get_env(epgpool, database_user),
    {ok, Passwd} = application:get_env(epgpool, database_password),
    {ok, DbName} = application:get_env(epgpool, database_name),

    {ok, C} = epgpool_conn_sup:start_sock(Opts),
    true = erlang:link(C),
    Ref = epgsqla:connect(C, Host, [User], [Passwd], [
         {database, DbName},
         {port, Port},
         {async, self()}
    ]),
    receive
        {'$gen_cast', kill} ->
            kill_and_exit(Host, Port, C, kill, ?KILL_TIMEOUT);
        {'EXIT', C, Info} ->
            ?WARN(Host, Port, Info),
            exit(Info);
        {C, Ref, connected} ->
            {ok, C};
        {C, Ref, Error} ->
            kill_and_exit(Host, Port, C, Error, ?INIT_TIMEOUT)
    after ?INIT_TIMEOUT ->
        kill_and_exit(Host, Port, C, timeout, ?INIT_TIMEOUT)
    end.

-spec kill_and_exit(Host, Port, C, Reason, timeout()) -> no_return()
    when Host :: string(), Port :: pos_integer(),
         C :: pid(), Reason :: term().
kill_and_exit(Host, Port, C, Reason, Timeout) ->
    ?WARN(Host, Port, Reason),
    ok = epgsql:close(C),
    receive
        {'EXIT', C, _Info} -> ok
    after Timeout ->
        exit(C, Reason),
        ok = skip_exit(Host, Port, C, Timeout)
    end,
    exit(Reason).

-spec skip_exit(string(), pos_integer(), pid(), timeout()) -> ok.
skip_exit(Host, Port, Pid, Timeout) ->
    receive
        {'EXIT', Pid, _Info} -> ok
    after Timeout ->
        ?WARN(Host, Port, timeout),
        exit(timeout)
    end.
