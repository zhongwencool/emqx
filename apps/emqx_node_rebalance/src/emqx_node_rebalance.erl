%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_node_rebalance).

-include("emqx_node_rebalance.hrl").

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-export([
    start/1,
    status/0,
    status/1,
    stop/0
]).

-export([start_link/0]).

-behaviour(gen_statem).

-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    code_change/4
]).

-export([
    is_node_available/0,
    available_nodes/1,
    connection_count/0,
    session_count/0,
    disconnected_session_count/0
]).

-export_type([
    start_opts/0,
    start_error/0
]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-type start_opts() :: #{
    conn_evict_rate => pos_integer(),
    sess_evict_rate => pos_integer(),
    wait_health_check => pos_integer(),
    wait_takeover => pos_integer(),
    abs_conn_threshold => pos_integer(),
    rel_conn_threshold => number(),
    abs_sess_threshold => pos_integer(),
    rel_sess_threshold => number(),
    nodes => [node()]
}.
-type start_error() :: already_started | [{node(), term()}].

-spec start(start_opts()) -> ok_or_error(start_error()).
start(StartOpts) ->
    Opts = maps:merge(default_opts(), StartOpts),
    gen_statem:call(?MODULE, {start, Opts}).

-spec stop() -> ok_or_error(not_started).
stop() ->
    gen_statem:call(?MODULE, stop).

-spec status() -> disabled | {enabled, map()}.
status() ->
    gen_statem:call(?MODULE, status).

-spec status(pid()) -> disabled | {enabled, map()}.
status(Pid) ->
    gen_statem:call(Pid, status).

-spec start_link() -> startlink_ret().
start_link() ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec available_nodes(list(node())) -> list(node()).
available_nodes(Nodes) when is_list(Nodes) ->
    {Available, _} = emqx_node_rebalance_proto_v1:available_nodes(Nodes),
    lists:filter(fun is_atom/1, Available).

%%--------------------------------------------------------------------
%% gen_statem callbacks
%%--------------------------------------------------------------------

callback_mode() -> handle_event_function.

%% states: disabled, wait_health_check, evicting_conns, wait_takeover, evicting_sessions

init([]) ->
    ?tp(debug, emqx_node_rebalance_started, #{}),
    {ok, disabled, #{}}.

%% start
handle_event(
    {call, From},
    {start, #{wait_health_check := WaitHealthCheck} = Opts},
    disabled,
    #{} = Data
) ->
    case enable_rebalance(Data#{opts => Opts}) of
        {ok, NewData} ->
            ?SLOG(warning, #{msg => "node_rebalance_enabled", opts => Opts}),
            {next_state, wait_health_check, NewData, [
                {state_timeout, seconds(WaitHealthCheck), evict_conns},
                {reply, From, ok}
            ]};
        {error, Reason} ->
            ?SLOG(warning, #{
                msg => "node_rebalance_enable_failed",
                reason => Reason
            }),
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From}, {start, _Opts}, _State, #{}) ->
    {keep_state_and_data, [{reply, From, {error, already_started}}]};
%% stop
handle_event({call, From}, stop, disabled, #{}) ->
    {keep_state_and_data, [{reply, From, {error, not_started}}]};
handle_event({call, From}, stop, _State, Data) ->
    ok = disable_rebalance(Data),
    ?SLOG(warning, #{msg => "node_rebalance_stopped"}),
    {next_state, disabled, deinit(Data), [{reply, From, ok}]};
%% status
handle_event({call, From}, status, disabled, #{}) ->
    {keep_state_and_data, [{reply, From, disabled}]};
handle_event({call, From}, status, State, Data) ->
    Stats = get_stats(State, Data),
    {keep_state_and_data, [
        {reply, From,
            {enabled, Stats#{
                state => State,
                coordinator_node => node()
            }}}
    ]};
%% conn eviction
handle_event(
    state_timeout,
    evict_conns,
    wait_health_check,
    Data
) ->
    ?SLOG(warning, #{msg => "node_rebalance_wait_health_check_over"}),
    {next_state, evicting_conns, Data, [{state_timeout, 0, evict_conns}]};
handle_event(
    state_timeout,
    evict_conns,
    evicting_conns,
    #{
        opts := #{
            wait_takeover := WaitTakeover,
            evict_interval := EvictInterval
        }
    } = Data
) ->
    case evict_conns(Data) of
        ok ->
            ?SLOG(warning, #{msg => "node_rebalance_evict_conns_over"}),
            {next_state, wait_takeover, Data, [
                {state_timeout, seconds(WaitTakeover), evict_sessions}
            ]};
        {continue, NewData} ->
            {keep_state, NewData, [{state_timeout, EvictInterval, evict_conns}]}
    end;
handle_event(
    state_timeout,
    evict_sessions,
    wait_takeover,
    Data
) ->
    ?SLOG(warning, #{msg => "node_rebalance_wait_takeover_over"}),
    {next_state, evicting_sessions, Data, [{state_timeout, 0, evict_sessions}]};
handle_event(
    state_timeout,
    evict_sessions,
    evicting_sessions,
    #{opts := #{evict_interval := EvictInterval}} = Data
) ->
    case evict_sessions(Data) of
        ok ->
            ?tp(debug, emqx_node_rebalance_evict_sess_over, #{}),
            ?SLOG(warning, #{msg => "node_rebalance_evict_sessions_over"}),
            ok = disable_rebalance(Data),
            ?SLOG(warning, #{msg => "node_rebalance_finished_successfully"}),
            {next_state, disabled, deinit(Data)};
        {continue, NewData} ->
            {keep_state, NewData, [{state_timeout, EvictInterval, evict_sessions}]}
    end;
handle_event({call, From}, Msg, _State, _Data) ->
    ?SLOG(warning, #{msg => "node_rebalance_unknown_call", call => Msg}),
    {keep_state_and_data, [{reply, From, ignored}]};
handle_event(info, Msg, _State, _Data) ->
    ?SLOG(warning, #{msg => "node_rebalance_unknown_info", info => Msg}),
    keep_state_and_data;
handle_event(cast, Msg, _State, _Data) ->
    ?SLOG(warning, #{msg => "node_rebalance_unknown_cast", cast => Msg}),
    keep_state_and_data.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%--------------------------------------------------------------------
%% internal funs
%%--------------------------------------------------------------------

enable_rebalance(#{opts := Opts} = Data) ->
    Nodes = maps:get(nodes, Opts),
    ConnCounts = multicall(Nodes, connection_counts, []),
    SessCounts = multicall(Nodes, session_counts, []),
    {_, Counts} = lists:unzip(ConnCounts),
    Avg = avg(Counts),
    {DonorCounts, RecipientCounts} = lists:partition(
        fun({_Node, Count}) ->
            Count >= Avg
        end,
        ConnCounts
    ),
    ?SLOG(warning, #{
        msg => "node_rebalance_enabling",
        conn_counts => ConnCounts,
        donor_counts => DonorCounts,
        recipient_counts => RecipientCounts
    }),
    {DonorNodes, _} = lists:unzip(DonorCounts),
    {RecipientNodes, _} = lists:unzip(RecipientCounts),
    case need_rebalance(DonorNodes, RecipientNodes, ConnCounts, SessCounts, Opts) of
        false ->
            {error, nothing_to_balance};
        true ->
            _ = multicall(DonorNodes, enable_rebalance_agent, [self()]),
            {ok, Data#{
                donors => DonorNodes,
                recipients => RecipientNodes,
                initial_conn_counts => maps:from_list(ConnCounts),
                initial_sess_counts => maps:from_list(SessCounts)
            }}
    end.

disable_rebalance(#{donors := DonorNodes}) ->
    _ = multicall(DonorNodes, disable_rebalance_agent, [self()]),
    ok.

evict_conns(#{donors := DonorNodes, recipients := RecipientNodes, opts := Opts} = Data) ->
    DonorNodeCounts = multicall(DonorNodes, connection_counts, []),
    {_, DonorCounts} = lists:unzip(DonorNodeCounts),
    RecipientNodeCounts = multicall(RecipientNodes, connection_counts, []),
    {_, RecipientCounts} = lists:unzip(RecipientNodeCounts),

    DonorAvg = avg(DonorCounts),
    RecipientAvg = avg(RecipientCounts),
    Thresholds = thresholds(conn, Opts),
    NewData = Data#{
        donor_conn_avg => DonorAvg,
        recipient_conn_avg => RecipientAvg,
        donor_conn_counts => maps:from_list(DonorNodeCounts),
        recipient_conn_counts => maps:from_list(RecipientNodeCounts)
    },
    case within_thresholds(DonorAvg, RecipientAvg, Thresholds) of
        true ->
            ok;
        false ->
            ConnEvictRate = maps:get(conn_evict_rate, Opts),
            NodesToEvict = nodes_to_evict(RecipientAvg, DonorNodeCounts),
            ?SLOG(warning, #{
                donor_conn_avg => DonorAvg,
                recipient_conn_avg => RecipientAvg,
                thresholds => Thresholds,
                msg => "node_rebalance_evict_conns",
                nodes => NodesToEvict,
                counts => ConnEvictRate
            }),
            _ = multicall(NodesToEvict, evict_connections, [ConnEvictRate]),
            {continue, NewData}
    end.

evict_sessions(#{donors := DonorNodes, recipients := RecipientNodes, opts := Opts} = Data) ->
    DonorNodeCounts = multicall(DonorNodes, disconnected_session_counts, []),
    {_, DonorCounts} = lists:unzip(DonorNodeCounts),
    RecipientNodeCounts = multicall(RecipientNodes, disconnected_session_counts, []),
    {_, RecipientCounts} = lists:unzip(RecipientNodeCounts),

    DonorAvg = avg(DonorCounts),
    RecipientAvg = avg(RecipientCounts),
    Thresholds = thresholds(sess, Opts),
    NewData = Data#{
        donor_sess_avg => DonorAvg,
        recipient_sess_avg => RecipientAvg,
        donor_sess_counts => maps:from_list(DonorNodeCounts),
        recipient_sess_counts => maps:from_list(RecipientNodeCounts)
    },
    case within_thresholds(DonorAvg, RecipientAvg, Thresholds) of
        true ->
            ok;
        false ->
            SessEvictRate = maps:get(sess_evict_rate, Opts),
            NodesToEvict = nodes_to_evict(RecipientAvg, DonorNodeCounts),
            ?SLOG(warning, #{
                donor_sess_avg => DonorAvg,
                recipient_sess_avg => RecipientAvg,
                thresholds => Thresholds,
                msg => "node_rebalance_evict_sessions",
                nodes => NodesToEvict,
                counts => SessEvictRate
            }),
            _ = multicall(
                NodesToEvict,
                evict_sessions,
                [SessEvictRate, RecipientNodes, disconnected]
            ),
            {continue, NewData}
    end.

need_rebalance([] = _DonorNodes, _RecipientNodes, _ConnCounts, _SessCounts, _Opts) ->
    false;
need_rebalance(_DonorNodes, [] = _RecipientNodes, _ConnCounts, _SessCounts, _Opts) ->
    false;
need_rebalance(DonorNodes, RecipientNodes, ConnCounts, SessCounts, Opts) ->
    DonorConnAvg = avg_for_nodes(DonorNodes, ConnCounts),
    RecipientConnAvg = avg_for_nodes(RecipientNodes, ConnCounts),
    DonorSessAvg = avg_for_nodes(DonorNodes, SessCounts),
    RecipientSessAvg = avg_for_nodes(RecipientNodes, SessCounts),
    Result =
        (not within_thresholds(DonorConnAvg, RecipientConnAvg, thresholds(conn, Opts))) orelse
            (not within_thresholds(DonorSessAvg, RecipientSessAvg, thresholds(sess, Opts))),
    ?tp(
        debug,
        emqx_node_rebalance_need_rebalance,
        #{
            donors => DonorNodes,
            recipients => RecipientNodes,
            conn_counts => ConnCounts,
            sess_counts => SessCounts,
            opts => Opts,
            result => Result
        }
    ),
    Result.

avg_for_nodes(Nodes, Counts) ->
    avg(maps:values(maps:with(Nodes, maps:from_list(Counts)))).

within_thresholds(Value, GoalValue, {AbsThres, RelThres}) ->
    (Value =< GoalValue + AbsThres) orelse (Value =< GoalValue * RelThres).

thresholds(conn, #{abs_conn_threshold := Abs, rel_conn_threshold := Rel}) ->
    {Abs, Rel};
thresholds(sess, #{abs_sess_threshold := Abs, rel_sess_threshold := Rel}) ->
    {Abs, Rel}.

nodes_to_evict(Goal, NodeCounts) ->
    {Nodes, _} = lists:unzip(
        lists:filter(
            fun({_Node, Count}) ->
                Count > Goal
            end,
            NodeCounts
        )
    ),
    Nodes.

get_stats(disabled, _Data) -> #{};
get_stats(_State, Data) -> Data.

avg(List) when length(List) >= 1 ->
    lists:sum(List) / length(List).

multicall(Nodes, F, A) ->
    case apply(emqx_node_rebalance_proto_v1, F, [Nodes | A]) of
        {Results, []} ->
            case lists:partition(fun is_ok/1, lists:zip(Nodes, Results)) of
                {OkResults, []} ->
                    [{Node, ok_result(Result)} || {Node, Result} <- OkResults];
                {_, BadResults} ->
                    error({bad_nodes, BadResults})
            end;
        {_, [_BadNode | _] = BadNodes} ->
            error({bad_nodes, BadNodes})
    end.

is_ok({_Node, {ok, _}}) -> true;
is_ok({_Node, ok}) -> true;
is_ok(_) -> false.

ok_result({ok, Result}) -> Result;
ok_result(ok) -> ok.

connection_count() ->
    {ok, emqx_eviction_agent:connection_count()}.

session_count() ->
    {ok, emqx_eviction_agent:session_count()}.

disconnected_session_count() ->
    {ok, emqx_eviction_agent:session_count(disconnected)}.

default_opts() ->
    #{
        conn_evict_rate => ?DEFAULT_CONN_EVICT_RATE,
        abs_conn_threshold => ?DEFAULT_ABS_CONN_THRESHOLD,
        rel_conn_threshold => ?DEFAULT_REL_CONN_THRESHOLD,

        sess_evict_rate => ?DEFAULT_SESS_EVICT_RATE,
        abs_sess_threshold => ?DEFAULT_ABS_SESS_THRESHOLD,
        rel_sess_threshold => ?DEFAULT_REL_SESS_THRESHOLD,

        wait_health_check => ?DEFAULT_WAIT_HEALTH_CHECK,
        wait_takeover => ?DEFAULT_WAIT_TAKEOVER,

        evict_interval => ?EVICT_INTERVAL,

        nodes => all_nodes()
    }.

deinit(Data) ->
    Keys = [
        recipient_conn_avg,
        recipient_sess_avg,
        donor_conn_avg,
        donor_sess_avg,
        recipient_conn_counts,
        recipient_sess_counts,
        donor_conn_counts,
        donor_sess_counts,
        initial_conn_counts,
        initial_sess_counts,
        opts
    ],
    maps:without(Keys, Data).

is_node_available() ->
    true = is_pid(whereis(emqx_node_rebalance_agent)),
    disabled = emqx_eviction_agent:status(),
    node().

all_nodes() ->
    mria_mnesia:running_nodes().

seconds(Sec) ->
    round(timer:seconds(Sec)).
