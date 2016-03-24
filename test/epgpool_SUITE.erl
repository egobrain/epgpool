-module(epgpool_SUITE).

-export([
         init_per_suite/1,
         groups/0,
         init_per_group/2,
         all/0,
         end_per_group/2,
         end_per_suite/1,

         squery_test/1,
         equery_test/1,
         transaction_test/1
        ]).

-include_lib("common_test/include/ct.hrl").

init_per_suite(State) ->
    Start = os:timestamp(),
    State2 = pipe([
        fun start_sasl/1,
        fun start_lager/1,
        fun start_epgpool/1
    ], State),
    lager:info("epgpool started in ~p ms\n",
        [timer:now_diff(os:timestamp(), Start) / 1000]),
    State2.

start_sasl(State) ->
    application:load(sasl),
    application:set_env(kernel, error_logger, silent),
    application:set_env(sasl, sasl_error_logger, {file, "log/sasl.log"}),
    error_logger:tty(false),
    State.

start_lager(State) ->
    application:load(lager),
    application:set_env(lager, log_root, "log"),
    application:set_env(lager, handlers, [
        {lager_console_backend, info}
    ]),
    application:set_env(lager, error_logger_hwm, 256),
    State.

start_epgpool(State) ->
    application:load(epgpool),
    Config = epgpool_cth:start_postgres(),
    epgpool_cth:set_env(Config),
    {ok, _} = application:ensure_all_started(epgpool),
    [{pg_config, Config}|State].

init_per_group(table, Config) ->
    {ok, _, _} = epgpool:squery(
        "create table test("
        "    id int primary key,"
        "    name text"
        ");"),
    Config.

end_per_group(table, _Config) ->
    {ok, _, _} = epgpool:squery("drop table test"),
    ok.

end_per_suite(State) ->
    ok = epgpool_cth:stop_postgres(?config(pg_config, State)).

pipe(Funs, Config) ->
    lists:foldl(fun(F, S) -> F(S) end, Config, Funs).

all() ->
    [
     squery_test,
     equery_test,
     {group, table}
    ].

groups() ->
    [
     {table, [
         transaction_test
     ]}
    ].

squery_test(_Config) ->
    {ok, _Columns, [{<<"1">>}]} = epgpool:squery("select 1").

equery_test(_Config) ->
    {ok, _Columns, [{1}]} = epgpool:equery("select 1", []).

transaction_test(_Config) ->
    {ok, 1} = epgpool:squery("insert into test(id,name) values (1, 'test')"),
    proc_lib:spawn_link(fun() ->
        epgpool:transaction(fun(C) ->
           timer:sleep(100),
           {ok, 1} = epgpool:squery(C, "update test set name='t1' where id=1")
        end)
    end),
    timer:sleep(10),
    proc_lib:spawn_link(fun() ->
        epgpool:transaction(fun(C) ->
           {ok, 1} = epgpool:squery(C, "update test set name='t2' where id=1")
        end)
    end),
    timer:sleep(200),
    {ok, _, [{<<"t1">>}]} = epgpool:squery("select name from test where id = 1").
