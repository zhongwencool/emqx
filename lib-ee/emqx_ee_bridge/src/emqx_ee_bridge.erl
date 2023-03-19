%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_ee_bridge).

-import(hoconsc, [mk/2, enum/1, ref/2]).

-export([
    api_schemas/1,
    examples/1,
    resource_type/1,
    fields/1
]).

api_schemas(Method) ->
    [
        ref(emqx_ee_bridge_gcp_pubsub, Method),
        ref(emqx_ee_bridge_kafka, Method ++ "_consumer"),
        ref(emqx_ee_bridge_kafka, Method ++ "_producer"),
        ref(emqx_ee_bridge_mysql, Method),
        ref(emqx_ee_bridge_pgsql, Method),
        ref(emqx_ee_bridge_mongodb, Method ++ "_rs"),
        ref(emqx_ee_bridge_mongodb, Method ++ "_sharded"),
        ref(emqx_ee_bridge_mongodb, Method ++ "_single"),
        ref(emqx_ee_bridge_hstreamdb, Method),
        ref(emqx_ee_bridge_influxdb, Method ++ "_api_v1"),
        ref(emqx_ee_bridge_influxdb, Method ++ "_api_v2"),
        ref(emqx_ee_bridge_redis, Method ++ "_single"),
        ref(emqx_ee_bridge_redis, Method ++ "_sentinel"),
        ref(emqx_ee_bridge_redis, Method ++ "_cluster"),
        ref(emqx_ee_bridge_timescale, Method),
        ref(emqx_ee_bridge_matrix, Method),
        ref(emqx_ee_bridge_tdengine, Method),
        ref(emqx_ee_bridge_clickhouse, Method),
        ref(emqx_ee_bridge_dynamo, Method)
    ].

schema_modules() ->
    [
        emqx_ee_bridge_kafka,
        emqx_ee_bridge_hstreamdb,
        emqx_ee_bridge_gcp_pubsub,
        emqx_ee_bridge_influxdb,
        emqx_ee_bridge_mongodb,
        emqx_ee_bridge_mysql,
        emqx_ee_bridge_redis,
        emqx_ee_bridge_pgsql,
        emqx_ee_bridge_timescale,
        emqx_ee_bridge_matrix,
        emqx_ee_bridge_tdengine,
        emqx_ee_bridge_clickhouse,
        emqx_ee_bridge_dynamo
    ].

examples(Method) ->
    MergeFun =
        fun(Example, Examples) ->
            maps:merge(Examples, Example)
        end,
    Fun =
        fun(Module, Examples) ->
            ConnectorExamples = erlang:apply(Module, conn_bridge_examples, [Method]),
            lists:foldl(MergeFun, Examples, ConnectorExamples)
        end,
    lists:foldl(Fun, #{}, schema_modules()).

resource_type(Type) when is_binary(Type) -> resource_type(binary_to_atom(Type, utf8));
resource_type(kafka_consumer) -> emqx_bridge_impl_kafka_consumer;
%% TODO: rename this to `kafka_producer' after alias support is added
%% to hocon; keeping this as just `kafka' for backwards compatibility.
resource_type(kafka) -> emqx_bridge_impl_kafka_producer;
resource_type(hstreamdb) -> emqx_ee_connector_hstreamdb;
resource_type(gcp_pubsub) -> emqx_ee_connector_gcp_pubsub;
resource_type(mongodb_rs) -> emqx_ee_connector_mongodb;
resource_type(mongodb_sharded) -> emqx_ee_connector_mongodb;
resource_type(mongodb_single) -> emqx_ee_connector_mongodb;
resource_type(mysql) -> emqx_connector_mysql;
resource_type(influxdb_api_v1) -> emqx_ee_connector_influxdb;
resource_type(influxdb_api_v2) -> emqx_ee_connector_influxdb;
resource_type(redis_single) -> emqx_ee_connector_redis;
resource_type(redis_sentinel) -> emqx_ee_connector_redis;
resource_type(redis_cluster) -> emqx_ee_connector_redis;
resource_type(pgsql) -> emqx_connector_pgsql;
resource_type(timescale) -> emqx_connector_pgsql;
resource_type(matrix) -> emqx_connector_pgsql;
resource_type(tdengine) -> emqx_ee_connector_tdengine;
resource_type(clickhouse) -> emqx_ee_connector_clickhouse;
resource_type(dynamo) -> emqx_ee_connector_dynamo.

fields(bridges) ->
    [
        {hstreamdb,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_hstreamdb, "config")),
                #{
                    desc => <<"HStreamDB Bridge Config">>,
                    required => false
                }
            )},
        {gcp_pubsub,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_gcp_pubsub, "config")),
                #{
                    desc => <<"EMQX Enterprise Config">>,
                    required => false
                }
            )},
        {mysql,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_mysql, "config")),
                #{
                    desc => <<"MySQL Bridge Config">>,
                    required => false
                }
            )},
        {tdengine,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_tdengine, "config")),
                #{
                    desc => <<"TDengine Bridge Config">>,
                    required => false
                }
            )},
        {dynamo,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_dynamo, "config")),
                #{
                    desc => <<"Dynamo Bridge Config">>,
                    required => false
                }
            )}
    ] ++ kafka_structs() ++ mongodb_structs() ++ influxdb_structs() ++ redis_structs() ++
        pgsql_structs() ++ clickhouse_structs().

mongodb_structs() ->
    [
        {Type,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_mongodb, Type)),
                #{
                    desc => <<"MongoDB Bridge Config">>,
                    required => false
                }
            )}
     || Type <- [mongodb_rs, mongodb_sharded, mongodb_single]
    ].

kafka_structs() ->
    [
        %% TODO: rename this to `kafka_producer' after alias support
        %% is added to hocon; keeping this as just `kafka' for
        %% backwards compatibility.
        {kafka,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_kafka, kafka_producer)),
                #{
                    desc => <<"Kafka Producer Bridge Config">>,
                    required => false,
                    converter => fun emqx_ee_bridge_kafka:kafka_producer_converter/2
                }
            )},
        {kafka_consumer,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_kafka, kafka_consumer)),
                #{desc => <<"Kafka Consumer Bridge Config">>, required => false}
            )}
    ].

influxdb_structs() ->
    [
        {Protocol,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_influxdb, Protocol)),
                #{
                    desc => <<"InfluxDB Bridge Config">>,
                    required => false
                }
            )}
     || Protocol <- [
            influxdb_api_v1,
            influxdb_api_v2
        ]
    ].

redis_structs() ->
    [
        {Type,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_redis, Type)),
                #{
                    desc => <<"Redis Bridge Config">>,
                    required => false
                }
            )}
     || Type <- [
            redis_single,
            redis_sentinel,
            redis_cluster
        ]
    ].

pgsql_structs() ->
    [
        {Type,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_pgsql, "config")),
                #{
                    desc => <<Name/binary, " Bridge Config">>,
                    required => false
                }
            )}
     || {Type, Name} <- [
            {pgsql, <<"PostgreSQL">>},
            {timescale, <<"Timescale">>},
            {matrix, <<"Matrix">>}
        ]
    ].

clickhouse_structs() ->
    [
        {clickhouse,
            mk(
                hoconsc:map(name, ref(emqx_ee_bridge_clickhouse, "config")),
                #{
                    desc => <<"Clickhouse Bridge Config">>,
                    required => false
                }
            )}
    ].
