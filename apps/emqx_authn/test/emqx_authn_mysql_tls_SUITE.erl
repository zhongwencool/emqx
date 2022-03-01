%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authn_mysql_tls_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include("emqx_connector.hrl").
-include("emqx_authn.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(MYSQL_HOST, "mysql-tls").

-define(PATH, [authentication]).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_testcase(_, Config) ->
    {ok, _} = emqx_cluster_rpc:start_link(node(), emqx_cluster_rpc, 1000),
    emqx_authentication:initialize_authentication(?GLOBAL, []),
    emqx_authn_test_lib:delete_authenticators(
      [authentication],
      ?GLOBAL),
    Config.

init_per_suite(Config) ->
    _ = application:load(emqx_conf),
    case emqx_common_test_helpers:is_tcp_server_available(?MYSQL_HOST, ?MYSQL_DEFAULT_PORT) of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_authn]),
            ok = start_apps([emqx_resource, emqx_connector]),
            Config;
        false ->
            {skip, no_mysql_tls}
    end.

end_per_suite(_Config) ->
    emqx_authn_test_lib:delete_authenticators(
      [authentication],
      ?GLOBAL),
    ok = stop_apps([emqx_resource, emqx_connector]),
    ok = emqx_common_test_helpers:stop_apps([emqx_authn]).

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_create(_Config) ->
    %% openssl s_client -tls1_2 -cipher ECDHE-RSA-AES256-GCM-SHA384 \
    %%   -connect authn-server:3306 -starttls mysql \
    %%   -cert client.crt -key client.key -CAfile ca.crt
    ?assertMatch(
       {ok, _},
       create_mysql_auth_with_ssl_opts(
         #{<<"server_name_indication">> => <<"authn-server">>,
           <<"verify">> => <<"verify_peer">>,
           <<"versions">> => [<<"tlsv1.2">>],
           <<"ciphers">> => [<<"ECDHE-RSA-AES256-GCM-SHA384">>]})).

t_create_invalid(_Config) ->

    %% invalid server_name
    ?assertMatch(
       {ok, _},
       create_mysql_auth_with_ssl_opts(
         #{<<"server_name_indication">> => <<"authn-server-unknown-host">>,
           <<"verify">> => <<"verify_peer">>})),

    %% incompatible versions
    ?assertMatch(
       {ok, _},
       create_mysql_auth_with_ssl_opts(
         #{<<"server_name_indication">> => <<"authn-server">>,
           <<"verify">> => <<"verify_peer">>,
           <<"versions">> => [<<"tlsv1.1">>]})),

    %% incompatible ciphers
    ?assertMatch(
       {ok, _},
       create_mysql_auth_with_ssl_opts(
         #{<<"server_name_indication">> => <<"authn-server">>,
           <<"verify">> => <<"verify_peer">>,
           <<"versions">> => [<<"tlsv1.2">>],
           <<"ciphers">> => [<<"ECDHE-ECDSA-AES128-GCM-SHA256">>]})).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

create_mysql_auth_with_ssl_opts(SpecificSSLOpts) ->
    AuthConfig = raw_mysql_auth_config(SpecificSSLOpts),
    emqx:update_config(?PATH, {create_authenticator, ?GLOBAL, AuthConfig}).

raw_mysql_auth_config(SpecificSSLOpts) ->
    SSLOpts = maps:merge(
                emqx_authn_test_lib:client_ssl_cert_opts(),
                #{enable => <<"true">>}),
    #{
      mechanism => <<"password-based">>,
      password_hash_algorithm => #{name => <<"plain">>,
                                   salt_position => <<"suffix">>},
      enable => <<"true">>,

      backend => <<"mysql">>,
      database => <<"mqtt">>,
      username => <<"root">>,
      password => <<"public">>,

      query => <<"SELECT password_hash, salt, is_superuser_str as is_superuser
                      FROM users where username = ${username} LIMIT 1">>,
      server => mysql_server(),
      ssl => maps:merge(SSLOpts, SpecificSSLOpts)
     }.

mysql_server() ->
    iolist_to_binary(io_lib:format("~s",[?MYSQL_HOST])).

start_apps(Apps) ->
    lists:foreach(fun application:ensure_all_started/1, Apps).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
