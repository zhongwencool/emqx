%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_machine_terminator).

-behaviour(gen_server).

-export([ start/0
        , graceful/0
        , graceful_wait/0
        , is_running/0
        ]).

-export([init/1, format_status/2,
         handle_cast/2, handle_call/3, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("emqx/include/logger.hrl").

-define(TERMINATOR, ?MODULE).
-define(DO_IT, graceful_shutdown).

%% @doc This API is called to shutdown the Erlang VM by RPC call from remote shell node.
%% The shutown of apps is delegated to a to a process instead of doing it in the RPC spawned
%% process which has a remote group leader.
start() ->
    {ok, _} = gen_server:start_link({local, ?TERMINATOR}, ?MODULE, [], []),
    %% NOTE: Do not link this process under any supervision tree
    ok.

is_running() -> is_pid(whereis(?TERMINATOR)).

%% @doc Send a signal to activate the terminator.
graceful() ->
    ?TERMINATOR ! ?DO_IT,
    ok.

%% @doc Shutdown the Erlang VM and wait until the terminator dies or the VM dies.
graceful_wait() ->
    case whereis(?TERMINATOR) of
        undefined ->
            ?SLOG(warning, #{msg => "shutdown_before_boot_is_complete"}),
            exit_loop();
        Pid ->
            ok = graceful(),
            Ref = monitor(process, Pid),
            %% NOTE: not exactly sure, but maybe there is a chance that
            %% Erlang VM goes down before this receive.
            %% In which case, the remote caller will get {badrpc, nodedown}
            receive {'DOWN', Ref, process, Pid, _} -> ok end
    end.

exit_loop() ->
    init:stop(),
    timer:sleep(100),
    exit_loop().

init(_) ->
    ok = emqx_machine_signal_handler:start(),
    {ok, #{}}.

handle_info(?DO_IT, State) ->
    try
        emqx_machine:stop_apps(normal)
    catch
        C : E : St ->
            Apps = [element(1, A) || A <- application:which_applications()],
            ?SLOG(error, #{msg => "failed_to_stop_apps",
                           exception => C,
                           reason => E,
                           stacktrace => St,
                           remaining_apps => Apps
                          })
    after
        init:stop()
    end,
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_call(_Call, _From, State) ->
    {noreply, State}.

format_status(_Opt, [_Pdict,_S]) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Args, _State) ->
    ok.
