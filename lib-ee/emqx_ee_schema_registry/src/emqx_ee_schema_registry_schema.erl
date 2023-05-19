%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ee_schema_registry_schema).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include("emqx_ee_schema_registry.hrl").

%% `hocon_schema' API
-export([
    roots/0,
    fields/1,
    desc/1,
    tags/0,
    union_member_selector/1
]).

%% `minirest_trails' API
-export([
    api_schema/1
]).

%%------------------------------------------------------------------------------
%% `hocon_schema' APIs
%%------------------------------------------------------------------------------

roots() ->
    [{?CONF_KEY_ROOT, mk(ref(?CONF_KEY_ROOT), #{required => false})}].

tags() ->
    [<<"Schema Registry">>].

fields(?CONF_KEY_ROOT) ->
    [
        {schemas,
            mk(
                hoconsc:map(
                    name,
                    hoconsc:union(fun union_member_selector/1)
                ),
                #{
                    default => #{},
                    desc => ?DESC("schema_registry_schemas")
                }
            )}
    ];
fields(avro) ->
    [
        {type, mk(avro, #{required => true, desc => ?DESC("schema_type")})},
        {source,
            mk(emqx_schema:json_binary(), #{required => true, desc => ?DESC("schema_source")})},
        {description, mk(binary(), #{default => <<>>, desc => ?DESC("schema_description")})}
    ];
fields(protobuf) ->
    [
        {type, mk(protobuf, #{required => true, desc => ?DESC("schema_type")})},
        {source, mk(binary(), #{required => true, desc => ?DESC("schema_source")})},
        {description, mk(binary(), #{default => <<>>, desc => ?DESC("schema_description")})}
    ];
fields("get_avro") ->
    [{name, mk(binary(), #{required => true, desc => ?DESC("schema_name")})} | fields(avro)];
fields("get_protobuf") ->
    [{name, mk(binary(), #{required => true, desc => ?DESC("schema_name")})} | fields(protobuf)];
fields("put_avro") ->
    fields(avro);
fields("put_protobuf") ->
    fields(protobuf);
fields("post_" ++ Type) ->
    fields("get_" ++ Type).

desc(?CONF_KEY_ROOT) ->
    ?DESC("schema_registry_root");
desc(avro) ->
    ?DESC("avro_type");
desc(protobuf) ->
    ?DESC("protobuf_type");
desc(_) ->
    undefined.

union_member_selector(all_union_members) ->
    refs();
union_member_selector({value, V}) ->
    refs(V).

union_member_selector_get_api(all_union_members) ->
    refs_get_api();
union_member_selector_get_api({value, V}) ->
    refs_get_api(V).

%%------------------------------------------------------------------------------
%% `minirest_trails' "APIs"
%%------------------------------------------------------------------------------

api_schema("get") ->
    hoconsc:union(fun union_member_selector_get_api/1);
api_schema("post") ->
    api_schema("get");
api_schema("put") ->
    hoconsc:union(fun union_member_selector/1).

%%------------------------------------------------------------------------------
%% Internal fns
%%------------------------------------------------------------------------------

mk(Type, Meta) -> hoconsc:mk(Type, Meta).
ref(Name) -> hoconsc:ref(?MODULE, Name).

supported_serde_types() ->
    [avro, protobuf].

refs() ->
    [ref(Type) || Type <- supported_serde_types()].

refs(#{<<"type">> := TypeAtom} = Value) when is_atom(TypeAtom) ->
    refs(Value#{<<"type">> := atom_to_binary(TypeAtom)});
refs(#{<<"type">> := <<"avro">>}) ->
    [ref(avro)];
refs(#{<<"type">> := <<"protobuf">>}) ->
    [ref(protobuf)];
refs(_) ->
    Expected = lists:join(" | ", [atom_to_list(T) || T <- supported_serde_types()]),
    throw(#{
        field_name => type,
        expected => Expected
    }).

refs_get_api() ->
    [ref("get_avro"), ref("get_protobuf")].

refs_get_api(#{<<"type">> := TypeAtom} = Value) when is_atom(TypeAtom) ->
    refs(Value#{<<"type">> := atom_to_binary(TypeAtom)});
refs_get_api(#{<<"type">> := <<"avro">>}) ->
    [ref("get_avro")];
refs_get_api(#{<<"type">> := <<"protobuf">>}) ->
    [ref("get_protobuf")];
refs_get_api(_) ->
    Expected = lists:join(" | ", [atom_to_list(T) || T <- supported_serde_types()]),
    throw(#{
        field_name => type,
        expected => Expected
    }).
