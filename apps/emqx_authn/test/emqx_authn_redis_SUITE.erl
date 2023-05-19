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

-module(emqx_authn_redis_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("emqx_connector/include/emqx_connector.hrl").
-include_lib("emqx_authn/include/emqx_authn.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(REDIS_HOST, "redis").
-define(REDIS_RESOURCE, <<"emqx_authn_redis_SUITE">>).

-define(PATH, [authentication]).
-define(ResourceID, <<"password_based:redis">>).

all() ->
    [
        {group, require_seeds},
        t_create,
        t_create_with_config_values_wont_work,
        t_create_invalid_config
    ].

groups() ->
    [{require_seeds, [], [t_authenticate, t_update, t_destroy]}].

init_per_testcase(_, Config) ->
    {ok, _} = emqx_cluster_rpc:start_link(node(), emqx_cluster_rpc, 1000),
    emqx_authentication:initialize_authentication(?GLOBAL, []),
    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),
    Config.

init_per_group(require_seeds, Config) ->
    ok = init_seeds(),
    Config.

end_per_group(require_seeds, Config) ->
    ok = drop_seeds(),
    Config.

init_per_suite(Config) ->
    _ = application:load(emqx_conf),
    case emqx_common_test_helpers:is_tcp_server_available(?REDIS_HOST, ?REDIS_DEFAULT_PORT) of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_authn]),
            ok = start_apps([emqx_resource]),
            {ok, _} = emqx_resource:create_local(
                ?REDIS_RESOURCE,
                ?RESOURCE_GROUP,
                emqx_connector_redis,
                redis_config(),
                #{}
            ),
            Config;
        false ->
            {skip, no_redis}
    end.

end_per_suite(_Config) ->
    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),
    ok = emqx_resource:remove_local(?REDIS_RESOURCE),
    ok = stop_apps([emqx_resource]),
    ok = emqx_common_test_helpers:stop_apps([emqx_authn]).

%%------------------------------------------------------------------------------
%% Tests
%%------------------------------------------------------------------------------

t_create(_Config) ->
    ?assertEqual(
        {error, {not_found, {chain, ?GLOBAL}}},
        emqx_authentication:list_authenticators(?GLOBAL)
    ),
    AuthConfig = raw_redis_auth_config(),
    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, AuthConfig}
    ),

    {ok, [#{provider := emqx_authn_redis}]} = emqx_authentication:list_authenticators(?GLOBAL).

t_create_with_config_values_wont_work(_Config) ->
    AuthConfig = raw_redis_auth_config(),
    InvalidConfigs =
        [
            AuthConfig#{
                <<"cmd">> => <<"MGET password_hash:${username} salt:${username}">>
            },
            AuthConfig#{
                <<"cmd">> => <<"HMGET mqtt_user:${username} password_hash invalid_field">>
            },
            AuthConfig#{
                <<"cmd">> => <<"HMGET mqtt_user:${username} salt is_superuser">>
            },
            AuthConfig#{
                <<"cmd">> => <<"HGETALL mqtt_user:${username} salt is_superuser">>
            }
        ],
    lists:foreach(
        fun(Config) ->
            {error, _} = emqx:update_config(
                ?PATH,
                {create_authenticator, ?GLOBAL, Config}
            ),

            ?assertEqual(
                {error, {not_found, {chain, ?GLOBAL}}},
                emqx_authentication:list_authenticators(?GLOBAL)
            )
        end,
        InvalidConfigs
    ),

    InvalidConfigs1 =
        [
            AuthConfig#{<<"server">> => <<"unknownhost:3333">>},
            AuthConfig#{<<"password">> => <<"wrongpass">>},
            AuthConfig#{<<"database">> => <<"5678">>}
        ],

    lists:foreach(
        fun(Config) ->
            {ok, _} = emqx:update_config(
                ?PATH,
                {create_authenticator, ?GLOBAL, Config}
            ),
            emqx_authn_test_lib:delete_config(?ResourceID),
            ?assertEqual(
                {error, {not_found, {chain, ?GLOBAL}}},
                emqx_authentication:list_authenticators(?GLOBAL)
            )
        end,
        InvalidConfigs1
    ).

t_create_invalid_config(_Config) ->
    Config0 = raw_redis_auth_config(),
    Config = maps:without([<<"server">>], Config0),
    ?assertMatch(
        {error, #{
            kind := validation_error,
            matched_type := "authn:redis_single",
            path := "authentication.1.server",
            reason := required_field
        }},
        emqx:update_config(?PATH, {create_authenticator, ?GLOBAL, Config})
    ),
    ?assertMatch([], emqx_config:get_raw([authentication])),
    ?assertEqual(
        {error, {not_found, {chain, ?GLOBAL}}},
        emqx_authentication:list_authenticators(?GLOBAL)
    ).

t_authenticate(_Config) ->
    ok = lists:foreach(
        fun(Sample) ->
            ct:pal("test_user_auth sample: ~p", [Sample]),
            test_user_auth(Sample)
        end,
        user_seeds()
    ).

test_user_auth(
    #{
        credentials := Credentials0,
        config_params := SpecificConfigParams,
        result := Result
    } = Config
) ->
    AuthConfig = maps:merge(raw_redis_auth_config(), SpecificConfigParams),

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, AuthConfig}
    ),

    {ok, [#{provider := emqx_authn_redis, state := State}]} =
        emqx_authentication:list_authenticators(?GLOBAL),

    Credentials = Credentials0#{
        listener => 'tcp:default',
        protocol => mqtt
    },

    ?assertEqual(Result, emqx_access_control:authenticate(Credentials)),

    case maps:get(redis_result, Config, undefined) of
        undefined ->
            ok;
        RedisResult ->
            ?assertEqual(RedisResult, emqx_authn_redis:authenticate(Credentials, State))
    end,

    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ).

t_destroy(_Config) ->
    AuthConfig = raw_redis_auth_config(),

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, AuthConfig}
    ),

    {ok, [#{provider := emqx_authn_redis, state := State}]} =
        emqx_authentication:list_authenticators(?GLOBAL),

    {ok, _} = emqx_authn_redis:authenticate(
        #{
            username => <<"plain">>,
            password => <<"plain">>
        },
        State
    ),

    emqx_authn_test_lib:delete_authenticators(
        [authentication],
        ?GLOBAL
    ),

    % Authenticator should not be usable anymore
    ?assertMatch(
        ignore,
        emqx_authn_redis:authenticate(
            #{
                username => <<"plain">>,
                password => <<"plain">>
            },
            State
        )
    ).

t_update(_Config) ->
    CorrectConfig = raw_redis_auth_config(),
    IncorrectConfig =
        CorrectConfig#{
            <<"cmd">> => <<"HMGET invalid_key:${username} password_hash salt is_superuser">>
        },

    {ok, _} = emqx:update_config(
        ?PATH,
        {create_authenticator, ?GLOBAL, IncorrectConfig}
    ),

    {error, not_authorized} = emqx_access_control:authenticate(
        #{
            username => <<"plain">>,
            password => <<"plain">>,
            listener => 'tcp:default',
            protocol => mqtt
        }
    ),

    % We update with config with correct query, provider should update and work properly
    {ok, _} = emqx:update_config(
        ?PATH,
        {update_authenticator, ?GLOBAL, <<"password_based:redis">>, CorrectConfig}
    ),

    {ok, _} = emqx_access_control:authenticate(
        #{
            username => <<"plain">>,
            password => <<"plain">>,
            listener => 'tcp:default',
            protocol => mqtt
        }
    ).

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

raw_redis_auth_config() ->
    #{
        <<"mechanism">> => <<"password_based">>,
        <<"password_hash_algorithm">> => #{
            <<"name">> => <<"plain">>,
            <<"salt_position">> => <<"suffix">>
        },
        <<"enable">> => <<"true">>,

        <<"backend">> => <<"redis">>,
        <<"cmd">> => <<"HMGET mqtt_user:${username} password_hash salt is_superuser">>,
        <<"database">> => <<"1">>,
        <<"password">> => <<"public">>,
        <<"redis_type">> => <<"single">>,
        <<"server">> => redis_server()
    }.

user_seeds() ->
    [
        #{
            data => #{
                password_hash => <<"plainsalt">>,
                salt => <<"salt">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                username => <<"plain">>,
                password => <<"plain">>
            },
            key => <<"mqtt_user:plain">>,
            config_params => #{},
            result => {ok, #{is_superuser => true}}
        },

        #{
            data => #{
                password_hash => <<"9b4d0c43d206d48279e69b9ad7132e22">>,
                salt => <<"salt">>,
                is_superuser => <<"0">>
            },
            credentials => #{
                username => <<"md5">>,
                password => <<"md5">>
            },
            key => <<"mqtt_user:md5">>,
            config_params => #{
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"md5">>,
                    <<"salt_position">> => <<"suffix">>
                }
            },
            result => {ok, #{is_superuser => false}}
        },

        #{
            data => #{
                password_hash =>
                    <<"ac63a624e7074776d677dd61a003b8c803eb11db004d0ec6ae032a5d7c9c5caf">>,
                salt => <<"salt">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                clientid => <<"sha256">>,
                password => <<"sha256">>
            },
            key => <<"mqtt_user:sha256">>,
            config_params => #{
                <<"cmd">> => <<"HMGET mqtt_user:${clientid} password_hash salt is_superuser">>,
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"sha256">>,
                    <<"salt_position">> => <<"prefix">>
                }
            },
            result => {ok, #{is_superuser => true}}
        },

        #{
            data => #{
                password_hash =>
                    <<"a3c7f6b085c3e5897ffb9b86f18a9d905063f8550a74444b5892e193c1b50428">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                clientid => <<"sha256_no_salt">>,
                password => <<"sha256_no_salt">>
            },
            key => <<"mqtt_user:sha256_no_salt">>,
            config_params => #{
                <<"cmd">> => <<"HMGET mqtt_user:${clientid} password_hash is_superuser">>,
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"sha256">>,
                    <<"salt_position">> => <<"disable">>
                }
            },
            result => {ok, #{is_superuser => true}}
        },

        #{
            data => #{
                password_hash =>
                    <<"$2b$12$wtY3h20mUjjmeaClpqZVveDWGlHzCGsvuThMlneGHA7wVeFYyns2u">>,
                salt => <<"$2b$12$wtY3h20mUjjmeaClpqZVve">>,
                is_superuser => <<"0">>
            },
            credentials => #{
                username => <<"bcrypt">>,
                password => <<"bcrypt">>
            },
            key => <<"mqtt_user:bcrypt">>,
            config_params => #{
                <<"password_hash_algorithm">> => #{<<"name">> => <<"bcrypt">>}
            },
            result => {ok, #{is_superuser => false}}
        },
        #{
            data => #{
                password_hash => <<"01dbee7f4a9e243e988b62c73cda935da05378b9">>,
                salt => <<"ATHENA.MIT.EDUraeburn">>,
                is_superuser => <<"0">>
            },
            credentials => #{
                username => <<"pbkdf2">>,
                password => <<"password">>
            },
            key => <<"mqtt_user:pbkdf2">>,
            config_params => #{
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"pbkdf2">>,
                    <<"iterations">> => <<"2">>,
                    <<"mac_fun">> => <<"sha">>
                }
            },
            result => {ok, #{is_superuser => false}}
        },
        #{
            data => #{
                password_hash =>
                    <<"$2b$12$wtY3h20mUjjmeaClpqZVveDWGlHzCGsvuThMlneGHA7wVeFYyns2u">>,
                salt => <<"$2b$12$wtY3h20mUjjmeaClpqZVve">>,
                is_superuser => <<"0">>
            },
            credentials => #{
                username => <<"bcrypt0">>,
                password => <<"bcrypt">>
            },
            key => <<"mqtt_user:bcrypt0">>,
            config_params => #{
                % clientid variable & username credentials
                <<"cmd">> => <<"HMGET mqtt_client:${clientid} password_hash salt is_superuser">>,
                <<"password_hash_algorithm">> => #{<<"name">> => <<"bcrypt">>}
            },
            result => {error, not_authorized}
        },

        #{
            data => #{
                password_hash =>
                    <<"$2b$12$wtY3h20mUjjmeaClpqZVveDWGlHzCGsvuThMlneGHA7wVeFYyns2u">>,
                salt => <<"$2b$12$wtY3h20mUjjmeaClpqZVve">>,
                is_superuser => <<"0">>
            },
            credentials => #{
                username => <<"bcrypt1">>,
                password => <<"bcrypt">>
            },
            key => <<"mqtt_user:bcrypt1">>,
            config_params => #{
                % Bad key in cmd
                <<"cmd">> => <<"HMGET badkey:${username} password_hash salt is_superuser">>,
                <<"password_hash_algorithm">> => #{<<"name">> => <<"bcrypt">>}
            },
            result => {error, not_authorized}
        },

        #{
            data => #{
                password_hash =>
                    <<"$2b$12$wtY3h20mUjjmeaClpqZVveDWGlHzCGsvuThMlneGHA7wVeFYyns2u">>,
                salt => <<"$2b$12$wtY3h20mUjjmeaClpqZVve">>,
                is_superuser => <<"0">>
            },
            credentials => #{
                username => <<"bcrypt2">>,
                % Wrong password
                password => <<"wrongpass">>
            },
            key => <<"mqtt_user:bcrypt2">>,
            config_params => #{
                <<"cmd">> => <<"HMGET mqtt_user:${username} password_hash salt is_superuser">>,
                <<"password_hash_algorithm">> => #{<<"name">> => <<"bcrypt">>}
            },
            result => {error, bad_username_or_password}
        },

        #{
            data => #{
                password =>
                    <<"a3c7f6b085c3e5897ffb9b86f18a9d905063f8550a74444b5892e193c1b50428">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                clientid => <<"sha256_no_salt">>,
                password => <<"sha256_no_salt">>
            },
            key => <<"mqtt_user:sha256_no_salt">>,
            config_params => #{
                %% Needs to be compatible with emqx 4.x auth data
                <<"cmd">> => <<"HMGET mqtt_user:${clientid} password is_superuser">>,
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"sha256">>,
                    <<"salt_position">> => <<"disable">>
                }
            },
            result => {ok, #{is_superuser => true}}
        },

        #{
            data => #{
                password_hash =>
                    <<"a3c7f6b085c3e5897ffb9b86f18a9d905063f8550a74444b5892e193c1b50428">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                clientid => <<"sha256_no_salt">>,
                cn => <<"cert_common_name">>,
                dn => <<"cert_subject_name">>,
                password => <<"sha256_no_salt">>
            },
            key => <<"mqtt_user:cert_common_name">>,
            config_params => #{
                <<"cmd">> => <<"HMGET mqtt_user:${cert_common_name} password_hash is_superuser">>,
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"sha256">>,
                    <<"salt_position">> => <<"disable">>
                }
            },
            result => {ok, #{is_superuser => true}}
        },

        #{
            data => #{
                password_hash =>
                    <<"a3c7f6b085c3e5897ffb9b86f18a9d905063f8550a74444b5892e193c1b50428">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                clientid => <<"sha256_no_salt">>,
                cn => <<"cert_common_name">>,
                dn => <<"cert_subject_name">>,
                password => <<"sha256_no_salt">>
            },
            key => <<"mqtt_user:cert_subject_name">>,
            config_params => #{
                <<"cmd">> => <<"HMGET mqtt_user:${cert_subject} password_hash is_superuser">>,
                <<"password_hash_algorithm">> => #{
                    <<"name">> => <<"sha256">>,
                    <<"salt_position">> => <<"disable">>
                }
            },
            result => {ok, #{is_superuser => true}}
        },

        %% user not exists
        #{
            data => #{
                password_hash => <<"plainsalt">>,
                salt => <<"salt">>,
                is_superuser => <<"1">>
            },
            credentials => #{
                username => <<"not_exists">>,
                password => <<"plain">>
            },
            key => <<"mqtt_user:plain">>,
            config_params => #{},
            result => {error, not_authorized},
            redis_result => ignore
        }
    ].

init_seeds() ->
    ok = drop_seeds(),
    lists:foreach(
        fun(#{key := UserKey, data := Values}) ->
            lists:foreach(
                fun({Key, Value}) ->
                    q(["HSET", UserKey, atom_to_list(Key), Value])
                end,
                maps:to_list(Values)
            )
        end,
        user_seeds()
    ).

q(Command) ->
    emqx_resource:simple_sync_query(
        ?REDIS_RESOURCE,
        {cmd, Command}
    ).

drop_seeds() ->
    lists:foreach(
        fun(#{key := UserKey}) ->
            q(["DEL", UserKey])
        end,
        user_seeds()
    ).

redis_server() ->
    iolist_to_binary(io_lib:format("~s", [?REDIS_HOST])).

redis_config() ->
    #{
        auto_reconnect => true,
        database => 1,
        pool_size => 8,
        redis_type => single,
        password => "public",
        server => <<?REDIS_HOST>>,
        ssl => #{enable => false}
    }.

start_apps(Apps) ->
    lists:foreach(fun application:ensure_all_started/1, Apps).

stop_apps(Apps) ->
    lists:foreach(fun application:stop/1, Apps).
