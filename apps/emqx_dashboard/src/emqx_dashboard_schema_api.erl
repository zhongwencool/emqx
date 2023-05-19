%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% This module is for dashboard to retrieve the schema hot config and bridges.
-module(emqx_dashboard_schema_api).

-behaviour(minirest_api).

-include_lib("hocon/include/hoconsc.hrl").

%% minirest API
-export([api_spec/0, paths/0, schema/1]).

-export([get_schema/2]).

-define(TAGS, [<<"dashboard">>]).
-define(BAD_REQUEST, 'BAD_REQUEST').

%%--------------------------------------------------------------------
%% minirest API and schema
%%--------------------------------------------------------------------

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    ["/schemas/:name"].

%% This is a rather hidden API, so we don't need to add translations for the description.
schema("/schemas/:name") ->
    #{
        'operationId' => get_schema,
        get => #{
            parameters => [
                {name, hoconsc:mk(hoconsc:enum([hotconf, bridges]), #{in => path})}
            ],
            desc => <<
                "Get the schema JSON of the specified name. "
                "NOTE: only intended for EMQX Dashboard."
            >>,
            tags => ?TAGS,
            security => [],
            responses => #{
                200 => hoconsc:mk(binary(), #{desc => <<"The JSON schema of the specified name.">>})
            }
        }
    }.

%%--------------------------------------------------------------------
%% API Handler funcs
%%--------------------------------------------------------------------

get_schema(get, #{
    bindings := #{name := Name}
}) ->
    {200, gen_schema(Name)};
get_schema(get, _) ->
    {400, ?BAD_REQUEST, <<"unknown">>}.

gen_schema(hotconf) ->
    emqx_conf:hotconf_schema_json();
gen_schema(bridges) ->
    emqx_conf:bridge_schema_json().
