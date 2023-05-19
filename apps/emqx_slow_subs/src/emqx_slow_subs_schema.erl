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
-module(emqx_slow_subs_schema).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([roots/0, fields/1, desc/1, namespace/0]).

namespace() -> "slow_subs".

roots() ->
    [{"slow_subs", ?HOCON(?R_REF("slow_subs"), #{importance => ?IMPORTANCE_HIDDEN})}].

fields("slow_subs") ->
    [
        {enable, sc(boolean(), false, enable)},
        {threshold,
            sc(
                emqx_schema:duration_ms(),
                <<"500ms">>,
                threshold
            )},
        {expire_interval,
            sc(
                emqx_schema:duration_ms(),
                <<"300s">>,
                expire_interval
            )},
        {top_k_num,
            sc(
                pos_integer(),
                10,
                top_k_num
            )},
        {stats_type,
            sc(
                ?ENUM([whole, internal, response]),
                whole,
                stats_type
            )}
    ].

desc("slow_subs") ->
    "Configuration for `slow_subs` feature.";
desc(_) ->
    undefined.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
sc(Type, Default, Desc) ->
    ?HOCON(Type, #{default => Default, desc => ?DESC(Desc)}).
