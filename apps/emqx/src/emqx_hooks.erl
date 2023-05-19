%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_hooks).

-behaviour(gen_server).

-include("logger.hrl").
-include("types.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-export([
    start_link/0,
    stop/0
]).

%% Hooks API
-export([
    add/3,
    add/4,
    put/3,
    put/4,
    del/2,
    run/2,
    run_fold/3,
    lookup/1
]).

-export([
    callback_action/1,
    callback_filter/1,
    callback_priority/1
]).

%% gen_server Function Exports
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export_type([
    hookpoint/0,
    action/0,
    filter/0
]).

%% Multiple callbacks can be registered on a hookpoint.
%% The execution order depends on the priority value:
%%   - Callbacks with greater priority values will be run before
%%     the ones with lower priority values. e.g. A Callback with
%%     priority = 2 precedes the callback with priority = 1.
%%   - The execution order is the adding order of callbacks if they have
%%     equal priority values.

-type hookpoint() :: atom() | binary().
-type action() :: {module(), atom(), [term()] | undefined}.
-type filter() :: {module(), atom(), [term()] | undefined}.

-record(callback, {
    action :: action(),
    filter :: maybe(filter()),
    priority :: integer()
}).

-type callback() :: #callback{}.

-record(hook, {
    name :: hookpoint(),
    callbacks :: list(#callback{})
}).

-define(TAB, ?MODULE).
-define(SERVER, ?MODULE).

-spec start_link() -> startlink_ret().
start_link() ->
    gen_server:start_link(
        {local, ?SERVER},
        ?MODULE,
        [],
        [{hibernate_after, 1000}]
    ).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER, normal, infinity).

%%--------------------------------------------------------------------
%% Test APIs
%%--------------------------------------------------------------------

%% @doc Get callback action.
callback_action(#callback{action = A}) -> A.

%% @doc Get callback filter.
callback_filter(#callback{filter = F}) -> F.

%% @doc Get callback priority.
callback_priority(#callback{priority = P}) -> P.

%%--------------------------------------------------------------------
%% Hooks API
%%--------------------------------------------------------------------

%% @doc `add/3,4` add a new hook, returns 'already_exists' if the hook exists.
-spec add(hookpoint(), action(), integer()) ->
    ok_or_error(already_exists).
add(HookPoint, Action, Priority) when is_integer(Priority) ->
    do_add(HookPoint, #callback{action = Action, priority = Priority}).

-spec add(hookpoint(), action(), integer(), filter()) ->
    ok_or_error(already_exists).
add(HookPoint, Action, Priority, Filter) when is_integer(Priority) ->
    do_add(HookPoint, #callback{action = Action, filter = Filter, priority = Priority}).

do_add(HookPoint, Callback) ->
    gen_server:call(?SERVER, {add, HookPoint, Callback}, infinity).

%% @doc `put/3,4` updates the existing hook, add it if not exists.
-spec put(hookpoint(), action(), integer()) -> ok.
put(HookPoint, Action, Priority) when is_integer(Priority) ->
    do_put(HookPoint, #callback{action = Action, priority = Priority}).

-spec put(hookpoint(), action(), integer(), filter()) -> ok.
put(HookPoint, Action, Priority, Filter) when is_integer(Priority) ->
    do_put(HookPoint, #callback{action = Action, filter = Filter, priority = Priority}).

do_put(HookPoint, Callback) ->
    case do_add(HookPoint, Callback) of
        ok -> ok;
        {error, already_exists} -> gen_server:call(?SERVER, {put, HookPoint, Callback}, infinity)
    end.

%% @doc Unregister a callback.
-spec del(hookpoint(), action() | {module(), atom()}) -> ok.
del(HookPoint, Action) ->
    gen_server:cast(?SERVER, {del, HookPoint, Action}).

%% @doc Run hooks.
-spec run(hookpoint(), list(Arg :: term())) -> ok.
run(HookPoint, Args) ->
    do_run(lookup(HookPoint), Args).

%% @doc Run hooks with Accumulator.
-spec run_fold(hookpoint(), list(Arg :: term()), Acc :: term()) -> Acc :: term().
run_fold(HookPoint, Args, Acc) ->
    do_run_fold(lookup(HookPoint), Args, Acc).

do_run([#callback{action = Action, filter = Filter} | Callbacks], Args) ->
    case filter_passed(Filter, Args) andalso safe_execute(Action, Args) of
        %% stop the hook chain and return
        stop -> ok;
        %% continue the hook chain, in following cases:
        %%   - the filter validation failed with 'false'
        %%   - the callback returns any term other than 'stop'
        _ -> do_run(Callbacks, Args)
    end;
do_run([], _Args) ->
    ok.

do_run_fold([#callback{action = Action, filter = Filter} | Callbacks], Args, Acc) ->
    Args1 = Args ++ [Acc],
    case filter_passed(Filter, Args1) andalso safe_execute(Action, Args1) of
        %% stop the hook chain
        stop -> Acc;
        %% stop the hook chain with NewAcc
        {stop, NewAcc} -> NewAcc;
        %% continue the hook chain with NewAcc
        {ok, NewAcc} -> do_run_fold(Callbacks, Args, NewAcc);
        %% continue the hook chain, in following cases:
        %%   - the filter validation failed with 'false'
        %%   - the callback returns any term other than 'stop' or {'stop', NewAcc}
        _ -> do_run_fold(Callbacks, Args, Acc)
    end;
do_run_fold([], _Args, Acc) ->
    Acc.

-spec filter_passed(filter(), Args :: term()) -> true | false.
filter_passed(undefined, _Args) -> true;
filter_passed(Filter, Args) -> execute(Filter, Args).

safe_execute({M, F, A}, Args) ->
    try execute({M, F, A}, Args) of
        Result -> Result
    catch
        Error:Reason:Stacktrace ->
            ?SLOG(error, #{
                msg => "failed_to_execute",
                exception => Error,
                reason => Reason,
                stacktrace => Stacktrace,
                failed_call => {M, F, Args ++ A}
            })
    end.

%% @doc execute a function.
execute({M, F, A}, Args) ->
    erlang:apply(M, F, Args ++ A).

%% @doc Lookup callbacks.
-spec lookup(hookpoint()) -> [callback()].
lookup(HookPoint) ->
    case ets:lookup(?TAB, HookPoint) of
        [#hook{callbacks = Callbacks}] ->
            Callbacks;
        [] ->
            []
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ok = emqx_utils_ets:new(?TAB, [{keypos, #hook.name}, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({add, HookPoint, Callback = #callback{action = {M, F, _}}}, _From, State) ->
    Reply =
        case
            lists:any(
                fun(#callback{action = {M0, F0, _}}) ->
                    M0 =:= M andalso F0 =:= F
                end,
                Callbacks = lookup(HookPoint)
            )
        of
            true -> {error, already_exists};
            false -> insert_hook(HookPoint, add_callback(Callback, Callbacks))
        end,
    {reply, Reply, State};
handle_call({put, HookPoint, Callback = #callback{action = {M, F, _}}}, _From, State) ->
    Callbacks = del_callback({M, F}, lookup(HookPoint)),
    Reply = update_hook(HookPoint, add_callback(Callback, Callbacks)),
    {reply, Reply, State};
handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", req => Req}),
    {reply, ignored, State}.

handle_cast({del, HookPoint, Action}, State) ->
    case del_callback(Action, lookup(HookPoint)) of
        [] ->
            ets:delete(?TAB, HookPoint);
        Callbacks ->
            insert_hook(HookPoint, Callbacks)
    end,
    {noreply, State};
handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", req => Msg}),
    {noreply, State}.

handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

insert_hook(HookPoint, Callbacks) ->
    ets:insert(?TAB, #hook{name = HookPoint, callbacks = Callbacks}),
    ok.
update_hook(HookPoint, Callbacks) ->
    Ms = ets:fun2ms(fun({hook, K, _V}) when K =:= HookPoint -> {hook, K, Callbacks} end),
    ets:select_replace(emqx_hooks, Ms),
    ok.

add_callback(C, Callbacks) ->
    add_callback(C, Callbacks, []).

add_callback(C, [], Acc) ->
    lists:reverse([C | Acc]);
add_callback(C1 = #callback{priority = P1}, [C2 = #callback{priority = P2} | More], Acc) when
    P1 < P2
->
    add_callback(C1, More, [C2 | Acc]);
add_callback(
    C1 = #callback{priority = P1, action = MFA1},
    [C2 = #callback{priority = P2, action = MFA2} | More],
    Acc
) when
    P1 =:= P2 andalso MFA1 >= MFA2
->
    add_callback(C1, More, [C2 | Acc]);
add_callback(C1, More, Acc) ->
    lists:append(lists:reverse(Acc), [C1 | More]).

del_callback(Action, Callbacks) ->
    del_callback(Action, Callbacks, []).

del_callback(_Action, [], Acc) ->
    lists:reverse(Acc);
del_callback(Action, [#callback{action = Action} | Callbacks], Acc) ->
    del_callback(Action, Callbacks, Acc);
del_callback(Action = {M, F}, [#callback{action = {M, F, _A}} | Callbacks], Acc) ->
    del_callback(Action, Callbacks, Acc);
del_callback(Action, [Callback | Callbacks], Acc) ->
    del_callback(Action, Callbacks, [Callback | Acc]).
