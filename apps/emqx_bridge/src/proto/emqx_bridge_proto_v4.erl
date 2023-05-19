%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_bridge_proto_v4).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,

    list_bridges_on_nodes/1,
    restart_bridge_to_node/3,
    start_bridge_to_node/3,
    stop_bridge_to_node/3,
    lookup_from_all_nodes/3,
    get_metrics_from_all_nodes/3,
    restart_bridges_to_all_nodes/3,
    start_bridges_to_all_nodes/3,
    stop_bridges_to_all_nodes/3
]).

-include_lib("emqx/include/bpapi.hrl").

-define(TIMEOUT, 15000).

introduced_in() ->
    "5.0.22".

-spec list_bridges_on_nodes([node()]) ->
    emqx_rpc:erpc_multicall([emqx_resource:resource_data()]).
list_bridges_on_nodes(Nodes) ->
    erpc:multicall(Nodes, emqx_bridge, list, [], ?TIMEOUT).

-type key() :: atom() | binary() | [byte()].

-spec restart_bridge_to_node(node(), key(), key()) ->
    term().
restart_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        restart,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec start_bridge_to_node(node(), key(), key()) ->
    term().
start_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        start,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec stop_bridge_to_node(node(), key(), key()) ->
    term().
stop_bridge_to_node(Node, BridgeType, BridgeName) ->
    rpc:call(
        Node,
        emqx_bridge_resource,
        stop,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec restart_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall().
restart_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        restart,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec start_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall().
start_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        start,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec stop_bridges_to_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall().
stop_bridges_to_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_resource,
        stop,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec lookup_from_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall().
lookup_from_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_api,
        lookup_from_local_node,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).

-spec get_metrics_from_all_nodes([node()], key(), key()) ->
    emqx_rpc:erpc_multicall(emqx_metrics_worker:metrics()).
get_metrics_from_all_nodes(Nodes, BridgeType, BridgeName) ->
    erpc:multicall(
        Nodes,
        emqx_bridge_api,
        get_metrics_from_local_node,
        [BridgeType, BridgeName],
        ?TIMEOUT
    ).
