% %%--------------------------------------------------------------------
% %% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
% %%
% %% Licensed under the Apache License, Version 2.0 (the "License");
% %% you may not use this file except in compliance with the License.
% %% You may obtain a copy of the License at
% %% http://www.apache.org/licenses/LICENSE-2.0
% %%
% %% Unless required by applicable law or agreed to in writing, software
% %% distributed under the License is distributed on an "AS IS" BASIS,
% %% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% %% See the License for the specific language governing permissions and
% %% limitations under the License.
% %%--------------------------------------------------------------------

-module(emqx_connector_mysql_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include("emqx_connector.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MYSQL_HOST, "mysql").
-define(MYSQL_RESOURCE_MOD, emqx_connector_mysql).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_suite(Config) ->
    case emqx_common_test_helpers:is_tcp_server_available(?MYSQL_HOST, ?MYSQL_DEFAULT_PORT) of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_conf]),
            ok = emqx_connector_test_helpers:start_apps([emqx_resource]),
            {ok, _} = application:ensure_all_started(emqx_connector),
            Config;
        false ->
            {skip, no_mysql}
    end.

end_per_suite(_Config) ->
    ok = emqx_common_test_helpers:stop_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:stop_apps([emqx_resource]),
    _ = application:stop(emqx_connector).

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    ok.

% %%------------------------------------------------------------------------------
% %% Testcases
% %%------------------------------------------------------------------------------

t_lifecycle(_Config) ->
    perform_lifecycle_check(
        <<"emqx_connector_mysql_SUITE">>,
        mysql_config()
    ).

perform_lifecycle_check(ResourceId, InitialConfig) ->
    {ok, #{config := CheckedConfig}} =
        emqx_resource:check_config(?MYSQL_RESOURCE_MOD, InitialConfig),
    {ok, #{
        state := #{pool_name := PoolName} = State,
        status := InitialStatus
    }} = emqx_resource:create_local(
        ResourceId,
        ?CONNECTOR_RESOURCE_GROUP,
        ?MYSQL_RESOURCE_MOD,
        CheckedConfig,
        #{}
    ),
    ?assertEqual(InitialStatus, connected),
    % Instance should match the state and status of the just started resource
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := InitialStatus
    }} =
        emqx_resource:get_instance(ResourceId),
    ?assertEqual({ok, connected}, emqx_resource:health_check(ResourceId)),
    % % Perform query as further check that the resource is working as expected
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_no_params())),
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_with_params())),
    ?assertMatch(
        {ok, _, [[1]]},
        emqx_resource:query(
            ResourceId,
            test_query_with_params_and_timeout()
        )
    ),
    ?assertEqual(ok, emqx_resource:stop(ResourceId)),
    % Resource will be listed still, but state will be changed and healthcheck will fail
    % as the worker no longer exists.
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := StoppedStatus
    }} =
        emqx_resource:get_instance(ResourceId),
    ?assertEqual(stopped, StoppedStatus),
    ?assertEqual({error, resource_is_stopped}, emqx_resource:health_check(ResourceId)),
    % Resource healthcheck shortcuts things by checking ets. Go deeper by checking pool itself.
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(PoolName)),
    % Can call stop/1 again on an already stopped instance
    ?assertEqual(ok, emqx_resource:stop(ResourceId)),
    % Make sure it can be restarted and the healthchecks and queries work properly
    ?assertEqual(ok, emqx_resource:restart(ResourceId)),
    % async restart, need to wait resource
    timer:sleep(500),
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{status := InitialStatus}} =
        emqx_resource:get_instance(ResourceId),
    ?assertEqual({ok, connected}, emqx_resource:health_check(ResourceId)),
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_no_params())),
    ?assertMatch({ok, _, [[1]]}, emqx_resource:query(ResourceId, test_query_with_params())),
    ?assertMatch(
        {ok, _, [[1]]},
        emqx_resource:query(
            ResourceId,
            test_query_with_params_and_timeout()
        )
    ),
    % Stop and remove the resource in one go.
    ?assertEqual(ok, emqx_resource:remove_local(ResourceId)),
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(PoolName)),
    % Should not even be able to get the resource data out of ets now unlike just stopping.
    ?assertEqual({error, not_found}, emqx_resource:get_instance(ResourceId)).

% %%------------------------------------------------------------------------------
% %% Helpers
% %%------------------------------------------------------------------------------

mysql_config() ->
    RawConfig = list_to_binary(
        io_lib:format(
            ""
            "\n"
            "    auto_reconnect = true\n"
            "    database = mqtt\n"
            "    username= root\n"
            "    password = public\n"
            "    pool_size = 8\n"
            "    server = \"~s:~b\"\n"
            "    "
            "",
            [?MYSQL_HOST, ?MYSQL_DEFAULT_PORT]
        )
    ),

    {ok, Config} = hocon:binary(RawConfig),
    #{<<"config">> => Config}.

test_query_no_params() ->
    {sql, <<"SELECT 1">>}.

test_query_with_params() ->
    {sql, <<"SELECT ?">>, [1]}.

test_query_with_params_and_timeout() ->
    {sql, <<"SELECT ?">>, [1], 1000}.
