%%--------------------------------------------------------------------
% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_rocketmq_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

% Bridge defaults
-define(TOPIC, "TopicTest").
-define(BATCH_SIZE, 10).
-define(PAYLOAD, <<"HELLO">>).

-define(GET_CONFIG(KEY__, CFG__), proplists:get_value(KEY__, CFG__)).

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    [
        {group, async},
        {group, sync}
    ].

groups() ->
    TCs = emqx_common_test_helpers:all(?MODULE),
    BatchingGroups = [{group, with_batch}, {group, without_batch}],
    [
        {async, BatchingGroups},
        {sync, BatchingGroups},
        {with_batch, TCs},
        {without_batch, TCs}
    ].

init_per_group(async, Config) ->
    [{query_mode, async} | Config];
init_per_group(sync, Config) ->
    [{query_mode, sync} | Config];
init_per_group(with_batch, Config0) ->
    Config = [{batch_size, ?BATCH_SIZE} | Config0],
    common_init(Config);
init_per_group(without_batch, Config0) ->
    Config = [{batch_size, 1} | Config0],
    common_init(Config);
init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, Config) when Group =:= with_batch; Group =:= without_batch ->
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
    delete_bridge(Config),
    Config.

end_per_testcase(_Testcase, Config) ->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    ok = snabbkaffe:stop(),
    delete_bridge(Config),
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

common_init(ConfigT) ->
    BridgeType = <<"rocketmq">>,
    Host = os:getenv("ROCKETMQ_HOST", "toxiproxy"),
    Port = list_to_integer(os:getenv("ROCKETMQ_PORT", "9876")),

    Config0 = [
        {host, Host},
        {port, Port},
        {proxy_name, "rocketmq"}
        | ConfigT
    ],

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
            {Name, RocketMQConf} = rocketmq_config(BridgeType, Config0),
            Config =
                [
                    {rocketmq_config, RocketMQConf},
                    {rocketmq_bridge_type, BridgeType},
                    {rocketmq_name, Name},
                    {proxy_host, ProxyHost},
                    {proxy_port, ProxyPort}
                    | Config0
                ],
            Config;
        false ->
            case os:getenv("IS_CI") of
                false ->
                    {skip, no_rocketmq};
                _ ->
                    throw(no_rocketmq)
            end
    end.

rocketmq_config(BridgeType, Config) ->
    Port = integer_to_list(?GET_CONFIG(port, Config)),
    Server = ?GET_CONFIG(host, Config) ++ ":" ++ Port,
    Name = atom_to_binary(?MODULE),
    BatchSize = ?config(batch_size, Config),
    QueryMode = ?config(query_mode, Config),
    ConfigString =
        io_lib:format(
            "bridges.~s.~s {\n"
            "  enable = true\n"
            "  servers = ~p\n"
            "  topic = ~p\n"
            "  resource_opts = {\n"
            "    request_timeout = 1500ms\n"
            "    batch_size = ~b\n"
            "    query_mode = ~s\n"
            "  }\n"
            "}",
            [
                BridgeType,
                Name,
                Server,
                ?TOPIC,
                BatchSize,
                QueryMode
            ]
        ),
    {Name, parse_and_check(ConfigString, BridgeType, Name)}.

parse_and_check(ConfigString, BridgeType, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{BridgeType := #{Name := Config}}} = RawConf,
    Config.

create_bridge(Config) ->
    BridgeType = ?GET_CONFIG(rocketmq_bridge_type, Config),
    Name = ?GET_CONFIG(rocketmq_name, Config),
    RocketMQConf = ?GET_CONFIG(rocketmq_config, Config),
    emqx_bridge:create(BridgeType, Name, RocketMQConf).

delete_bridge(Config) ->
    BridgeType = ?GET_CONFIG(rocketmq_bridge_type, Config),
    Name = ?GET_CONFIG(rocketmq_name, Config),
    emqx_bridge:remove(BridgeType, Name).

create_bridge_http(Params) ->
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

send_message(Config, Payload) ->
    Name = ?GET_CONFIG(rocketmq_name, Config),
    BridgeType = ?GET_CONFIG(rocketmq_bridge_type, Config),
    BridgeID = emqx_bridge_resource:bridge_id(BridgeType, Name),
    emqx_bridge:send_message(BridgeID, Payload).

query_resource(Config, Request) ->
    Name = ?GET_CONFIG(rocketmq_name, Config),
    BridgeType = ?GET_CONFIG(rocketmq_bridge_type, Config),
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),
    emqx_resource:query(ResourceID, Request, #{timeout => 500}).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_setup_via_config_and_publish(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    SentData = #{payload => ?PAYLOAD},
    ?check_trace(
        begin
            ?wait_async_action(
                ?assertEqual(ok, send_message(Config, SentData)),
                #{?snk_kind := rocketmq_connector_query_return},
                10_000
            ),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(rocketmq_connector_query_return, Trace0),
            ?assertMatch([#{result := ok}], Trace),
            ok
        end
    ),
    ok.

t_setup_via_http_api_and_publish(Config) ->
    BridgeType = ?GET_CONFIG(rocketmq_bridge_type, Config),
    Name = ?GET_CONFIG(rocketmq_name, Config),
    RocketMQConf = ?GET_CONFIG(rocketmq_config, Config),
    RocketMQConf2 = RocketMQConf#{
        <<"name">> => Name,
        <<"type">> => BridgeType
    },
    ?assertMatch(
        {ok, _},
        create_bridge_http(RocketMQConf2)
    ),
    SentData = #{payload => ?PAYLOAD},
    ?check_trace(
        begin
            ?wait_async_action(
                ?assertEqual(ok, send_message(Config, SentData)),
                #{?snk_kind := rocketmq_connector_query_return},
                10_000
            ),
            ok
        end,
        fun(Trace0) ->
            Trace = ?of_kind(rocketmq_connector_query_return, Trace0),
            ?assertMatch([#{result := ok}], Trace),
            ok
        end
    ),
    ok.

t_get_status(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),

    Name = ?GET_CONFIG(rocketmq_name, Config),
    BridgeType = ?GET_CONFIG(rocketmq_bridge_type, Config),
    ResourceID = emqx_bridge_resource:resource_id(BridgeType, Name),

    ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceID)),
    ok.

t_simple_query(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Request = {send_message, #{message => <<"Hello">>}},
    Result = query_resource(Config, Request),
    ?assertEqual(ok, Result),
    ok.
