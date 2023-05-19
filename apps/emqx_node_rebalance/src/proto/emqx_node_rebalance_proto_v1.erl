%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_node_rebalance_proto_v1).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,

    available_nodes/1,
    evict_connections/2,
    evict_sessions/4,
    connection_counts/1,
    session_counts/1,
    enable_rebalance_agent/2,
    disable_rebalance_agent/2,
    disconnected_session_counts/1
]).

-include_lib("emqx/include/bpapi.hrl").
-include_lib("emqx/include/types.hrl").

introduced_in() ->
    "5.0.22".

-spec available_nodes([node()]) -> emqx_rpc:multicall_result(node()).
available_nodes(Nodes) ->
    rpc:multicall(Nodes, emqx_node_rebalance, is_node_available, []).

-spec evict_connections([node()], non_neg_integer()) ->
    emqx_rpc:multicall_result(ok_or_error(disabled)).
evict_connections(Nodes, Count) ->
    rpc:multicall(Nodes, emqx_eviction_agent, evict_connections, [Count]).

-spec evict_sessions([node()], non_neg_integer(), [node()], emqx_channel:conn_state()) ->
    emqx_rpc:multicall_result(ok_or_error(disabled)).
evict_sessions(Nodes, Count, RecipientNodes, ConnState) ->
    rpc:multicall(Nodes, emqx_eviction_agent, evict_sessions, [Count, RecipientNodes, ConnState]).

-spec connection_counts([node()]) -> emqx_rpc:multicall_result({ok, non_neg_integer()}).
connection_counts(Nodes) ->
    rpc:multicall(Nodes, emqx_node_rebalance, connection_count, []).

-spec session_counts([node()]) -> emqx_rpc:multicall_result({ok, non_neg_integer()}).
session_counts(Nodes) ->
    rpc:multicall(Nodes, emqx_node_rebalance, session_count, []).

-spec enable_rebalance_agent([node()], pid()) ->
    emqx_rpc:multicall_result(ok_or_error(already_enabled | eviction_agent_busy)).
enable_rebalance_agent(Nodes, OwnerPid) ->
    rpc:multicall(Nodes, emqx_node_rebalance_agent, enable, [OwnerPid]).

-spec disable_rebalance_agent([node()], pid()) ->
    emqx_rpc:multicall_result(ok_or_error(already_disabled | invalid_coordinator)).
disable_rebalance_agent(Nodes, OwnerPid) ->
    rpc:multicall(Nodes, emqx_node_rebalance_agent, disable, [OwnerPid]).

-spec disconnected_session_counts([node()]) -> emqx_rpc:multicall_result({ok, non_neg_integer()}).
disconnected_session_counts(Nodes) ->
    rpc:multicall(Nodes, emqx_node_rebalance, disconnected_session_count, []).
