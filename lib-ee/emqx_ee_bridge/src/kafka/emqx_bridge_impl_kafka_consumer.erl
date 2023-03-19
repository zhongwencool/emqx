%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_impl_kafka_consumer).

-behaviour(emqx_resource).

%% `emqx_resource' API
-export([
    callback_mode/0,
    is_buffer_supported/0,
    on_start/2,
    on_stop/2,
    on_get_status/2
]).

%% `brod_group_consumer' API
-export([
    init/2,
    handle_message/2
]).

-ifdef(TEST).
-export([consumer_group_id/1]).
-endif.

-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
%% needed for the #kafka_message record definition
-include_lib("brod/include/brod.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").

-type config() :: #{
    authentication := term(),
    bootstrap_hosts := binary(),
    bridge_name := atom(),
    kafka := #{
        max_batch_bytes := emqx_schema:bytesize(),
        max_rejoin_attempts := non_neg_integer(),
        offset_commit_interval_seconds := pos_integer(),
        offset_reset_policy := offset_reset_policy(),
        topic := binary()
    },
    topic_mapping := nonempty_list(
        #{
            kafka_topic := kafka_topic(),
            mqtt_topic := emqx_types:topic(),
            qos := emqx_types:qos(),
            payload_template := string()
        }
    ),
    ssl := _,
    any() => term()
}.
-type subscriber_id() :: emqx_ee_bridge_kafka_consumer_sup:child_id().
-type kafka_topic() :: brod:topic().
-type state() :: #{
    kafka_topics := nonempty_list(kafka_topic()),
    subscriber_id := subscriber_id(),
    kafka_client_id := brod:client_id()
}.
-type offset_reset_policy() :: reset_to_latest | reset_to_earliest | reset_by_subscriber.
%% -type mqtt_payload() :: full_message | message_value.
-type encoding_mode() :: none | base64.
-type consumer_init_data() :: #{
    hookpoint := binary(),
    key_encoding_mode := encoding_mode(),
    resource_id := resource_id(),
    topic_mapping := #{
        kafka_topic() := #{
            payload_template := emqx_plugin_libs_rule:tmpl_token(),
            mqtt_topic => emqx_types:topic(),
            qos => emqx_types:qos()
        }
    },
    value_encoding_mode := encoding_mode()
}.
-type consumer_state() :: #{
    hookpoint := binary(),
    kafka_topic := binary(),
    key_encoding_mode := encoding_mode(),
    resource_id := resource_id(),
    topic_mapping := #{
        kafka_topic() := #{
            payload_template := emqx_plugin_libs_rule:tmpl_token(),
            mqtt_topic => emqx_types:topic(),
            qos => emqx_types:qos()
        }
    },
    value_encoding_mode := encoding_mode()
}.
-type subscriber_init_info() :: #{
    topic => brod:topic(),
    parition => brod:partition(),
    group_id => brod:group_id(),
    commit_fun => brod_group_subscriber_v2:commit_fun()
}.

%%-------------------------------------------------------------------------------------
%% `emqx_resource' API
%%-------------------------------------------------------------------------------------

callback_mode() ->
    async_if_possible.

%% there are no queries to be made to this bridge, so we say that
%% buffer is supported so we don't spawn unused resource buffer
%% workers.
is_buffer_supported() ->
    true.

-spec on_start(manager_id(), config()) -> {ok, state()}.
on_start(InstanceId, Config) ->
    #{
        authentication := Auth,
        bootstrap_hosts := BootstrapHosts0,
        bridge_name := BridgeName,
        hookpoint := _,
        kafka := #{
            max_batch_bytes := _,
            max_rejoin_attempts := _,
            offset_commit_interval_seconds := _,
            offset_reset_policy := _
        },
        ssl := SSL,
        topic_mapping := _
    } = Config,
    BootstrapHosts = emqx_bridge_impl_kafka:hosts(BootstrapHosts0),
    KafkaType = kafka_consumer,
    %% Note: this is distinct per node.
    ClientID = make_client_id(InstanceId, KafkaType, BridgeName),
    ClientOpts0 =
        case Auth of
            none -> [];
            Auth -> [{sasl, emqx_bridge_impl_kafka:sasl(Auth)}]
        end,
    ClientOpts = add_ssl_opts(ClientOpts0, SSL),
    case brod:start_client(BootstrapHosts, ClientID, ClientOpts) of
        ok ->
            ?tp(
                kafka_consumer_client_started,
                #{client_id => ClientID, instance_id => InstanceId}
            ),
            ?SLOG(info, #{
                msg => "kafka_consumer_client_started",
                instance_id => InstanceId,
                kafka_hosts => BootstrapHosts
            });
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "failed_to_start_kafka_consumer_client",
                instance_id => InstanceId,
                kafka_hosts => BootstrapHosts,
                reason => emqx_misc:redact(Reason)
            }),
            throw(failed_to_start_kafka_client)
    end,
    start_consumer(Config, InstanceId, ClientID).

-spec on_stop(manager_id(), state()) -> ok.
on_stop(_InstanceID, State) ->
    #{
        subscriber_id := SubscriberId,
        kafka_client_id := ClientID
    } = State,
    stop_subscriber(SubscriberId),
    stop_client(ClientID),
    ok.

-spec on_get_status(manager_id(), state()) -> connected | disconnected.
on_get_status(_InstanceID, State) ->
    #{
        subscriber_id := SubscriberId,
        kafka_client_id := ClientID,
        kafka_topics := KafkaTopics
    } = State,
    do_get_status(ClientID, KafkaTopics, SubscriberId).

%%-------------------------------------------------------------------------------------
%% `brod_group_subscriber' API
%%-------------------------------------------------------------------------------------

-spec init(subscriber_init_info(), consumer_init_data()) -> {ok, consumer_state()}.
init(GroupData, State0) ->
    ?tp(kafka_consumer_subscriber_init, #{group_data => GroupData, state => State0}),
    #{topic := KafkaTopic} = GroupData,
    State = State0#{kafka_topic => KafkaTopic},
    {ok, State}.

-spec handle_message(#kafka_message{}, consumer_state()) -> {ok, commit, consumer_state()}.
handle_message(Message, State) ->
    ?tp_span(
        kafka_consumer_handle_message,
        #{message => Message, state => State},
        do_handle_message(Message, State)
    ).

do_handle_message(Message, State) ->
    #{
        hookpoint := Hookpoint,
        kafka_topic := KafkaTopic,
        key_encoding_mode := KeyEncodingMode,
        resource_id := ResourceId,
        topic_mapping := TopicMapping,
        value_encoding_mode := ValueEncodingMode
    } = State,
    #{
        mqtt_topic := MQTTTopic,
        qos := MQTTQoS,
        payload_template := PayloadTemplate
    } = maps:get(KafkaTopic, TopicMapping),
    FullMessage = #{
        headers => maps:from_list(Message#kafka_message.headers),
        key => encode(Message#kafka_message.key, KeyEncodingMode),
        offset => Message#kafka_message.offset,
        topic => KafkaTopic,
        ts => Message#kafka_message.ts,
        ts_type => Message#kafka_message.ts_type,
        value => encode(Message#kafka_message.value, ValueEncodingMode)
    },
    Payload = render(FullMessage, PayloadTemplate),
    MQTTMessage = emqx_message:make(ResourceId, MQTTQoS, MQTTTopic, Payload),
    _ = emqx:publish(MQTTMessage),
    emqx:run_hook(Hookpoint, [FullMessage]),
    emqx_resource_metrics:received_inc(ResourceId),
    %% note: just `ack' does not commit the offset to the
    %% kafka consumer group.
    {ok, commit, State}.

%%-------------------------------------------------------------------------------------
%% Helper fns
%%-------------------------------------------------------------------------------------

add_ssl_opts(ClientOpts, #{enable := false}) ->
    ClientOpts;
add_ssl_opts(ClientOpts, SSL) ->
    [{ssl, emqx_tls_lib:to_client_opts(SSL)} | ClientOpts].

-spec make_subscriber_id(atom() | binary()) -> emqx_ee_bridge_kafka_consumer_sup:child_id().
make_subscriber_id(BridgeName) ->
    BridgeNameBin = to_bin(BridgeName),
    <<"kafka_subscriber:", BridgeNameBin/binary>>.

ensure_consumer_supervisor_started() ->
    Mod = emqx_ee_bridge_kafka_consumer_sup,
    ChildSpec =
        #{
            id => Mod,
            start => {Mod, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [Mod]
        },
    case supervisor:start_child(emqx_bridge_sup, ChildSpec) of
        {ok, _Pid} ->
            ok;
        {error, already_present} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok
    end.

-spec start_consumer(config(), manager_id(), brod:client_id()) -> {ok, state()}.
start_consumer(Config, InstanceId, ClientID) ->
    #{
        bootstrap_hosts := BootstrapHosts0,
        bridge_name := BridgeName,
        hookpoint := Hookpoint,
        kafka := #{
            max_batch_bytes := MaxBatchBytes,
            max_rejoin_attempts := MaxRejoinAttempts,
            offset_commit_interval_seconds := OffsetCommitInterval,
            offset_reset_policy := OffsetResetPolicy
        },
        key_encoding_mode := KeyEncodingMode,
        topic_mapping := TopicMapping0,
        value_encoding_mode := ValueEncodingMode
    } = Config,
    ok = ensure_consumer_supervisor_started(),
    TopicMapping = convert_topic_mapping(TopicMapping0),
    InitialState = #{
        key_encoding_mode => KeyEncodingMode,
        hookpoint => Hookpoint,
        resource_id => emqx_bridge_resource:resource_id(kafka_consumer, BridgeName),
        topic_mapping => TopicMapping,
        value_encoding_mode => ValueEncodingMode
    },
    %% note: the group id should be the same for all nodes in the
    %% cluster, so that the load gets distributed between all
    %% consumers and we don't repeat messages in the same cluster.
    GroupID = consumer_group_id(BridgeName),
    ConsumerConfig = [
        {max_bytes, MaxBatchBytes},
        {offset_reset_policy, OffsetResetPolicy}
    ],
    GroupConfig = [
        {max_rejoin_attempts, MaxRejoinAttempts},
        {offset_commit_interval_seconds, OffsetCommitInterval}
    ],
    KafkaTopics = maps:keys(TopicMapping),
    GroupSubscriberConfig =
        #{
            client => ClientID,
            group_id => GroupID,
            topics => KafkaTopics,
            cb_module => ?MODULE,
            init_data => InitialState,
            message_type => message,
            consumer_config => ConsumerConfig,
            group_config => GroupConfig
        },
    %% Below, we spawn a single `brod_group_consumer_v2' worker, with
    %% no option for a pool of those. This is because that worker
    %% spawns one worker for each assigned topic-partition
    %% automatically, so we should not spawn duplicate workers.
    SubscriberId = make_subscriber_id(BridgeName),
    case emqx_ee_bridge_kafka_consumer_sup:start_child(SubscriberId, GroupSubscriberConfig) of
        {ok, _ConsumerPid} ->
            ?tp(
                kafka_consumer_subscriber_started,
                #{instance_id => InstanceId, subscriber_id => SubscriberId}
            ),
            {ok, #{
                subscriber_id => SubscriberId,
                kafka_client_id => ClientID,
                kafka_topics => KafkaTopics
            }};
        {error, Reason2} ->
            ?SLOG(error, #{
                msg => "failed_to_start_kafka_consumer",
                instance_id => InstanceId,
                kafka_hosts => emqx_bridge_impl_kafka:hosts(BootstrapHosts0),
                reason => emqx_misc:redact(Reason2)
            }),
            stop_client(ClientID),
            throw(failed_to_start_kafka_consumer)
    end.

-spec stop_subscriber(emqx_ee_bridge_kafka_consumer_sup:child_id()) -> ok.
stop_subscriber(SubscriberId) ->
    _ = log_when_error(
        fun() ->
            emqx_ee_bridge_kafka_consumer_sup:ensure_child_deleted(SubscriberId)
        end,
        #{
            msg => "failed_to_delete_kafka_subscriber",
            subscriber_id => SubscriberId
        }
    ),
    ok.

-spec stop_client(brod:client_id()) -> ok.
stop_client(ClientID) ->
    _ = log_when_error(
        fun() ->
            brod:stop_client(ClientID)
        end,
        #{
            msg => "failed_to_delete_kafka_consumer_client",
            client_id => ClientID
        }
    ),
    ok.

do_get_status(ClientID, [KafkaTopic | RestTopics], SubscriberId) ->
    case brod:get_partitions_count(ClientID, KafkaTopic) of
        {ok, NPartitions} ->
            case do_get_status(ClientID, KafkaTopic, SubscriberId, NPartitions) of
                connected -> do_get_status(ClientID, RestTopics, SubscriberId);
                disconnected -> disconnected
            end;
        _ ->
            disconnected
    end;
do_get_status(_ClientID, _KafkaTopics = [], _SubscriberId) ->
    connected.

-spec do_get_status(brod:client_id(), binary(), subscriber_id(), pos_integer()) ->
    connected | disconnected.
do_get_status(ClientID, KafkaTopic, SubscriberId, NPartitions) ->
    Results =
        lists:map(
            fun(N) ->
                brod_client:get_leader_connection(ClientID, KafkaTopic, N)
            end,
            lists:seq(0, NPartitions - 1)
        ),
    AllLeadersOk =
        length(Results) > 0 andalso
            lists:all(
                fun
                    ({ok, _}) ->
                        true;
                    (_) ->
                        false
                end,
                Results
            ),
    WorkersAlive = are_subscriber_workers_alive(SubscriberId),
    case AllLeadersOk andalso WorkersAlive of
        true ->
            connected;
        false ->
            disconnected
    end.

are_subscriber_workers_alive(SubscriberId) ->
    Children = supervisor:which_children(emqx_ee_bridge_kafka_consumer_sup),
    case lists:keyfind(SubscriberId, 1, Children) of
        false ->
            false;
        {_, Pid, _, _} ->
            Workers = brod_group_subscriber_v2:get_workers(Pid),
            %% we can't enforce the number of partitions on a single
            %% node, as the group might be spread across an emqx
            %% cluster.
            lists:all(fun is_process_alive/1, maps:values(Workers))
    end.

log_when_error(Fun, Log) ->
    try
        Fun()
    catch
        C:E ->
            ?SLOG(error, Log#{
                exception => C,
                reason => E
            })
    end.

-spec consumer_group_id(atom() | binary()) -> binary().
consumer_group_id(BridgeName0) ->
    BridgeName = to_bin(BridgeName0),
    <<"emqx-kafka-consumer-", BridgeName/binary>>.

-spec is_dry_run(manager_id()) -> boolean().
is_dry_run(InstanceId) ->
    TestIdStart = string:find(InstanceId, ?TEST_ID_PREFIX),
    case TestIdStart of
        nomatch ->
            false;
        _ ->
            string:equal(TestIdStart, InstanceId)
    end.

-spec make_client_id(manager_id(), kafka_consumer, atom() | binary()) -> atom().
make_client_id(InstanceId, KafkaType, KafkaName) ->
    case is_dry_run(InstanceId) of
        false ->
            ClientID0 = emqx_bridge_impl_kafka:make_client_id(KafkaType, KafkaName),
            binary_to_atom(ClientID0);
        true ->
            %% It is a dry run and we don't want to leak too many
            %% atoms.
            probing_brod_consumers
    end.

convert_topic_mapping(TopicMappingList) ->
    lists:foldl(
        fun(Fields, Acc) ->
            #{
                kafka_topic := KafkaTopic,
                mqtt_topic := MQTTTopic,
                qos := QoS,
                payload_template := PayloadTemplate0
            } = Fields,
            PayloadTemplate = emqx_plugin_libs_rule:preproc_tmpl(PayloadTemplate0),
            Acc#{
                KafkaTopic => #{
                    payload_template => PayloadTemplate,
                    mqtt_topic => MQTTTopic,
                    qos => QoS
                }
            }
        end,
        #{},
        TopicMappingList
    ).

render(FullMessage, PayloadTemplate) ->
    Opts = #{
        return => full_binary,
        var_trans => fun
            (undefined) ->
                <<>>;
            (X) ->
                emqx_plugin_libs_rule:bin(X)
        end
    },
    emqx_plugin_libs_rule:proc_tmpl(PayloadTemplate, FullMessage, Opts).

encode(Value, none) ->
    Value;
encode(Value, base64) ->
    base64:encode(Value).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
