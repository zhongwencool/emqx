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

-module(emqx_prometheus_api_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-define(CLUSTER_RPC_SHARD, emqx_cluster_rpc_shard).

-define(LOGT(Format, Args), ct:pal("TEST_SUITE: " ++ Format, Args)).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    application:load(emqx_conf),
    ok = ekka:start(),
    ok = mria_rlog:wait_for_shards([?CLUSTER_RPC_SHARD], infinity),

    meck:new(mria_rlog, [non_strict, passthrough, no_link]),

    emqx_prometheus_SUITE:load_config(),
    emqx_mgmt_api_test_util:init_suite([emqx_prometheus]),

    Config.

end_per_suite(Config) ->
    ekka:stop(),
    mria:stop(),
    mria_mnesia:delete_schema(),

    meck:unload(mria_rlog),

    emqx_mgmt_api_test_util:end_suite([emqx_prometheus]),
    Config.

init_per_testcase(_, Config) ->
    {ok, _} = emqx_cluster_rpc:start_link(),
    Config.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------
t_prometheus_api(_) ->
    Path = emqx_mgmt_api_test_util:api_path(["prometheus"]),
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    {ok, Response} = emqx_mgmt_api_test_util:request_api(get, Path, "", Auth),

    Conf = emqx_utils_json:decode(Response, [return_maps]),
    ?assertMatch(
        #{
            <<"push_gateway_server">> := _,
            <<"interval">> := _,
            <<"enable">> := _,
            <<"vm_statistics_collector">> := _,
            <<"vm_system_info_collector">> := _,
            <<"vm_memory_collector">> := _,
            <<"vm_msacc_collector">> := _
        },
        Conf
    ),
    #{<<"enable">> := Enable} = Conf,
    ?assertEqual(Enable, undefined =/= erlang:whereis(emqx_prometheus)),
    NewConf = Conf#{<<"interval">> => <<"2s">>, <<"vm_statistics_collector">> => <<"disabled">>},
    {ok, Response2} = emqx_mgmt_api_test_util:request_api(put, Path, "", Auth, NewConf),

    Conf2 = emqx_utils_json:decode(Response2, [return_maps]),
    ?assertMatch(NewConf, Conf2),
    ?assertEqual({ok, []}, application:get_env(prometheus, vm_statistics_collector_metrics)),
    ?assertEqual({ok, all}, application:get_env(prometheus, vm_memory_collector_metrics)),

    NewConf1 = Conf#{<<"enable">> => (not Enable)},
    {ok, _Response3} = emqx_mgmt_api_test_util:request_api(put, Path, "", Auth, NewConf1),
    ?assertEqual((not Enable), undefined =/= erlang:whereis(emqx_prometheus)),

    ConfWithoutScheme = Conf#{<<"push_gateway_server">> => "127.0.0.1:8081"},
    ?assertMatch(
        {error, {"HTTP/1.1", 400, _}},
        emqx_mgmt_api_test_util:request_api(put, Path, "", Auth, ConfWithoutScheme)
    ),
    ok.

t_stats_api(_) ->
    Path = emqx_mgmt_api_test_util:api_path(["prometheus", "stats"]),
    Auth = emqx_mgmt_api_test_util:auth_header_(),
    Headers = [{"accept", "application/json"}, Auth],
    {ok, Response} = emqx_mgmt_api_test_util:request_api(get, Path, "", Headers),

    Data = emqx_utils_json:decode(Response, [return_maps]),
    ?assertMatch(#{<<"client">> := _, <<"delivery">> := _}, Data),

    {ok, _} = emqx_mgmt_api_test_util:request_api(get, Path, "", Auth),

    ok = meck:expect(mria_rlog, backend, fun() -> rlog end),
    {ok, _} = emqx_mgmt_api_test_util:request_api(get, Path, "", Auth),

    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
