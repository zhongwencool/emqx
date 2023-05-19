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

-module(emqx_dashboard_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(
    emqx_common_test_http,
    [
        request_api/3,
        request_api/5,
        get_http_data/1
    ]
).

-include_lib("eunit/include/eunit.hrl").
-include_lib("emqx/include/emqx.hrl").
-include("emqx_dashboard.hrl").

-define(CONTENT_TYPE, "application/x-www-form-urlencoded").

-define(HOST, "http://127.0.0.1:18083").

%% -define(API_VERSION, "v5").

-define(BASE_PATH, "/api/v5").

-define(APP_DASHBOARD, emqx_dashboard).
-define(APP_MANAGEMENT, emqx_management).

-define(OVERVIEWS, [
    "alarms",
    "banned",
    "stats",
    "metrics",
    "listeners",
    "clients",
    "subscriptions"
]).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_mgmt_api_test_util:init_suite([emqx_management]),
    Config.

end_per_suite(_Config) ->
    emqx_mgmt_api_test_util:end_suite([emqx_management]).

t_overview(_) ->
    mnesia:clear_table(?ADMIN),
    emqx_dashboard_admin:add_user(<<"admin">>, <<"public_www1">>, <<"simple_description">>),
    Headers = auth_header_(<<"admin">>, <<"public_www1">>),
    [
        {ok, _} = request_dashboard(get, api_path([Overview]), Headers)
     || Overview <- ?OVERVIEWS
    ].

t_admins_add_delete(_) ->
    mnesia:clear_table(?ADMIN),
    Desc = <<"simple description">>,
    {ok, _} = emqx_dashboard_admin:add_user(<<"username">>, <<"password_0">>, Desc),
    {ok, _} = emqx_dashboard_admin:add_user(<<"username1">>, <<"password1">>, Desc),
    Admins = emqx_dashboard_admin:all_users(),
    ?assertEqual(2, length(Admins)),
    {ok, _} = emqx_dashboard_admin:remove_user(<<"username1">>),
    Users = emqx_dashboard_admin:all_users(),
    ?assertEqual(1, length(Users)),
    {ok, _} = emqx_dashboard_admin:change_password(
        <<"username">>,
        <<"password_0">>,
        <<"new_pwd_1234">>
    ),
    timer:sleep(10),
    {ok, _} = emqx_dashboard_admin:remove_user(<<"username">>).

t_admin_delete_self_failed(_) ->
    mnesia:clear_table(?ADMIN),
    Desc = <<"simple description">>,
    _ = emqx_dashboard_admin:add_user(<<"username1">>, <<"password_1">>, Desc),
    Admins = emqx_dashboard_admin:all_users(),
    ?assertEqual(1, length(Admins)),
    Header = auth_header_(<<"username1">>, <<"password_1">>),
    {error, {_, 400, _}} = request_dashboard(delete, api_path(["users", "username1"]), Header),
    Token = ["Basic ", base64:encode("username1:password_1")],
    Header2 = {"Authorization", Token},
    {error, {_, 401, _}} = request_dashboard(delete, api_path(["users", "username1"]), Header2),
    mnesia:clear_table(?ADMIN).

t_rest_api(_Config) ->
    mnesia:clear_table(?ADMIN),
    Desc = <<"administrator">>,
    Password = <<"public_www1">>,
    emqx_dashboard_admin:add_user(<<"admin">>, Password, Desc),
    {ok, 200, Res0} = http_get(["users"]),
    ?assertEqual(
        [
            #{
                <<"username">> => <<"admin">>,
                <<"description">> => <<"administrator">>
            }
        ],
        get_http_data(Res0)
    ),
    {ok, 200, _} = http_put(["users", "admin"], #{<<"description">> => <<"a_new_description">>}),
    {ok, 200, _} = http_post(["users"], #{
        <<"username">> => <<"usera">>,
        <<"password">> => <<"passwd_01234">>,
        <<"description">> => Desc
    }),
    {ok, 204, _} = http_delete(["users", "usera"]),
    {ok, 404, _} = http_delete(["users", "usera"]),
    {ok, 204, _} = http_post(
        ["users", "admin", "change_pwd"],
        #{
            <<"old_pwd">> => Password,
            <<"new_pwd">> => <<"newpwd_lkdfki1">>
        }
    ),
    mnesia:clear_table(?ADMIN),
    emqx_dashboard_admin:add_user(<<"admin">>, Password, <<"administrator">>),
    ok.

t_swagger_json(_Config) ->
    Url = ?HOST ++ "/api-docs/swagger.json",
    %% with auth
    Auth = auth_header_(<<"admin">>, <<"public_www1">>),
    {ok, 200, Body1} = request_api(get, Url, Auth),
    ?assert(emqx_utils_json:is_json(Body1)),
    %% without auth
    {ok, {{"HTTP/1.1", 200, "OK"}, _Headers, Body2}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    ?assertEqual(Body1, Body2),
    ok.

t_cli(_Config) ->
    [mria:dirty_delete(?ADMIN, Admin) || Admin <- mnesia:dirty_all_keys(?ADMIN)],
    emqx_dashboard_cli:admins(["add", "username", "password_ww2"]),
    [#?ADMIN{username = <<"username">>, pwdhash = <<Salt:4/binary, Hash/binary>>}] =
        emqx_dashboard_admin:lookup_user(<<"username">>),
    ?assertEqual(Hash, crypto:hash(sha256, <<Salt/binary, <<"password_ww2">>/binary>>)),
    emqx_dashboard_cli:admins(["passwd", "username", "new_password"]),
    [#?ADMIN{username = <<"username">>, pwdhash = <<Salt1:4/binary, Hash1/binary>>}] =
        emqx_dashboard_admin:lookup_user(<<"username">>),
    ?assertEqual(Hash1, crypto:hash(sha256, <<Salt1/binary, <<"new_password">>/binary>>)),
    emqx_dashboard_cli:admins(["del", "username"]),
    [] = emqx_dashboard_admin:lookup_user(<<"username">>),
    emqx_dashboard_cli:admins(["add", "admin1", "pass_lkdfkd1"]),
    emqx_dashboard_cli:admins(["add", "admin2", "w_pass_lkdfkd2"]),
    AdminList = emqx_dashboard_admin:all_users(),
    ?assertEqual(2, length(AdminList)).

t_lookup_by_username_jwt(_Config) ->
    User = bin(["user-", integer_to_list(random_num())]),
    Pwd = bin("t_password" ++ integer_to_list(random_num())),
    emqx_dashboard_token:sign(User, Pwd),
    ?assertMatch(
        [#?ADMIN_JWT{username = User}],
        emqx_dashboard_token:lookup_by_username(User)
    ),
    ok = emqx_dashboard_token:destroy_by_username(User),
    %% issue a gen_server call to sync the async destroy gen_server cast
    ok = gen_server:call(emqx_dashboard_token, dummy, infinity),
    ?assertMatch([], emqx_dashboard_token:lookup_by_username(User)),
    ok.

t_clean_expired_jwt(_Config) ->
    User = bin(["user-", integer_to_list(random_num())]),
    Pwd = bin("t_password" ++ integer_to_list(random_num())),
    emqx_dashboard_token:sign(User, Pwd),
    [#?ADMIN_JWT{username = User, exptime = ExpTime}] =
        emqx_dashboard_token:lookup_by_username(User),
    ok = emqx_dashboard_token:clean_expired_jwt(_Now1 = ExpTime),
    ?assertMatch(
        [#?ADMIN_JWT{username = User}],
        emqx_dashboard_token:lookup_by_username(User)
    ),
    ok = emqx_dashboard_token:clean_expired_jwt(_Now2 = ExpTime + 1),
    ?assertMatch([], emqx_dashboard_token:lookup_by_username(User)),
    ok.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

bin(X) -> iolist_to_binary(X).

random_num() ->
    erlang:system_time(nanosecond).

http_get(Parts) ->
    request_api(get, api_path(Parts), auth_header_(<<"admin">>, <<"public_www1">>)).

http_delete(Parts) ->
    request_api(delete, api_path(Parts), auth_header_(<<"admin">>, <<"public_www1">>)).

http_post(Parts, Body) ->
    request_api(post, api_path(Parts), [], auth_header_(<<"admin">>, <<"public_www1">>), Body).

http_put(Parts, Body) ->
    request_api(put, api_path(Parts), [], auth_header_(<<"admin">>, <<"public_www1">>), Body).

request_dashboard(Method, Url, Auth) ->
    Request = {Url, [Auth]},
    do_request_dashboard(Method, Request).
request_dashboard(Method, Url, QueryParams, Auth) ->
    Request = {Url ++ "?" ++ QueryParams, [Auth]},
    do_request_dashboard(Method, Request).
do_request_dashboard(Method, Request) ->
    ct:pal("Method: ~p, Request: ~p", [Method, Request]),
    case httpc:request(Method, Request, [], []) of
        {error, socket_closed_remotely} ->
            {error, socket_closed_remotely};
        {ok, {{"HTTP/1.1", Code, _}, _Headers, Return}} when
            Code >= 200 andalso Code =< 299
        ->
            {ok, Return};
        {ok, {Reason, _, _}} ->
            {error, Reason}
    end.

auth_header_() ->
    auth_header_(<<"admin">>, <<"public">>).

auth_header_(Username, Password) ->
    {ok, Token} = emqx_dashboard_admin:sign_token(Username, Password),
    {"Authorization", "Bearer " ++ binary_to_list(Token)}.

api_path(Parts) ->
    ?HOST ++ filename:join([?BASE_PATH | Parts]).

json(Data) ->
    {ok, Jsx} = emqx_utils_json:safe_decode(Data, [return_maps]),
    Jsx.
