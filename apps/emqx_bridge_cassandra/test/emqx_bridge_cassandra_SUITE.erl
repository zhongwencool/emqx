%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_cassandra_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

% SQL definitions
-define(SQL_BRIDGE,
    "insert into mqtt_msg_test(topic, payload, arrived) "
    "values (${topic}, ${payload}, ${timestamp})"
).
-define(SQL_CREATE_TABLE,
    ""
    "\n"
    "CREATE TABLE mqtt.mqtt_msg_test (\n"
    "    topic text,\n"
    "    payload text,\n"
    "    arrived timestamp,\n"
    "    PRIMARY KEY (topic)\n"
    ");\n"
    ""
).
-define(SQL_DROP_TABLE, "DROP TABLE mqtt.mqtt_msg_test").
-define(SQL_DELETE, "TRUNCATE mqtt.mqtt_msg_test").
-define(SQL_SELECT, "SELECT payload FROM mqtt.mqtt_msg_test").

% DB defaults
-define(CASSA_KEYSPACE, "mqtt").
-define(CASSA_USERNAME, "cassandra").
-define(CASSA_PASSWORD, "cassandra").
-define(BATCH_SIZE, 10).

%% cert files for client
-define(CERT_ROOT,
    filename:join([emqx_common_test_helpers:proj_root(), ".ci", "docker-compose-file", "certs"])
).

-define(CAFILE, filename:join(?CERT_ROOT, ["ca.crt"])).
-define(CERTFILE, filename:join(?CERT_ROOT, ["client.pem"])).
-define(KEYFILE, filename:join(?CERT_ROOT, ["client.key"])).

%% How to run it locally:
%%  1. Start all deps services
%%    sudo docker compose -f .ci/docker-compose-file/docker-compose.yaml \
%%                        -f .ci/docker-compose-file/docker-compose-cassandra.yaml \
%%                        -f .ci/docker-compose-file/docker-compose-toxiproxy.yaml \
%%                        up --build
%%
%%  2. Run use cases with special environment variables
%%    CASSA_TCP_HOST=127.0.0.1 CASSA_TCP_PORT=19042 \
%%    CASSA_TLS_HOST=127.0.0.1 CASSA_TLS_PORT=19142 \
%%    PROXY_HOST=127.0.0.1 ./rebar3 as test ct -c -v --name ct@127.0.0.1 \
%%    --suite apps/emqx_bridge_cassandra/test/emqx_bridge_cassandra_SUITE.erl
%%

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    [
        {group, tcp},
        {group, tls}
    ].

groups() ->
    TCs = emqx_common_test_helpers:all(?MODULE),
    NonBatchCases = [t_write_timeout, t_simple_sql_query],
    QueryModeGroups = [{group, async}, {group, sync}],
    BatchingGroups = [
        {group, with_batch},
        {group, without_batch}
    ],
    [
        {tcp, QueryModeGroups},
        {tls, QueryModeGroups},
        {async, BatchingGroups},
        {sync, BatchingGroups},
        {with_batch, TCs -- NonBatchCases},
        {without_batch, TCs}
    ].

init_per_group(tcp, Config) ->
    Host = os:getenv("CASSA_TCP_HOST", "toxiproxy"),
    Port = list_to_integer(os:getenv("CASSA_TCP_PORT", "9042")),
    [
        {cassa_host, Host},
        {cassa_port, Port},
        {enable_tls, false},
        {proxy_name, "cassa_tcp"}
        | Config
    ];
init_per_group(tls, Config) ->
    Host = os:getenv("CASSA_TLS_HOST", "toxiproxy"),
    Port = list_to_integer(os:getenv("CASSA_TLS_PORT", "9142")),
    [
        {cassa_host, Host},
        {cassa_port, Port},
        {enable_tls, true},
        {proxy_name, "cassa_tls"}
        | Config
    ];
init_per_group(async, Config) ->
    [{query_mode, async} | Config];
init_per_group(sync, Config) ->
    [{query_mode, sync} | Config];
init_per_group(with_batch, Config0) ->
    Config = [{enable_batch, true} | Config0],
    common_init(Config);
init_per_group(without_batch, Config0) ->
    Config = [{enable_batch, false} | Config0],
    common_init(Config);
init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, Config) when
    Group == without_batch; Group == without_batch
->
    connect_and_drop_table(Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_common_test_helpers:stop_apps([emqx_bridge, emqx_conf]),
    ok.

init_per_testcase(_Testcase, Config) ->
    connect_and_clear_table(Config),
    delete_bridge(Config),
    snabbkaffe:start_trace(),
    Config.

end_per_testcase(_Testcase, Config) ->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    ok = snabbkaffe:stop(),
    connect_and_clear_table(Config),
    delete_bridge(Config),
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

common_init(Config0) ->
    ct:pal("commit_init: ~p~n", [Config0]),
    BridgeType = proplists:get_value(bridge_type, Config0, <<"cassandra">>),
    Host = ?config(cassa_host, Config0),
    Port = ?config(cassa_port, Config0),
    case emqx_common_test_helpers:is_tcp_server_available(Host, Port) of
        true ->
            % Setup toxiproxy
            ProxyHost = os:getenv("PROXY_HOST", "toxiproxy"),
            ProxyPort = list_to_integer(os:getenv("PROXY_PORT", "8474")),
            emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
            % Ensure EE bridge module is loaded
            _ = application:load(emqx_ee_bridge),
            _ = emqx_ee_bridge:module_info(),
            ok = emqx_common_test_helpers:start_apps([emqx_conf, emqx_bridge]),
            emqx_mgmt_api_test_util:init_suite(),
            % Connect to cassnadra directly and create the table
            catch connect_and_drop_table(Config0),
            connect_and_create_table(Config0),
            {Name, CassaConf} = cassa_config(BridgeType, Config0),
            Config =
                [
                    {cassa_config, CassaConf},
                    {cassa_bridge_type, BridgeType},
                    {cassa_name, Name},
                    {proxy_host, ProxyHost},
                    {proxy_port, ProxyPort}
                    | Config0
                ],
            Config;
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_cassandra);
                _ ->
                    {skip, no_cassandra}
            end
    end.

cassa_config(BridgeType, Config) ->
    Port = integer_to_list(?config(cassa_port, Config)),
    Server = ?config(cassa_host, Config) ++ ":" ++ Port,
    Name = atom_to_binary(?MODULE),
    BatchSize =
        case ?config(enable_batch, Config) of
            true -> ?BATCH_SIZE;
            false -> 1
        end,
    QueryMode = ?config(query_mode, Config),
    TlsEnabled = ?config(enable_tls, Config),
    ConfigString =
        io_lib:format(
            "bridges.~s.~s {\n"
            "  enable = true\n"
            "  servers = ~p\n"
            "  keyspace = ~p\n"
            "  username = ~p\n"
            "  password = ~p\n"
            "  cql = ~p\n"
            "  resource_opts = {\n"
            "    request_timeout = 500ms\n"
            "    batch_size = ~b\n"
            "    query_mode = ~s\n"
            "  }\n"
            "  ssl = {\n"
            "    enable = ~w\n"
            "    cacertfile = \"~s\"\n"
            "    certfile = \"~s\"\n"
            "    keyfile = \"~s\"\n"
            "    server_name_indication = disable\n"
            "  }\n"
            "}",
            [
                BridgeType,
                Name,
                Server,
                ?CASSA_KEYSPACE,
                ?CASSA_USERNAME,
                ?CASSA_PASSWORD,
                ?SQL_BRIDGE,
                BatchSize,
                QueryMode,
                TlsEnabled,
                ?CAFILE,
                ?CERTFILE,
                ?KEYFILE
            ]
        ),
    {Name, parse_and_check(ConfigString, BridgeType, Name)}.

parse_and_check(ConfigString, BridgeType, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{BridgeType := #{Name := Config}}} = RawConf,
    Config.

create_bridge(Config) ->
    create_bridge(Config, _Overrides = #{}).

create_bridge(Config, Overrides) ->
    BridgeType = ?config(cassa_bridge_type, Config),
    Name = ?config(cassa_name, Config),
    BridgeConfig0 = ?config(cassa_config, Config),
    BridgeConfig = emqx_utils_maps:deep_merge(BridgeConfig0, Overrides),
    emqx_bridge:create(BridgeType, Name, BridgeConfig).

delete_bridge(Config) ->
    BridgeType = ?config(cassa_bridge_type, Config),
    Name = ?config(cassa_name, Config),
    emqx_bridge:remove(BridgeType, Name).

create_bridge_http(Params) ->
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

bridges_probe_http(Params) ->
    Path = emqx_mgmt_api_test_util:api_path(["bridges_probe"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, _} -> ok;
        Error -> Error
    end.

send_message(Config, Payload) ->
    Name = ?config(cassa_name, Config),
    BridgeType = ?config(cassa_bridge_type, Config),
    BridgeID = emqx_bridge_resource:bridge_id(BridgeType, Name),
    emqx_bridge:send_message(BridgeID, Payload).

query_resource(Config, Request) ->
    Name = ?config(cassa_name, Config),
    BridgeType = ?config(cassa_bridge_type, Config),
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),
    emqx_resource:query(ResourceID, Request, #{timeout => 1_000}).

query_resource_async(Config, Request) ->
    Name = ?config(cassa_name, Config),
    BridgeType = ?config(cassa_bridge_type, Config),
    Ref = alias([reply]),
    AsyncReplyFun = fun(Result) -> Ref ! {result, Ref, Result} end,
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),
    Return = emqx_resource:query(ResourceID, Request, #{
        timeout => 500, async_reply_fun => {AsyncReplyFun, []}
    }),
    {Return, Ref}.

receive_result(Ref, Timeout) when is_reference(Ref) ->
    receive
        {result, Ref, Result} ->
            {ok, Result};
        {Ref, Result} ->
            {ok, Result}
    after Timeout ->
        timeout
    end.

connect_direct_cassa(Config) ->
    Opts = #{
        nodes => [{?config(cassa_host, Config), ?config(cassa_port, Config)}],
        username => ?CASSA_USERNAME,
        password => ?CASSA_PASSWORD,
        keyspace => ?CASSA_KEYSPACE
    },
    SslOpts =
        case ?config(enable_tls, Config) of
            true ->
                Opts#{
                    ssl => emqx_tls_lib:to_client_opts(
                        #{
                            enable => true,
                            cacertfile => ?CAFILE,
                            certfile => ?CERTFILE,
                            keyfile => ?KEYFILE
                        }
                    )
                };
            false ->
                Opts
        end,
    {ok, Con} = ecql:connect(maps:to_list(SslOpts)),
    Con.

% These funs connect and then stop the cassandra connection
connect_and_create_table(Config) ->
    with_direct_conn(Config, fun(Conn) ->
        {ok, _} = ecql:query(Conn, ?SQL_CREATE_TABLE)
    end).

connect_and_drop_table(Config) ->
    with_direct_conn(Config, fun(Conn) ->
        {ok, _} = ecql:query(Conn, ?SQL_DROP_TABLE)
    end).

connect_and_clear_table(Config) ->
    with_direct_conn(Config, fun(Conn) ->
        ok = ecql:query(Conn, ?SQL_DELETE)
    end).

connect_and_get_payload(Config) ->
    with_direct_conn(Config, fun(Conn) ->
        {ok, {_Keyspace, _ColsSpec, [[Result]]}} = ecql:query(Conn, ?SQL_SELECT),
        Result
    end).

with_direct_conn(Config, Fn) ->
    Conn = connect_direct_cassa(Config),
    try
        Fn(Conn)
    after
        ok = ecql:close(Conn)
    end.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_setup_via_config_and_publish(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Val = integer_to_binary(erlang:unique_integer()),
    SentData = #{
        topic => atom_to_binary(?FUNCTION_NAME),
        payload => Val,
        timestamp => 1668602148000
    },
    ?check_trace(
        begin
            ?wait_async_action(
                ?assertEqual(ok, send_message(Config, SentData)),
                #{?snk_kind := cassandra_connector_query_return},
                10_000
            ),
            ?assertMatch(
                Val,
                connect_and_get_payload(Config)
            ),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(cassandra_connector_query_return, Trace0),
            ?assertMatch([#{result := {ok, _Pid}}], Trace),
            ok
        end
    ),
    ok.

t_setup_via_http_api_and_publish(Config) ->
    BridgeType = ?config(cassa_bridge_type, Config),
    Name = ?config(cassa_name, Config),
    BridgeConfig0 = ?config(cassa_config, Config),
    BridgeConfig = BridgeConfig0#{
        <<"name">> => Name,
        <<"type">> => BridgeType
    },
    ?assertMatch(
        {ok, _},
        create_bridge_http(BridgeConfig)
    ),
    Val = integer_to_binary(erlang:unique_integer()),
    SentData = #{
        topic => atom_to_binary(?FUNCTION_NAME),
        payload => Val,
        timestamp => 1668602148000
    },
    ?check_trace(
        begin
            ?wait_async_action(
                ?assertEqual(ok, send_message(Config, SentData)),
                #{?snk_kind := cassandra_connector_query_return},
                10_000
            ),
            ?assertMatch(
                Val,
                connect_and_get_payload(Config)
            ),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(cassandra_connector_query_return, Trace0),
            ?assertMatch([#{result := {ok, _Pid}}], Trace),
            ok
        end
    ),
    ok.

t_get_status(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),

    Name = ?config(cassa_name, Config),
    BridgeType = ?config(cassa_bridge_type, Config),
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),

    ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceID)),
    emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
        ?assertMatch(
            {ok, Status} when Status =:= disconnected orelse Status =:= connecting,
            emqx_resource_manager:health_check(ResourceID)
        )
    end),
    ok.

t_bridges_probe_via_http(Config) ->
    BridgeType = ?config(cassa_bridge_type, Config),
    Name = ?config(cassa_name, Config),
    BridgeConfig0 = ?config(cassa_config, Config),
    BridgeConfig = BridgeConfig0#{
        <<"name">> => Name,
        <<"type">> => BridgeType
    },
    ?assertMatch(ok, bridges_probe_http(BridgeConfig)),

    ok.

t_create_disconnected(Config) ->
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),
    ?check_trace(
        emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
            ?assertMatch({ok, _}, create_bridge(Config))
        end),
        fun(Trace) ->
            ?assertMatch(
                [#{error := {start_pool_failed, _, _}}],
                ?of_kind(cassandra_connector_start_failed, Trace)
            ),
            ok
        end
    ),
    ok.

t_write_failure(Config) ->
    ProxyName = ?config(proxy_name, Config),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    QueryMode = ?config(query_mode, Config),
    {ok, _} = create_bridge(Config),
    Val = integer_to_binary(erlang:unique_integer()),
    SentData = #{
        topic => atom_to_binary(?FUNCTION_NAME),
        payload => Val,
        timestamp => 1668602148000
    },
    ?check_trace(
        emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
            {_, {ok, _}} =
                ?wait_async_action(
                    case QueryMode of
                        sync ->
                            ?assertMatch({error, _}, send_message(Config, SentData));
                        async ->
                            send_message(Config, SentData)
                    end,
                    #{?snk_kind := buffer_worker_flush_nack},
                    10_000
                )
        end),
        fun(Trace0) ->
            ct:pal("trace: ~p", [Trace0]),
            Trace = ?of_kind(buffer_worker_flush_nack, Trace0),
            [#{result := Result} | _] = Trace,
            case Result of
                {async_return, {error, {resource_error, _}}} ->
                    ok;
                {async_return, {error, {recoverable_error, disconnected}}} ->
                    ok;
                {error, {resource_error, _}} ->
                    ok;
                _ ->
                    ct:fail("unexpected error: ~p", [Result])
            end
        end
    ),
    ok.

%% This test doesn't work with batch enabled since it is not possible
%% to set the timeout directly for batch queries
%%
%% XXX: parameter with request timeout is not supported yet.
%%
%t_write_timeout(Config) ->
%    ProxyName = ?config(proxy_name, Config),
%    ProxyPort = ?config(proxy_port, Config),
%    ProxyHost = ?config(proxy_host, Config),
%    {ok, _} = create_bridge(Config),
%    Val = integer_to_binary(erlang:unique_integer()),
%    SentData = #{payload => Val, timestamp => 1668602148000},
%    Timeout = 1000,
%    emqx_common_test_helpers:with_failure(timeout, ProxyName, ProxyHost, ProxyPort, fun() ->
%        ?assertMatch(
%            {error, {resource_error, #{reason := timeout}}},
%            query_resource(Config, {send_message, SentData, [], Timeout})
%        )
%    end),
%    ok.

t_simple_sql_query(Config) ->
    QueryMode = ?config(query_mode, Config),
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Request = {query, <<"SELECT count(1) AS T FROM system.local">>},
    Result =
        case QueryMode of
            sync ->
                query_resource(Config, Request);
            async ->
                {_, Ref} = query_resource_async(Config, Request),
                {ok, Res} = receive_result(Ref, 2_000),
                Res
        end,
    ?assertMatch({ok, {<<"system.local">>, _, [[1]]}}, Result),
    ok.

t_missing_data(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    %% emqx_bridge_cassandra_connector will send missed data as a `null` atom
    %% to ecql driver
    ?check_trace(
        begin
            ?wait_async_action(
                send_message(Config, #{}),
                #{?snk_kind := handle_async_reply, result := {error, {8704, _}}},
                10_000
            ),
            ok
        end,
        fun(Trace0) ->
            %% 1. ecql driver will return `ok` first in async query
            Trace = ?of_kind(cassandra_connector_query_return, Trace0),
            ?assertMatch([#{result := {ok, _Pid}}], Trace),
            %% 2. then it will return an error in callback function
            Trace1 = ?of_kind(handle_async_reply, Trace0),
            ?assertMatch([#{result := {error, {8704, _}}}], Trace1),
            ok
        end
    ),
    ok.

t_bad_sql_parameter(Config) ->
    QueryMode = ?config(query_mode, Config),
    ?assertMatch(
        {ok, _},
        create_bridge(
            Config,
            #{
                <<"resource_opts">> => #{
                    <<"request_timeout">> => 500,
                    <<"resume_interval">> => 100,
                    <<"health_check_interval">> => 100
                }
            }
        )
    ),
    Request = {query, <<"">>, [bad_parameter]},
    Result =
        case QueryMode of
            sync ->
                query_resource(Config, Request);
            async ->
                {_, Ref} = query_resource_async(Config, Request),
                case receive_result(Ref, 5_000) of
                    {ok, Res} ->
                        Res;
                    timeout ->
                        ct:pal("mailbox:\n  ~p", [process_info(self(), messages)]),
                        ct:fail("no response received")
                end
        end,
    ?assertMatch({error, _}, Result),
    ok.

t_nasty_sql_string(Config) ->
    ?assertMatch({ok, _}, create_bridge(Config)),
    Payload = list_to_binary(lists:seq(1, 127)),
    Message = #{
        topic => atom_to_binary(?FUNCTION_NAME),
        payload => Payload,
        timestamp => erlang:system_time(millisecond)
    },
    %% XXX: why ok instead of {ok, AffectedLines}?
    ?assertEqual(ok, send_message(Config, Message)),
    ?assertEqual(Payload, connect_and_get_payload(Config)).
