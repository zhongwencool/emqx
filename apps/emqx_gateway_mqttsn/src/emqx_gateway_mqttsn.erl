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

%% @doc The MQTT-SN Gateway implement interface
-module(emqx_gateway_mqttsn).

-include_lib("emqx/include/logger.hrl").

%% define a gateway named stomp
-gateway(#{
    name => mqttsn,
    callback_module => ?MODULE,
    config_schema_module => emqx_mqttsn_schema
}).

%% callback_module must implement the emqx_gateway_impl behaviour
-behaviour(emqx_gateway_impl).

%% callback for emqx_gateway_impl
-export([
    on_gateway_load/2,
    on_gateway_update/3,
    on_gateway_unload/2
]).

-import(
    emqx_gateway_utils,
    [
        normalize_config/1,
        start_listeners/4,
        stop_listeners/2
    ]
).

%%--------------------------------------------------------------------
%% emqx_gateway_impl callbacks
%%--------------------------------------------------------------------

on_gateway_load(
    _Gateway = #{
        name := GwName,
        config := Config
    },
    Ctx
) ->
    %% We Also need to start `emqx_mqttsn_broadcast` &
    %% `emqx_mqttsn_registry` process
    case maps:get(broadcast, Config, false) of
        false ->
            ok;
        true ->
            %% FIXME:
            Port = 1884,
            SnGwId = maps:get(gateway_id, Config, undefined),
            _ = emqx_mqttsn_broadcast:start_link(SnGwId, Port),
            ok
    end,

    PredefTopics = maps:get(predefined, Config, []),
    {ok, RegistrySvr} = emqx_mqttsn_registry:start_link(GwName, PredefTopics),

    NConfig = maps:without(
        [broadcast, predefined],
        Config#{registry => emqx_mqttsn_registry:lookup_name(RegistrySvr)}
    ),

    Listeners = emqx_gateway_utils:normalize_config(NConfig),

    ModCfg = #{
        frame_mod => emqx_mqttsn_frame,
        chann_mod => emqx_mqttsn_channel
    },

    case
        start_listeners(
            Listeners, GwName, Ctx, ModCfg
        )
    of
        {ok, ListenerPids} ->
            {ok, ListenerPids, _GwState = #{ctx => Ctx}};
        {error, {Reason, Listener}} ->
            throw(
                {badconf, #{
                    key => listeners,
                    value => Listener,
                    reason => Reason
                }}
            )
    end.

on_gateway_update(Config, Gateway, GwState = #{ctx := Ctx}) ->
    GwName = maps:get(name, Gateway),
    try
        %% XXX: 1. How hot-upgrade the changes ???
        %% XXX: 2. Check the New confs first before destroy old instance ???
        on_gateway_unload(Gateway, GwState),
        on_gateway_load(Gateway#{config => Config}, Ctx)
    catch
        Class:Reason:Stk ->
            logger:error(
                "Failed to update ~ts; "
                "reason: {~0p, ~0p} stacktrace: ~0p",
                [GwName, Class, Reason, Stk]
            ),
            {error, Reason}
    end.

on_gateway_unload(
    _Gateway = #{
        name := GwName,
        config := Config
    },
    _GwState
) ->
    Listeners = normalize_config(Config),
    stop_listeners(GwName, Listeners).
