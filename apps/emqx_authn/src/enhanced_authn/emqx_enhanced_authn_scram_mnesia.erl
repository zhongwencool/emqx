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

-module(emqx_enhanced_authn_scram_mnesia).

-include("emqx_authn.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).
-behaviour(emqx_authentication).

-export([
    namespace/0,
    tags/0,
    roots/0,
    fields/1,
    desc/1
]).

-export([
    refs/0,
    create/2,
    update/2,
    authenticate/2,
    destroy/1
]).

-export([
    add_user/2,
    delete_user/2,
    update_user/3,
    lookup_user/2,
    list_users/2
]).

-export([
    qs2ms/2,
    run_fuzzy_filter/2,
    format_user_info/1,
    group_match_spec/1
]).

%% Internal exports (RPC)
-export([
    do_destroy/1,
    do_add_user/2,
    do_delete_user/2,
    do_update_user/3
]).

-define(TAB, ?MODULE).
-define(AUTHN_QSCHEMA, [
    {<<"like_user_id">>, binary},
    {<<"user_group">>, binary},
    {<<"is_superuser">>, atom}
]).

-type user_group() :: binary().

-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).

-record(user_info, {
    user_id,
    stored_key,
    server_key,
    salt,
    is_superuser
}).

-reflect_type([user_group/0]).

%%------------------------------------------------------------------------------
%% Mnesia bootstrap
%%------------------------------------------------------------------------------

%% @doc Create or replicate tables.
-spec mnesia(boot | copy) -> ok.
mnesia(boot) ->
    ok = mria:create_table(?TAB, [
        {rlog_shard, ?AUTH_SHARD},
        {type, ordered_set},
        {storage, disc_copies},
        {record_name, user_info},
        {attributes, record_info(fields, user_info)},
        {storage_properties, [{ets, [{read_concurrency, true}]}]}
    ]).

%%------------------------------------------------------------------------------
%% Hocon Schema
%%------------------------------------------------------------------------------

namespace() -> "authn".

tags() ->
    [<<"Authentication">>].

%% used for config check when the schema module is resolved
roots() ->
    [{?CONF_NS, hoconsc:mk(hoconsc:ref(?MODULE, scram))}].

fields(scram) ->
    [
        {mechanism, emqx_authn_schema:mechanism(scram)},
        {backend, emqx_authn_schema:backend(built_in_database)},
        {algorithm, fun algorithm/1},
        {iteration_count, fun iteration_count/1}
    ] ++ emqx_authn_schema:common_fields().

desc(scram) ->
    "Settings for Salted Challenge Response Authentication Mechanism\n"
    "(SCRAM) authentication.";
desc(_) ->
    undefined.

algorithm(type) -> hoconsc:enum([sha256, sha512]);
algorithm(desc) -> "Hashing algorithm.";
algorithm(default) -> sha256;
algorithm(_) -> undefined.

iteration_count(type) -> non_neg_integer();
iteration_count(desc) -> "Iteration count.";
iteration_count(default) -> 4096;
iteration_count(_) -> undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

refs() ->
    [hoconsc:ref(?MODULE, scram)].

create(
    AuthenticatorID,
    #{
        algorithm := Algorithm,
        iteration_count := IterationCount
    }
) ->
    State = #{
        user_group => AuthenticatorID,
        algorithm => Algorithm,
        iteration_count => IterationCount
    },
    {ok, State}.

update(Config, #{user_group := ID}) ->
    create(ID, Config).

authenticate(
    #{
        auth_method := AuthMethod,
        auth_data := AuthData,
        auth_cache := AuthCache
    },
    State
) ->
    case ensure_auth_method(AuthMethod, AuthData, State) of
        true ->
            case AuthCache of
                #{next_step := client_final} ->
                    check_client_final_message(AuthData, AuthCache, State);
                _ ->
                    check_client_first_message(AuthData, AuthCache, State)
            end;
        false ->
            ignore
    end;
authenticate(_Credential, _State) ->
    ignore.

destroy(#{user_group := UserGroup}) ->
    trans(fun ?MODULE:do_destroy/1, [UserGroup]).

do_destroy(UserGroup) ->
    MatchSpec = group_match_spec(UserGroup),
    ok = lists:foreach(
        fun(UserInfo) ->
            mnesia:delete_object(?TAB, UserInfo, write)
        end,
        mnesia:select(?TAB, MatchSpec, write)
    ).

add_user(UserInfo, State) ->
    trans(fun ?MODULE:do_add_user/2, [UserInfo, State]).

do_add_user(
    #{
        user_id := UserID,
        password := Password
    } = UserInfo,
    #{user_group := UserGroup} = State
) ->
    case mnesia:read(?TAB, {UserGroup, UserID}, write) of
        [] ->
            IsSuperuser = maps:get(is_superuser, UserInfo, false),
            add_user(UserGroup, UserID, Password, IsSuperuser, State),
            {ok, #{user_id => UserID, is_superuser => IsSuperuser}};
        [_] ->
            {error, already_exist}
    end.

delete_user(UserID, State) ->
    trans(fun ?MODULE:do_delete_user/2, [UserID, State]).

do_delete_user(UserID, #{user_group := UserGroup}) ->
    case mnesia:read(?TAB, {UserGroup, UserID}, write) of
        [] ->
            {error, not_found};
        [_] ->
            mnesia:delete(?TAB, {UserGroup, UserID}, write)
    end.

update_user(UserID, User, State) ->
    trans(fun ?MODULE:do_update_user/3, [UserID, User, State]).

do_update_user(
    UserID,
    User,
    #{user_group := UserGroup} = State
) ->
    case mnesia:read(?TAB, {UserGroup, UserID}, write) of
        [] ->
            {error, not_found};
        [#user_info{is_superuser = IsSuperuser} = UserInfo] ->
            UserInfo1 = UserInfo#user_info{
                is_superuser = maps:get(is_superuser, User, IsSuperuser)
            },
            UserInfo2 =
                case maps:get(password, User, undefined) of
                    undefined ->
                        UserInfo1;
                    Password ->
                        {StoredKey, ServerKey, Salt} = esasl_scram:generate_authentication_info(
                            Password, State
                        ),
                        UserInfo1#user_info{
                            stored_key = StoredKey,
                            server_key = ServerKey,
                            salt = Salt
                        }
                end,
            mnesia:write(?TAB, UserInfo2, write),
            {ok, format_user_info(UserInfo2)}
    end.

lookup_user(UserID, #{user_group := UserGroup}) ->
    case mnesia:dirty_read(?TAB, {UserGroup, UserID}) of
        [UserInfo] ->
            {ok, format_user_info(UserInfo)};
        [] ->
            {error, not_found}
    end.

list_users(QueryString, #{user_group := UserGroup}) ->
    NQueryString = QueryString#{<<"user_group">> => UserGroup},
    emqx_mgmt_api:node_query(
        node(),
        ?TAB,
        NQueryString,
        ?AUTHN_QSCHEMA,
        fun ?MODULE:qs2ms/2,
        fun ?MODULE:format_user_info/1
    ).

%%--------------------------------------------------------------------
%% QueryString to MatchSpec

-spec qs2ms(atom(), {list(), list()}) -> emqx_mgmt_api:match_spec_and_filter().
qs2ms(_Tab, {QString, Fuzzy}) ->
    #{
        match_spec => ms_from_qstring(QString),
        fuzzy_fun => fuzzy_filter_fun(Fuzzy)
    }.

%% Fuzzy username funcs
fuzzy_filter_fun([]) ->
    undefined;
fuzzy_filter_fun(Fuzzy) ->
    {fun ?MODULE:run_fuzzy_filter/2, [Fuzzy]}.

run_fuzzy_filter(_, []) ->
    true;
run_fuzzy_filter(
    E = #user_info{user_id = {_, UserID}},
    [{user_id, like, UserIDSubStr} | Fuzzy]
) ->
    binary:match(UserID, UserIDSubStr) /= nomatch andalso run_fuzzy_filter(E, Fuzzy).

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

ensure_auth_method(_AuthMethod, undefined, _State) ->
    false;
ensure_auth_method(<<"SCRAM-SHA-256">>, _AuthData, #{algorithm := sha256}) ->
    true;
ensure_auth_method(<<"SCRAM-SHA-512">>, _AuthData, #{algorithm := sha512}) ->
    true;
ensure_auth_method(_AuthMethod, _AuthData, _State) ->
    false.

check_client_first_message(Bin, _Cache, #{iteration_count := IterationCount} = State) ->
    RetrieveFun = fun(Username) ->
        retrieve(Username, State)
    end,
    case
        esasl_scram:check_client_first_message(
            Bin,
            #{
                iteration_count => IterationCount,
                retrieve => RetrieveFun
            }
        )
    of
        {continue, ServerFirstMessage, Cache} ->
            {continue, ServerFirstMessage, Cache};
        ignore ->
            ignore;
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER("check_client_first_message_error", #{
                reason => Reason
            }),
            {error, not_authorized}
    end.

check_client_final_message(Bin, #{is_superuser := IsSuperuser} = Cache, #{algorithm := Alg}) ->
    case
        esasl_scram:check_client_final_message(
            Bin,
            Cache#{algorithm => Alg}
        )
    of
        {ok, ServerFinalMessage} ->
            {ok, #{is_superuser => IsSuperuser}, ServerFinalMessage};
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER("check_client_final_message_error", #{
                reason => Reason
            }),
            {error, not_authorized}
    end.

add_user(UserGroup, UserID, Password, IsSuperuser, State) ->
    {StoredKey, ServerKey, Salt} = esasl_scram:generate_authentication_info(Password, State),
    UserInfo = #user_info{
        user_id = {UserGroup, UserID},
        stored_key = StoredKey,
        server_key = ServerKey,
        salt = Salt,
        is_superuser = IsSuperuser
    },
    mnesia:write(?TAB, UserInfo, write).

retrieve(UserID, #{user_group := UserGroup}) ->
    case mnesia:dirty_read(?TAB, {UserGroup, UserID}) of
        [
            #user_info{
                stored_key = StoredKey,
                server_key = ServerKey,
                salt = Salt,
                is_superuser = IsSuperuser
            }
        ] ->
            {ok, #{
                stored_key => StoredKey,
                server_key => ServerKey,
                salt => Salt,
                is_superuser => IsSuperuser
            }};
        [] ->
            {error, not_found}
    end.

%% TODO: Move to emqx_authn_utils.erl
trans(Fun, Args) ->
    case mria:transaction(?AUTH_SHARD, Fun, Args) of
        {atomic, Res} -> Res;
        {aborted, {function_clause, Stack}} -> erlang:raise(error, function_clause, Stack);
        {aborted, Reason} -> {error, Reason}
    end.

format_user_info(#user_info{user_id = {_, UserID}, is_superuser = IsSuperuser}) ->
    #{user_id => UserID, is_superuser => IsSuperuser}.

ms_from_qstring(QString) ->
    case lists:keytake(user_group, 1, QString) of
        {value, {user_group, '=:=', UserGroup}, QString2} ->
            group_match_spec(UserGroup, QString2);
        _ ->
            []
    end.

group_match_spec(UserGroup) ->
    ets:fun2ms(
        fun(#user_info{user_id = {Group, _}} = User) when Group =:= UserGroup ->
            User
        end
    ).

group_match_spec(UserGroup, QString) ->
    case lists:keyfind(is_superuser, 1, QString) of
        false ->
            ets:fun2ms(fun(#user_info{user_id = {Group, _}} = User) when Group =:= UserGroup ->
                User
            end);
        {is_superuser, '=:=', Value} ->
            ets:fun2ms(fun(#user_info{user_id = {Group, _}, is_superuser = IsSuper} = User) when
                Group =:= UserGroup, IsSuper =:= Value
            ->
                User
            end)
    end.
