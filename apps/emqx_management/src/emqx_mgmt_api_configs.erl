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

-module(emqx_mgmt_api_configs).

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/logger.hrl").
-behaviour(minirest_api).

-export([api_spec/0, namespace/0]).
-export([paths/0, schema/1, fields/1]).

-export([
    config/3,
    config_reset/3,
    configs/3,
    get_full_config/0,
    global_zone_configs/3,
    limiter/3
]).

-define(PREFIX, "/configs/").
-define(PREFIX_RESET, "/configs_reset/").
-define(ERR_MSG(MSG), list_to_binary(io_lib:format("~p", [MSG]))).
-define(OPTS, #{rawconf_with_defaults => true, override_to => cluster}).
-define(TAGS, ["Configs"]).

-define(ROOT_KEYS, [
    <<"dashboard">>,
    <<"alarm">>,
    <<"sys_topics">>,
    <<"sysmon">>,
    <<"log">>,
    <<"persistent_session_store">>,
    <<"zones">>
]).

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

namespace() -> "configuration".

paths() ->
    [
        "/configs",
        "/configs_reset/:rootname",
        "/configs/global_zone",
        "/configs/limiter"
    ] ++
        lists:map(fun({Name, _Type}) -> ?PREFIX ++ binary_to_list(Name) end, config_list()).

schema("/configs") ->
    #{
        'operationId' => configs,
        get => #{
            tags => ?TAGS,
            description =>
                <<"Get all the configurations of the specified node, including hot and non-hot updatable items.">>,
            parameters => [
                {node,
                    hoconsc:mk(
                        typerefl:atom(),
                        #{
                            in => query,
                            required => false,
                            example => <<"emqx@127.0.0.1">>,
                            desc =>
                                <<"Node's name: If you do not fill in the fields, this node will be used by default.">>
                        }
                    )}
            ],
            responses => #{
                200 => lists:map(fun({_, Schema}) -> Schema end, config_list()),
                404 => emqx_dashboard_swagger:error_codes(['NOT_FOUND']),
                500 => emqx_dashboard_swagger:error_codes(['BAD_NODE'])
            }
        }
    };
schema("/configs_reset/:rootname") ->
    Paths = lists:map(fun({Path, _}) -> binary_to_atom(Path) end, config_list()),
    #{
        'operationId' => config_reset,
        post => #{
            tags => ?TAGS,
            description =>
                <<
                    "Reset the config entry specified by the query string parameter `conf_path`.<br/>"
                    "- For a config entry that has default value, this resets it to the default value;\n"
                    "- For a config entry that has no default value, an error 400 will be returned"
                >>,
            %% We only return "200" rather than the new configs that has been changed, as
            %% the schema of the changed configs is depends on the request parameter
            %% `conf_path`, it cannot be defined here.
            parameters => [
                {rootname,
                    hoconsc:mk(
                        hoconsc:enum(Paths),
                        #{in => path, example => <<"sysmon">>}
                    )},
                {conf_path,
                    hoconsc:mk(
                        typerefl:binary(),
                        #{
                            in => query,
                            required => false,
                            example => <<"os.sysmem_high_watermark">>,
                            desc => <<"The config path separated by '.' character">>
                        }
                    )}
            ],
            responses => #{
                200 => <<"Rest config successfully">>,
                400 => emqx_dashboard_swagger:error_codes(['NO_DEFAULT_VALUE', 'REST_FAILED']),
                403 => emqx_dashboard_swagger:error_codes(['REST_FAILED'])
            }
        }
    };
schema("/configs/global_zone") ->
    Schema = global_zone_schema(),
    #{
        'operationId' => global_zone_configs,
        get => #{
            tags => ?TAGS,
            description => <<"Get the global zone configs">>,
            responses => #{200 => Schema}
        },
        put => #{
            tags => ?TAGS,
            description => <<"Update globbal zone configs">>,
            'requestBody' => Schema,
            responses => #{
                200 => Schema,
                400 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED']),
                403 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED'])
            }
        }
    };
schema("/configs/limiter") ->
    #{
        'operationId' => limiter,
        get => #{
            tags => ?TAGS,
            description => <<"Get the node-level limiter configs">>,
            responses => #{
                200 => hoconsc:mk(hoconsc:ref(emqx_limiter_schema, limiter)),
                404 => emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<"config not found">>)
            }
        },
        put => #{
            tags => ?TAGS,
            description => <<"Update the node-level limiter configs">>,
            'requestBody' => hoconsc:mk(hoconsc:ref(emqx_limiter_schema, limiter)),
            responses => #{
                200 => hoconsc:mk(hoconsc:ref(emqx_limiter_schema, limiter)),
                400 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED']),
                403 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED'])
            }
        }
    };
schema(Path) ->
    {RootKey, {_Root, Schema}} = find_schema(Path),
    #{
        'operationId' => config,
        get => #{
            tags => ?TAGS,
            description => iolist_to_binary([
                <<"Get the sub-configurations under *">>,
                RootKey,
                <<"*">>
            ]),
            responses => #{
                200 => Schema,
                404 => emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<"config not found">>)
            }
        },
        put => #{
            tags => ?TAGS,
            description => iolist_to_binary([
                <<"Update the sub-configurations under *">>,
                RootKey,
                <<"*">>
            ]),
            'requestBody' => Schema,
            responses => #{
                200 => Schema,
                400 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED']),
                403 => emqx_dashboard_swagger:error_codes(['UPDATE_FAILED'])
            }
        }
    }.

find_schema(Path) ->
    [_, _Prefix, Root | _] = string:split(Path, "/", all),
    Configs = config_list(),
    lists:keyfind(list_to_binary(Root), 1, Configs).

%% we load all configs from emqx_*_schema, some of them are defined as local ref
%% we need redirect to emqx_*_schema.
%% such as hoconsc:ref("node") to hoconsc:ref(emqx_*_schema, "node")
fields(Field) ->
    Mod = emqx_conf:schema_module(),
    apply(Mod, fields, [Field]).

%%%==============================================================================================
%% HTTP API Callbacks
config(get, _Params, Req) ->
    [Path] = conf_path(Req),
    {200, get_raw_config(Path)};
config(put, #{body := NewConf}, Req) ->
    Path = conf_path(Req),
    case emqx_conf:update(Path, NewConf, ?OPTS) of
        {ok, #{raw_config := RawConf}} ->
            {200, RawConf};
        {error, Reason} ->
            {400, #{code => 'UPDATE_FAILED', message => ?ERR_MSG(Reason)}}
    end.

global_zone_configs(get, _Params, _Req) ->
    {200, get_zones()};
global_zone_configs(put, #{body := Body}, _Req) ->
    PrevZones = get_zones(),
    Res =
        maps:fold(
            fun(Path, Value, Acc) ->
                PrevValue = maps:get(Path, PrevZones),
                case Value =/= PrevValue of
                    true ->
                        case emqx_conf:update([Path], Value, ?OPTS) of
                            {ok, #{raw_config := RawConf}} ->
                                Acc#{Path => RawConf};
                            {error, Reason} ->
                                ?SLOG(error, #{
                                    msg => "update global zone failed",
                                    reason => Reason,
                                    path => Path,
                                    value => Value
                                }),
                                Acc
                        end;
                    false ->
                        Acc#{Path => Value}
                end
            end,
            #{},
            Body
        ),
    case maps:size(Res) =:= maps:size(Body) of
        true -> {200, Res};
        false -> {400, #{code => 'UPDATE_FAILED'}}
    end.

config_reset(post, _Params, Req) ->
    %% reset the config specified by the query string param 'conf_path'
    Path = conf_path_reset(Req) ++ conf_path_from_querystr(Req),
    case emqx_conf:reset(Path, ?OPTS) of
        {ok, _} ->
            {200};
        {error, no_default_value} ->
            {400, #{code => 'NO_DEFAULT_VALUE', message => <<"No Default Value.">>}};
        {error, Reason} ->
            {400, #{code => 'REST_FAILED', message => ?ERR_MSG(Reason)}}
    end.

configs(get, Params, _Req) ->
    QS = maps:get(query_string, Params, #{}),
    Node = maps:get(<<"node">>, QS, node()),
    case
        lists:member(Node, emqx:running_nodes()) andalso
            emqx_management_proto_v2:get_full_config(Node)
    of
        false ->
            Message = list_to_binary(io_lib:format("Bad node ~p, reason not found", [Node])),
            {404, #{code => 'NOT_FOUND', message => Message}};
        {badrpc, R} ->
            Message = list_to_binary(io_lib:format("Bad node ~p, reason ~p", [Node, R])),
            {500, #{code => 'BAD_NODE', message => Message}};
        Res ->
            {200, Res}
    end.

limiter(get, _Params, _Req) ->
    {200, format_limiter_config(get_raw_config(limiter))};
limiter(put, #{body := NewConf}, _Req) ->
    case emqx_conf:update([limiter], NewConf, ?OPTS) of
        {ok, #{raw_config := RawConf}} ->
            {200, format_limiter_config(RawConf)};
        {error, {permission_denied, Reason}} ->
            {403, #{code => 'UPDATE_FAILED', message => Reason}};
        {error, Reason} ->
            {400, #{code => 'UPDATE_FAILED', message => ?ERR_MSG(Reason)}}
    end.

format_limiter_config(RawConf) ->
    Shorts = lists:map(fun erlang:atom_to_binary/1, emqx_limiter_schema:short_paths()),
    maps:with(Shorts, RawConf).

conf_path_reset(Req) ->
    <<"/api/v5", ?PREFIX_RESET, Path/binary>> = cowboy_req:path(Req),
    string:lexemes(Path, "/ ").

get_full_config() ->
    emqx_config:fill_defaults(
        maps:with(
            ?ROOT_KEYS,
            emqx:get_raw_config([])
        ),
        #{obfuscate_sensitive_values => true}
    ).

get_raw_config(Path) ->
    #{Path := Conf} =
        emqx_config:fill_defaults(
            #{Path => emqx:get_raw_config([Path])},
            #{obfuscate_sensitive_values => true}
        ),
    Conf.

get_zones() ->
    lists:foldl(
        fun(Path, Acc) ->
            maps:merge(Acc, get_config_with_default(Path))
        end,
        #{},
        global_zone_roots()
    ).

get_config_with_default(Path) ->
    emqx_config:fill_defaults(#{Path => emqx:get_raw_config([Path])}).

conf_path_from_querystr(Req) ->
    case proplists:get_value(<<"conf_path">>, cowboy_req:parse_qs(Req)) of
        undefined -> [];
        Path -> string:lexemes(Path, ". ")
    end.

config_list() ->
    Mod = emqx_conf:schema_module(),
    Roots = hocon_schema:roots(Mod),
    lists:foldl(fun(Key, Acc) -> [lists:keyfind(Key, 1, Roots) | Acc] end, [], ?ROOT_KEYS).

conf_path(Req) ->
    <<"/api/v5", ?PREFIX, Path/binary>> = cowboy_req:path(Req),
    string:lexemes(Path, "/ ").

global_zone_roots() ->
    lists:map(fun({K, _}) -> list_to_binary(K) end, global_zone_schema()).

global_zone_schema() ->
    emqx_zone_schema:zone_without_hidden().
