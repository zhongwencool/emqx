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

-module(emqx_resource_pool).

-export([
    start/3,
    stop/1,
    health_check_workers/2,
    health_check_workers/3
]).

-include_lib("emqx/include/logger.hrl").

-define(HEALTH_CHECK_TIMEOUT, 15000).

start(Name, Mod, Options) ->
    case ecpool:start_sup_pool(Name, Mod, Options) of
        {ok, _} ->
            ?SLOG(info, #{msg => "start_ecpool_ok", pool_name => Name}),
            ok;
        {error, {already_started, _Pid}} ->
            stop(Name),
            start(Name, Mod, Options);
        {error, Reason} ->
            NReason = parse_reason(Reason),
            ?SLOG(error, #{
                msg => "start_ecpool_error",
                pool_name => Name,
                reason => NReason
            }),
            {error, {start_pool_failed, Name, NReason}}
    end.

stop(Name) ->
    case ecpool:stop_sup_pool(Name) of
        ok ->
            ?SLOG(info, #{msg => "stop_ecpool_ok", pool_name => Name});
        {error, not_found} ->
            ok;
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "stop_ecpool_failed",
                pool_name => Name,
                reason => Reason
            }),
            error({stop_pool_failed, Name, Reason})
    end.

health_check_workers(PoolName, CheckFunc) ->
    health_check_workers(PoolName, CheckFunc, ?HEALTH_CHECK_TIMEOUT).

health_check_workers(PoolName, CheckFunc, Timeout) ->
    Workers = [Worker || {_WorkerName, Worker} <- ecpool:workers(PoolName)],
    DoPerWorker =
        fun(Worker) ->
            case ecpool_worker:client(Worker) of
                {ok, Conn} ->
                    erlang:is_process_alive(Conn) andalso
                        ecpool_worker:exec(Worker, CheckFunc, Timeout);
                _ ->
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

parse_reason({
    {shutdown, {failed_to_start_child, _, {shutdown, {failed_to_start_child, _, Reason}}}},
    _
}) ->
    Reason;
parse_reason(Reason) ->
    Reason.
