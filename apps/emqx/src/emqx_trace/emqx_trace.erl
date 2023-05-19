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
-module(emqx_trace).

-behaviour(gen_server).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("snabbkaffe/include/trace.hrl").
-include_lib("emqx/include/emqx_trace.hrl").

-export([
    publish/1,
    subscribe/3,
    unsubscribe/2,
    log/3
]).

-export([
    start_link/0,
    list/0,
    list/1,
    get_trace_filename/1,
    create/1,
    delete/1,
    clear/0,
    update/2,
    check/0,
    now_second/0
]).

-export([
    format/1,
    zip_dir/0,
    filename/2,
    trace_dir/0,
    trace_file/1,
    trace_file_detail/1,
    delete_files_after_send/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-ifdef(TEST).
-export([
    log_file/2,
    find_closest_time/2
]).
-endif.

-export_type([ip_address/0]).
-type ip_address() :: string().

publish(#message{topic = <<"$SYS/", _/binary>>}) ->
    ignore;
publish(#message{from = From, topic = Topic, payload = Payload}) when
    is_binary(From); is_atom(From)
->
    ?TRACE("PUBLISH", "publish_to", #{topic => Topic, payload => Payload}).

subscribe(<<"$SYS/", _/binary>>, _SubId, _SubOpts) ->
    ignore;
subscribe(Topic, SubId, SubOpts) ->
    ?TRACE("SUBSCRIBE", "subscribe", #{topic => Topic, sub_opts => SubOpts, sub_id => SubId}).

unsubscribe(<<"$SYS/", _/binary>>, _SubOpts) ->
    ignore;
unsubscribe(Topic, SubOpts) ->
    ?TRACE("UNSUBSCRIBE", "unsubscribe", #{topic => Topic, sub_opts => SubOpts}).

log(List, Msg, Meta) ->
    Log = #{level => debug, meta => enrich_meta(Meta), msg => Msg},
    log_filter(List, Log).

enrich_meta(Meta) ->
    case logger:get_process_metadata() of
        undefined -> Meta;
        ProcMeta -> maps:merge(ProcMeta, Meta)
    end.

log_filter([], _Log) ->
    ok;
log_filter([{Id, FilterFun, Filter, Name} | Rest], Log0) ->
    case FilterFun(Log0, {Filter, Name}) of
        stop ->
            stop;
        ignore ->
            ignore;
        Log ->
            case logger_config:get(ets:whereis(logger), Id) of
                {ok, #{module := Module} = HandlerConfig0} ->
                    HandlerConfig = maps:without(?OWN_KEYS, HandlerConfig0),
                    try
                        Module:log(Log, HandlerConfig)
                    catch
                        C:R:S ->
                            case logger:remove_handler(Id) of
                                ok ->
                                    logger:internal_log(
                                        error, {removed_failing_handler, Id, C, R, S}
                                    );
                                {error, {not_found, _}} ->
                                    %% Probably already removed by other client
                                    %% Don't report again
                                    ok;
                                {error, Reason} ->
                                    logger:internal_log(
                                        error,
                                        {removed_handler_failed, Id, Reason, C, R, S}
                                    )
                            end
                    end;
                {error, {not_found, Id}} ->
                    ok;
                {error, Reason} ->
                    logger:internal_log(error, {find_handle_id_failed, Id, Reason})
            end
    end,
    log_filter(Rest, Log0).

-spec start_link() -> emqx_types:startlink_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec list() -> [tuple()].
list() ->
    ets:match_object(?TRACE, #?TRACE{_ = '_'}).

-spec list(boolean()) -> [tuple()].
list(Enable) ->
    ets:match_object(?TRACE, #?TRACE{enable = Enable, _ = '_'}).

-spec create([{Key :: binary(), Value :: binary()}] | #{atom() => binary()}) ->
    {ok, #?TRACE{}}
    | {error,
        {duplicate_condition, iodata()}
        | {already_existed, iodata()}
        | {bad_type, any()}
        | iodata()}.
create(Trace) ->
    case mnesia:table_info(?TRACE, size) < ?MAX_SIZE of
        true ->
            case to_trace(Trace) of
                {ok, TraceRec} -> insert_new_trace(TraceRec);
                {error, Reason} -> {error, Reason}
            end;
        false ->
            {error,
                "The number of traces created has reache the maximum"
                " please delete the useless ones first"}
    end.

-spec delete(Name :: binary()) -> ok | {error, not_found}.
delete(Name) ->
    transaction(fun emqx_trace_dl:delete/1, [Name]).

-spec clear() -> ok | {error, Reason :: term()}.
clear() ->
    case mria:clear_table(?TRACE) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec update(Name :: binary(), Enable :: boolean()) ->
    ok | {error, not_found | finished}.
update(Name, Enable) ->
    transaction(fun emqx_trace_dl:update/2, [Name, Enable]).

check() ->
    gen_server:call(?MODULE, check).

-spec get_trace_filename(Name :: binary()) ->
    {ok, FileName :: string()} | {error, not_found}.
get_trace_filename(Name) ->
    transaction(fun emqx_trace_dl:get_trace_filename/1, [Name]).

-spec trace_file(File :: file:filename_all()) ->
    {ok, Node :: list(), Binary :: binary()}
    | {error, Node :: list(), Reason :: term()}.
trace_file(File) ->
    FileName = filename:join(trace_dir(), File),
    Node = atom_to_list(node()),
    case file:read_file(FileName) of
        {ok, Bin} -> {ok, Node, Bin};
        {error, Reason} -> {error, Node, Reason}
    end.

trace_file_detail(File) ->
    FileName = filename:join(trace_dir(), File),
    Node = atom_to_binary(node()),
    case file:read_file_info(FileName, [{'time', 'posix'}]) of
        {ok, #file_info{size = Size, mtime = Mtime}} ->
            {ok, #{size => Size, mtime => Mtime, node => Node}};
        {error, Reason} ->
            {error, #{reason => Reason, node => Node, file => File}}
    end.

delete_files_after_send(TraceLog, Zips) ->
    gen_server:cast(?MODULE, {delete_tag, self(), [TraceLog | Zips]}).

-spec format(list(#?TRACE{})) -> list(map()).
format(Traces) ->
    Fields = record_info(fields, ?TRACE),
    lists:map(
        fun(Trace0 = #?TRACE{}) ->
            [_ | Values] = tuple_to_list(Trace0),
            maps:from_list(lists:zip(Fields, Values))
        end,
        Traces
    ).

init([]) ->
    erlang:process_flag(trap_exit, true),
    Fields = record_info(fields, ?TRACE),
    ok = mria:create_table(?TRACE, [
        {type, set},
        {rlog_shard, ?SHARD},
        {storage, disc_copies},
        {record_name, ?TRACE},
        {attributes, Fields}
    ]),
    ok = mria:wait_for_tables([?TRACE]),
    maybe_migrate_trace(Fields),
    {ok, _} = mnesia:subscribe({table, ?TRACE, simple}),
    ok = filelib:ensure_dir(filename:join([trace_dir(), dummy])),
    ok = filelib:ensure_dir(filename:join([zip_dir(), dummy])),
    Traces = get_enabled_trace(),
    TRef = update_trace(Traces),
    update_trace_handler(),
    {ok, #{timer => TRef, monitors => #{}}}.

handle_call(check, _From, State) ->
    {_, NewState} = handle_info({mnesia_table_event, check}, State),
    {reply, ok, NewState};
handle_call(Req, _From, State) ->
    ?SLOG(error, #{unexpected_call => Req}),
    {reply, ok, State}.

handle_cast({delete_tag, Pid, Files}, State = #{monitors := Monitors}) ->
    erlang:monitor(process, Pid),
    {noreply, State#{monitors => Monitors#{Pid => Files}}};
handle_cast(Msg, State) ->
    ?SLOG(error, #{unexpected_cast => Msg}),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #{monitors := Monitors}) ->
    case maps:take(Pid, Monitors) of
        error ->
            {noreply, State};
        {Files, NewMonitors} ->
            lists:foreach(fun file:delete/1, Files),
            {noreply, State#{monitors => NewMonitors}}
    end;
handle_info({timeout, TRef, update_trace}, #{timer := TRef} = State) ->
    Traces = get_enabled_trace(),
    NextTRef = update_trace(Traces),
    update_trace_handler(),
    ?tp(update_trace_done, #{}),
    {noreply, State#{timer => NextTRef}};
handle_info({mnesia_table_event, _Events}, State = #{timer := TRef}) ->
    emqx_utils:cancel_timer(TRef),
    handle_info({timeout, TRef, update_trace}, State);
handle_info(Info, State) ->
    ?SLOG(error, #{unexpected_info => Info}),
    {noreply, State}.

terminate(_Reason, #{timer := TRef}) ->
    _ = mnesia:unsubscribe({table, ?TRACE, simple}),
    emqx_utils:cancel_timer(TRef),
    stop_all_trace_handler(),
    update_trace_handler(),
    _ = file:del_dir_r(zip_dir()),
    ok.

code_change(_, State, _Extra) ->
    {ok, State}.

insert_new_trace(Trace) ->
    transaction(fun emqx_trace_dl:insert_new_trace/1, [Trace]).

update_trace(Traces) ->
    Now = now_second(),
    {_Waiting, Running, Finished} = classify_by_time(Traces, Now),
    disable_finished(Finished),
    Started = emqx_trace_handler:running(),
    {NeedRunning, AllStarted} = start_trace(Running, Started),
    NeedStop = filter_cli_handler(AllStarted) -- NeedRunning,
    ok = stop_trace(NeedStop, Started),
    clean_stale_trace_files(),
    NextTime = find_closest_time(Traces, Now),
    emqx_utils:start_timer(NextTime, update_trace).

stop_all_trace_handler() ->
    lists:foreach(
        fun(#{id := Id}) -> emqx_trace_handler:uninstall(Id) end,
        emqx_trace_handler:running()
    ).

get_enabled_trace() ->
    {atomic, Traces} =
        mria:ro_transaction(?SHARD, fun emqx_trace_dl:get_enabled_trace/0),
    Traces.

find_closest_time(Traces, Now) ->
    Sec =
        lists:foldl(
            fun
                (#?TRACE{start_at = Start, end_at = End, enable = true}, Closest) ->
                    min(closest(End, Now, Closest), closest(Start, Now, Closest));
                (_, Closest) ->
                    Closest
            end,
            60 * 15,
            Traces
        ),
    timer:seconds(Sec).

closest(Time, Now, Closest) when Now >= Time -> Closest;
closest(Time, Now, Closest) -> min(Time - Now, Closest).

disable_finished([]) ->
    ok;
disable_finished(Traces) ->
    transaction(fun emqx_trace_dl:delete_finished/1, [Traces]).

start_trace(Traces, Started0) ->
    Started = lists:map(fun(#{name := Name}) -> Name end, Started0),
    lists:foldl(
        fun(
            #?TRACE{name = Name} = Trace,
            {Running, StartedAcc}
        ) ->
            case lists:member(Name, StartedAcc) of
                true ->
                    {[Name | Running], StartedAcc};
                false ->
                    case start_trace(Trace) of
                        ok -> {[Name | Running], [Name | StartedAcc]};
                        {error, _Reason} -> {[Name | Running], StartedAcc}
                    end
            end
        end,
        {[], Started},
        Traces
    ).

start_trace(Trace) ->
    #?TRACE{
        name = Name,
        type = Type,
        filter = Filter,
        start_at = Start,
        payload_encode = PayloadEncode
    } = Trace,
    Who = #{name => Name, type => Type, filter => Filter, payload_encode => PayloadEncode},
    emqx_trace_handler:install(Who, debug, log_file(Name, Start)).

stop_trace(Finished, Started) ->
    lists:foreach(
        fun(#{name := Name, type := Type, filter := Filter}) ->
            case lists:member(Name, Finished) of
                true ->
                    ?TRACE("API", "trace_stopping", #{Type => Filter}),
                    emqx_trace_handler:uninstall(Type, Name);
                false ->
                    ok
            end
        end,
        Started
    ).

clean_stale_trace_files() ->
    TraceDir = trace_dir(),
    case file:list_dir(TraceDir) of
        {ok, AllFiles} when AllFiles =/= ["zip"] ->
            FileFun = fun(#?TRACE{name = Name, start_at = StartAt}) -> filename(Name, StartAt) end,
            KeepFiles = lists:map(FileFun, list()),
            case AllFiles -- ["zip" | KeepFiles] of
                [] ->
                    ok;
                DeleteFiles ->
                    DelFun = fun(F) -> file:delete(filename:join(TraceDir, F)) end,
                    lists:foreach(DelFun, DeleteFiles)
            end;
        _ ->
            ok
    end.

classify_by_time(Traces, Now) ->
    classify_by_time(Traces, Now, [], [], []).

classify_by_time([], _Now, Wait, Run, Finish) ->
    {Wait, Run, Finish};
classify_by_time(
    [Trace = #?TRACE{start_at = Start} | Traces],
    Now,
    Wait,
    Run,
    Finish
) when Start > Now ->
    classify_by_time(Traces, Now, [Trace | Wait], Run, Finish);
classify_by_time(
    [Trace = #?TRACE{end_at = End} | Traces],
    Now,
    Wait,
    Run,
    Finish
) when End =< Now ->
    classify_by_time(Traces, Now, Wait, Run, [Trace | Finish]);
classify_by_time([Trace | Traces], Now, Wait, Run, Finish) ->
    classify_by_time(Traces, Now, Wait, [Trace | Run], Finish).

to_trace(TraceParam) ->
    case to_trace(ensure_map(TraceParam), #?TRACE{}) of
        {error, Reason} ->
            {error, Reason};
        {ok, #?TRACE{name = undefined}} ->
            {error, "name required"};
        {ok, #?TRACE{type = undefined}} ->
            {error, "type=[topic,clientid,ip_address] required"};
        {ok, TraceRec0 = #?TRACE{}} ->
            case fill_default(TraceRec0) of
                #?TRACE{start_at = Start, end_at = End} when End =< Start ->
                    {error, "failed by start_at >= end_at"};
                TraceRec ->
                    {ok, TraceRec}
            end
    end.

ensure_map(#{} = Trace) ->
    maps:fold(
        fun
            (K, V, Acc) when is_binary(K) -> Acc#{binary_to_existing_atom(K) => V};
            (K, V, Acc) when is_atom(K) -> Acc#{K => V}
        end,
        #{},
        Trace
    );
ensure_map(Trace) when is_list(Trace) ->
    lists:foldl(
        fun
            ({K, V}, Acc) when is_binary(K) -> Acc#{binary_to_existing_atom(K) => V};
            ({K, V}, Acc) when is_atom(K) -> Acc#{K => V};
            (_, Acc) -> Acc
        end,
        #{},
        Trace
    ).

fill_default(Trace = #?TRACE{start_at = undefined}) ->
    fill_default(Trace#?TRACE{start_at = now_second()});
fill_default(Trace = #?TRACE{end_at = undefined, start_at = StartAt}) ->
    fill_default(Trace#?TRACE{end_at = StartAt + 10 * 60});
fill_default(Trace) ->
    Trace.

-define(NAME_RE, "^[A-Za-z]+[A-Za-z0-9-_]*$").

to_trace(#{name := Name} = Trace, Rec) ->
    case re:run(Name, ?NAME_RE) of
        nomatch -> {error, "Name should be " ?NAME_RE};
        _ -> to_trace(maps:remove(name, Trace), Rec#?TRACE{name = Name})
    end;
to_trace(#{type := clientid, clientid := Filter} = Trace, Rec) ->
    Trace0 = maps:without([type, clientid], Trace),
    to_trace(Trace0, Rec#?TRACE{type = clientid, filter = Filter});
to_trace(#{type := topic, topic := Filter} = Trace, Rec) ->
    case validate_topic(Filter) of
        ok ->
            Trace0 = maps:without([type, topic], Trace),
            to_trace(Trace0, Rec#?TRACE{type = topic, filter = Filter});
        Error ->
            Error
    end;
to_trace(#{type := ip_address, ip_address := Filter} = Trace, Rec) ->
    case validate_ip_address(Filter) of
        ok ->
            Trace0 = maps:without([type, ip_address], Trace),
            to_trace(Trace0, Rec#?TRACE{type = ip_address, filter = binary_to_list(Filter)});
        Error ->
            Error
    end;
to_trace(#{type := Type}, _Rec) ->
    {error, io_lib:format("required ~s field", [Type])};
to_trace(#{payload_encode := PayloadEncode} = Trace, Rec) ->
    to_trace(maps:remove(payload_encode, Trace), Rec#?TRACE{payload_encode = PayloadEncode});
to_trace(#{start_at := StartAt} = Trace, Rec) ->
    {ok, Sec} = to_system_second(StartAt),
    to_trace(maps:remove(start_at, Trace), Rec#?TRACE{start_at = Sec});
to_trace(#{end_at := EndAt} = Trace, Rec) ->
    Now = now_second(),
    case to_system_second(EndAt) of
        {ok, Sec} when Sec > Now ->
            to_trace(maps:remove(end_at, Trace), Rec#?TRACE{end_at = Sec});
        {ok, _Sec} ->
            {error, "end_at time has already passed"}
    end;
to_trace(_, Rec) ->
    {ok, Rec}.

validate_topic(TopicName) ->
    try emqx_topic:validate(filter, TopicName) of
        true -> ok
    catch
        error:Error ->
            {error, io_lib:format("topic: ~s invalid by ~p", [TopicName, Error])}
    end.
validate_ip_address(IP) ->
    case inet:parse_address(binary_to_list(IP)) of
        {ok, _} -> ok;
        {error, Reason} -> {error, lists:flatten(io_lib:format("ip address: ~p", [Reason]))}
    end.

to_system_second(Sec) ->
    {ok, erlang:max(now_second(), Sec)}.

zip_dir() ->
    filename:join([trace_dir(), "zip"]).

trace_dir() ->
    filename:join(emqx:data_dir(), "trace").

log_file(Name, Start) ->
    filename:join(trace_dir(), filename(Name, Start)).

filename(Name, Start) ->
    [Time, _] = string:split(calendar:system_time_to_rfc3339(Start), "T", leading),
    lists:flatten(["trace_", binary_to_list(Name), "_", Time, ".log"]).

transaction(Fun, Args) ->
    case mria:transaction(?COMMON_SHARD, Fun, Args) of
        {atomic, Res} -> Res;
        {aborted, Reason} -> {error, Reason}
    end.

update_trace_handler() ->
    case emqx_trace_handler:running() of
        [] ->
            persistent_term:erase(?TRACE_FILTER);
        Running ->
            List = lists:map(
                fun(
                    #{
                        id := Id,
                        filter_fun := FilterFun,
                        filter := Filter,
                        name := Name
                    }
                ) ->
                    {Id, FilterFun, Filter, Name}
                end,
                Running
            ),
            case List =/= persistent_term:get(?TRACE_FILTER, undefined) of
                true -> persistent_term:put(?TRACE_FILTER, List);
                false -> ok
            end
    end.

filter_cli_handler(Names) ->
    lists:filter(
        fun(Name) ->
            nomatch =:= re:run(Name, "^CLI-+.", [])
        end,
        Names
    ).

now_second() ->
    os:system_time(second).

maybe_migrate_trace(Fields) ->
    case mnesia:table_info(emqx_trace, attributes) =:= Fields of
        true ->
            ok;
        false ->
            TransFun = fun(Trace) ->
                case Trace of
                    {?TRACE, Name, Type, Filter, Enable, StartAt, EndAt} ->
                        #?TRACE{
                            name = Name,
                            type = Type,
                            filter = Filter,
                            enable = Enable,
                            start_at = StartAt,
                            end_at = EndAt,
                            payload_encode = text,
                            extra = #{}
                        };
                    #?TRACE{} ->
                        Trace
                end
            end,
            {atomic, ok} = mnesia:transform_table(?TRACE, TransFun, Fields, ?TRACE),
            ok
    end.
