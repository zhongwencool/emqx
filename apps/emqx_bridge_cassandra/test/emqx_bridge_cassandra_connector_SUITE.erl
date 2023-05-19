%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_cassandra_connector_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include("emqx_bridge_cassandra.hrl").
-include("emqx_connector/include/emqx_connector.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("stdlib/include/assert.hrl").

%% Cassandra server defined at `.ci/docker-compose-file/docker-compose-cassandra-tcp.yaml`
%% You can change it to `127.0.0.1`, if you run this SUITE locally
-define(CASSANDRA_HOST, "cassandra").
-define(CASSANDRA_RESOURCE_MOD, emqx_bridge_cassandra_connector).

%% This test SUITE requires a running cassandra instance. If you don't want to
%% bring up the whole CI infrastuctucture with the `scripts/ct/run.sh` script
%% you can create a cassandra instance with the following command (execute it
%% from root of the EMQX directory.). You also need to set ?CASSANDRA_HOST and
%% ?CASSANDRA_PORT to appropriate values.
%%
%% sudo docker run --rm -d --name cassandra --network host cassandra:3.11.14

%% Cassandra default username & password once enable `authenticator: PasswordAuthenticator`
%% in cassandra config
-define(CASSA_USERNAME, <<"cassandra">>).
-define(CASSA_PASSWORD, <<"cassandra">>).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

cassandra_servers() ->
    lists:map(
        fun(#{hostname := Host, port := Port}) ->
            {Host, Port}
        end,
        emqx_schema:parse_servers(
            iolist_to_binary([?CASSANDRA_HOST, ":", erlang:integer_to_list(?CASSANDRA_DEFAULT_PORT)]),
            #{default_port => ?CASSANDRA_DEFAULT_PORT}
        )
    ).

init_per_suite(Config) ->
    case
        emqx_common_test_helpers:is_tcp_server_available(?CASSANDRA_HOST, ?CASSANDRA_DEFAULT_PORT)
    of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_conf]),
            ok = emqx_connector_test_helpers:start_apps([emqx_resource]),
            {ok, _} = application:ensure_all_started(emqx_connector),
            {ok, _} = application:ensure_all_started(emqx_ee_connector),
            %% keyspace `mqtt` must be created in advance
            {ok, Conn} =
                ecql:connect([
                    {nodes, cassandra_servers()},
                    {username, ?CASSA_USERNAME},
                    {password, ?CASSA_PASSWORD},
                    {keyspace, "mqtt"}
                ]),
            ecql:close(Conn),
            Config;
        false ->
            case os:getenv("IS_CI") of
                "yes" ->
                    throw(no_cassandra);
                _ ->
                    {skip, no_cassandra}
            end
    end.

end_per_suite(_Config) ->
    ok = emqx_common_test_helpers:stop_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:stop_apps([emqx_resource]),
    _ = application:stop(emqx_connector),
    _ = application:stop(emqx_ee_connector).

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% cases
%%--------------------------------------------------------------------

t_lifecycle(_Config) ->
    perform_lifecycle_check(
        <<"emqx_connector_cassandra_SUITE">>,
        cassandra_config()
    ).

show(X) ->
    erlang:display(X),
    X.

show(Label, What) ->
    erlang:display({Label, What}),
    What.

perform_lifecycle_check(ResourceId, InitialConfig) ->
    {ok, #{config := CheckedConfig}} =
        emqx_resource:check_config(?CASSANDRA_RESOURCE_MOD, InitialConfig),
    {ok, #{
        state := #{pool_name := PoolName} = State,
        status := InitialStatus
    }} =
        emqx_resource:create_local(
            ResourceId,
            ?CONNECTOR_RESOURCE_GROUP,
            ?CASSANDRA_RESOURCE_MOD,
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
    (fun() ->
        erlang:display({pool_name, ResourceId}),
        QueryNoParamsResWrapper = emqx_resource:query(ResourceId, test_query_no_params()),
        ?assertMatch({ok, _}, QueryNoParamsResWrapper)
    end)(),
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
    (fun() ->
        QueryNoParamsResWrapper =
            emqx_resource:query(ResourceId, test_query_no_params()),
        ?assertMatch({ok, _}, QueryNoParamsResWrapper)
    end)(),
    % Stop and remove the resource in one go.
    ?assertEqual(ok, emqx_resource:remove_local(ResourceId)),
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(PoolName)),
    % Should not even be able to get the resource data out of ets now unlike just stopping.
    ?assertEqual({error, not_found}, emqx_resource:get_instance(ResourceId)).

%%--------------------------------------------------------------------
%% utils
%%--------------------------------------------------------------------

cassandra_config() ->
    Config =
        #{
            auto_reconnect => true,
            keyspace => <<"mqtt">>,
            username => ?CASSA_USERNAME,
            password => ?CASSA_PASSWORD,
            pool_size => 8,
            servers => iolist_to_binary(
                io_lib:format(
                    "~s:~b",
                    [
                        ?CASSANDRA_HOST,
                        ?CASSANDRA_DEFAULT_PORT
                    ]
                )
            )
        },
    #{<<"config">> => Config}.

test_query_no_params() ->
    {query, <<"SELECT count(1) AS T FROM system.local">>}.
