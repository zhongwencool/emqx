%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_rule_engine_jwt_sup).

-behaviour(supervisor).

-export([ start_link/0
        , start_worker/2
        , stop_worker/1
        ]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{ strategy => one_for_one
                , intensity => 10
                , period => 5
                , auto_shutdown => never
                },
    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.

start_worker(Id, Config) ->
    Ref = erlang:alias([reply]),
    ChildSpec = jwt_worker_child_spec(Id, Config, Ref),
    {ok, Pid} = supervisor:start_child(?MODULE, ChildSpec),
    {Ref, Pid}.

stop_worker(Id) ->
    supervisor:terminate_child(?MODULE, Id).

jwt_worker_child_spec(Id, Config, Ref) ->
    #{ id => Id
     , start => {emqx_rule_engine_jwt_worker, start_link, [Config, Ref]}
     , restart => permanent
     , type => worker
     , significant => false
     , shutdown => brutal_kill
     , modules => [emqx_rule_engine_jwt_worker]
     }.
