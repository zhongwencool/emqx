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

-module(emqx_gateway_cli_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-define(GP(S), begin
    S,
    receive
        {fmt, P} -> P;
        O -> O
    end
end).

%% this parses to #{}, will not cause config cleanup
%% so we will need call emqx_config:erase
-define(CONF_DEFAULT, <<
    "\n"
    "gateway {}\n"
>>).

%% The config with json format for mqtt-sn gateway
-define(CONF_MQTTSN,
    "\n"
    "{\"idle_timeout\": \"30s\",\n"
    " \"enable_stats\": true,\n"
    " \"mountpoint\": \"mqttsn/\",\n"
    " \"gateway_id\": 1,\n"
    " \"broadcast\": true,\n"
    " \"enable_qos3\": true,\n"
    " \"predefined\": [{\"id\": 1001, \"topic\": \"pred/a\"}],\n"
    " \"listeners\":\n"
    "    [{\"type\": \"udp\",\n"
    "      \"name\": \"ct\",\n"
    "      \"bind\": \"1884\"\n"
    "    }]\n"
    "}\n"
).

%%--------------------------------------------------------------------
%% Setup
%%--------------------------------------------------------------------

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Conf) ->
    emqx_config:erase(gateway),
    emqx_gateway_test_utils:load_all_gateway_apps(),
    emqx_common_test_helpers:load_config(emqx_gateway_schema, ?CONF_DEFAULT),
    emqx_mgmt_api_test_util:init_suite([emqx_conf, emqx_authn, emqx_gateway]),
    Conf.

end_per_suite(Conf) ->
    emqx_mgmt_api_test_util:end_suite([emqx_gateway, emqx_authn, emqx_conf]),
    Conf.

init_per_testcase(_, Conf) ->
    Self = self(),
    ok = meck:new(emqx_ctl, [passthrough, no_history, no_link]),
    ok = meck:expect(
        emqx_ctl,
        usage,
        fun(L) -> emqx_ctl:format_usage(L) end
    ),
    ok = meck:expect(
        emqx_ctl,
        print,
        fun(Fmt) ->
            Self ! {fmt, emqx_ctl:format(Fmt, [])}
        end
    ),
    ok = meck:expect(
        emqx_ctl,
        print,
        fun(Fmt, Args) ->
            Self ! {fmt, emqx_ctl:format(Fmt, Args)}
        end
    ),
    Conf.

end_per_testcase(_, _) ->
    meck:unload([emqx_ctl]),
    ok.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------

%% TODO:

t_load_unload(_) ->
    ok.

t_gateway_registry_usage(_) ->
    ?assertEqual(
        ["gateway-registry list # List all registered gateways\n"],
        emqx_gateway_cli:'gateway-registry'(usage)
    ).

t_gateway_registry_list(_) ->
    emqx_gateway_cli:'gateway-registry'(["list"]),
    ?assertEqual(
        "Registered Name: coap, Callback Module: emqx_gateway_coap\n"
        "Registered Name: exproto, Callback Module: emqx_gateway_exproto\n"
        "Registered Name: lwm2m, Callback Module: emqx_gateway_lwm2m\n"
        "Registered Name: mqttsn, Callback Module: emqx_gateway_mqttsn\n"
        "Registered Name: stomp, Callback Module: emqx_gateway_stomp\n",
        acc_print()
    ).

t_gateway_usage(_) ->
    ?assertEqual(
        [
            "gateway list                     # List all gateway\n",
            "gateway lookup <Name>            # Lookup a gateway detailed information\n",
            "gateway load   <Name> <JsonConf> # Load a gateway with config\n",
            "gateway unload <Name>            # Unload the gateway\n",
            "gateway stop   <Name>            # Stop the gateway\n",
            "gateway start  <Name>            # Start the gateway\n"
        ],
        emqx_gateway_cli:gateway(usage)
    ).

t_gateway_list(_) ->
    emqx_gateway_cli:gateway(["list"]),
    ?assertEqual(
        "Gateway(name=coap, status=unloaded)\n"
        "Gateway(name=exproto, status=unloaded)\n"
        "Gateway(name=lwm2m, status=unloaded)\n"
        "Gateway(name=mqttsn, status=unloaded)\n"
        "Gateway(name=stomp, status=unloaded)\n",
        acc_print()
    ),

    emqx_gateway_cli:gateway(["load", "mqttsn", ?CONF_MQTTSN]),
    ?assertEqual("ok\n", acc_print()),

    emqx_gateway_cli:gateway(["list"]),
    %% TODO: assert it.
    _ = acc_print(),

    emqx_gateway_cli:gateway(["unload", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()).

t_gateway_load_unload_lookup(_) ->
    emqx_gateway_cli:gateway(["lookup", "mqttsn"]),
    ?assertEqual("undefined\n", acc_print()),

    emqx_gateway_cli:gateway(["load", "mqttsn", ?CONF_MQTTSN]),
    ?assertEqual("ok\n", acc_print()),

    %% TODO: bad config name, format???

    emqx_gateway_cli:gateway(["lookup", "mqttsn"]),
    %% TODO: assert it. for example:
    %% name: mqttsn
    %% status: running
    %% created_at: 2022-01-05T14:40:20.039+08:00
    %% started_at: 2022-01-05T14:42:37.894+08:00
    %% config: #{broadcast => false,enable => true,enable_qos3 => true,
    %%           enable_stats => true,gateway_id => 1,idle_timeout => 30000,
    %%           mountpoint => <<>>,predefined => []}
    _ = acc_print(),

    emqx_gateway_cli:gateway(["load", "mqttsn", "{}"]),
    ?assertEqual(
        "Error: The mqttsn gateway already loaded\n",
        acc_print()
    ),

    emqx_gateway_cli:gateway(["load", "bad-gw-name", "{}"]),
    %% TODO: assert it. for example:
    %% Error: Illegal gateway name
    _ = acc_print(),

    emqx_gateway_cli:gateway(["unload", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()),
    %% Always return ok, even the gateway has unloaded
    emqx_gateway_cli:gateway(["unload", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()),

    emqx_gateway_cli:gateway(["lookup", "mqttsn"]),
    ?assertEqual("undefined\n", acc_print()).

t_gateway_start_stop(_) ->
    emqx_gateway_cli:gateway(["load", "mqttsn", ?CONF_MQTTSN]),
    ?assertEqual("ok\n", acc_print()),

    emqx_gateway_cli:gateway(["stop", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()),
    %% duplicated stop gateway, return ok
    emqx_gateway_cli:gateway(["stop", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()),

    emqx_gateway_cli:gateway(["start", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()),
    %% duplicated start gateway, return ok
    emqx_gateway_cli:gateway(["start", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()),

    emqx_gateway_cli:gateway(["unload", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()).

t_gateway_clients_usage(_) ->
    ?assertEqual(
        [
            "gateway-clients list   <Name>            "
            "# List all clients for a gateway\n",
            "gateway-clients lookup <Name> <ClientId> "
            "# Lookup the Client Info for specified client\n",
            "gateway-clients kick   <Name> <ClientId> "
            "# Kick out a client\n"
        ],
        emqx_gateway_cli:'gateway-clients'(usage)
    ).

t_gateway_clients(_) ->
    emqx_gateway_cli:gateway(["load", "mqttsn", ?CONF_MQTTSN]),
    ?assertEqual("ok\n", acc_print()),

    Socket = sn_client_connect(<<"client1">>),

    _ = emqx_gateway_cli:'gateway-clients'(["list", "mqttsn"]),
    ClientDesc1 = acc_print(),

    _ = emqx_gateway_cli:'gateway-clients'(["lookup", "mqttsn", "client1"]),
    ClientDesc2 = acc_print(),
    ?assertEqual(ClientDesc1, ClientDesc2),

    sn_client_disconnect(Socket),
    timer:sleep(500),

    _ = emqx_gateway_cli:'gateway-clients'(["lookup", "mqttsn", "bad-client"]),
    ?assertEqual("Not Found.\n", acc_print()),

    _ = emqx_gateway_cli:'gateway-clients'(["lookup", "bad-gw", "bad-client"]),
    ?assertEqual("Bad Gateway Name.\n", acc_print()),

    _ = emqx_gateway_cli:'gateway-clients'(["list", "mqttsn"]),
    %% no print for empty client list

    _ = emqx_gateway_cli:'gateway-clients'(["list", "bad-gw"]),
    ?assertEqual("Bad Gateway Name.\n", acc_print()),

    emqx_gateway_cli:gateway(["unload", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()).

t_gateway_clients_kick(_) ->
    emqx_gateway_cli:gateway(["load", "mqttsn", ?CONF_MQTTSN]),
    ?assertEqual("ok\n", acc_print()),

    Socket = sn_client_connect(<<"client1">>),

    _ = emqx_gateway_cli:'gateway-clients'(["list", "mqttsn"]),
    _ = acc_print(),

    _ = emqx_gateway_cli:'gateway-clients'(["kick", "mqttsn", "bad-client"]),
    ?assertEqual("Not Found.\n", acc_print()),

    _ = emqx_gateway_cli:'gateway-clients'(["kick", "mqttsn", "client1"]),
    ?assertEqual("ok\n", acc_print()),

    sn_client_disconnect(Socket),

    emqx_gateway_cli:gateway(["unload", "mqttsn"]),
    ?assertEqual("ok\n", acc_print()).

t_gateway_metrcis_usage(_) ->
    ?assertEqual(
        [
            "gateway-metrics <Name> "
            "# List all metrics for a gateway\n"
        ],
        emqx_gateway_cli:'gateway-metrics'(usage)
    ).

t_gateway_metrcis(_) ->
    ok.

acc_print() ->
    lists:concat(lists:reverse(acc_print([]))).

acc_print(Acc) ->
    receive
        {fmt, S} -> acc_print([S | Acc])
    after 200 ->
        Acc
    end.

sn_client_connect(ClientId) ->
    {ok, Socket} = gen_udp:open(0, [binary]),
    _ = emqx_sn_protocol_SUITE:send_connect_msg(Socket, ClientId),
    ?assertEqual(
        <<3, 16#05, 0>>,
        emqx_sn_protocol_SUITE:receive_response(Socket)
    ),
    Socket.

sn_client_disconnect(Socket) ->
    _ = emqx_sn_protocol_SUITE:send_disconnect_msg(Socket, undefined),
    gen_udp:close(Socket),
    ok.
