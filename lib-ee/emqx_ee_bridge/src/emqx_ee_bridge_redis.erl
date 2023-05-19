%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_ee_bridge_redis).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-import(hoconsc, [mk/2, enum/1, ref/1, ref/2]).

-export([
    conn_bridge_examples/1
]).

-export([
    namespace/0,
    roots/0,
    fields/1,
    desc/1
]).

%% -------------------------------------------------------------------------------------------------
%% api

conn_bridge_examples(Method) ->
    [
        #{
            <<"redis_single">> => #{
                summary => <<"Redis Single Node Bridge">>,
                value => values("single", Method)
            }
        },
        #{
            <<"redis_sentinel">> => #{
                summary => <<"Redis Sentinel Bridge">>,
                value => values("sentinel", Method)
            }
        },
        #{
            <<"redis_cluster">> => #{
                summary => <<"Redis Cluster Bridge">>,
                value => values("cluster", Method)
            }
        }
    ].

values(Protocol, get) ->
    values(Protocol, post);
values("single", post) ->
    SpecificOpts = #{
        server => <<"127.0.0.1:6379">>,
        redis_type => single,
        database => 1
    },
    values(common, "single", SpecificOpts);
values("sentinel", post) ->
    SpecificOpts = #{
        servers => [<<"127.0.0.1:26379">>],
        redis_type => sentinel,
        sentinel => <<"mymaster">>,
        database => 1
    },
    values(common, "sentinel", SpecificOpts);
values("cluster", post) ->
    SpecificOpts = #{
        servers => [<<"127.0.0.1:6379">>],
        redis_type => cluster
    },
    values(common, "cluster", SpecificOpts);
values(Protocol, put) ->
    maps:without([type, name], values(Protocol, post)).

values(common, RedisType, SpecificOpts) ->
    Config = #{
        type => list_to_atom("redis_" ++ RedisType),
        name => <<"redis_bridge">>,
        enable => true,
        local_topic => <<"local/topic/#">>,
        pool_size => 8,
        password => <<"******">>,
        command_template => [<<"LPUSH">>, <<"MSGS">>, <<"${payload}">>],
        resource_opts => values(resource_opts, RedisType, #{}),
        ssl => #{enable => false}
    },
    maps:merge(Config, SpecificOpts);
values(resource_opts, "cluster", SpecificOpts) ->
    SpecificOpts;
values(resource_opts, _RedisType, SpecificOpts) ->
    maps:merge(
        #{
            batch_size => 1,
            batch_time => <<"20ms">>
        },
        SpecificOpts
    ).

%% -------------------------------------------------------------------------------------------------
%% Hocon Schema Definitions
namespace() -> "bridge_redis".

roots() -> [].

fields("post_single") ->
    method_fileds(post, redis_single);
fields("post_sentinel") ->
    method_fileds(post, redis_sentinel);
fields("post_cluster") ->
    method_fileds(post, redis_cluster);
fields("put_single") ->
    method_fileds(put, redis_single);
fields("put_sentinel") ->
    method_fileds(put, redis_sentinel);
fields("put_cluster") ->
    method_fileds(put, redis_cluster);
fields("get_single") ->
    method_fileds(get, redis_single);
fields("get_sentinel") ->
    method_fileds(get, redis_sentinel);
fields("get_cluster") ->
    method_fileds(get, redis_cluster);
fields(Type) when
    Type == redis_single orelse Type == redis_sentinel orelse Type == redis_cluster
->
    redis_bridge_common_fields(Type) ++
        connector_fields(Type);
fields("creation_opts_" ++ Type) ->
    resource_creation_fields(Type).

method_fileds(post, ConnectorType) ->
    redis_bridge_common_fields(ConnectorType) ++
        connector_fields(ConnectorType) ++
        type_name_fields(ConnectorType);
method_fileds(get, ConnectorType) ->
    redis_bridge_common_fields(ConnectorType) ++
        connector_fields(ConnectorType) ++
        type_name_fields(ConnectorType) ++
        emqx_bridge_schema:status_fields();
method_fileds(put, ConnectorType) ->
    redis_bridge_common_fields(ConnectorType) ++
        connector_fields(ConnectorType).

redis_bridge_common_fields(Type) ->
    emqx_bridge_schema:common_bridge_fields() ++
        [
            {local_topic, mk(binary(), #{desc => ?DESC("local_topic")})},
            {command_template, fun command_template/1}
        ] ++
        resource_fields(Type).

connector_fields(Type) ->
    RedisType = bridge_type_to_redis_conn_type(Type),
    emqx_connector_redis:fields(RedisType).

bridge_type_to_redis_conn_type(redis_single) ->
    single;
bridge_type_to_redis_conn_type(redis_sentinel) ->
    sentinel;
bridge_type_to_redis_conn_type(redis_cluster) ->
    cluster.

type_name_fields(Type) ->
    [
        {type, mk(Type, #{required => true, desc => ?DESC("desc_type")})},
        {name, mk(binary(), #{required => true, desc => ?DESC("desc_name")})}
    ].

resource_fields(Type) ->
    [
        {resource_opts,
            mk(
                ref("creation_opts_" ++ atom_to_list(Type)),
                #{
                    required => false,
                    default => #{},
                    desc => ?DESC(emqx_resource_schema, <<"resource_opts">>)
                }
            )}
    ].

resource_creation_fields("redis_cluster") ->
    % TODO
    % Cluster bridge is currently incompatible with batching.
    Fields = emqx_resource_schema:fields("creation_opts"),
    lists:foldl(fun proplists:delete/2, Fields, [batch_size, batch_time, enable_batch]);
resource_creation_fields(_) ->
    emqx_resource_schema:fields("creation_opts").

desc("config") ->
    ?DESC("desc_config");
desc(Method) when Method =:= "get"; Method =:= "put"; Method =:= "post" ->
    ["Configuration for Redis using `", string:to_upper(Method), "` method."];
desc(redis_single) ->
    ?DESC(emqx_connector_redis, "single");
desc(redis_sentinel) ->
    ?DESC(emqx_connector_redis, "sentinel");
desc(redis_cluster) ->
    ?DESC(emqx_connector_redis, "cluster");
desc("creation_opts_" ++ _Type) ->
    ?DESC(emqx_resource_schema, "creation_opts");
desc(_) ->
    undefined.

command_template(type) ->
    list(binary());
command_template(required) ->
    true;
command_template(validator) ->
    fun is_command_template_valid/1;
command_template(desc) ->
    ?DESC("command_template");
command_template(_) ->
    undefined.

is_command_template_valid(CommandSegments) ->
    case
        is_list(CommandSegments) andalso length(CommandSegments) > 0 andalso
            lists:all(fun is_binary/1, CommandSegments)
    of
        true ->
            ok;
        false ->
            {error,
                "the value of the field 'command_template' should be a nonempty "
                "list of strings (templates for Redis command and arguments)"}
    end.
