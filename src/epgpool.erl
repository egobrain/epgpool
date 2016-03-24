-module(epgpool).

-include_lib("epgsql/include/epgsql.hrl").

-export([
    equery/2,
    equery/3,
    squery/1,
    squery/2,
    transaction/1,
    transaction/2,
    with/1,
    with/2,
    kill_all_workers/0
]).

-type pgsql_ret() ::
       epgsql:ok_reply(tuple()) |
       {error, epgsql:query_error() | dupplicate | foreignkey}.
-type connection() :: pid().
-type func(A) :: fun((connection()) -> A).

-export_type([pgsql_ret/0, connection/0, func/1]).

-define(TIMEOUT, 60000).

%% =============================================================================
%% Api Functions
%% =============================================================================

-spec equery(Sql :: iolist(), Params :: list()) -> pgsql_ret().
equery(Sql, Params) ->
    with(fun(C) -> equery(C, Sql, Params) end).

-spec equery(connection(), iolist(), list()) -> pgsql_ret().
equery(C, Sql, Params) ->
    handle_error(Sql, epgsql:equery(C, Sql, Params)).

-spec squery(Sql :: iolist()) -> pgsql_ret().
squery(Sql) ->
    with(fun(C) -> squery(C, Sql) end).

-spec squery(connection(),iolist()) -> pgsql_ret().
squery(C, Sql) ->
    handle_error(Sql, epgsql:squery(C, Sql)).

-spec transaction(func(A)) -> A.
transaction(F) ->
    transaction(F, ?TIMEOUT).

-spec transaction(func(A), timeout()) -> A.
transaction(Fun, Timeout) ->
    with(fun (C) ->
        Result =
        try
            {ok, [], []} = squery(C, "BEGIN"),
            Fun(C)
        catch Class:Reason ->
            Stacktrace = erlang:get_stacktrace(),
            catch (squery(C, "ROLLBACK")),
            erlang:raise(Class, Reason, Stacktrace)
        end,
        {ok, [], []} = squery(C, "COMMIT"),
        Result
    end, Timeout).

-spec with(func(A)) -> A.
with(Fun) ->
    with(Fun, ?TIMEOUT).

-spec with(func(A), timeout()) -> A.
with(Fun, Timeout) ->
    Worker = poolboy:checkout(epgpool, true, Timeout),
    call(Worker, Fun).

call(Worker, Fun) ->
    try
        case get(checked_out) of
            undefined -> ok;
            _ ->
                case application:get_env(epgpool, log_nested_checkouts, false) of
                    true ->
                        {_, StackTrace} = process_info(self(), current_stacktrace),
                        lager:error("Nested checkout: ~p", [StackTrace]);
                    _ -> ok
                end
        end,
        put(checked_out, true),

        {ok, Connection} = epgpool_worker:checkout(Worker),
        Result = Fun(Connection),
        epgpool_worker:checkin(Worker, ok),
        Result
    catch Class:Reason ->
        Stacktrace = erlang:get_stacktrace(),
        epgpool_worker:checkin(Worker, error),
        case application:get_env(epgpool, log_errors_verbose, false) of
            true ->
                lager:error(
                    "Exception thrown in epgpool:with, Class = ~p, Reason = ~p, Stacktrace = ~p",
                    [Class, Reason, Stacktrace]);
            _ -> ok
        end,
        erlang:raise(Class, Reason, Stacktrace)
    after
        erase(checked_out),
        poolboy:checkin(epgpool, Worker)
    end.

-spec kill_all_workers() -> ok.
kill_all_workers() ->
    Workers = gen_server:call(epgpool_sup, get_all_workers),
    _ = [ epgpool_worker:kill(Pid) || {_, Pid, worker, _} <- Workers ],
    ok.

%% =============================================================================
%% Internal functions
%% =============================================================================

handle_error(_Sql, {error, #error{code= <<"23505">>}}) -> {error, duplicate};
handle_error(_Sql, {error, #error{code= <<"23503">>}}) -> {error, foreignkey};
handle_error(Sql, {error, Error=#error{message=Msg}}) ->
    ok = lager:error("PostgreSQL Error: ~s | Query: ~s", [Msg, Sql]),
    {error, Error};
handle_error(_Sql, Ok) -> Ok.
