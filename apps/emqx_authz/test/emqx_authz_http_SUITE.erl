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

-module(emqx_authz_http_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include("emqx_authz.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(HTTP_PORT, 33333).
-define(HTTP_PATH, "/authz/[...]").

-define(AUTHZ_HTTP_RESP(Result, Req),
    cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        "{\"result\": \"" ++ atom_to_list(Result) ++ "\"}",
        Req
    )
).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    ok = stop_apps([emqx_resource, cowboy]),
    ok = emqx_common_test_helpers:start_apps(
        [emqx_conf, emqx_authz],
        fun set_special_configs/1
    ),
    ok = start_apps([emqx_resource, cowboy]),
    Config.

end_per_suite(_Config) ->
    ok = emqx_authz_test_lib:restore_authorizers(),
    ok = stop_apps([emqx_resource, cowboy]),
    ok = emqx_common_test_helpers:stop_apps([emqx_conf, emqx_authz]).

set_special_configs(emqx_authz) ->
    ok = emqx_authz_test_lib:reset_authorizers();
set_special_configs(_) ->
    ok.

init_per_testcase(_Case, Config) ->
    ok = emqx_authz_test_lib:reset_authorizers(),
    {ok, _} = emqx_authz_http_test_server:start_link(?HTTP_PORT, ?HTTP_PATH),
    Config.

end_per_testcase(_Case, _Config) ->
    try
        ok = emqx_authz_http_test_server:stop()
    catch
        exit:noproc ->
            ok
    end,
    snabbkaffe:stop(),
    ok.

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_response_handling(_Config) ->
    ClientInfo = #{
        clientid => <<"clientid">>,
        username => <<"username">>,
        peerhost => {127, 0, 0, 1},
        zone => default,
        listener => {tcp, default}
    },

    %% OK, get, body & headers
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            {ok, ?AUTHZ_HTTP_RESP(allow, Req0), State}
        end,
        #{}
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ),

    %% Not OK, get, no body
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            Req = cowboy_req:reply(200, Req0),
            {ok, Req, State}
        end,
        #{}
    ),

    deny = emqx_access_control:authorize(ClientInfo, publish, <<"t">>),

    %% OK, get, 204
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            Req = cowboy_req:reply(204, Req0),
            {ok, Req, State}
        end,
        #{}
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ),

    %% Not OK, get, 400
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            Req = cowboy_req:reply(400, Req0),
            {ok, Req, State}
        end,
        #{}
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ),

    %% Not OK, get, 400 + body & headers
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            Req = cowboy_req:reply(
                400,
                #{<<"content-type">> => <<"text/plain">>},
                "Response body",
                Req0
            ),
            {ok, Req, State}
        end,
        #{}
    ),

    ?assertEqual(
        deny,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ),

    %% the server cannot be reached; should skip to the next
    %% authorizer in the chain.
    ok = emqx_authz_http_test_server:stop(),

    ?check_trace(
        ?assertEqual(
            deny,
            emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
        ),
        fun(Trace) ->
            ?assertMatch(
                [
                    #{
                        ?snk_kind := authz_http_request_failure,
                        error := {recoverable_error, econnrefused}
                    }
                ],
                ?of_kind(authz_http_request_failure, Trace)
            ),
            ?assert(
                ?strict_causality(
                    #{?snk_kind := authz_http_request_failure},
                    #{?snk_kind := authz_non_superuser, result := nomatch},
                    Trace
                )
            ),
            ok
        end
    ),

    ok.

t_query_params(_Config) ->
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            #{
                username := <<"user name">>,
                clientid := <<"client id">>,
                peerhost := <<"127.0.0.1">>,
                proto_name := <<"MQTT">>,
                mountpoint := <<"MOUNTPOINT">>,
                topic := <<"t/1">>,
                action := <<"publish">>
            } = cowboy_req:match_qs(
                [
                    username,
                    clientid,
                    peerhost,
                    proto_name,
                    mountpoint,
                    topic,
                    action
                ],
                Req0
            ),
            {ok, ?AUTHZ_HTTP_RESP(allow, Req0), State}
        end,
        #{
            <<"url">> => <<
                "http://127.0.0.1:33333/authz/users/?"
                "username=${username}&"
                "clientid=${clientid}&"
                "peerhost=${peerhost}&"
                "proto_name=${proto_name}&"
                "mountpoint=${mountpoint}&"
                "topic=${topic}&"
                "action=${action}"
            >>
        }
    ),

    ClientInfo = #{
        clientid => <<"client id">>,
        username => <<"user name">>,
        peerhost => {127, 0, 0, 1},
        protocol => <<"MQTT">>,
        mountpoint => <<"MOUNTPOINT">>,
        zone => default,
        listener => {tcp, default}
    },

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t/1">>)
    ).

t_path(_Config) ->
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            ?assertEqual(
                <<
                    "/authz/use%20rs/"
                    "user%20name/"
                    "client%20id/"
                    "127.0.0.1/"
                    "MQTT/"
                    "MOUNTPOINT/"
                    "t%2F1/"
                    "publish"
                >>,
                cowboy_req:path(Req0)
            ),
            {ok, ?AUTHZ_HTTP_RESP(allow, Req0), State}
        end,
        #{
            <<"url">> => <<
                "http://127.0.0.1:33333/authz/use%20rs/"
                "${username}/"
                "${clientid}/"
                "${peerhost}/"
                "${proto_name}/"
                "${mountpoint}/"
                "${topic}/"
                "${action}"
            >>
        }
    ),

    ClientInfo = #{
        clientid => <<"client id">>,
        username => <<"user name">>,
        peerhost => {127, 0, 0, 1},
        protocol => <<"MQTT">>,
        mountpoint => <<"MOUNTPOINT">>,
        zone => default,
        listener => {tcp, default}
    },

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t/1">>)
    ).

t_json_body(_Config) ->
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            ?assertEqual(
                <<"/authz/users/">>,
                cowboy_req:path(Req0)
            ),

            {ok, RawBody, Req1} = cowboy_req:read_body(Req0),

            ?assertMatch(
                #{
                    <<"username">> := <<"user name">>,
                    <<"CLIENT">> := <<"client id">>,
                    <<"peerhost">> := <<"127.0.0.1">>,
                    <<"proto_name">> := <<"MQTT">>,
                    <<"mountpoint">> := <<"MOUNTPOINT">>,
                    <<"topic">> := <<"t">>,
                    <<"action">> := <<"publish">>
                },
                emqx_utils_json:decode(RawBody, [return_maps])
            ),
            {ok, ?AUTHZ_HTTP_RESP(allow, Req1), State}
        end,
        #{
            <<"method">> => <<"post">>,
            <<"body">> => #{
                <<"username">> => <<"${username}">>,
                <<"CLIENT">> => <<"${clientid}">>,
                <<"peerhost">> => <<"${peerhost}">>,
                <<"proto_name">> => <<"${proto_name}">>,
                <<"mountpoint">> => <<"${mountpoint}">>,
                <<"topic">> => <<"${topic}">>,
                <<"action">> => <<"${action}">>
            }
        }
    ),

    ClientInfo = #{
        clientid => <<"client id">>,
        username => <<"user name">>,
        peerhost => {127, 0, 0, 1},
        protocol => <<"MQTT">>,
        mountpoint => <<"MOUNTPOINT">>,
        zone => default,
        listener => {tcp, default}
    },

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ).

t_placeholder_and_body(_Config) ->
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            ?assertEqual(
                <<"/authz/users/">>,
                cowboy_req:path(Req0)
            ),

            {ok, [{PostVars, true}], Req1} = cowboy_req:read_urlencoded_body(Req0),

            ?assertMatch(
                #{
                    <<"username">> := <<"user name">>,
                    <<"clientid">> := <<"client id">>,
                    <<"peerhost">> := <<"127.0.0.1">>,
                    <<"proto_name">> := <<"MQTT">>,
                    <<"mountpoint">> := <<"MOUNTPOINT">>,
                    <<"topic">> := <<"t">>,
                    <<"action">> := <<"publish">>,
                    <<"CN">> := ?PH_CERT_CN_NAME,
                    <<"CS">> := ?PH_CERT_SUBJECT
                },
                emqx_utils_json:decode(PostVars, [return_maps])
            ),
            {ok, ?AUTHZ_HTTP_RESP(allow, Req1), State}
        end,
        #{
            <<"method">> => <<"post">>,
            <<"body">> => #{
                <<"username">> => <<"${username}">>,
                <<"clientid">> => <<"${clientid}">>,
                <<"peerhost">> => <<"${peerhost}">>,
                <<"proto_name">> => <<"${proto_name}">>,
                <<"mountpoint">> => <<"${mountpoint}">>,
                <<"topic">> => <<"${topic}">>,
                <<"action">> => <<"${action}">>,
                <<"CN">> => ?PH_CERT_CN_NAME,
                <<"CS">> => ?PH_CERT_SUBJECT
            },
            <<"headers">> => #{<<"content-type">> => <<"application/x-www-form-urlencoded">>}
        }
    ),

    ClientInfo = #{
        clientid => <<"client id">>,
        username => <<"user name">>,
        peerhost => {127, 0, 0, 1},
        protocol => <<"MQTT">>,
        mountpoint => <<"MOUNTPOINT">>,
        zone => default,
        listener => {tcp, default},
        cn => ?PH_CERT_CN_NAME,
        dn => ?PH_CERT_SUBJECT
    },

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ).

t_no_value_for_placeholder(_Config) ->
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            ?assertEqual(
                <<"/authz/users/">>,
                cowboy_req:path(Req0)
            ),

            {ok, RawBody, Req1} = cowboy_req:read_body(Req0),

            ?assertMatch(
                #{
                    <<"mountpoint">> := <<"[]">>
                },
                emqx_utils_json:decode(RawBody, [return_maps])
            ),
            {ok, ?AUTHZ_HTTP_RESP(allow, Req1), State}
        end,
        #{
            <<"method">> => <<"post">>,
            <<"body">> => #{
                <<"mountpoint">> => <<"[${mountpoint}]">>
            }
        }
    ),

    ClientInfo = #{
        clientid => <<"client id">>,
        username => <<"user name">>,
        peerhost => {127, 0, 0, 1},
        protocol => <<"MQTT">>,
        zone => default,
        listener => {tcp, default}
    },

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ).

t_create_replace(_Config) ->
    ClientInfo = #{
        clientid => <<"clientid">>,
        username => <<"username">>,
        peerhost => {127, 0, 0, 1},
        zone => default,
        listener => {tcp, default}
    },

    %% Create with valid URL
    ok = setup_handler_and_config(
        fun(Req0, State) ->
            {ok, ?AUTHZ_HTTP_RESP(allow, Req0), State}
        end,
        #{
            <<"url">> =>
                <<"http://127.0.0.1:33333/authz/users/?topic=${topic}&action=${action}">>
        }
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ),

    %% Changing to valid config
    OkConfig = maps:merge(
        raw_http_authz_config(),
        #{
            <<"url">> =>
                <<"http://127.0.0.1:33333/authz/users/?topic=${topic}&action=${action}">>
        }
    ),

    ?assertMatch(
        {ok, _},
        emqx_authz:update({?CMD_REPLACE, http}, OkConfig)
    ),

    ?assertEqual(
        allow,
        emqx_access_control:authorize(ClientInfo, publish, <<"t">>)
    ).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

raw_http_authz_config() ->
    #{
        <<"enable">> => <<"true">>,
        <<"type">> => <<"http">>,
        <<"method">> => <<"get">>,
        <<"url">> => <<"http://127.0.0.1:33333/authz/users/?topic=${topic}&action=${action}">>,
        <<"headers">> => #{<<"X-Test-Header">> => <<"Test Value">>}
    }.

setup_handler_and_config(Handler, Config) ->
    ok = emqx_authz_http_test_server:set_handler(Handler),
    ok = emqx_authz_test_lib:setup_config(
        raw_http_authz_config(),
        Config
    ).

start_apps(Apps) ->
    lists:foreach(fun application:ensure_all_started/1, Apps).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
