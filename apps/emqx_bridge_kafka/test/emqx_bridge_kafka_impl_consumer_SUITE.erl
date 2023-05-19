%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_kafka_impl_consumer_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("brod/include/brod.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

-import(emqx_common_test_helpers, [on_exit/1]).

-define(BRIDGE_TYPE_BIN, <<"kafka_consumer">>).
-define(APPS, [emqx_bridge, emqx_resource, emqx_rule_engine, emqx_bridge_kafka]).

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    [
        {group, plain},
        {group, ssl},
        {group, sasl_plain},
        {group, sasl_ssl}
    ].

groups() ->
    AllTCs = emqx_common_test_helpers:all(?MODULE),
    SASLAuths = [
        sasl_auth_plain,
        sasl_auth_scram256,
        sasl_auth_scram512,
        sasl_auth_kerberos
    ],
    SASLAuthGroups = [{group, Type} || Type <- SASLAuths],
    OnlyOnceTCs = only_once_tests(),
    MatrixTCs = AllTCs -- OnlyOnceTCs,
    SASLTests = [{Group, MatrixTCs} || Group <- SASLAuths],
    [
        {plain, MatrixTCs ++ OnlyOnceTCs},
        {ssl, MatrixTCs},
        {sasl_plain, SASLAuthGroups},
        {sasl_ssl, SASLAuthGroups}
    ] ++ SASLTests.

sasl_only_tests() ->
    [t_failed_creation_then_fixed].

%% tests that do not need to be run on all groups
only_once_tests() ->
    [
        t_begin_offset_earliest,
        t_bridge_rule_action_source,
        t_cluster_group,
        t_node_joins_existing_cluster,
        t_cluster_node_down,
        t_multiple_topic_mappings
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_common_test_helpers:stop_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:stop_apps(lists:reverse(?APPS)),
    _ = application:stop(emqx_connector),
    ok.

init_per_group(plain = Type, Config) ->
    KafkaHost = os:getenv("KAFKA_PLAIN_HOST", "toxiproxy.emqx.net"),
    KafkaPort = list_to_integer(os:getenv("KAFKA_PLAIN_PORT", "9292")),
    DirectKafkaHost = os:getenv("KAFKA_DIRECT_PLAIN_HOST", "kafka-1.emqx.net"),
    DirectKafkaPort = list_to_integer(os:getenv("KAFKA_DIRECT_PLAIN_PORT", "9092")),
    ProxyName = "kafka_plain",
    case emqx_common_test_helpers:is_tcp_server_available(KafkaHost, KafkaPort) of
        true ->
            Config1 = common_init_per_group(),
            [
                {proxy_name, ProxyName},
                {kafka_host, KafkaHost},
                {kafka_port, KafkaPort},
                {direct_kafka_host, DirectKafkaHost},
                {direct_kafka_port, DirectKafkaPort},
                {kafka_type, Type},
                {use_sasl, false},
                {use_tls, false}
                | Config1 ++ Config
            ];
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_kafka);
                _ ->
                    {skip, no_kafka}
            end
    end;
init_per_group(sasl_plain = Type, Config) ->
    KafkaHost = os:getenv("KAFKA_SASL_PLAIN_HOST", "toxiproxy.emqx.net"),
    KafkaPort = list_to_integer(os:getenv("KAFKA_SASL_PLAIN_PORT", "9293")),
    DirectKafkaHost = os:getenv("KAFKA_DIRECT_SASL_HOST", "kafka-1.emqx.net"),
    DirectKafkaPort = list_to_integer(os:getenv("KAFKA_DIRECT_SASL_PORT", "9093")),
    ProxyName = "kafka_sasl_plain",
    case emqx_common_test_helpers:is_tcp_server_available(KafkaHost, KafkaPort) of
        true ->
            Config1 = common_init_per_group(),
            [
                {proxy_name, ProxyName},
                {kafka_host, KafkaHost},
                {kafka_port, KafkaPort},
                {direct_kafka_host, DirectKafkaHost},
                {direct_kafka_port, DirectKafkaPort},
                {kafka_type, Type},
                {use_sasl, true},
                {use_tls, false}
                | Config1 ++ Config
            ];
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_kafka);
                _ ->
                    {skip, no_kafka}
            end
    end;
init_per_group(ssl = Type, Config) ->
    KafkaHost = os:getenv("KAFKA_SSL_HOST", "toxiproxy.emqx.net"),
    KafkaPort = list_to_integer(os:getenv("KAFKA_SSL_PORT", "9294")),
    DirectKafkaHost = os:getenv("KAFKA_DIRECT_SSL_HOST", "kafka-1.emqx.net"),
    DirectKafkaPort = list_to_integer(os:getenv("KAFKA_DIRECT_SSL_PORT", "9094")),
    ProxyName = "kafka_ssl",
    case emqx_common_test_helpers:is_tcp_server_available(KafkaHost, KafkaPort) of
        true ->
            Config1 = common_init_per_group(),
            [
                {proxy_name, ProxyName},
                {kafka_host, KafkaHost},
                {kafka_port, KafkaPort},
                {direct_kafka_host, DirectKafkaHost},
                {direct_kafka_port, DirectKafkaPort},
                {kafka_type, Type},
                {use_sasl, false},
                {use_tls, true}
                | Config1 ++ Config
            ];
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_kafka);
                _ ->
                    {skip, no_kafka}
            end
    end;
init_per_group(sasl_ssl = Type, Config) ->
    KafkaHost = os:getenv("KAFKA_SASL_SSL_HOST", "toxiproxy.emqx.net"),
    KafkaPort = list_to_integer(os:getenv("KAFKA_SASL_SSL_PORT", "9295")),
    DirectKafkaHost = os:getenv("KAFKA_DIRECT_SASL_SSL_HOST", "kafka-1.emqx.net"),
    DirectKafkaPort = list_to_integer(os:getenv("KAFKA_DIRECT_SASL_SSL_PORT", "9095")),
    ProxyName = "kafka_sasl_ssl",
    case emqx_common_test_helpers:is_tcp_server_available(KafkaHost, KafkaPort) of
        true ->
            Config1 = common_init_per_group(),
            [
                {proxy_name, ProxyName},
                {kafka_host, KafkaHost},
                {kafka_port, KafkaPort},
                {direct_kafka_host, DirectKafkaHost},
                {direct_kafka_port, DirectKafkaPort},
                {kafka_type, Type},
                {use_sasl, true},
                {use_tls, true}
                | Config1 ++ Config
            ];
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_kafka);
                _ ->
                    {skip, no_kafka}
            end
    end;
init_per_group(sasl_auth_plain, Config) ->
    [{sasl_auth_mechanism, plain} | Config];
init_per_group(sasl_auth_scram256, Config) ->
    [{sasl_auth_mechanism, scram_sha_256} | Config];
init_per_group(sasl_auth_scram512, Config) ->
    [{sasl_auth_mechanism, scram_sha_512} | Config];
init_per_group(sasl_auth_kerberos, Config0) ->
    %% currently it's tricky to setup kerberos + toxiproxy, probably
    %% due to hostname issues...
    UseTLS = ?config(use_tls, Config0),
    {KafkaHost, KafkaPort} =
        case UseTLS of
            true ->
                {
                    os:getenv("KAFKA_SASL_SSL_HOST", "kafka-1.emqx.net"),
                    list_to_integer(os:getenv("KAFKA_SASL_SSL_PORT", "9095"))
                };
            false ->
                {
                    os:getenv("KAFKA_SASL_PLAIN_HOST", "kafka-1.emqx.net"),
                    list_to_integer(os:getenv("KAFKA_SASL_PLAIN_PORT", "9093"))
                }
        end,
    Config =
        lists:map(
            fun
                ({kafka_host, _KafkaHost}) ->
                    {kafka_host, KafkaHost};
                ({kafka_port, _KafkaPort}) ->
                    {kafka_port, KafkaPort};
                (KV) ->
                    KV
            end,
            [{has_proxy, false}, {sasl_auth_mechanism, kerberos} | Config0]
        ),
    Config;
init_per_group(_Group, Config) ->
    Config.

common_init_per_group() ->
    ProxyHost = os:getenv("PROXY_HOST", "toxiproxy"),
    ProxyPort = list_to_integer(os:getenv("PROXY_PORT", "8474")),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    application:load(emqx_bridge),
    ok = emqx_common_test_helpers:start_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:start_apps(?APPS),
    {ok, _} = application:ensure_all_started(emqx_connector),
    emqx_mgmt_api_test_util:init_suite(),
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    MQTTTopic = <<"mqtt/topic/", UniqueNum/binary>>,
    [
        {proxy_host, ProxyHost},
        {proxy_port, ProxyPort},
        {mqtt_topic, MQTTTopic},
        {mqtt_qos, 0},
        {mqtt_payload, full_message},
        {num_partitions, 3}
    ].

common_end_per_group(Config) ->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    delete_all_bridges(),
    ok.

end_per_group(Group, Config) when
    Group =:= plain;
    Group =:= ssl;
    Group =:= sasl_plain;
    Group =:= sasl_ssl
->
    common_end_per_group(Config),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) when
    TestCase =:= t_failed_creation_then_fixed
->
    KafkaType = ?config(kafka_type, Config),
    AuthMechanism = ?config(sasl_auth_mechanism, Config),
    IsSASL = lists:member(KafkaType, [sasl_plain, sasl_ssl]),
    case {IsSASL, AuthMechanism} of
        {true, kerberos} ->
            [{skip_does_not_apply, true}];
        {true, _} ->
            common_init_per_testcase(TestCase, Config);
        {false, _} ->
            [{skip_does_not_apply, true}]
    end;
init_per_testcase(TestCase, Config) when
    TestCase =:= t_failed_creation_then_fixed
->
    %% test with one partiton only for this case because
    %% the wait probe may not be always sent to the same partition
    HasProxy = proplists:get_value(has_proxy, Config, true),
    case HasProxy of
        false ->
            [{skip_does_not_apply, true}];
        true ->
            common_init_per_testcase(TestCase, [{num_partitions, 1} | Config])
    end;
init_per_testcase(TestCase, Config) when
    TestCase =:= t_on_get_status;
    TestCase =:= t_receive_after_recovery
->
    HasProxy = proplists:get_value(has_proxy, Config, true),
    case HasProxy of
        false ->
            [{skip_does_not_apply, true}];
        true ->
            common_init_per_testcase(TestCase, Config)
    end;
init_per_testcase(t_cluster_group = TestCase, Config0) ->
    Config = emqx_utils:merge_opts(Config0, [{num_partitions, 6}]),
    common_init_per_testcase(TestCase, Config);
init_per_testcase(t_multiple_topic_mappings = TestCase, Config0) ->
    KafkaTopicBase =
        <<
            (atom_to_binary(TestCase))/binary,
            (integer_to_binary(erlang:unique_integer()))/binary
        >>,
    MQTTTopicBase =
        <<"mqtt/", (atom_to_binary(TestCase))/binary,
            (integer_to_binary(erlang:unique_integer()))/binary, "/">>,
    TopicMapping =
        [
            #{
                kafka_topic => <<KafkaTopicBase/binary, "-1">>,
                mqtt_topic => <<MQTTTopicBase/binary, "1">>,
                qos => 1,
                payload_template => <<"${.}">>
            },
            #{
                kafka_topic => <<KafkaTopicBase/binary, "-2">>,
                mqtt_topic => <<MQTTTopicBase/binary, "2">>,
                qos => 2,
                payload_template => <<"v = ${.value}">>
            }
        ],
    Config = [{topic_mapping, TopicMapping} | Config0],
    common_init_per_testcase(TestCase, Config);
init_per_testcase(TestCase, Config) ->
    common_init_per_testcase(TestCase, Config).

common_init_per_testcase(TestCase, Config0) ->
    ct:timetrap(timer:seconds(60)),
    delete_all_bridges(),
    KafkaTopic =
        <<
            (atom_to_binary(TestCase))/binary,
            (integer_to_binary(erlang:unique_integer()))/binary
        >>,
    KafkaType = ?config(kafka_type, Config0),
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    MQTTTopic = proplists:get_value(mqtt_topic, Config0, <<"mqtt/topic/", UniqueNum/binary>>),
    MQTTQoS = proplists:get_value(mqtt_qos, Config0, 0),
    DefaultTopicMapping = [
        #{
            kafka_topic => KafkaTopic,
            mqtt_topic => MQTTTopic,
            qos => MQTTQoS,
            payload_template => <<"${.}">>
        }
    ],
    TopicMapping = proplists:get_value(topic_mapping, Config0, DefaultTopicMapping),
    Config = [
        {kafka_topic, KafkaTopic},
        {topic_mapping, TopicMapping}
        | Config0
    ],
    {Name, ConfigString, KafkaConfig} = kafka_config(
        TestCase, KafkaType, Config
    ),
    ensure_topics(Config),
    ProducersConfigs = start_producers(TestCase, Config),
    ok = snabbkaffe:start_trace(),
    [
        {kafka_name, Name},
        {kafka_config_string, ConfigString},
        {kafka_config, KafkaConfig},
        {kafka_producers, ProducersConfigs}
        | Config
    ].

end_per_testcase(_Testcase, Config) ->
    case proplists:get_bool(skip_does_not_apply, Config) of
        true ->
            ok;
        false ->
            ProxyHost = ?config(proxy_host, Config),
            ProxyPort = ?config(proxy_port, Config),
            ProducersConfigs = ?config(kafka_producers, Config),
            emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
            delete_all_bridges(),
            #{clientid := KafkaProducerClientId, producers := ProducersMapping} =
                ProducersConfigs,
            lists:foreach(
                fun(Producers) ->
                    ok = wolff:stop_and_delete_supervised_producers(Producers)
                end,
                maps:values(ProducersMapping)
            ),
            ok = wolff:stop_and_delete_supervised_client(KafkaProducerClientId),
            %% in CI, apparently this needs more time since the
            %% machines struggle with all the containers running...
            emqx_common_test_helpers:call_janitor(60_000),
            ok = snabbkaffe:stop(),
            ok
    end.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

start_producers(TestCase, Config) ->
    TopicMapping = ?config(topic_mapping, Config),
    KafkaClientId =
        <<"test-client-", (atom_to_binary(TestCase))/binary,
            (integer_to_binary(erlang:unique_integer()))/binary>>,
    DirectKafkaHost = ?config(direct_kafka_host, Config),
    DirectKafkaPort = ?config(direct_kafka_port, Config),
    UseTLS = ?config(use_tls, Config),
    UseSASL = ?config(use_sasl, Config),
    Hosts = emqx_bridge_kafka_impl:hosts(
        DirectKafkaHost ++ ":" ++ integer_to_list(DirectKafkaPort)
    ),
    SSL =
        case UseTLS of
            true ->
                %% hint: when running locally, need to
                %% `chmod og+rw` those files to be readable.
                emqx_tls_lib:to_client_opts(
                    #{
                        keyfile => shared_secret(client_keyfile),
                        certfile => shared_secret(client_certfile),
                        cacertfile => shared_secret(client_cacertfile),
                        verify => verify_none,
                        enable => true
                    }
                );
            false ->
                []
        end,
    SASL =
        case UseSASL of
            true -> {plain, <<"emqxuser">>, <<"password">>};
            false -> undefined
        end,
    ClientConfig = #{
        min_metadata_refresh_interval => 5_000,
        connect_timeout => 5_000,
        client_id => KafkaClientId,
        request_timeout => 1_000,
        sasl => SASL,
        ssl => SSL
    },
    {ok, Clients} = wolff:ensure_supervised_client(KafkaClientId, Hosts, ClientConfig),
    ProducersData0 =
        #{
            clients => Clients,
            clientid => KafkaClientId,
            producers => #{}
        },
    lists:foldl(
        fun(#{kafka_topic := KafkaTopic}, #{producers := ProducersMapping0} = Acc) ->
            Producers = do_start_producer(KafkaClientId, KafkaTopic),
            ProducersMapping = ProducersMapping0#{KafkaTopic => Producers},
            Acc#{producers := ProducersMapping}
        end,
        ProducersData0,
        TopicMapping
    ).

do_start_producer(KafkaClientId, KafkaTopic) ->
    Name = binary_to_atom(<<KafkaTopic/binary, "_test_producer">>),
    ProducerConfig =
        #{
            name => Name,
            partitioner => roundrobin,
            partition_count_refresh_interval_seconds => 1_000,
            replayq_max_total_bytes => 10_000,
            replayq_seg_bytes => 9_000,
            drop_if_highmem => false,
            required_acks => leader_only,
            max_batch_bytes => 900_000,
            max_send_ahead => 0,
            compression => no_compression,
            telemetry_meta_data => #{}
        },
    {ok, Producers} = wolff:ensure_supervised_producers(KafkaClientId, KafkaTopic, ProducerConfig),
    Producers.

ensure_topics(Config) ->
    TopicMapping = ?config(topic_mapping, Config),
    KafkaHost = ?config(kafka_host, Config),
    KafkaPort = ?config(kafka_port, Config),
    UseTLS = ?config(use_tls, Config),
    UseSASL = ?config(use_sasl, Config),
    NumPartitions = proplists:get_value(num_partitions, Config, 3),
    Endpoints = [{KafkaHost, KafkaPort}],
    TopicConfigs = [
        #{
            name => KafkaTopic,
            num_partitions => NumPartitions,
            replication_factor => 1,
            assignments => [],
            configs => []
        }
     || #{kafka_topic := KafkaTopic} <- TopicMapping
    ],
    RequestConfig = #{timeout => 5_000},
    ConnConfig0 =
        case UseTLS of
            true ->
                %% hint: when running locally, need to
                %% `chmod og+rw` those files to be readable.
                #{
                    ssl => emqx_tls_lib:to_client_opts(
                        #{
                            keyfile => shared_secret(client_keyfile),
                            certfile => shared_secret(client_certfile),
                            cacertfile => shared_secret(client_cacertfile),
                            verify => verify_none,
                            enable => true
                        }
                    )
                };
            false ->
                #{}
        end,
    ConnConfig =
        case UseSASL of
            true ->
                ConnConfig0#{sasl => {plain, <<"emqxuser">>, <<"password">>}};
            false ->
                ConnConfig0#{sasl => undefined}
        end,
    case brod:create_topics(Endpoints, TopicConfigs, RequestConfig, ConnConfig) of
        ok -> ok;
        {error, topic_already_exists} -> ok
    end.

shared_secret_path() ->
    os:getenv("CI_SHARED_SECRET_PATH", "/var/lib/secret").

shared_secret(client_keyfile) ->
    filename:join([shared_secret_path(), "client.key"]);
shared_secret(client_certfile) ->
    filename:join([shared_secret_path(), "client.crt"]);
shared_secret(client_cacertfile) ->
    filename:join([shared_secret_path(), "ca.crt"]);
shared_secret(rig_keytab) ->
    filename:join([shared_secret_path(), "rig.keytab"]).

publish(Config, Messages) ->
    %% pick the first topic if not specified
    #{producers := ProducersMapping} = ?config(kafka_producers, Config),
    [{KafkaTopic, Producers} | _] = maps:to_list(ProducersMapping),
    ct:pal("publishing to ~p:\n ~p", [KafkaTopic, Messages]),
    {_Partition, _OffsetReply} = wolff:send_sync(Producers, Messages, 10_000).

publish(Config, KafkaTopic, Messages) ->
    #{producers := ProducersMapping} = ?config(kafka_producers, Config),
    #{KafkaTopic := Producers} = ProducersMapping,
    ct:pal("publishing to ~p:\n ~p", [KafkaTopic, Messages]),
    {_Partition, _OffsetReply} = wolff:send_sync(Producers, Messages, 10_000).

kafka_config(TestCase, _KafkaType, Config) ->
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    KafkaHost = ?config(kafka_host, Config),
    KafkaPort = ?config(kafka_port, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    AuthType = proplists:get_value(sasl_auth_mechanism, Config, none),
    UseTLS = proplists:get_value(use_tls, Config, false),
    Name = <<
        (atom_to_binary(TestCase))/binary, UniqueNum/binary
    >>,
    MQTTTopic = proplists:get_value(mqtt_topic, Config, <<"mqtt/topic/", UniqueNum/binary>>),
    MQTTQoS = proplists:get_value(mqtt_qos, Config, 0),
    DefaultTopicMapping = [
        #{
            kafka_topic => KafkaTopic,
            mqtt_topic => MQTTTopic,
            qos => MQTTQoS,
            payload_template => <<"${.}">>
        }
    ],
    TopicMapping0 = proplists:get_value(topic_mapping, Config, DefaultTopicMapping),
    TopicMappingStr = topic_mapping(TopicMapping0),
    ConfigString =
        io_lib:format(
            "bridges.kafka_consumer.~s {\n"
            "  enable = true\n"
            "  bootstrap_hosts = \"~p:~b\"\n"
            "  connect_timeout = 5s\n"
            "  min_metadata_refresh_interval = 3s\n"
            "  metadata_request_timeout = 5s\n"
            "~s"
            "  kafka {\n"
            "    max_batch_bytes = 896KB\n"
            "    max_rejoin_attempts = 5\n"
            "    offset_commit_interval_seconds = 3\n"
            %% todo: matrix this
            "    offset_reset_policy = latest\n"
            "  }\n"
            "~s"
            "  key_encoding_mode = none\n"
            "  value_encoding_mode = none\n"
            "  ssl {\n"
            "    enable = ~p\n"
            "    verify = verify_none\n"
            "    server_name_indication = \"auto\"\n"
            "  }\n"
            "}\n",
            [
                Name,
                KafkaHost,
                KafkaPort,
                authentication(AuthType),
                TopicMappingStr,
                UseTLS
            ]
        ),
    {Name, ConfigString, parse_and_check(ConfigString, Name)}.

topic_mapping(TopicMapping0) ->
    Template0 = <<
        "{kafka_topic = \"{{ kafka_topic }}\","
        " mqtt_topic = \"{{ mqtt_topic }}\","
        " qos = {{ qos }},"
        " payload_template = \"{{{ payload_template }}}\" }"
    >>,
    Template = bbmustache:parse_binary(Template0),
    Entries =
        lists:map(
            fun(Params) ->
                bbmustache:compile(Template, Params, [{key_type, atom}])
            end,
            TopicMapping0
        ),
    iolist_to_binary(
        [
            "  topic_mapping = [",
            lists:join(<<",\n">>, Entries),
            "]\n"
        ]
    ).

authentication(Type) when
    Type =:= scram_sha_256;
    Type =:= scram_sha_512;
    Type =:= plain
->
    io_lib:format(
        "  authentication = {\n"
        "    mechanism = ~p\n"
        "    username = emqxuser\n"
        "    password = password\n"
        "  }\n",
        [Type]
    );
authentication(kerberos) ->
    %% TODO: how to make this work locally outside docker???
    io_lib:format(
        "  authentication = {\n"
        "    kerberos_principal = rig@KDC.EMQX.NET\n"
        "    kerberos_keytab_file = \"~s\"\n"
        "  }\n",
        [shared_secret(rig_keytab)]
    );
authentication(_) ->
    "  authentication = none\n".

parse_and_check(ConfigString, Name) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    TypeBin = ?BRIDGE_TYPE_BIN,
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{TypeBin := #{Name := Config}}} = RawConf,
    Config.

create_bridge(Config) ->
    create_bridge(Config, _Overrides = #{}).

create_bridge(Config, Overrides) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(kafka_name, Config),
    KafkaConfig0 = ?config(kafka_config, Config),
    KafkaConfig = emqx_utils_maps:deep_merge(KafkaConfig0, Overrides),
    emqx_bridge:create(Type, Name, KafkaConfig).

delete_bridge(Config) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(kafka_name, Config),
    emqx_bridge:remove(Type, Name).

delete_all_bridges() ->
    lists:foreach(
        fun(#{name := Name, type := Type}) ->
            emqx_bridge:remove(Type, Name)
        end,
        emqx_bridge:list()
    ).

create_bridge_api(Config) ->
    create_bridge_api(Config, _Overrides = #{}).

create_bridge_api(Config, Overrides) ->
    TypeBin = ?BRIDGE_TYPE_BIN,
    Name = ?config(kafka_name, Config),
    KafkaConfig0 = ?config(kafka_config, Config),
    KafkaConfig = emqx_utils_maps:deep_merge(KafkaConfig0, Overrides),
    Params = KafkaConfig#{<<"type">> => TypeBin, <<"name">> => Name},
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("creating bridge (via http): ~p", [Params]),
    Res =
        case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params, Opts) of
            {ok, {Status, Headers, Body0}} ->
                {ok, {Status, Headers, emqx_utils_json:decode(Body0, [return_maps])}};
            Error ->
                Error
        end,
    ct:pal("bridge create result: ~p", [Res]),
    Res.

update_bridge_api(Config) ->
    update_bridge_api(Config, _Overrides = #{}).

update_bridge_api(Config, Overrides) ->
    TypeBin = ?BRIDGE_TYPE_BIN,
    Name = ?config(kafka_name, Config),
    KafkaConfig0 = ?config(kafka_config, Config),
    KafkaConfig = emqx_utils_maps:deep_merge(KafkaConfig0, Overrides),
    BridgeId = emqx_bridge_resource:bridge_id(TypeBin, Name),
    Params = KafkaConfig#{<<"type">> => TypeBin, <<"name">> => Name},
    Path = emqx_mgmt_api_test_util:api_path(["bridges", BridgeId]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("updating bridge (via http): ~p", [Params]),
    Res =
        case emqx_mgmt_api_test_util:request_api(put, Path, "", AuthHeader, Params, Opts) of
            {ok, {_Status, _Headers, Body0}} -> {ok, emqx_utils_json:decode(Body0, [return_maps])};
            Error -> Error
        end,
    ct:pal("bridge update result: ~p", [Res]),
    Res.

probe_bridge_api(Config) ->
    TypeBin = ?BRIDGE_TYPE_BIN,
    Name = ?config(kafka_name, Config),
    KafkaConfig = ?config(kafka_config, Config),
    Params = KafkaConfig#{<<"type">> => TypeBin, <<"name">> => Name},
    Path = emqx_mgmt_api_test_util:api_path(["bridges_probe"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("probing bridge (via http): ~p", [Params]),
    Res =
        case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params, Opts) of
            {ok, {{_, 204, _}, _Headers, _Body0} = Res0} -> {ok, Res0};
            Error -> Error
        end,
    ct:pal("bridge probe result: ~p", [Res]),
    Res.

send_message(Config, Payload) ->
    Name = ?config(kafka_name, Config),
    Type = ?BRIDGE_TYPE_BIN,
    BridgeId = emqx_bridge_resource:bridge_id(Type, Name),
    emqx_bridge:send_message(BridgeId, Payload).

resource_id(Config) ->
    Type = ?BRIDGE_TYPE_BIN,
    Name = ?config(kafka_name, Config),
    emqx_bridge_resource:resource_id(Type, Name).

instance_id(Config) ->
    ResourceId = resource_id(Config),
    [{_, InstanceId}] = ets:lookup(emqx_resource_manager, {owner, ResourceId}),
    InstanceId.

wait_for_expected_published_messages(Messages0, Timeout) ->
    Messages = maps:from_list([{K, Msg} || Msg = #{key := K} <- Messages0]),
    do_wait_for_expected_published_messages(Messages, [], Timeout).

do_wait_for_expected_published_messages(Messages, Acc, _Timeout) when map_size(Messages) =:= 0 ->
    lists:reverse(Acc);
do_wait_for_expected_published_messages(Messages0, Acc0, Timeout) ->
    receive
        {publish, Msg0 = #{payload := Payload}} ->
            case emqx_utils_json:safe_decode(Payload, [return_maps]) of
                {error, _} ->
                    ct:pal("unexpected message: ~p; discarding", [Msg0]),
                    do_wait_for_expected_published_messages(Messages0, Acc0, Timeout);
                {ok, Decoded = #{<<"key">> := K}} when is_map_key(K, Messages0) ->
                    Msg = Msg0#{payload := Decoded},
                    ct:pal("received expected message: ~p", [Msg]),
                    Acc = [Msg | Acc0],
                    Messages = maps:remove(K, Messages0),
                    do_wait_for_expected_published_messages(Messages, Acc, Timeout);
                {ok, Decoded} ->
                    ct:pal("unexpected message: ~p; discarding", [Msg0#{payload := Decoded}]),
                    do_wait_for_expected_published_messages(Messages0, Acc0, Timeout)
            end
    after Timeout ->
        error(
            {timed_out_waiting_for_published_messages, #{
                so_far => Acc0,
                remaining => Messages0,
                mailbox => process_info(self(), messages)
            }}
        )
    end.

receive_published() ->
    receive_published(#{}).

receive_published(Opts0) ->
    Default = #{n => 1, timeout => 10_000},
    Opts = maps:merge(Default, Opts0),
    receive_published(Opts, []).

receive_published(#{n := N, timeout := _Timeout}, Acc) when N =< 0 ->
    lists:reverse(Acc);
receive_published(#{n := N, timeout := Timeout} = Opts, Acc) ->
    receive
        {publish, Msg} ->
            receive_published(Opts#{n := N - 1}, [Msg | Acc])
    after Timeout ->
        error(
            {timeout, #{
                msgs_so_far => Acc,
                mailbox => process_info(self(), messages),
                expected_remaining => N
            }}
        )
    end.

wait_until_subscribers_are_ready(N, Timeout) ->
    {ok, _} =
        snabbkaffe:block_until(
            ?match_n_events(N, #{?snk_kind := kafka_consumer_subscriber_init}),
            Timeout
        ),
    ok.

%% kinda hacky, but for yet unknown reasons kafka/brod seem a bit
%% flaky about when they decide truly consuming the messages...
%% `Period' should be greater than the `sleep_timeout' of the consumer
%% (default 1 s).
ping_until_healthy(Config, Period, Timeout) ->
    #{producers := ProducersMapping} = ?config(kafka_producers, Config),
    [KafkaTopic | _] = maps:keys(ProducersMapping),
    ping_until_healthy(Config, KafkaTopic, Period, Timeout).

ping_until_healthy(_Config, _KafkaTopic, _Period, Timeout) when Timeout =< 0 ->
    ct:fail("kafka subscriber did not stabilize!");
ping_until_healthy(Config, KafkaTopic, Period, Timeout) ->
    TimeA = erlang:monotonic_time(millisecond),
    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
    publish(Config, KafkaTopic, [#{key => <<"probing">>, value => Payload}]),
    Res =
        ?block_until(
            #{
                ?snk_kind := kafka_consumer_handle_message,
                ?snk_span := {complete, _},
                message := #kafka_message{value = Payload}
            },
            Period
        ),
    case Res of
        timeout ->
            TimeB = erlang:monotonic_time(millisecond),
            ConsumedTime = TimeB - TimeA,
            ping_until_healthy(Config, Period, Timeout - ConsumedTime);
        {ok, _} ->
            ResourceId = resource_id(Config),
            emqx_resource_manager:reset_metrics(ResourceId),
            ok
    end.

ensure_connected(Config) ->
    ?retry(
        _Interval = 500,
        _NAttempts = 20,
        {ok, _} = get_client_connection(Config)
    ),
    ok.

consumer_clientid(Config) ->
    KafkaName = ?config(kafka_name, Config),
    binary_to_atom(emqx_bridge_kafka_impl:make_client_id(kafka_consumer, KafkaName)).

get_client_connection(Config) ->
    KafkaHost = ?config(kafka_host, Config),
    KafkaPort = ?config(kafka_port, Config),
    ClientID = consumer_clientid(Config),
    brod_client:get_connection(ClientID, KafkaHost, KafkaPort).

get_subscriber_workers() ->
    [{_, SubscriberPid, _, _}] = supervisor:which_children(emqx_bridge_kafka_consumer_sup),
    brod_group_subscriber_v2:get_workers(SubscriberPid).

wait_downs(Refs, _Timeout) when map_size(Refs) =:= 0 ->
    ok;
wait_downs(Refs0, Timeout) ->
    receive
        {'DOWN', Ref, process, _Pid, _Reason} when is_map_key(Ref, Refs0) ->
            Refs = maps:remove(Ref, Refs0),
            wait_downs(Refs, Timeout)
    after Timeout ->
        ct:fail("processes didn't die; remaining: ~p", [map_size(Refs0)])
    end.

create_rule_and_action_http(Config) ->
    KafkaName = ?config(kafka_name, Config),
    MQTTTopic = ?config(mqtt_topic, Config),
    BridgeId = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE_BIN, KafkaName),
    ActionFn = <<(atom_to_binary(?MODULE))/binary, ":action_response">>,
    Params = #{
        enable => true,
        sql => <<"SELECT * FROM \"$bridges/", BridgeId/binary, "\"">>,
        actions =>
            [
                #{
                    <<"function">> => <<"republish">>,
                    <<"args">> =>
                        #{
                            <<"topic">> => <<"republish/", MQTTTopic/binary>>,
                            <<"payload">> => <<>>,
                            <<"qos">> => 0,
                            <<"retain">> => false,
                            <<"user_properties">> => <<"${headers}">>
                        }
                },
                #{<<"function">> => ActionFn}
            ]
    },
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    ct:pal("rule action params: ~p", [Params]),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res} -> {ok, emqx_utils_json:decode(Res, [return_maps])};
        Error -> Error
    end.

action_response(Selected, Envs, Args) ->
    ?tp(action_response, #{
        selected => Selected,
        envs => Envs,
        args => Args
    }),
    ok.

wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, Timeout) ->
    do_wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, Timeout, #{}).

do_wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, Timeout, Acc0) ->
    AllPartitionsCovered = map_size(Acc0) =:= NPartitions,
    PresentNodes = lists:usort([N || {_Partition, {N, _MemberId}} <- maps:to_list(Acc0)]),
    AllNodesCovered = PresentNodes =:= lists:usort(Nodes),
    case AllPartitionsCovered andalso AllNodesCovered of
        true ->
            ct:pal("group balanced: ~p", [Acc0]),
            {ok, Acc0};
        false ->
            receive
                {kafka_assignment, Node, {Pid, MemberId, GenerationId, TopicAssignments}} ->
                    Event = #{
                        node => Node,
                        pid => Pid,
                        member_id => MemberId,
                        generation_id => GenerationId,
                        topic_assignments => TopicAssignments
                    },
                    Acc = reconstruct_assignments_from_events(KafkaTopic, [Event], Acc0),
                    do_wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, Timeout, Acc)
            after Timeout ->
                {timeout, Acc0}
            end
    end.

reconstruct_assignments_from_events(KafkaTopic, Events) ->
    reconstruct_assignments_from_events(KafkaTopic, Events, #{}).

reconstruct_assignments_from_events(KafkaTopic, Events0, Acc0) ->
    %% when running the test multiple times with the same kafka
    %% cluster, kafka will send assignments from old test topics that
    %% we must discard.
    Assignments = [
        {MemberId, Node, P}
     || #{
            node := Node,
            member_id := MemberId,
            topic_assignments := Assignments
        } <- Events0,
        #brod_received_assignment{topic = T, partition = P} <- Assignments,
        T =:= KafkaTopic
    ],
    ct:pal("assignments for topic ~p:\n ~p", [KafkaTopic, Assignments]),
    lists:foldl(
        fun({MemberId, Node, Partition}, Acc) ->
            Acc#{Partition => {Node, MemberId}}
        end,
        Acc0,
        Assignments
    ).

setup_group_subscriber_spy(Node) ->
    TestPid = self(),
    ok = erpc:call(
        Node,
        fun() ->
            ok = meck:new(brod_group_subscriber_v2, [
                passthrough, no_link, no_history, non_strict
            ]),
            ok = meck:expect(
                brod_group_subscriber_v2,
                assignments_received,
                fun(Pid, MemberId, GenerationId, TopicAssignments) ->
                    ?tp(
                        kafka_assignment,
                        #{
                            node => node(),
                            pid => Pid,
                            member_id => MemberId,
                            generation_id => GenerationId,
                            topic_assignments => TopicAssignments
                        }
                    ),
                    TestPid !
                        {kafka_assignment, node(), {Pid, MemberId, GenerationId, TopicAssignments}},
                    meck:passthrough([Pid, MemberId, GenerationId, TopicAssignments])
                end
            ),
            ok
        end
    ).

wait_for_cluster_rpc(Node) ->
    %% need to wait until the config handler is ready after
    %% restarting during the cluster join.
    ?retry(
        _Sleep0 = 100,
        _Attempts0 = 50,
        true = is_pid(erpc:call(Node, erlang, whereis, [emqx_config_handler]))
    ).

setup_and_start_listeners(Node, NodeOpts) ->
    erpc:call(
        Node,
        fun() ->
            lists:foreach(
                fun(Type) ->
                    Port = emqx_common_test_helpers:listener_port(NodeOpts, Type),
                    ok = emqx_config:put(
                        [listeners, Type, default, bind],
                        {{127, 0, 0, 1}, Port}
                    ),
                    ok = emqx_config:put_raw(
                        [listeners, Type, default, bind],
                        iolist_to_binary([<<"127.0.0.1:">>, integer_to_binary(Port)])
                    ),
                    ok
                end,
                [tcp, ssl, ws, wss]
            ),
            ok = emqx_listeners:start(),
            ok
        end
    ).

cluster(Config) ->
    PrivDataDir = ?config(priv_dir, Config),
    PeerModule =
        case os:getenv("IS_CI") of
            false ->
                slave;
            _ ->
                ct_slave
        end,
    Cluster = emqx_common_test_helpers:emqx_cluster(
        [core, core],
        [
            {apps, [emqx_conf, emqx_bridge, emqx_rule_engine, emqx_bridge_kafka]},
            {listener_ports, []},
            {peer_mod, PeerModule},
            {priv_data_dir, PrivDataDir},
            {load_schema, true},
            {start_autocluster, true},
            {schema_mod, emqx_ee_conf_schema},
            {env_handler, fun
                (emqx) ->
                    application:set_env(emqx, boot_modules, [broker, router]),
                    ok;
                (emqx_conf) ->
                    ok;
                (_) ->
                    ok
            end}
        ]
    ),
    ct:pal("cluster: ~p", [Cluster]),
    Cluster.

start_async_publisher(Config, KafkaTopic) ->
    TId = ets:new(kafka_payloads, [public, ordered_set]),
    Loop = fun Go() ->
        receive
            stop -> ok
        after 0 ->
            Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
            publish(Config, KafkaTopic, [#{key => Payload, value => Payload}]),
            ets:insert(TId, {Payload}),
            timer:sleep(400),
            Go()
        end
    end,
    Pid = spawn_link(Loop),
    {TId, Pid}.

stop_async_publisher(Pid) ->
    MRef = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', MRef, process, Pid, _} ->
            ok
    after 1_000 ->
        ct:fail("publisher didn't die")
    end,
    ok.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_start_and_consume_ok(Config) ->
    MQTTTopic = ?config(mqtt_topic, Config),
    MQTTQoS = ?config(mqtt_qos, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    NPartitions = ?config(num_partitions, Config),
    ResourceId = resource_id(Config),
    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
    ?check_trace(
        begin
            ?assertMatch(
                {ok, _},
                create_bridge(Config)
            ),
            wait_until_subscribers_are_ready(NPartitions, 40_000),
            ping_until_healthy(Config, _Period = 1_500, _Timeout = 24_000),
            {ok, C} = emqtt:start_link(),
            on_exit(fun() -> emqtt:stop(C) end),
            {ok, _} = emqtt:connect(C),
            {ok, _, [0]} = emqtt:subscribe(C, MQTTTopic),

            {Res, {ok, _}} =
                ?wait_async_action(
                    publish(Config, [
                        #{
                            key => <<"mykey">>,
                            value => Payload,
                            headers => [{<<"hkey">>, <<"hvalue">>}]
                        }
                    ]),
                    #{?snk_kind := kafka_consumer_handle_message, ?snk_span := {complete, _}},
                    20_000
                ),

            %% Check that the bridge probe API doesn't leak atoms.
            ProbeRes0 = probe_bridge_api(Config),
            ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes0),
            AtomsBefore = erlang:system_info(atom_count),
            %% Probe again; shouldn't have created more atoms.
            ProbeRes1 = probe_bridge_api(Config),
            ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes1),
            AtomsAfter = erlang:system_info(atom_count),
            ?assertEqual(AtomsBefore, AtomsAfter),

            Res
        end,
        fun({_Partition, OffsetReply}, Trace) ->
            ?assertMatch([_, _ | _], ?of_kind(kafka_consumer_handle_message, Trace)),
            Published = receive_published(),
            ?assertMatch(
                [
                    #{
                        qos := MQTTQoS,
                        topic := MQTTTopic,
                        payload := _
                    }
                ],
                Published
            ),
            [#{payload := PayloadBin}] = Published,
            ?assertMatch(
                #{
                    <<"value">> := Payload,
                    <<"key">> := <<"mykey">>,
                    <<"topic">> := KafkaTopic,
                    <<"offset">> := OffsetReply,
                    <<"headers">> := #{<<"hkey">> := <<"hvalue">>}
                },
                emqx_utils_json:decode(PayloadBin, [return_maps]),
                #{
                    offset_reply => OffsetReply,
                    kafka_topic => KafkaTopic,
                    payload => Payload
                }
            ),
            ?assertEqual(1, emqx_resource_metrics:received_get(ResourceId)),
            ok
        end
    ),
    ok.

t_multiple_topic_mappings(Config) ->
    TopicMapping = ?config(topic_mapping, Config),
    MQTTTopics = [MQTTTopic || #{mqtt_topic := MQTTTopic} <- TopicMapping],
    KafkaTopics = [KafkaTopic || #{kafka_topic := KafkaTopic} <- TopicMapping],
    NumMQTTTopics = length(MQTTTopics),
    NPartitions = ?config(num_partitions, Config),
    ResourceId = resource_id(Config),
    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
    ?check_trace(
        begin
            ?assertMatch(
                {ok, {{_, 201, _}, _, _}},
                create_bridge_api(Config)
            ),
            wait_until_subscribers_are_ready(NPartitions, 40_000),
            lists:foreach(
                fun(KafkaTopic) ->
                    ping_until_healthy(Config, KafkaTopic, _Period = 1_500, _Timeout = 24_000)
                end,
                KafkaTopics
            ),

            {ok, C} = emqtt:start_link([{proto_ver, v5}]),
            on_exit(fun() -> emqtt:stop(C) end),
            {ok, _} = emqtt:connect(C),
            lists:foreach(
                fun(MQTTTopic) ->
                    %% we use the hightest QoS so that we can check what
                    %% the subscription was.
                    QoS2Granted = 2,
                    {ok, _, [QoS2Granted]} = emqtt:subscribe(C, MQTTTopic, ?QOS_2)
                end,
                MQTTTopics
            ),

            {ok, SRef0} =
                snabbkaffe:subscribe(
                    ?match_event(#{
                        ?snk_kind := kafka_consumer_handle_message, ?snk_span := {complete, _}
                    }),
                    NumMQTTTopics,
                    _Timeout0 = 20_000
                ),
            lists:foreach(
                fun(KafkaTopic) ->
                    publish(Config, KafkaTopic, [
                        #{
                            key => <<"mykey">>,
                            value => Payload,
                            headers => [{<<"hkey">>, <<"hvalue">>}]
                        }
                    ])
                end,
                KafkaTopics
            ),
            {ok, _} = snabbkaffe:receive_events(SRef0),

            %% Check that the bridge probe API doesn't leak atoms.
            ProbeRes0 = probe_bridge_api(Config),
            ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes0),
            AtomsBefore = erlang:system_info(atom_count),
            %% Probe again; shouldn't have created more atoms.
            ProbeRes1 = probe_bridge_api(Config),
            ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes1),
            AtomsAfter = erlang:system_info(atom_count),
            ?assertEqual(AtomsBefore, AtomsAfter),

            ok
        end,
        fun(Trace) ->
            %% two messages processed with begin/end events
            ?assertMatch([_, _, _, _ | _], ?of_kind(kafka_consumer_handle_message, Trace)),
            Published = receive_published(#{n => NumMQTTTopics}),
            lists:foreach(
                fun(
                    #{
                        mqtt_topic := MQTTTopic,
                        qos := MQTTQoS
                    }
                ) ->
                    [Msg] = [
                        Msg
                     || Msg = #{topic := T} <- Published,
                        T =:= MQTTTopic
                    ],
                    ?assertMatch(
                        #{
                            qos := MQTTQoS,
                            topic := MQTTTopic,
                            payload := _
                        },
                        Msg
                    )
                end,
                TopicMapping
            ),
            %% check that we observed the different payload templates
            %% as configured.
            Payloads =
                lists:sort([
                    case emqx_utils_json:safe_decode(P, [return_maps]) of
                        {ok, Decoded} -> Decoded;
                        {error, _} -> P
                    end
                 || #{payload := P} <- Published
                ]),
            ?assertMatch(
                [
                    #{
                        <<"headers">> := #{<<"hkey">> := <<"hvalue">>},
                        <<"key">> := <<"mykey">>,
                        <<"offset">> := Offset,
                        <<"topic">> := KafkaTopic,
                        <<"ts">> := TS,
                        <<"ts_type">> := <<"create">>,
                        <<"value">> := Payload
                    },
                    <<"v = ", Payload/binary>>
                ] when is_integer(Offset) andalso is_integer(TS) andalso is_binary(KafkaTopic),
                Payloads
            ),
            ?assertEqual(2, emqx_resource_metrics:received_get(ResourceId)),
            ok
        end
    ),
    ok.

t_on_get_status(Config) ->
    case proplists:get_bool(skip_does_not_apply, Config) of
        true ->
            ok;
        false ->
            do_t_on_get_status(Config)
    end.

do_t_on_get_status(Config) ->
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),
    KafkaName = ?config(kafka_name, Config),
    ResourceId = emqx_bridge_resource:resource_id(kafka_consumer, KafkaName),
    ?assertMatch(
        {ok, _},
        create_bridge(Config)
    ),
    %% Since the connection process is async, we give it some time to
    %% stabilize and avoid flakiness.
    ct:sleep(1_200),
    ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId)),
    emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
        ct:sleep(500),
        ?assertEqual({ok, disconnected}, emqx_resource_manager:health_check(ResourceId))
    end),
    ok.

%% ensure that we can create and use the bridge successfully after
%% creating it with bad config.
t_failed_creation_then_fixed(Config) ->
    case proplists:get_bool(skip_does_not_apply, Config) of
        true ->
            ok;
        false ->
            ?check_trace(do_t_failed_creation_then_fixed(Config), [])
    end.

do_t_failed_creation_then_fixed(Config) ->
    ct:timetrap({seconds, 180}),
    MQTTTopic = ?config(mqtt_topic, Config),
    MQTTQoS = ?config(mqtt_qos, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    NPartitions = ?config(num_partitions, Config),
    {ok, _} = create_bridge(Config, #{
        <<"authentication">> => #{<<"password">> => <<"wrong password">>}
    }),
    ?retry(
        _Interval0 = 200,
        _Attempts0 = 10,
        begin
            ClientConn0 = get_client_connection(Config),
            case ClientConn0 of
                {error, client_down} ->
                    ok;
                {error, {client_down, _Stacktrace}} ->
                    ok;
                _ ->
                    error({client_should_be_down, ClientConn0})
            end
        end
    ),
    %% now, update with the correct configuration
    ?assertMatch(
        {{ok, _}, {ok, _}},
        ?wait_async_action(
            update_bridge_api(Config),
            #{?snk_kind := kafka_consumer_subscriber_started},
            60_000
        )
    ),
    wait_until_subscribers_are_ready(NPartitions, 120_000),
    ResourceId = resource_id(Config),
    ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId)),
    ping_until_healthy(Config, _Period = 1_500, _Timeout = 24_000),

    {ok, C} = emqtt:start_link(),
    on_exit(fun() -> emqtt:stop(C) end),
    {ok, _} = emqtt:connect(C),
    {ok, _, [0]} = emqtt:subscribe(C, MQTTTopic),
    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),

    {_, {ok, _}} =
        ?wait_async_action(
            publish(Config, [
                #{
                    key => <<"mykey">>,
                    value => Payload,
                    headers => [{<<"hkey">>, <<"hvalue">>}]
                }
            ]),
            #{?snk_kind := kafka_consumer_handle_message, ?snk_span := {complete, _}},
            20_000
        ),
    Published = receive_published(),
    ?assertMatch(
        [
            #{
                qos := MQTTQoS,
                topic := MQTTTopic,
                payload := _
            }
        ],
        Published
    ),
    [#{payload := PayloadBin}] = Published,
    ?assertMatch(
        #{
            <<"value">> := Payload,
            <<"key">> := <<"mykey">>,
            <<"topic">> := KafkaTopic,
            <<"offset">> := _,
            <<"headers">> := #{<<"hkey">> := <<"hvalue">>}
        },
        emqx_utils_json:decode(PayloadBin, [return_maps]),
        #{
            kafka_topic => KafkaTopic,
            payload => Payload
        }
    ),
    ok.

%% check that we commit the offsets so that restarting an emqx node or
%% recovering from a network partition will make the subscribers
%% consume the messages produced during the down time.
t_receive_after_recovery(Config) ->
    case proplists:get_bool(skip_does_not_apply, Config) of
        true ->
            ok;
        false ->
            do_t_receive_after_recovery(Config)
    end.

do_t_receive_after_recovery(Config) ->
    ct:timetrap(120_000),
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),
    MQTTTopic = ?config(mqtt_topic, Config),
    NPartitions = ?config(num_partitions, Config),
    KafkaName = ?config(kafka_name, Config),
    KafkaNameA = binary_to_atom(KafkaName),
    KafkaClientId = consumer_clientid(Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            {ok, _} = create_bridge(
                Config,
                #{<<"kafka">> => #{<<"offset_reset_policy">> => <<"earliest">>}}
            ),
            ping_until_healthy(Config, _Period = 1_500, _Timeout0 = 24_000),
            {ok, connected} = emqx_resource_manager:health_check(ResourceId),
            %% 0) ensure each partition commits its offset so it can
            %% recover later.
            Messages0 = [
                #{
                    key => <<"commit", (integer_to_binary(N))/binary>>,
                    value => <<"commit", (integer_to_binary(N))/binary>>
                }
             || N <- lists:seq(1, NPartitions)
            ],
            %% we do distinct passes over this producing part so that
            %% wolff won't batch everything together.
            lists:foreach(
                fun(Msg) ->
                    {_, {ok, _}} =
                        ?wait_async_action(
                            publish(Config, [Msg]),
                            #{
                                ?snk_kind := kafka_consumer_handle_message,
                                ?snk_span := {complete, {ok, commit, _}}
                            },
                            _Timeout1 = 2_000
                        )
                end,
                Messages0
            ),
            ?retry(
                _Interval = 500,
                _NAttempts = 20,
                begin
                    GroupId = emqx_bridge_kafka_impl_consumer:consumer_group_id(KafkaNameA),
                    {ok, [#{partitions := Partitions}]} = brod:fetch_committed_offsets(
                        KafkaClientId, GroupId
                    ),
                    NPartitions = length(Partitions)
                end
            ),
            %% we need some time to avoid flakiness due to the
            %% subscription happening while the consumers are still
            %% publishing messages...
            ct:sleep(500),

            %% 1) cut the connection with kafka.
            WorkerRefs = maps:from_list([
                {monitor(process, Pid), Pid}
             || {_TopicPartition, Pid} <-
                    maps:to_list(get_subscriber_workers())
            ]),
            NumMsgs = 50,
            Messages1 = [
                begin
                    X = emqx_guid:to_hexstr(emqx_guid:gen()),
                    #{
                        key => X,
                        value => X
                    }
                end
             || _ <- lists:seq(1, NumMsgs)
            ],
            {ok, C} = emqtt:start_link(),
            on_exit(fun() -> emqtt:stop(C) end),
            {ok, _} = emqtt:connect(C),
            {ok, _, [0]} = emqtt:subscribe(C, MQTTTopic),
            emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
                wait_downs(WorkerRefs, _Timeout2 = 1_000),
                %% 2) publish messages while the consumer is down.
                %% we use `pmap' to avoid wolff sending the whole
                %% batch to a single partition.
                emqx_utils:pmap(fun(Msg) -> publish(Config, [Msg]) end, Messages1),
                ok
            end),
            %% 3) restore and consume messages
            {ok, SRef1} = snabbkaffe:subscribe(
                ?match_event(#{
                    ?snk_kind := kafka_consumer_handle_message,
                    ?snk_span := {complete, _}
                }),
                NumMsgs,
                _Timeout3 = 60_000
            ),
            {ok, _} = snabbkaffe:receive_events(SRef1),
            #{num_msgs => NumMsgs, msgs => lists:sort(Messages1)}
        end,
        fun(#{num_msgs := NumMsgs, msgs := ExpectedMsgs}, Trace) ->
            Received0 = wait_for_expected_published_messages(ExpectedMsgs, _Timeout4 = 2_000),
            Received1 =
                lists:map(
                    fun(#{payload := #{<<"key">> := K, <<"value">> := V}}) ->
                        #{key => K, value => V}
                    end,
                    Received0
                ),
            Received = lists:sort(Received1),
            ?assertEqual(ExpectedMsgs, Received),
            ?assert(length(?of_kind(kafka_consumer_handle_message, Trace)) > NumMsgs * 2),
            ok
        end
    ),
    ok.

t_bridge_rule_action_source(Config) ->
    MQTTTopic = ?config(mqtt_topic, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    ResourceId = resource_id(Config),
    ?check_trace(
        begin
            {ok, _} = create_bridge(Config),
            ping_until_healthy(Config, _Period = 1_500, _Timeout = 24_000),

            {ok, #{<<"id">> := RuleId}} = create_rule_and_action_http(Config),
            on_exit(fun() -> ok = emqx_rule_engine:delete_rule(RuleId) end),

            RepublishTopic = <<"republish/", MQTTTopic/binary>>,
            {ok, C} = emqtt:start_link([{proto_ver, v5}]),
            on_exit(fun() -> emqtt:stop(C) end),
            {ok, _} = emqtt:connect(C),
            {ok, _, [0]} = emqtt:subscribe(C, RepublishTopic),

            UniquePayload = emqx_guid:to_hexstr(emqx_guid:gen()),
            {_, {ok, _}} =
                ?wait_async_action(
                    publish(Config, [
                        #{
                            key => UniquePayload,
                            value => UniquePayload,
                            headers => [{<<"hkey">>, <<"hvalue">>}]
                        }
                    ]),
                    #{?snk_kind := action_response},
                    5_000
                ),

            #{republish_topic => RepublishTopic, unique_payload => UniquePayload}
        end,
        fun(Res, _Trace) ->
            #{
                republish_topic := RepublishTopic,
                unique_payload := UniquePayload
            } = Res,
            Published = receive_published(),
            ?assertMatch(
                [
                    #{
                        topic := RepublishTopic,
                        properties := #{'User-Property' := [{<<"hkey">>, <<"hvalue">>}]},
                        payload := _Payload,
                        dup := false,
                        qos := 0,
                        retain := false
                    }
                ],
                Published
            ),
            [#{payload := RawPayload}] = Published,
            ?assertMatch(
                #{
                    <<"key">> := UniquePayload,
                    <<"value">> := UniquePayload,
                    <<"headers">> := #{<<"hkey">> := <<"hvalue">>},
                    <<"topic">> := KafkaTopic
                },
                emqx_utils_json:decode(RawPayload, [return_maps])
            ),
            ?retry(
                _Interval = 200,
                _NAttempts = 20,
                ?assertEqual(1, emqx_resource_metrics:received_get(ResourceId))
            ),
            ok
        end
    ),
    ok.

%% checks that an existing cluster can be configured with a kafka
%% consumer bridge and that the consumers will distribute over the two
%% nodes.
t_cluster_group(Config) ->
    ct:timetrap({seconds, 150}),
    NPartitions = ?config(num_partitions, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    KafkaName = ?config(kafka_name, Config),
    ResourceId = resource_id(Config),
    BridgeId = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE_BIN, KafkaName),
    Cluster = cluster(Config),
    ?check_trace(
        begin
            Nodes =
                [_N1, N2 | _] = [
                    emqx_common_test_helpers:start_slave(Name, Opts)
                 || {Name, Opts} <- Cluster
                ],
            on_exit(fun() ->
                emqx_utils:pmap(
                    fun(N) ->
                        ct:pal("stopping ~p", [N]),
                        ok = emqx_common_test_helpers:stop_slave(N)
                    end,
                    Nodes
                )
            end),
            lists:foreach(fun setup_group_subscriber_spy/1, Nodes),
            {ok, SRef0} = snabbkaffe:subscribe(
                ?match_event(#{?snk_kind := kafka_consumer_subscriber_started}),
                length(Nodes),
                15_000
            ),
            wait_for_cluster_rpc(N2),
            erpc:call(N2, fun() -> {ok, _} = create_bridge(Config) end),
            {ok, _} = snabbkaffe:receive_events(SRef0),
            lists:foreach(
                fun(N) ->
                    ?assertMatch(
                        {ok, _},
                        erpc:call(N, emqx_bridge, lookup, [BridgeId]),
                        #{node => N}
                    )
                end,
                Nodes
            ),

            %% give kafka some time to rebalance the group; we need to
            %% sleep so that the two nodes have time to distribute the
            %% subscribers, rather than just one node containing all
            %% of them.
            {ok, _} = wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, 30_000),
            lists:foreach(
                fun(N) ->
                    ?assertEqual(
                        {ok, connected},
                        erpc:call(N, emqx_resource_manager, health_check, [ResourceId]),
                        #{node => N}
                    )
                end,
                Nodes
            ),

            #{nodes => Nodes}
        end,
        fun(Res, Trace0) ->
            #{nodes := Nodes} = Res,
            Trace1 = ?of_kind(kafka_assignment, Trace0),
            Assignments = reconstruct_assignments_from_events(KafkaTopic, Trace1),
            ?assertEqual(
                lists:usort(Nodes),
                lists:usort([
                    N
                 || {_Partition, {N, _MemberId}} <-
                        maps:to_list(Assignments)
                ])
            ),
            ?assertEqual(NPartitions, map_size(Assignments)),
            ok
        end
    ),
    ok.

%% test that the kafka consumer group rebalances correctly if a bridge
%% already exists when a new EMQX node joins the cluster.
t_node_joins_existing_cluster(Config) ->
    ct:timetrap({seconds, 150}),
    TopicMapping = ?config(topic_mapping, Config),
    [MQTTTopic] = [MQTTTopic || #{mqtt_topic := MQTTTopic} <- TopicMapping],
    NPartitions = ?config(num_partitions, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    KafkaName = ?config(kafka_name, Config),
    ResourceId = resource_id(Config),
    BridgeId = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE_BIN, KafkaName),
    Cluster = cluster(Config),
    ?check_trace(
        begin
            [{Name1, Opts1}, {Name2, Opts2} | _] = Cluster,
            ct:pal("starting ~p", [Name1]),
            N1 = emqx_common_test_helpers:start_slave(Name1, Opts1),
            on_exit(fun() ->
                ct:pal("stopping ~p", [N1]),
                ok = emqx_common_test_helpers:stop_slave(N1)
            end),
            setup_group_subscriber_spy(N1),
            {{ok, _}, {ok, _}} =
                ?wait_async_action(
                    erpc:call(N1, fun() ->
                        {ok, _} = create_bridge(
                            Config,
                            #{
                                <<"kafka">> =>
                                    #{
                                        <<"offset_reset_policy">> =>
                                            <<"earliest">>
                                    }
                            }
                        )
                    end),
                    #{?snk_kind := kafka_consumer_subscriber_started},
                    15_000
                ),
            ?assertMatch({ok, _}, erpc:call(N1, emqx_bridge, lookup, [BridgeId])),
            {ok, _} = wait_until_group_is_balanced(KafkaTopic, NPartitions, [N1], 30_000),
            ?assertEqual(
                {ok, connected},
                erpc:call(N1, emqx_resource_manager, health_check, [ResourceId])
            ),

            %% Now, we start the second node and have it join the cluster.
            setup_and_start_listeners(N1, Opts1),
            TCPPort1 = emqx_common_test_helpers:listener_port(Opts1, tcp),
            {ok, C1} = emqtt:start_link([{port, TCPPort1}, {proto_ver, v5}]),
            on_exit(fun() -> catch emqtt:stop(C1) end),
            {ok, _} = emqtt:connect(C1),
            {ok, _, [2]} = emqtt:subscribe(C1, MQTTTopic, 2),

            {ok, SRef0} = snabbkaffe:subscribe(
                ?match_event(#{?snk_kind := kafka_consumer_subscriber_started}),
                1,
                30_000
            ),
            ct:pal("starting ~p", [Name2]),
            N2 = emqx_common_test_helpers:start_slave(Name2, Opts2),
            on_exit(fun() ->
                ct:pal("stopping ~p", [N2]),
                ok = emqx_common_test_helpers:stop_slave(N2)
            end),
            setup_group_subscriber_spy(N2),
            Nodes = [N1, N2],
            wait_for_cluster_rpc(N2),

            {ok, _} = snabbkaffe:receive_events(SRef0),
            ?retry(
                _Sleep1 = 100,
                _Attempts1 = 50,
                ?assertMatch({ok, _}, erpc:call(N2, emqx_bridge, lookup, [BridgeId]))
            ),

            %% Give some time for the consumers in both nodes to
            %% rebalance.
            {ok, _} = wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, 30_000),
            %% Publish some messages so we can check they came from each node.
            ?retry(
                _Sleep2 = 100,
                _Attempts2 = 50,
                true = erpc:call(N2, emqx_router, has_routes, [MQTTTopic])
            ),
            {ok, SRef1} =
                snabbkaffe:subscribe(
                    ?match_event(#{
                        ?snk_kind := kafka_consumer_handle_message,
                        ?snk_span := {complete, _}
                    }),
                    NPartitions,
                    20_000
                ),
            lists:foreach(
                fun(N) ->
                    Key = <<"k", (integer_to_binary(N))/binary>>,
                    Val = <<"v", (integer_to_binary(N))/binary>>,
                    publish(Config, KafkaTopic, [#{key => Key, value => Val}])
                end,
                lists:seq(1, NPartitions)
            ),
            {ok, _} = snabbkaffe:receive_events(SRef1),

            #{nodes => Nodes}
        end,
        fun(Res, Trace0) ->
            #{nodes := Nodes} = Res,
            Trace1 = ?of_kind(kafka_assignment, Trace0),
            Assignments = reconstruct_assignments_from_events(KafkaTopic, Trace1),
            NodeAssignments = lists:usort([
                N
             || {_Partition, {N, _MemberId}} <-
                    maps:to_list(Assignments)
            ]),
            ?assertEqual(lists:usort(Nodes), NodeAssignments),
            ?assertEqual(NPartitions, map_size(Assignments)),
            Published = receive_published(#{n => NPartitions, timeout => 3_000}),
            ct:pal("published:\n  ~p", [Published]),
            PublishingNodesFromTrace =
                [
                    N
                 || #{
                        ?snk_kind := kafka_consumer_handle_message,
                        ?snk_span := start,
                        ?snk_meta := #{node := N}
                    } <- Trace0
                ],
            ?assertEqual(lists:usort(Nodes), lists:usort(PublishingNodesFromTrace)),
            ok
        end
    ),
    ok.

%% Checks that the consumers get rebalanced after an EMQX nodes goes
%% down.
t_cluster_node_down(Config) ->
    ct:timetrap({seconds, 150}),
    TopicMapping = ?config(topic_mapping, Config),
    [MQTTTopic] = [MQTTTopic || #{mqtt_topic := MQTTTopic} <- TopicMapping],
    NPartitions = ?config(num_partitions, Config),
    KafkaTopic = ?config(kafka_topic, Config),
    KafkaName = ?config(kafka_name, Config),
    BridgeId = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE_BIN, KafkaName),
    Cluster = cluster(Config),
    ?check_trace(
        begin
            {_N2, Opts2} = lists:nth(2, Cluster),
            Nodes =
                [N1, N2 | _] =
                lists:map(
                    fun({Name, Opts}) ->
                        ct:pal("starting ~p", [Name]),
                        emqx_common_test_helpers:start_slave(Name, Opts)
                    end,
                    Cluster
                ),
            on_exit(fun() ->
                emqx_utils:pmap(
                    fun(N) ->
                        ct:pal("stopping ~p", [N]),
                        ok = emqx_common_test_helpers:stop_slave(N)
                    end,
                    Nodes
                )
            end),
            lists:foreach(fun setup_group_subscriber_spy/1, Nodes),
            {ok, SRef0} = snabbkaffe:subscribe(
                ?match_event(#{?snk_kind := kafka_consumer_subscriber_started}),
                length(Nodes),
                15_000
            ),
            wait_for_cluster_rpc(N2),
            erpc:call(N2, fun() -> {ok, _} = create_bridge(Config) end),
            {ok, _} = snabbkaffe:receive_events(SRef0),
            lists:foreach(
                fun(N) ->
                    ?retry(
                        _Sleep1 = 100,
                        _Attempts1 = 50,
                        ?assertMatch(
                            {ok, _},
                            erpc:call(N, emqx_bridge, lookup, [BridgeId]),
                            #{node => N}
                        )
                    )
                end,
                Nodes
            ),
            {ok, _} = wait_until_group_is_balanced(KafkaTopic, NPartitions, Nodes, 30_000),

            %% Now, we stop one of the nodes and watch the group
            %% rebalance.
            setup_and_start_listeners(N2, Opts2),
            TCPPort = emqx_common_test_helpers:listener_port(Opts2, tcp),
            {ok, C} = emqtt:start_link([{port, TCPPort}, {proto_ver, v5}]),
            on_exit(fun() -> catch emqtt:stop(C) end),
            {ok, _} = emqtt:connect(C),
            {ok, _, [2]} = emqtt:subscribe(C, MQTTTopic, 2),
            {TId, Pid} = start_async_publisher(Config, KafkaTopic),

            ct:pal("stopping node ~p", [N1]),
            ok = emqx_common_test_helpers:stop_slave(N1),

            %% Give some time for the consumers in remaining node to
            %% rebalance.
            {ok, _} = wait_until_group_is_balanced(KafkaTopic, NPartitions, [N2], 60_000),

            ok = stop_async_publisher(Pid),

            #{nodes => Nodes, payloads_tid => TId}
        end,
        fun(Res, Trace0) ->
            #{nodes := Nodes, payloads_tid := TId} = Res,
            [_N1, N2 | _] = Nodes,
            Trace1 = ?of_kind(kafka_assignment, Trace0),
            Assignments = reconstruct_assignments_from_events(KafkaTopic, Trace1),
            NodeAssignments = lists:usort([
                N
             || {_Partition, {N, _MemberId}} <-
                    maps:to_list(Assignments)
            ]),
            %% The surviving node has all the partitions assigned to
            %% it.
            ?assertEqual([N2], NodeAssignments),
            ?assertEqual(NPartitions, map_size(Assignments)),
            NumPublished = ets:info(TId, size),
            %% All published messages are eventually received.
            Published = receive_published(#{n => NumPublished, timeout => 3_000}),
            ct:pal("published:\n  ~p", [Published]),
            ok
        end
    ),
    ok.

t_begin_offset_earliest(Config) ->
    MQTTTopic = ?config(mqtt_topic, Config),
    ResourceId = resource_id(Config),
    Payload = emqx_guid:to_hexstr(emqx_guid:gen()),
    {ok, C} = emqtt:start_link([{proto_ver, v5}]),
    on_exit(fun() -> emqtt:stop(C) end),
    {ok, _} = emqtt:connect(C),
    {ok, _, [2]} = emqtt:subscribe(C, MQTTTopic, 2),

    ?check_trace(
        begin
            %% publish a message before the bridge is started.
            NumMessages = 5,
            lists:foreach(
                fun(N) ->
                    publish(Config, [
                        #{
                            key => <<"mykey", (integer_to_binary(N))/binary>>,
                            value => Payload,
                            headers => [{<<"hkey">>, <<"hvalue">>}]
                        }
                    ])
                end,
                lists:seq(1, NumMessages)
            ),

            {ok, _} = create_bridge(Config, #{
                <<"kafka">> => #{<<"offset_reset_policy">> => <<"earliest">>}
            }),

            #{num_published => NumMessages}
        end,
        fun(Res, _Trace) ->
            #{num_published := NumMessages} = Res,
            %% we should receive messages published before starting
            %% the consumers
            Published = receive_published(#{n => NumMessages}),
            Payloads = lists:map(
                fun(#{payload := P}) -> emqx_utils_json:decode(P, [return_maps]) end,
                Published
            ),
            ?assert(
                lists:all(
                    fun(#{<<"value">> := V}) -> V =:= Payload end,
                    Payloads
                ),
                #{payloads => Payloads}
            ),
            ?assertEqual(NumMessages, emqx_resource_metrics:received_get(ResourceId)),
            ok
        end
    ),
    ok.
