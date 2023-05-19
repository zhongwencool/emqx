%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_node_rebalance_evacuation_proto_v1).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,

    available_nodes/1
]).

-include_lib("emqx/include/bpapi.hrl").

introduced_in() ->
    "5.0.22".

-spec available_nodes([node()]) -> emqx_rpc:multicall_result(node()).
available_nodes(Nodes) ->
    rpc:multicall(Nodes, emqx_node_rebalance_evacuation, is_node_available, []).
