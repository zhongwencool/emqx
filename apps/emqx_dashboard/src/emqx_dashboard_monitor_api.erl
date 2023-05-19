%%--------------------------------------------------------------------
%% Copyright (c) 2019-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_dashboard_monitor_api).

-include("emqx_dashboard.hrl").
-include_lib("typerefl/include/types.hrl").

-behaviour(minirest_api).

-export([api_spec/0]).

-export([
    paths/0,
    schema/1,
    fields/1
]).

-export([
    monitor/2,
    monitor_current/2
]).

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true, translate_body => true}).

paths() ->
    [
        "/monitor",
        "/monitor/nodes/:node",
        "/monitor_current",
        "/monitor_current/nodes/:node"
    ].

schema("/monitor") ->
    #{
        'operationId' => monitor,
        get => #{
            tags => [<<"Metrics">>],
            desc => <<"List monitor data.">>,
            parameters => [parameter_latest()],
            responses => #{
                200 => hoconsc:mk(hoconsc:array(hoconsc:ref(sampler)), #{}),
                400 => emqx_dashboard_swagger:error_codes(['BAD_RPC'], <<"Bad RPC">>)
            }
        }
    };
schema("/monitor/nodes/:node") ->
    #{
        'operationId' => monitor,
        get => #{
            tags => [<<"Metrics">>],
            desc => <<"List the monitor data on the node.">>,
            parameters => [parameter_node(), parameter_latest()],
            responses => #{
                200 => hoconsc:mk(hoconsc:array(hoconsc:ref(sampler)), #{}),
                404 => emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<"Node not found">>)
            }
        }
    };
schema("/monitor_current") ->
    #{
        'operationId' => monitor_current,
        get => #{
            tags => [<<"Metrics">>],
            desc => <<"Current status. Gauge and rate.">>,
            responses => #{
                200 => hoconsc:mk(hoconsc:ref(sampler_current), #{})
            }
        }
    };
schema("/monitor_current/nodes/:node") ->
    #{
        'operationId' => monitor_current,
        get => #{
            tags => [<<"Metrics">>],
            desc => <<"Node current status. Gauge and rate.">>,
            parameters => [parameter_node()],
            responses => #{
                200 => hoconsc:mk(hoconsc:ref(sampler_current), #{}),
                404 => emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<"Node not found">>)
            }
        }
    }.

parameter_latest() ->
    Info = #{
        in => query,
        required => false,
        example => 5 * 60,
        desc => <<"The latest N seconds data. Like 300 for 5 min.">>
    },
    {latest, hoconsc:mk(range(1, inf), Info)}.

parameter_node() ->
    Info = #{
        in => path,
        required => true,
        example => node(),
        desc => <<"EMQX node name.">>
    },
    {node, hoconsc:mk(binary(), Info)}.

fields(sampler) ->
    Samplers =
        [
            {SamplerName, hoconsc:mk(integer(), #{desc => swagger_desc(SamplerName)})}
         || SamplerName <- ?SAMPLER_LIST
        ],
    [{time_stamp, hoconsc:mk(non_neg_integer(), #{desc => <<"Timestamp">>})} | Samplers];
fields(sampler_current) ->
    Names = maps:values(?DELTA_SAMPLER_RATE_MAP) ++ ?GAUGE_SAMPLER_LIST,
    [
        {SamplerName, hoconsc:mk(integer(), #{desc => swagger_desc(SamplerName)})}
     || SamplerName <- Names
    ].

%% -------------------------------------------------------------------------------------------------
%% API

monitor(get, #{query_string := QS, bindings := Bindings}) ->
    Latest = maps:get(<<"latest">>, QS, infinity),
    RawNode = maps:get(node, Bindings, <<"all">>),
    emqx_utils_api:with_node_or_cluster(RawNode, dashboard_samplers_fun(Latest)).

dashboard_samplers_fun(Latest) ->
    fun(NodeOrCluster) ->
        case emqx_dashboard_monitor:samplers(NodeOrCluster, Latest) of
            {badrpc, _} = Error -> {error, Error};
            Samplers -> {ok, Samplers}
        end
    end.

monitor_current(get, #{bindings := []}) ->
    emqx_utils_api:with_node_or_cluster(erlang:node(), fun emqx_dashboard_monitor:current_rate/1);
monitor_current(get, #{bindings := Bindings}) ->
    RawNode = maps:get(node, Bindings, <<"all">>),
    emqx_utils_api:with_node_or_cluster(RawNode, fun current_rate/1).

current_rate(Node) ->
    case emqx_dashboard_monitor:current_rate(Node) of
        {badrpc, _} = BadRpc ->
            {error, BadRpc};
        {ok, _} = OkResult ->
            OkResult
    end.

%% -------------------------------------------------------------------------------------------------
%% Internal

swagger_desc(received) ->
    swagger_desc_format("Received messages ");
swagger_desc(received_bytes) ->
    swagger_desc_format("Received bytes ");
swagger_desc(sent) ->
    swagger_desc_format("Sent messages ");
swagger_desc(sent_bytes) ->
    swagger_desc_format("Sent bytes ");
swagger_desc(dropped) ->
    swagger_desc_format("Dropped messages ");
swagger_desc(subscriptions) ->
    <<
        "Subscriptions at the time of sampling."
        " Can only represent the approximate state"
    >>;
swagger_desc(topics) ->
    <<
        "Count topics at the time of sampling."
        " Can only represent the approximate state"
    >>;
swagger_desc(connections) ->
    <<
        "Connections at the time of sampling."
        " Can only represent the approximate state"
    >>;
swagger_desc(received_msg_rate) ->
    swagger_desc_format("Dropped messages ", per);
%swagger_desc(received_bytes_rate) -> swagger_desc_format("Received bytes ", per);
swagger_desc(sent_msg_rate) ->
    swagger_desc_format("Sent messages ", per);
%swagger_desc(sent_bytes_rate)     -> swagger_desc_format("Sent bytes ", per);
swagger_desc(dropped_msg_rate) ->
    swagger_desc_format("Dropped messages ", per).

swagger_desc_format(Format) ->
    swagger_desc_format(Format, last).

swagger_desc_format(Format, Type) ->
    Interval = emqx_conf:get([dashboard, monitor, interval], ?DEFAULT_SAMPLE_INTERVAL),
    list_to_binary(io_lib:format(Format ++ "~p ~p seconds", [Type, Interval])).
