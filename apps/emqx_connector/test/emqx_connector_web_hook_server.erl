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

-module(emqx_connector_web_hook_server).

-compile([nowarn_export_all, export_all]).

-behaviour(supervisor).
-behaviour(cowboy_handler).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

start_link(Port, Path) ->
    start_link(Port, Path, false).

start_link(Port, Path, SSLOpts) ->
    case Port of
        random ->
            PickedPort = pick_port_number(56000),
            {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE, [PickedPort, Path, SSLOpts]),
            {ok, {PickedPort, Pid}};
        _ ->
            supervisor:start_link({local, ?MODULE}, ?MODULE, [Port, Path, SSLOpts])
    end.

stop() ->
    try
        gen_server:stop(?MODULE)
    catch
        exit:noproc ->
            ok
    end.

set_handler(F) when is_function(F, 2) ->
    true = ets:insert(?MODULE, {handler, F}),
    ok.

%%------------------------------------------------------------------------------
%% supervisor API
%%------------------------------------------------------------------------------

init([Port, Path, SSLOpts]) ->
    Dispatch = cowboy_router:compile(
        [
            {'_', [{Path, ?MODULE, []}]}
        ]
    ),

    ProtoOpts = #{env => #{dispatch => Dispatch}},

    Tab = ets:new(?MODULE, [set, named_table, public]),
    ets:insert(Tab, {handler, fun default_handler/2}),

    {Transport, TransOpts, CowboyModule} = transport_settings(Port, SSLOpts),

    ChildSpec = ranch:child_spec(?MODULE, Transport, TransOpts, CowboyModule, ProtoOpts),

    {ok, {#{}, [ChildSpec]}}.

%%------------------------------------------------------------------------------
%% cowboy_server API
%%------------------------------------------------------------------------------

init(Req, State) ->
    [{handler, Handler}] = ets:lookup(?MODULE, handler),
    Handler(Req, State).

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

transport_settings(Port, _SSLOpts = false) ->
    TransOpts = #{
        socket_opts => [{port, Port}],
        connection_type => supervisor
    },
    {ranch_tcp, TransOpts, cowboy_clear};
transport_settings(Port, SSLOpts) ->
    TransOpts = #{
        socket_opts => [
            {port, Port},
            {next_protocols_advertised, [<<"h2">>, <<"http/1.1">>]},
            {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
            | SSLOpts
        ],
        connection_type => supervisor
    },
    {ranch_ssl, TransOpts, cowboy_tls}.

default_handler(Req0, State) ->
    Req = cowboy_req:reply(
        400,
        #{<<"content-type">> => <<"text/plain">>},
        <<"">>,
        Req0
    ),
    {ok, Req, State}.

pick_port_number(Port) ->
    case is_port_in_use(Port) of
        true ->
            pick_port_number(Port + 1);
        false ->
            Port
    end.

is_port_in_use(Port) ->
    case gen_tcp:listen(Port, [{reuseaddr, true}, {active, false}]) of
        {ok, ListenSocket} ->
            gen_tcp:close(ListenSocket),
            false;
        {error, eaddrinuse} ->
            true
    end.
