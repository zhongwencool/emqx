%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_gcp_pubsub_connector).

-behaviour(emqx_resource).

-include_lib("emqx_connector/include/emqx_connector_tables.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% `emqx_resource' API
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_query_async/4,
    on_batch_query/3,
    on_batch_query_async/4,
    on_get_status/2,
    is_buffer_supported/0
]).
-export([reply_delegator/3]).

-type jwt_worker() :: binary().
-type service_account_json() :: emqx_bridge_gcp_pubsub:service_account_json().
-type config() :: #{
    connect_timeout := emqx_schema:duration_ms(),
    max_retries := non_neg_integer(),
    pubsub_topic := binary(),
    resource_opts := #{request_timeout := emqx_schema:duration_ms(), any() => term()},
    service_account_json := service_account_json(),
    any() => term()
}.
-type state() :: #{
    connect_timeout := timer:time(),
    jwt_worker_id := jwt_worker(),
    max_retries := non_neg_integer(),
    payload_template := emqx_plugin_libs_rule:tmpl_token(),
    pool_name := binary(),
    project_id := binary(),
    pubsub_topic := binary(),
    request_timeout := timer:time()
}.
-type headers() :: [{binary(), iodata()}].
-type body() :: iodata().
-type status_code() :: 100..599.

-define(DEFAULT_PIPELINE_SIZE, 100).

%%-------------------------------------------------------------------------------------------------
%% emqx_resource API
%%-------------------------------------------------------------------------------------------------

is_buffer_supported() -> false.

callback_mode() -> async_if_possible.

-spec on_start(resource_id(), config()) -> {ok, state()} | {error, term()}.
on_start(
    ResourceId,
    #{
        connect_timeout := ConnectTimeout,
        max_retries := MaxRetries,
        payload_template := PayloadTemplate,
        pool_size := PoolSize,
        pubsub_topic := PubSubTopic,
        resource_opts := #{request_timeout := RequestTimeout}
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_gcp_pubsub_bridge",
        connector => ResourceId,
        config => Config
    }),
    %% emulating the emulator behavior
    %% https://cloud.google.com/pubsub/docs/emulator
    HostPort = os:getenv("PUBSUB_EMULATOR_HOST", "pubsub.googleapis.com:443"),
    #{hostname := Host, port := Port} = emqx_schema:parse_server(HostPort, #{default_port => 443}),
    PoolType = random,
    Transport = tls,
    TransportOpts = emqx_tls_lib:to_client_opts(#{enable => true, verify => verify_none}),
    NTransportOpts = emqx_utils:ipv6_probe(TransportOpts),
    PoolOpts = [
        {host, Host},
        {port, Port},
        {connect_timeout, ConnectTimeout},
        {keepalive, 30_000},
        {pool_type, PoolType},
        {pool_size, PoolSize},
        {transport, Transport},
        {transport_opts, NTransportOpts},
        {enable_pipelining, maps:get(enable_pipelining, Config, ?DEFAULT_PIPELINE_SIZE)}
    ],
    #{
        jwt_worker_id := JWTWorkerId,
        project_id := ProjectId
    } = ensure_jwt_worker(ResourceId, Config),
    State = #{
        connect_timeout => ConnectTimeout,
        jwt_worker_id => JWTWorkerId,
        max_retries => MaxRetries,
        payload_template => emqx_plugin_libs_rule:preproc_tmpl(PayloadTemplate),
        pool_name => ResourceId,
        project_id => ProjectId,
        pubsub_topic => PubSubTopic,
        request_timeout => RequestTimeout
    },
    ?tp(
        gcp_pubsub_on_start_before_starting_pool,
        #{
            resource_id => ResourceId,
            pool_name => ResourceId,
            pool_opts => PoolOpts
        }
    ),
    ?tp(gcp_pubsub_starting_ehttpc_pool, #{pool_name => ResourceId}),
    case ehttpc_sup:start_pool(ResourceId, PoolOpts) of
        {ok, _} ->
            {ok, State};
        {error, {already_started, _}} ->
            ?tp(gcp_pubsub_ehttpc_pool_already_started, #{pool_name => ResourceId}),
            {ok, State};
        {error, Reason} ->
            ?tp(gcp_pubsub_ehttpc_pool_start_failure, #{
                pool_name => ResourceId,
                reason => Reason
            }),
            {error, Reason}
    end.

-spec on_stop(resource_id(), state()) -> ok | {error, term()}.
on_stop(
    ResourceId,
    _State = #{jwt_worker_id := JWTWorkerId}
) ->
    ?tp(gcp_pubsub_stop, #{resource_id => ResourceId, jwt_worker_id => JWTWorkerId}),
    ?SLOG(info, #{
        msg => "stopping_gcp_pubsub_bridge",
        connector => ResourceId
    }),
    emqx_connector_jwt_sup:ensure_worker_deleted(JWTWorkerId),
    emqx_connector_jwt:delete_jwt(?JWT_TABLE, ResourceId),
    ehttpc_sup:stop_pool(ResourceId).

-spec on_query(
    resource_id(),
    {send_message, map()},
    state()
) ->
    {ok, status_code(), headers()}
    | {ok, status_code(), headers(), body()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_query(ResourceId, {send_message, Selected}, State) ->
    Requests = [{send_message, Selected}],
    ?TRACE(
        "QUERY_SYNC",
        "gcp_pubsub_received",
        #{requests => Requests, connector => ResourceId, state => State}
    ),
    do_send_requests_sync(State, Requests, ResourceId).

-spec on_query_async(
    resource_id(),
    {send_message, map()},
    {ReplyFun :: function(), Args :: list()},
    state()
) -> {ok, pid()}.
on_query_async(ResourceId, {send_message, Selected}, ReplyFunAndArgs, State) ->
    Requests = [{send_message, Selected}],
    ?TRACE(
        "QUERY_ASYNC",
        "gcp_pubsub_received",
        #{requests => Requests, connector => ResourceId, state => State}
    ),
    do_send_requests_async(State, Requests, ReplyFunAndArgs, ResourceId).

-spec on_batch_query(
    resource_id(),
    [{send_message, map()}],
    state()
) ->
    {ok, status_code(), headers()}
    | {ok, status_code(), headers(), body()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_batch_query(ResourceId, Requests, State) ->
    ?TRACE(
        "QUERY_SYNC",
        "gcp_pubsub_received",
        #{requests => Requests, connector => ResourceId, state => State}
    ),
    do_send_requests_sync(State, Requests, ResourceId).

-spec on_batch_query_async(
    resource_id(),
    [{send_message, map()}],
    {ReplyFun :: function(), Args :: list()},
    state()
) -> {ok, pid()}.
on_batch_query_async(ResourceId, Requests, ReplyFunAndArgs, State) ->
    ?TRACE(
        "QUERY_ASYNC",
        "gcp_pubsub_received",
        #{requests => Requests, connector => ResourceId, state => State}
    ),
    do_send_requests_async(State, Requests, ReplyFunAndArgs, ResourceId).

-spec on_get_status(resource_id(), state()) -> connected | disconnected.
on_get_status(ResourceId, #{connect_timeout := Timeout} = State) ->
    case do_get_status(ResourceId, Timeout) of
        true ->
            connected;
        false ->
            ?SLOG(error, #{
                msg => "gcp_pubsub_bridge_get_status_failed",
                state => State
            }),
            disconnected
    end.

%%-------------------------------------------------------------------------------------------------
%% Helper fns
%%-------------------------------------------------------------------------------------------------

-spec ensure_jwt_worker(resource_id(), config()) ->
    #{
        jwt_worker_id := jwt_worker(),
        project_id := binary()
    }.
ensure_jwt_worker(ResourceId, #{
    service_account_json := ServiceAccountJSON
}) ->
    #{
        project_id := ProjectId,
        private_key_id := KId,
        private_key := PrivateKeyPEM,
        client_email := ServiceAccountEmail
    } = ServiceAccountJSON,
    %% fixed for pubsub; trailing slash is important.
    Aud = <<"https://pubsub.googleapis.com/">>,
    ExpirationMS = timer:hours(1),
    Alg = <<"RS256">>,
    Config = #{
        private_key => PrivateKeyPEM,
        resource_id => ResourceId,
        expiration => ExpirationMS,
        table => ?JWT_TABLE,
        iss => ServiceAccountEmail,
        sub => ServiceAccountEmail,
        aud => Aud,
        kid => KId,
        alg => Alg
    },

    JWTWorkerId = <<"gcp_pubsub_jwt_worker:", ResourceId/binary>>,
    Worker =
        case emqx_connector_jwt_sup:ensure_worker_present(JWTWorkerId, Config) of
            {ok, Worker0} ->
                Worker0;
            Error ->
                ?tp(error, "gcp_pubsub_bridge_jwt_worker_failed_to_start", #{
                    connector => ResourceId,
                    reason => Error
                }),
                _ = emqx_connector_jwt_sup:ensure_worker_deleted(JWTWorkerId),
                throw(failed_to_start_jwt_worker)
        end,
    MRef = monitor(process, Worker),
    Ref = emqx_connector_jwt_worker:ensure_jwt(Worker),

    %% to ensure that this resource and its actions will be ready to
    %% serve when started, we must ensure that the first JWT has been
    %% produced by the worker.
    receive
        {Ref, token_created} ->
            ?tp(gcp_pubsub_bridge_jwt_created, #{resource_id => ResourceId}),
            demonitor(MRef, [flush]),
            ok;
        {'DOWN', MRef, process, Worker, Reason} ->
            ?tp(error, "gcp_pubsub_bridge_jwt_worker_failed_to_start", #{
                connector => ResourceId,
                reason => Reason
            }),
            _ = emqx_connector_jwt_sup:ensure_worker_deleted(JWTWorkerId),
            throw(failed_to_start_jwt_worker)
    after 10_000 ->
        ?tp(warning, "gcp_pubsub_bridge_jwt_timeout", #{connector => ResourceId}),
        demonitor(MRef, [flush]),
        _ = emqx_connector_jwt_sup:ensure_worker_deleted(JWTWorkerId),
        throw(timeout_creating_jwt)
    end,
    #{
        jwt_worker_id => JWTWorkerId,
        project_id => ProjectId
    }.

-spec encode_payload(state(), Selected :: map()) -> #{data := binary()}.
encode_payload(_State = #{payload_template := PayloadTemplate}, Selected) ->
    Interpolated =
        case PayloadTemplate of
            [] -> emqx_utils_json:encode(Selected);
            _ -> emqx_plugin_libs_rule:proc_tmpl(PayloadTemplate, Selected)
        end,
    #{data => base64:encode(Interpolated)}.

-spec to_pubsub_request([#{data := binary()}]) -> binary().
to_pubsub_request(Payloads) ->
    emqx_utils_json:encode(#{messages => Payloads}).

-spec publish_path(state()) -> binary().
publish_path(
    _State = #{
        project_id := ProjectId,
        pubsub_topic := PubSubTopic
    }
) ->
    <<"/v1/projects/", ProjectId/binary, "/topics/", PubSubTopic/binary, ":publish">>.

-spec get_jwt_authorization_header(resource_id()) -> [{binary(), binary()}].
get_jwt_authorization_header(ResourceId) ->
    case emqx_connector_jwt:lookup_jwt(?JWT_TABLE, ResourceId) of
        %% Since we synchronize the JWT creation during resource start
        %% (see `on_start/2'), this will be always be populated.
        {ok, JWT} ->
            [{<<"Authorization">>, <<"Bearer ", JWT/binary>>}]
    end.

-spec do_send_requests_sync(
    state(),
    [{send_message, map()}],
    resource_id()
) ->
    {ok, status_code(), headers()}
    | {ok, status_code(), headers(), body()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
do_send_requests_sync(State, Requests, ResourceId) ->
    #{
        pool_name := PoolName,
        max_retries := MaxRetries,
        request_timeout := RequestTimeout
    } = State,
    ?tp(
        gcp_pubsub_bridge_do_send_requests,
        #{
            query_mode => sync,
            resource_id => ResourceId,
            requests => Requests
        }
    ),
    Headers = get_jwt_authorization_header(ResourceId),
    Payloads =
        lists:map(
            fun({send_message, Selected}) ->
                encode_payload(State, Selected)
            end,
            Requests
        ),
    Body = to_pubsub_request(Payloads),
    Path = publish_path(State),
    Method = post,
    Request = {Path, Headers, Body},
    case
        ehttpc:request(
            PoolName,
            Method,
            Request,
            RequestTimeout,
            MaxRetries
        )
    of
        {error, Reason} when
            Reason =:= econnrefused;
            %% this comes directly from `gun'...
            Reason =:= {closed, "The connection was lost."};
            Reason =:= timeout
        ->
            ?tp(
                warning,
                gcp_pubsub_request_failed,
                #{
                    reason => Reason,
                    query_mode => sync,
                    recoverable_error => true,
                    connector => ResourceId
                }
            ),
            {error, {recoverable_error, Reason}};
        {error, Reason} = Result ->
            ?tp(
                error,
                gcp_pubsub_request_failed,
                #{
                    reason => Reason,
                    query_mode => sync,
                    recoverable_error => false,
                    connector => ResourceId
                }
            ),
            Result;
        {ok, StatusCode, _} = Result when StatusCode >= 200 andalso StatusCode < 300 ->
            ?tp(
                gcp_pubsub_response,
                #{
                    response => Result,
                    query_mode => sync,
                    connector => ResourceId
                }
            ),
            Result;
        {ok, StatusCode, _, _} = Result when StatusCode >= 200 andalso StatusCode < 300 ->
            ?tp(
                gcp_pubsub_response,
                #{
                    response => Result,
                    query_mode => sync,
                    connector => ResourceId
                }
            ),
            Result;
        {ok, StatusCode, RespHeaders} = _Result ->
            ?tp(
                gcp_pubsub_response,
                #{
                    response => _Result,
                    query_mode => sync,
                    connector => ResourceId
                }
            ),
            ?SLOG(error, #{
                msg => "gcp_pubsub_error_response",
                request => Request,
                connector => ResourceId,
                status_code => StatusCode
            }),
            {error, #{status_code => StatusCode, headers => RespHeaders}};
        {ok, StatusCode, RespHeaders, RespBody} = _Result ->
            ?tp(
                gcp_pubsub_response,
                #{
                    response => _Result,
                    query_mode => sync,
                    connector => ResourceId
                }
            ),
            ?SLOG(error, #{
                msg => "gcp_pubsub_error_response",
                request => Request,
                connector => ResourceId,
                status_code => StatusCode
            }),
            {error, #{status_code => StatusCode, headers => RespHeaders, body => RespBody}}
    end.

-spec do_send_requests_async(
    state(),
    [{send_message, map()}],
    {ReplyFun :: function(), Args :: list()},
    resource_id()
) -> {ok, pid()}.
do_send_requests_async(State, Requests, ReplyFunAndArgs, ResourceId) ->
    #{
        pool_name := PoolName,
        request_timeout := RequestTimeout
    } = State,
    ?tp(
        gcp_pubsub_bridge_do_send_requests,
        #{
            query_mode => async,
            resource_id => ResourceId,
            requests => Requests
        }
    ),
    Headers = get_jwt_authorization_header(ResourceId),
    Payloads =
        lists:map(
            fun({send_message, Selected}) ->
                encode_payload(State, Selected)
            end,
            Requests
        ),
    Body = to_pubsub_request(Payloads),
    Path = publish_path(State),
    Method = post,
    Request = {Path, Headers, Body},
    Worker = ehttpc_pool:pick_worker(PoolName),
    ok = ehttpc:request_async(
        Worker,
        Method,
        Request,
        RequestTimeout,
        {fun ?MODULE:reply_delegator/3, [ResourceId, ReplyFunAndArgs]}
    ),
    {ok, Worker}.

-spec reply_delegator(
    resource_id(),
    {ReplyFun :: function(), Args :: list()},
    term() | {error, econnrefused | timeout | term()}
) -> ok.
reply_delegator(_ResourceId, ReplyFunAndArgs, Result) ->
    case Result of
        {error, Reason} when
            Reason =:= econnrefused;
            %% this comes directly from `gun'...
            Reason =:= {closed, "The connection was lost."};
            Reason =:= timeout
        ->
            ?tp(
                gcp_pubsub_request_failed,
                #{
                    reason => Reason,
                    query_mode => async,
                    recoverable_error => true,
                    connector => _ResourceId
                }
            ),
            Result1 = {error, {recoverable_error, Reason}},
            emqx_resource:apply_reply_fun(ReplyFunAndArgs, Result1);
        _ ->
            ?tp(
                gcp_pubsub_response,
                #{
                    response => Result,
                    query_mode => async,
                    connector => _ResourceId
                }
            ),
            emqx_resource:apply_reply_fun(ReplyFunAndArgs, Result)
    end.

-spec do_get_status(resource_id(), timer:time()) -> boolean().
do_get_status(ResourceId, Timeout) ->
    Workers = [Worker || {_WorkerName, Worker} <- ehttpc:workers(ResourceId)],
    DoPerWorker =
        fun(Worker) ->
            case ehttpc:health_check(Worker, Timeout) of
                ok ->
                    true;
                {error, Reason} ->
                    ?SLOG(error, #{
                        msg => "ehttpc_health_check_failed",
                        connector => ResourceId,
                        reason => Reason,
                        worker => Worker
                    }),
                    false
            end
        end,
    try emqx_utils:pmap(DoPerWorker, Workers, Timeout) of
        [_ | _] = Status ->
            lists:all(fun(St) -> St =:= true end, Status);
        [] ->
            false
    catch
        exit:timeout ->
            false
    end.
