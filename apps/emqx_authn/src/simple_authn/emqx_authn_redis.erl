%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_authn_redis).

-include("emqx_authn.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-behaviour(hocon_schema).
-behaviour(emqx_authentication).

-export([
    namespace/0,
    tags/0,
    roots/0,
    fields/1,
    desc/1
]).

-export([
    refs/0,
    union_member_selector/1,
    create/2,
    update/2,
    authenticate/2,
    destroy/1
]).

%%------------------------------------------------------------------------------
%% Hocon Schema
%%------------------------------------------------------------------------------

namespace() -> "authn".

tags() ->
    [<<"Authentication">>].

%% used for config check when the schema module is resolved
roots() ->
    [
        {?CONF_NS,
            hoconsc:mk(
                hoconsc:union(fun ?MODULE:union_member_selector/1),
                #{}
            )}
    ].

fields(redis_single) ->
    common_fields() ++ emqx_connector_redis:fields(single);
fields(redis_cluster) ->
    common_fields() ++ emqx_connector_redis:fields(cluster);
fields(redis_sentinel) ->
    common_fields() ++ emqx_connector_redis:fields(sentinel).

desc(redis_single) ->
    ?DESC(single);
desc(redis_cluster) ->
    ?DESC(cluster);
desc(redis_sentinel) ->
    ?DESC(sentinel);
desc(_) ->
    "".

common_fields() ->
    [
        {mechanism, emqx_authn_schema:mechanism(password_based)},
        {backend, emqx_authn_schema:backend(redis)},
        {cmd, fun cmd/1},
        {password_hash_algorithm, fun emqx_authn_password_hashing:type_ro/1}
    ] ++ emqx_authn_schema:common_fields().

cmd(type) -> string();
cmd(desc) -> ?DESC(?FUNCTION_NAME);
cmd(required) -> true;
cmd(_) -> undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

refs() ->
    [
        hoconsc:ref(?MODULE, redis_single),
        hoconsc:ref(?MODULE, redis_cluster),
        hoconsc:ref(?MODULE, redis_sentinel)
    ].

union_member_selector(all_union_members) ->
    refs();
union_member_selector({value, Value}) ->
    refs(Value).

refs(#{<<"redis_type">> := <<"single">>}) ->
    [hoconsc:ref(?MODULE, redis_single)];
refs(#{<<"redis_type">> := <<"cluster">>}) ->
    [hoconsc:ref(?MODULE, redis_cluster)];
refs(#{<<"redis_type">> := <<"sentinel">>}) ->
    [hoconsc:ref(?MODULE, redis_sentinel)];
refs(_) ->
    throw(#{
        field_name => redis_type,
        expected => "single | cluster | sentinel"
    }).

create(_AuthenticatorID, Config) ->
    create(Config).

create(Config0) ->
    ResourceId = emqx_authn_utils:make_resource_id(?MODULE),
    case parse_config(Config0) of
        {error, _} = Res ->
            Res;
        {Config, State} ->
            {ok, _Data} = emqx_authn_utils:create_resource(
                ResourceId,
                emqx_connector_redis,
                Config
            ),
            {ok, State#{resource_id => ResourceId}}
    end.

update(Config0, #{resource_id := ResourceId} = _State) ->
    {Config, NState} = parse_config(Config0),
    case emqx_authn_utils:update_resource(emqx_connector_redis, Config, ResourceId) of
        {error, Reason} ->
            error({load_config_error, Reason});
        {ok, _} ->
            {ok, NState#{resource_id => ResourceId}}
    end.

destroy(#{resource_id := ResourceId}) ->
    _ = emqx_resource:remove_local(ResourceId),
    ok.

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(
    #{password := Password} = Credential,
    #{
        cmd := {CommandName, KeyTemplate, Fields},
        resource_id := ResourceId,
        password_hash_algorithm := Algorithm
    }
) ->
    NKey = emqx_authn_utils:render_str(KeyTemplate, Credential),
    Command = [CommandName, NKey | Fields],
    case emqx_resource:simple_sync_query(ResourceId, {cmd, Command}) of
        {ok, []} ->
            ignore;
        {ok, Values} ->
            case merge(Fields, Values) of
                Selected when Selected =/= #{} ->
                    case
                        emqx_authn_utils:check_password_from_selected_map(
                            Algorithm, Selected, Password
                        )
                    of
                        ok ->
                            {ok, emqx_authn_utils:is_superuser(Selected)};
                        {error, _Reason} = Error ->
                            Error
                    end;
                _ ->
                    ?TRACE_AUTHN_PROVIDER(info, "redis_query_not_matched", #{
                        resource => ResourceId,
                        cmd => Command,
                        keys => NKey,
                        fields => Fields
                    }),
                    ignore
            end;
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER(error, "redis_query_failed", #{
                resource => ResourceId,
                cmd => Command,
                keys => NKey,
                fields => Fields,
                reason => Reason
            }),
            ignore
    end.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

parse_config(
    #{
        cmd := Cmd,
        password_hash_algorithm := Algorithm
    } = Config
) ->
    try
        NCmd = parse_cmd(Cmd),
        ok = emqx_authn_password_hashing:init(Algorithm),
        ok = emqx_authn_utils:ensure_apps_started(Algorithm),
        State = maps:with([password_hash_algorithm, salt_position], Config),
        {Config, State#{cmd => NCmd}}
    catch
        error:{unsupported_cmd, _Cmd} ->
            {error, {unsupported_cmd, Cmd}};
        error:missing_password_hash ->
            {error, missing_password_hash};
        error:{unsupported_fields, Fields} ->
            {error, {unsupported_fields, Fields}}
    end.

%% Only support HGET and HMGET
parse_cmd(Cmd) ->
    case string:tokens(Cmd, " ") of
        [Command, Key, Field | Fields] when Command =:= "HGET" orelse Command =:= "HMGET" ->
            NFields = [Field | Fields],
            check_fields(NFields),
            KeyTemplate = emqx_authn_utils:parse_str(list_to_binary(Key)),
            {Command, KeyTemplate, NFields};
        _ ->
            error({unsupported_cmd, Cmd})
    end.

check_fields(Fields) ->
    HasPassHash = lists:member("password_hash", Fields) orelse lists:member("password", Fields),
    KnownFields = ["password_hash", "password", "salt", "is_superuser"],
    UnknownFields = [F || F <- Fields, not lists:member(F, KnownFields)],

    case {HasPassHash, UnknownFields} of
        {true, []} -> ok;
        {true, _} -> error({unsupported_fields, UnknownFields});
        {false, _} -> error(missing_password_hash)
    end.

merge(Fields, Value) when not is_list(Value) ->
    merge(Fields, [Value]);
merge(Fields, Values) ->
    maps:from_list(
        [
            {list_to_binary(K), V}
         || {K, V} <- lists:zip(Fields, Values), V =/= undefined
        ]
    ).
