%%--------------------------------------------------------------------
%% Copyright (c) 2018-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_kernel_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {
        {one_for_one, 10, 100},
        %% always start emqx_config_handler first to load the emqx.conf to emqx_config
        [
            child_spec(emqx_config_handler, worker),
            child_spec(emqx_pool_sup, supervisor),
            child_spec(emqx_hooks, worker),
            child_spec(emqx_stats, worker),
            child_spec(emqx_metrics, worker),
            child_spec(emqx_authn_authz_metrics_sup, supervisor),
            child_spec(emqx_ocsp_cache, worker),
            child_spec(emqx_crl_cache, worker)
        ]
    }}.

child_spec(M, Type) ->
    child_spec(M, Type, []).

child_spec(M, worker, Args) ->
    #{
        id => M,
        start => {M, start_link, Args},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [M]
    };
child_spec(M, supervisor, Args) ->
    #{
        id => M,
        start => {M, start_link, Args},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [M]
    }.
