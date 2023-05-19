%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_statsd_schema).

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("typerefl/include/types.hrl").
-include("emqx_statsd.hrl").

-behaviour(hocon_schema).

-export([
    namespace/0,
    roots/0,
    fields/1,
    desc/1,
    validations/0
]).

namespace() -> "statsd".

roots() ->
    [{"statsd", hoconsc:mk(hoconsc:ref(?MODULE, "statsd"), #{importance => ?IMPORTANCE_HIDDEN})}].

fields("statsd") ->
    [
        {enable,
            hoconsc:mk(
                boolean(),
                #{
                    default => false,
                    desc => ?DESC(enable)
                }
            )},
        {server, server()},
        {sample_time_interval, fun sample_interval/1},
        {flush_time_interval, fun flush_interval/1},
        {tags, fun tags/1}
    ].

desc("statsd") -> ?DESC(statsd);
desc(_) -> undefined.

server() ->
    Meta = #{
        default => <<"127.0.0.1:8125">>,
        desc => ?DESC(?FUNCTION_NAME)
    },
    emqx_schema:servers_sc(Meta, ?SERVER_PARSE_OPTS).

sample_interval(type) -> emqx_schema:duration_ms();
sample_interval(default) -> <<"30s">>;
sample_interval(desc) -> ?DESC(?FUNCTION_NAME);
sample_interval(_) -> undefined.

flush_interval(type) -> emqx_schema:duration_ms();
flush_interval(default) -> <<"30s">>;
flush_interval(desc) -> ?DESC(?FUNCTION_NAME);
flush_interval(_) -> undefined.

tags(type) -> map();
tags(default) -> #{};
tags(desc) -> ?DESC(?FUNCTION_NAME);
tags(_) -> undefined.

validations() ->
    [
        {check_interval, fun check_interval/1}
    ].

check_interval(Conf) ->
    case hocon_maps:get("statsd.sample_time_interval", Conf) of
        undefined ->
            ok;
        Sample ->
            Flush = hocon_maps:get("statsd.flush_time_interval", Conf),
            case Sample =< Flush of
                true ->
                    true;
                false ->
                    {bad_interval, #{sample_time_interval => Sample, flush_time_interval => Flush}}
            end
    end.
