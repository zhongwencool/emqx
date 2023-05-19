%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_bridge_webhook_schema).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-import(hoconsc, [mk/2, enum/1, ref/2]).

-export([roots/0, fields/1, namespace/0, desc/1]).

%%======================================================================================
%% Hocon Schema Definitions
namespace() -> "bridge_webhook".

roots() -> [].

fields("config") ->
    basic_config() ++ request_config();
fields("post") ->
    [
        type_field(),
        name_field()
    ] ++ fields("config");
fields("put") ->
    fields("config");
fields("get") ->
    emqx_bridge_schema:status_fields() ++ fields("post");
fields("creation_opts") ->
    [
        hidden_request_timeout()
        | lists:filter(
            fun({K, _V}) ->
                not lists:member(K, unsupported_opts())
            end,
            emqx_resource_schema:fields("creation_opts")
        )
    ].

desc("config") ->
    ?DESC("desc_config");
desc("creation_opts") ->
    ?DESC(emqx_resource_schema, "creation_opts");
desc(Method) when Method =:= "get"; Method =:= "put"; Method =:= "post" ->
    ["Configuration for WebHook using `", string:to_upper(Method), "` method."];
desc(_) ->
    undefined.

basic_config() ->
    [
        {enable,
            mk(
                boolean(),
                #{
                    desc => ?DESC("config_enable"),
                    default => true
                }
            )}
    ] ++ webhook_creation_opts() ++
        proplists:delete(
            max_retries, emqx_connector_http:fields(config)
        ).

request_config() ->
    [
        {url,
            mk(
                binary(),
                #{
                    required => true,
                    desc => ?DESC("config_url")
                }
            )},
        {direction,
            mk(
                egress,
                #{
                    desc => ?DESC("config_direction"),
                    required => {false, recursively},
                    deprecated => {since, "5.0.12"}
                }
            )},
        {local_topic,
            mk(
                binary(),
                #{
                    desc => ?DESC("config_local_topic"),
                    required => false
                }
            )},
        {method,
            mk(
                method(),
                #{
                    default => post,
                    desc => ?DESC("config_method")
                }
            )},
        {headers,
            mk(
                map(),
                #{
                    default => #{
                        <<"accept">> => <<"application/json">>,
                        <<"cache-control">> => <<"no-cache">>,
                        <<"connection">> => <<"keep-alive">>,
                        <<"content-type">> => <<"application/json">>,
                        <<"keep-alive">> => <<"timeout=5">>
                    },
                    desc => ?DESC("config_headers")
                }
            )},
        {body,
            mk(
                binary(),
                #{
                    default => undefined,
                    desc => ?DESC("config_body")
                }
            )},
        {max_retries,
            mk(
                non_neg_integer(),
                #{
                    default => 2,
                    desc => ?DESC("config_max_retries")
                }
            )},
        {request_timeout,
            mk(
                emqx_schema:duration_ms(),
                #{
                    default => <<"15s">>,
                    desc => ?DESC("config_request_timeout")
                }
            )}
    ].

webhook_creation_opts() ->
    [
        {resource_opts,
            mk(
                ref(?MODULE, "creation_opts"),
                #{
                    required => false,
                    default => #{},
                    desc => ?DESC(emqx_resource_schema, <<"resource_opts">>)
                }
            )}
    ].

unsupported_opts() ->
    [
        enable_batch,
        batch_size,
        batch_time,
        request_timeout
    ].

%%======================================================================================

type_field() ->
    {type,
        mk(
            webhook,
            #{
                required => true,
                desc => ?DESC("desc_type")
            }
        )}.

name_field() ->
    {name,
        mk(
            binary(),
            #{
                required => true,
                desc => ?DESC("desc_name")
            }
        )}.

method() ->
    enum([post, put, get, delete]).

hidden_request_timeout() ->
    {request_timeout,
        mk(
            hoconsc:union([infinity, emqx_schema:duration_ms()]),
            #{
                required => false,
                importance => ?IMPORTANCE_HIDDEN
            }
        )}.
