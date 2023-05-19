%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ee_bridge_mongodb_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    [
        {group, async},
        {group, sync}
        | (emqx_common_test_helpers:all(?MODULE) -- group_tests())
    ].

group_tests() ->
    [
        t_setup_via_config_and_publish,
        t_setup_via_http_api_and_publish,
        t_payload_template,
        t_collection_template,
        t_mongo_date_rule_engine_functions
    ].

groups() ->
    TypeGroups = [
        {group, rs},
        {group, sharded},
        {group, single}
    ],
    [
        {async, TypeGroups},
        {sync, TypeGroups},
        {rs, group_tests()},
        {sharded, group_tests()},
        {single, group_tests()}
    ].

init_per_group(async, Config) ->
    [{query_mode, async} | Config];
init_per_group(sync, Config) ->
    [{query_mode, sync} | Config];
init_per_group(Type = rs, Config) ->
    MongoHost = os:getenv("MONGO_RS_HOST", "mongo1"),
    MongoPort = list_to_integer(os:getenv("MONGO_RS_PORT", "27017")),
    case emqx_common_test_helpers:is_tcp_server_available(MongoHost, MongoPort) of
        true ->
            ok = start_apps(),
            emqx_mgmt_api_test_util:init_suite(),
            {Name, MongoConfig} = mongo_config(MongoHost, MongoPort, Type, Config),
            [
                {mongo_host, MongoHost},
                {mongo_port, MongoPort},
                {mongo_config, MongoConfig},
                {mongo_type, Type},
                {mongo_name, Name}
                | Config
            ];
        false ->
            {skip, no_mongo}
    end;
init_per_group(Type = sharded, Config) ->
    MongoHost = os:getenv("MONGO_SHARDED_HOST", "mongosharded3"),
    MongoPort = list_to_integer(os:getenv("MONGO_SHARDED_PORT", "27017")),
    case emqx_common_test_helpers:is_tcp_server_available(MongoHost, MongoPort) of
        true ->
            ok = start_apps(),
            emqx_mgmt_api_test_util:init_suite(),
            {Name, MongoConfig} = mongo_config(MongoHost, MongoPort, Type, Config),
            [
                {mongo_host, MongoHost},
                {mongo_port, MongoPort},
                {mongo_config, MongoConfig},
                {mongo_type, Type},
                {mongo_name, Name}
                | Config
            ];
        false ->
            {skip, no_mongo}
    end;
init_per_group(Type = single, Config) ->
    MongoHost = os:getenv("MONGO_SINGLE_HOST", "mongo"),
    MongoPort = list_to_integer(os:getenv("MONGO_SINGLE_PORT", "27017")),
    case emqx_common_test_helpers:is_tcp_server_available(MongoHost, MongoPort) of
        true ->
            ok = start_apps(),
            emqx_mgmt_api_test_util:init_suite(),
            {Name, MongoConfig} = mongo_config(MongoHost, MongoPort, Type, Config),
            [
                {mongo_host, MongoHost},
                {mongo_port, MongoPort},
                {mongo_config, MongoConfig},
                {mongo_type, Type},
                {mongo_name, Name}
                | Config
            ];
        false ->
            {skip, no_mongo}
    end.

end_per_group(_Type, _Config) ->
    ok.

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_common_test_helpers:stop_apps([emqx_bridge, emqx_conf, emqx_rule_engine]),
    ok.

init_per_testcase(_Testcase, Config) ->
    catch clear_db(Config),
    delete_bridge(Config),
    snabbkaffe:start_trace(),
    Config.

end_per_testcase(_Testcase, Config) ->
    catch clear_db(Config),
    delete_bridge(Config),
    snabbkaffe:stop(),
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

start_apps() ->
    ensure_loaded(),
    %% some configs in emqx_conf app are mandatory,
    %% we want to make sure they are loaded before
    %% ekka start in emqx_common_test_helpers:start_apps/1
    emqx_common_test_helpers:render_and_load_app_config(emqx_conf),
    ok = emqx_common_test_helpers:start_apps([emqx_conf, emqx_rule_engine, emqx_bridge]).

ensure_loaded() ->
    _ = application:load(emqx_ee_bridge),
    _ = application:load(emqtt),
    _ = emqx_ee_bridge:module_info(),
    ok.

mongo_type(Config) ->
    case ?config(mongo_type, Config) of
        rs ->
            {rs, maps:get(<<"replica_set_name">>, ?config(mongo_config, Config))};
        sharded ->
            sharded;
        single ->
            single
    end.

mongo_type_bin(rs) ->
    <<"mongodb_rs">>;
mongo_type_bin(sharded) ->
    <<"mongodb_sharded">>;
mongo_type_bin(single) ->
    <<"mongodb_single">>.

mongo_config(MongoHost, MongoPort0, rs = Type, Config) ->
    QueryMode = ?config(query_mode, Config),
    MongoPort = integer_to_list(MongoPort0),
    Servers = MongoHost ++ ":" ++ MongoPort,
    Name = atom_to_binary(?MODULE),
    ConfigString =
        io_lib:format(
            "bridges.mongodb_rs.~s {\n"
            "  enable = true\n"
            "  collection = mycol\n"
            "  replica_set_name = rs0\n"
            "  servers = [~p]\n"
            "  w_mode = safe\n"
            "  database = mqtt\n"
            "  resource_opts = {\n"
            "    query_mode = ~s\n"
            "    worker_pool_size = 1\n"
            "  }\n"
            "}",
            [
                Name,
                Servers,
                QueryMode
            ]
        ),
    {Name, parse_and_check(ConfigString, Type, Name)};
mongo_config(MongoHost, MongoPort0, sharded = Type, Config) ->
    QueryMode = ?config(query_mode, Config),
    MongoPort = integer_to_list(MongoPort0),
    Servers = MongoHost ++ ":" ++ MongoPort,
    Name = atom_to_binary(?MODULE),
    ConfigString =
        io_lib:format(
            "bridges.mongodb_sharded.~s {\n"
            "  enable = true\n"
            "  collection = mycol\n"
            "  servers = [~p]\n"
            "  w_mode = safe\n"
            "  database = mqtt\n"
            "  resource_opts = {\n"
            "    query_mode = ~s\n"
            "    worker_pool_size = 1\n"
            "  }\n"
            "}",
            [
                Name,
                Servers,
                QueryMode
            ]
        ),
    {Name, parse_and_check(ConfigString, Type, Name)};
mongo_config(MongoHost, MongoPort0, single = Type, Config) ->
    QueryMode = ?config(query_mode, Config),
    MongoPort = integer_to_list(MongoPort0),
    Server = MongoHost ++ ":" ++ MongoPort,
    Name = atom_to_binary(?MODULE),
    ConfigString =
        io_lib:format(
            "bridges.mongodb_single.~s {\n"
            "  enable = true\n"
            "  collection = mycol\n"
            "  server = ~p\n"
            "  w_mode = safe\n"
            "  database = mqtt\n"
            "  resource_opts = {\n"
            "    query_mode = ~s\n"
            "    worker_pool_size = 1\n"
            "  }\n"
            "}",
            [
                Name,
                Server,
                QueryMode
            ]
        ),
    {Name, parse_and_check(ConfigString, Type, Name)}.

parse_and_check(ConfigString, Type, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    TypeBin = mongo_type_bin(Type),
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{TypeBin := #{Name := Config}}} = RawConf,
    Config.

create_bridge(Config) ->
    create_bridge(Config, _Overrides = #{}).

create_bridge(Config, Overrides) ->
    Type = mongo_type_bin(?config(mongo_type, Config)),
    Name = ?config(mongo_name, Config),
    MongoConfig0 = ?config(mongo_config, Config),
    MongoConfig = emqx_utils_maps:deep_merge(MongoConfig0, Overrides),
    ct:pal("creating ~p bridge with config:\n ~p", [Type, MongoConfig]),
    emqx_bridge:create(Type, Name, MongoConfig).

delete_bridge(Config) ->
    Type = mongo_type_bin(?config(mongo_type, Config)),
    Name = ?config(mongo_name, Config),
    emqx_bridge:remove(Type, Name).

create_bridge_http(Params) ->
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

clear_db(Config) ->
    Type = mongo_type(Config),
    Host = ?config(mongo_host, Config),
    Port = ?config(mongo_port, Config),
    Server = Host ++ ":" ++ integer_to_list(Port),
    #{<<"database">> := Db, <<"collection">> := Collection} = ?config(mongo_config, Config),
    {ok, Client} = mongo_api:connect(Type, [Server], [], [{database, Db}, {w_mode, unsafe}]),
    {true, _} = mongo_api:delete(Client, Collection, _Selector = #{}),
    mongo_api:disconnect(Client).

find_all(Config) ->
    Type = mongo_type_bin(?config(mongo_type, Config)),
    Name = ?config(mongo_name, Config),
    #{<<"collection">> := Collection} = ?config(mongo_config, Config),
    ResourceID = emqx_bridge_resource:resource_id(Type, Name),
    emqx_resource:simple_sync_query(ResourceID, {find, Collection, #{}, #{}}).

find_all_wait_until_non_empty(Config) ->
    wait_until(
        fun() ->
            case find_all(Config) of
                {ok, []} -> false;
                _ -> true
            end
        end,
        5_000
    ),
    find_all(Config).

wait_until(Fun, Timeout) when Timeout >= 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, Timeout - 100)
    end.

send_message(Config, Payload) ->
    Name = ?config(mongo_name, Config),
    Type = mongo_type_bin(?config(mongo_type, Config)),
    BridgeID = emqx_bridge_resource:bridge_id(Type, Name),
    emqx_bridge:send_message(BridgeID, Payload).

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_setup_via_config_and_publish(Config) ->
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    Val = erlang:unique_integer(),
    {ok, {ok, _}} =
        ?wait_async_action(
            send_message(Config, #{key => Val}),
            #{?snk_kind := mongo_ee_connector_on_query_return},
            5_000
        ),
    ?assertMatch(
        {ok, [#{<<"key">> := Val}]},
        find_all(Config)
    ),
    ok.

t_setup_via_http_api_and_publish(Config) ->
    Type = mongo_type_bin(?config(mongo_type, Config)),
    Name = ?config(mongo_name, Config),
    MongoConfig0 = ?config(mongo_config, Config),
    MongoConfig = MongoConfig0#{
        <<"name">> => Name,
        <<"type">> => Type
    },
    ?assertMatch(
        {ok, _},
        create_bridge_http(MongoConfig)
    ),
    Val = erlang:unique_integer(),
    {ok, {ok, _}} =
        ?wait_async_action(
            send_message(Config, #{key => Val}),
            #{?snk_kind := mongo_ee_connector_on_query_return},
            5_000
        ),
    ?assertMatch(
        {ok, [#{<<"key">> := Val}]},
        find_all(Config)
    ),
    ok.

t_payload_template(Config) ->
    {ok, _} = create_bridge(Config, #{<<"payload_template">> => <<"{\"foo\": \"${clientid}\"}">>}),
    Val = erlang:unique_integer(),
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    {ok, {ok, _}} =
        ?wait_async_action(
            send_message(Config, #{key => Val, clientid => ClientId}),
            #{?snk_kind := mongo_ee_connector_on_query_return},
            5_000
        ),
    ?assertMatch(
        {ok, [#{<<"foo">> := ClientId}]},
        find_all(Config)
    ),
    ok.

t_collection_template(Config) ->
    {ok, _} = create_bridge(
        Config,
        #{
            <<"payload_template">> => <<"{\"foo\": \"${clientid}\"}">>,
            <<"collection">> => <<"${mycollectionvar}">>
        }
    ),
    Val = erlang:unique_integer(),
    ClientId = emqx_guid:to_hexstr(emqx_guid:gen()),
    {ok, {ok, _}} =
        ?wait_async_action(
            send_message(Config, #{
                key => Val,
                clientid => ClientId,
                mycollectionvar => <<"mycol">>
            }),
            #{?snk_kind := mongo_ee_connector_on_query_return},
            5_000
        ),
    ?assertMatch(
        {ok, [#{<<"foo">> := ClientId}]},
        find_all(Config)
    ),
    ok.

t_mongo_date_rule_engine_functions(Config) ->
    {ok, _} =
        create_bridge(
            Config,
            #{
                <<"payload_template">> =>
                    <<"{\"date_0\": ${date_0}, \"date_1\": ${date_1}, \"date_2\": ${date_2}}">>
            }
        ),
    Type = mongo_type_bin(?config(mongo_type, Config)),
    Name = ?config(mongo_name, Config),
    SQL =
        "SELECT mongo_date() as date_0, mongo_date(1000) as date_1, mongo_date(1, 'second') as date_2 FROM "
        "\"t_mongo_date_rule_engine_functions/topic\"",
    %% Remove rule if it already exists
    RuleId = <<"rule:t_mongo_date_rule_engine_functions">>,
    emqx_rule_engine:delete_rule(RuleId),
    BridgeId = emqx_bridge_resource:bridge_id(Type, Name),
    {ok, _Rule} = emqx_rule_engine:create_rule(
        #{
            id => <<"rule:t_mongo_date_rule_engine_functions">>,
            sql => SQL,
            actions => [
                BridgeId,
                #{function => console}
            ],
            description => <<"to mongo bridge">>
        }
    ),
    %% Send a message to topic
    {ok, Client} = emqtt:start_link([{clientid, <<"pub-02">>}, {proto_ver, v5}]),
    {ok, _} = emqtt:connect(Client),
    emqtt:publish(Client, <<"t_mongo_date_rule_engine_functions/topic">>, #{}, <<"{\"x\":1}">>, [
        {qos, 2}
    ]),
    emqtt:stop(Client),
    ?assertMatch(
        {ok, [
            #{
                <<"date_0">> := {_, _, _},
                <<"date_1">> := {0, 1, 0},
                <<"date_2">> := {0, 1, 0}
            }
        ]},
        find_all_wait_until_non_empty(Config)
    ),
    ok.
