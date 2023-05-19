%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_node_rebalance_status).

-export([
    local_status/0,
    local_status/1,
    global_status/0,
    format_local_status/1,
    format_coordinator_status/1
]).

%% For RPC
-export([
    evacuation_status/0,
    rebalance_status/0
]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec local_status() -> disabled | {evacuation, map()} | {rebalance, map()}.
local_status() ->
    case emqx_node_rebalance_evacuation:status() of
        {enabled, Status} ->
            {evacuation, evacuation(Status)};
        disabled ->
            case emqx_node_rebalance_agent:status() of
                {enabled, CoordinatorPid} ->
                    case emqx_node_rebalance:status(CoordinatorPid) of
                        {enabled, Status} ->
                            local_rebalance(Status, node());
                        disabled ->
                            disabled
                    end;
                disabled ->
                    disabled
            end
    end.

-spec local_status(node()) -> disabled | {evacuation, map()} | {rebalance, map()}.
local_status(Node) ->
    emqx_node_rebalance_status_proto_v1:local_status(Node).

-spec format_local_status(map()) -> iodata().
format_local_status(Status) ->
    format_status(Status, local_status_field_format_order()).

-spec global_status() -> #{rebalances := [{node(), map()}], evacuations := [{node(), map()}]}.
global_status() ->
    Nodes = mria_mnesia:running_nodes(),
    {RebalanceResults, _} = emqx_node_rebalance_status_proto_v1:rebalance_status(Nodes),
    Rebalances = [
        {Node, coordinator_rebalance(Status)}
     || {Node, {enabled, Status}} <- RebalanceResults
    ],
    {EvacuatioResults, _} = emqx_node_rebalance_status_proto_v1:evacuation_status(Nodes),
    Evacuations = [{Node, evacuation(Status)} || {Node, {enabled, Status}} <- EvacuatioResults],
    #{rebalances => Rebalances, evacuations => Evacuations}.

-spec format_coordinator_status(map()) -> iodata().
format_coordinator_status(Status) ->
    format_status(Status, coordinator_status_field_format_order()).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

evacuation(Status) ->
    #{
        state => maps:get(state, Status),
        connection_eviction_rate => maps:get(conn_evict_rate, Status),
        session_eviction_rate => maps:get(sess_evict_rate, Status),
        connection_goal => 0,
        session_goal => 0,
        session_recipients => maps:get(migrate_to, Status),
        stats => #{
            initial_connected => maps:get(initial_conns, Status),
            current_connected => maps:get(current_conns, Status),
            initial_sessions => maps:get(initial_sessions, Status),
            current_sessions => maps:get(current_sessions, Status)
        }
    }.

local_rebalance(#{donors := Donors} = Stats, Node) ->
    case lists:member(Node, Donors) of
        true -> {rebalance, donor_rebalance(Stats, Node)};
        false -> disabled
    end.

donor_rebalance(Status, Node) ->
    Opts = maps:get(opts, Status),
    InitialConnCounts = maps:get(initial_conn_counts, Status),
    InitialSessCounts = maps:get(initial_sess_counts, Status),

    CurrentStats = #{
        initial_connected => maps:get(Node, InitialConnCounts),
        initial_sessions => maps:get(Node, InitialSessCounts),
        current_connected => emqx_eviction_agent:connection_count(),
        current_sessions => emqx_eviction_agent:session_count(),
        current_disconnected_sessions => emqx_eviction_agent:session_count(
            disconnected
        )
    },
    maps:from_list(
        [
            {state, maps:get(state, Status)},
            {coordinator_node, maps:get(coordinator_node, Status)},
            {connection_eviction_rate, maps:get(conn_evict_rate, Opts)},
            {session_eviction_rate, maps:get(sess_evict_rate, Opts)},
            {recipients, maps:get(recipients, Status)},
            {stats, CurrentStats}
        ] ++
            [
                {connection_goal, maps:get(recipient_conn_avg, Status)}
             || maps:is_key(recipient_conn_avg, Status)
            ] ++
            [
                {disconnected_session_goal, maps:get(recipient_sess_avg, Status)}
             || maps:is_key(recipient_sess_avg, Status)
            ]
    ).

coordinator_rebalance(Status) ->
    Opts = maps:get(opts, Status),
    maps:from_list(
        [
            {state, maps:get(state, Status)},
            {coordinator_node, maps:get(coordinator_node, Status)},
            {connection_eviction_rate, maps:get(conn_evict_rate, Opts)},
            {session_eviction_rate, maps:get(sess_evict_rate, Opts)},
            {recipients, maps:get(recipients, Status)},
            {donors, maps:get(donors, Status)}
        ] ++
            [
                {connection_goal, maps:get(recipient_conn_avg, Status)}
             || maps:is_key(recipient_conn_avg, Status)
            ] ++
            [
                {disconnected_session_goal, maps:get(recipient_sess_avg, Status)}
             || maps:is_key(recipient_sess_avg, Status)
            ] ++
            [
                {donor_conn_avg, maps:get(donor_conn_avg, Status)}
             || maps:is_key(donor_conn_avg, Status)
            ] ++
            [
                {donor_sess_avg, maps:get(donor_sess_avg, Status)}
             || maps:is_key(donor_sess_avg, Status)
            ]
    ).

local_status_field_format_order() ->
    [
        state,
        coordinator_node,
        connection_eviction_rate,
        session_eviction_rate,
        connection_goal,
        session_goal,
        disconnected_session_goal,
        session_recipients,
        recipients,
        stats
    ].

coordinator_status_field_format_order() ->
    [
        state,
        coordinator_node,
        donors,
        recipients,
        connection_eviction_rate,
        session_eviction_rate,
        connection_goal,
        disconnected_session_goal,
        donor_conn_avg,
        donor_sess_avg
    ].

format_status(Status, FieldOrder) ->
    Fields = lists:flatmap(
        fun(FieldName) ->
            maps:to_list(maps:with([FieldName], Status))
        end,
        FieldOrder
    ),
    lists:map(
        fun format_local_status_field/1,
        Fields
    ).

format_local_status_field({state, State}) ->
    io_lib:format("Rebalance state: ~p~n", [State]);
format_local_status_field({coordinator_node, Node}) ->
    io_lib:format("Coordinator node: ~p~n", [Node]);
format_local_status_field({connection_eviction_rate, ConnEvictRate}) ->
    io_lib:format("Connection eviction rate: ~p connections/second~n", [ConnEvictRate]);
format_local_status_field({session_eviction_rate, SessEvictRate}) ->
    io_lib:format("Session eviction rate: ~p sessions/second~n", [SessEvictRate]);
format_local_status_field({connection_goal, ConnGoal}) ->
    io_lib:format("Connection goal: ~p~n", [ConnGoal]);
format_local_status_field({session_goal, SessGoal}) ->
    io_lib:format("Session goal: ~p~n", [SessGoal]);
format_local_status_field({disconnected_session_goal, DisconnSessGoal}) ->
    io_lib:format("Disconnected session goal: ~p~n", [DisconnSessGoal]);
format_local_status_field({session_recipients, SessionRecipients}) ->
    io_lib:format("Session recipient nodes: ~p~n", [SessionRecipients]);
format_local_status_field({recipients, Recipients}) ->
    io_lib:format("Recipient nodes: ~p~n", [Recipients]);
format_local_status_field({donors, Donors}) ->
    io_lib:format("Donor nodes: ~p~n", [Donors]);
format_local_status_field({donor_conn_avg, DonorConnAvg}) ->
    io_lib:format("Current average donor node connection count: ~p~n", [DonorConnAvg]);
format_local_status_field({donor_sess_avg, DonorSessAvg}) ->
    io_lib:format("Current average donor node disconnected session count: ~p~n", [DonorSessAvg]);
format_local_status_field({stats, Stats}) ->
    format_local_stats(Stats).

format_local_stats(Stats) ->
    [
        "Channel statistics:\n"
        | lists:map(
            fun({Name, Value}) ->
                io_lib:format("  ~p: ~p~n", [Name, Value])
            end,
            maps:to_list(Stats)
        )
    ].

evacuation_status() ->
    {node(), emqx_node_rebalance_evacuation:status()}.

rebalance_status() ->
    {node(), emqx_node_rebalance:status()}.
