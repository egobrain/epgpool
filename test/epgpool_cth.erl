-module(epgpool_cth).

-export([
         start_epgpool/0,
         start_postgres/0,
         stop_postgres/1,
         set_env/1
        ]).

-define(PG_TIMEOUT, 30000).

start_epgpool() ->
    Config = start_postgres(),
    ok = set_env(Config),
    Config.

set_env(#{pg_port := PgPort, pg_host := PgHost, pg_database := PgDatabase,
          pg_user := PgUser, pg_pass := PgPass}) ->
    application:set_env(epgpool, database_port, PgPort),
    application:set_env(epgpool, database_host, PgHost),
    application:set_env(epgpool, database_name, PgDatabase),
    application:set_env(epgpool, database_user, PgUser),
    application:set_env(epgpool, database_password, PgPass),
    ok.

start_postgres() ->
    {ok, _} = application:ensure_all_started(erlexec),
    pipe([
        fun find_utils/1,
        fun init_database/1,
        fun start_postgresql/1,
        fun create_user/1,
        fun create_database/1
    ], #{}).

stop_postgres(#{pg_proc := PgProc}) ->
    PgProc ! stop,
    ok.

find_utils(State) ->
    Utils = [initdb, createdb, createuser, postgres],
    UtilsMap = lists:foldl(fun(U, Map) ->
        UList = atom_to_list(U),
        Path = case os:find_executable(UList) of
            false ->
                case filelib:wildcard("/usr/lib/postgresql/**/" ++ UList) of
                    [] ->
                        io:format("~s not found", [U]),
                        throw({util_no_found, U});
                    List -> lists:last(lists:sort(List))
                end;
            P -> P
        end,
        maps:put(U, Path, Map)
    end, #{}, Utils),
    State#{utils => UtilsMap}.

start_postgresql(#{pg_datadir := PgDataDir, utils := #{postgres := Postgres}} = Config) ->
    PgHost = "localhost",
    PgPort = get_free_port(),
    SocketDir = "/tmp/",
    Pid = proc_lib:spawn(fun() ->
        {ok, _, I} = exec:run_link(lists:concat([Postgres,
            " -k ", SocketDir,
            " -D ", PgDataDir,
            " -h ", PgHost,
            " -p ", PgPort]),
            [{stderr,
              fun(_, _, Msg) ->
                  lager:info("postgres: ~s", [Msg])
              end}]),
        (fun Loop() ->
             receive
                 stop -> exec:kill(I, 0);
                 _ -> Loop()
             end
        end)()
    end),
    ConfigR = Config#{pg_host => PgHost, pg_port => PgPort, pg_proc => Pid},
    wait_postgresql_ready(SocketDir, ConfigR).

wait_postgresql_ready(SocketDir, #{pg_port := PgPort} = Config) ->
    PgFile = lists:concat([".s.PGSQL.", PgPort]),
    Path = filename:join(SocketDir, PgFile),
    WaitUntil = ts_add(os:timestamp(), ?PG_TIMEOUT),
    case wait_(Path, WaitUntil) of
        true -> ok;
        false -> throw(<<"Postgresql init timeout">>)
    end,
    Config.

wait_(Path, Until) ->
    case file:read_file_info(Path) of
        {error, enoent} ->
            case os:timestamp() > Until of
                true -> false;
                _ ->
                    timer:sleep(300),
                    wait_(Path, Until)
            end;
        _ -> true
    end.

init_database(#{utils := #{initdb := Initdb}}=Config) ->
    {ok, Cwd} = file:get_cwd(),
    PgDataDir = filename:append(Cwd, gen_data_dir_name()),
    {ok, _} = exec:run(Initdb ++ " -A trust -D " ++ PgDataDir, [sync,stdout,stderr]),
    Config#{pg_datadir => PgDataDir}.

create_user(#{pg_host := PgHost, pg_port := PgPort,
              utils := #{createuser := Createuser}} = Config) ->
    PgUser = "test_user",
    {ok, []} = exec:run(lists:concat([Createuser,
        " -drswh ", PgHost,
        " -p ", PgPort,
        " ", PgUser]), [sync]),
    Config#{pg_user => PgUser, pg_pass => <<"no_password">>}.

create_database(#{pg_host := PgHost, pg_port := PgPort, pg_user := PgUser,
                 utils := #{createdb := CreateDB}} = Config) ->
    PgDatabase = "test_database",
    {ok, []} = exec:run(lists:concat([CreateDB,
        " -wO ", PgUser,
        " -h ", PgHost,
        " -p ", PgPort,
        " ", PgDatabase]), [sync]),
    Config#{pg_database => PgDatabase}.

%% =============================================================================
%% Internal functions
%% =============================================================================

get_free_port() ->
    {ok, Listen} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

pipe(Funs, Config) ->
    lists:foldl(fun(F, S) -> F(S) end, Config, Funs).

ts_add({Mega, Sec, Micro}, Timeout) ->
    V = (Mega * 1000000 + Sec)*1000000 + Micro + Timeout * 1000,
    {V div 1000000000000,
     V div 1000000 rem 1000000,
     V rem 1000000}.

gen_data_dir_name() ->
    {{Y,M,D}, {Hh,Mm,Ss}} = calendar:universal_time(),
    lists:flatten(io_lib:format(
        "pg_data_~4..0b~2..0b~2..0b~2..0b~2..0b~2..0b",
        [Y,M,D,Hh,Mm,Ss])).
