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

-module(emqx_authn_jwt).

-include("emqx_authn.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-behaviour(hocon_schema).

-export([
    namespace/0,
    tags/0,
    roots/0,
    fields/1,
    desc/1
]).

-export([
    refs/0,
    union_member_selector/1,
    create/2,
    update/2,
    authenticate/2,
    destroy/1
]).

%%------------------------------------------------------------------------------
%% Hocon Schema
%%------------------------------------------------------------------------------

namespace() -> "authn".

tags() ->
    [<<"Authentication">>].

%% used for config check when the schema module is resolved
roots() ->
    [
        {?CONF_NS,
            hoconsc:mk(
                hoconsc:union(fun ?MODULE:union_member_selector/1),
                #{}
            )}
    ].

fields(jwt_hmac) ->
    [
        %% for hmac, it's the 'algorithm' field which selects this type
        %% use_jwks field can be ignored (kept for backward compatibility)
        {use_jwks,
            sc(
                hoconsc:enum([false]),
                #{
                    required => false,
                    desc => ?DESC(use_jwks),
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {algorithm,
            sc(hoconsc:enum(['hmac-based']), #{required => true, desc => ?DESC(algorithm)})},
        {secret, fun secret/1},
        {secret_base64_encoded, fun secret_base64_encoded/1}
    ] ++ common_fields();
fields(jwt_public_key) ->
    [
        %% for public-key, it's the 'algorithm' field which selects this type
        %% use_jwks field can be ignored (kept for backward compatibility)
        {use_jwks,
            sc(
                hoconsc:enum([false]),
                #{
                    required => false,
                    desc => ?DESC(use_jwks),
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {algorithm,
            sc(hoconsc:enum(['public-key']), #{required => true, desc => ?DESC(algorithm)})},
        {public_key, fun public_key/1}
    ] ++ common_fields();
fields(jwt_jwks) ->
    [
        {use_jwks, sc(hoconsc:enum([true]), #{required => true, desc => ?DESC(use_jwks)})},
        {endpoint, fun endpoint/1},
        {pool_size, fun emqx_connector_schema_lib:pool_size/1},
        {refresh_interval, fun refresh_interval/1},
        {ssl, #{
            type => hoconsc:ref(emqx_schema, "ssl_client_opts"),
            default => #{<<"enable">> => false},
            desc => ?DESC("ssl")
        }}
    ] ++ common_fields().

desc(jwt_hmac) ->
    ?DESC(jwt_hmac);
desc(jwt_public_key) ->
    ?DESC(jwt_public_key);
desc(jwt_jwks) ->
    ?DESC(jwt_jwks);
desc(undefined) ->
    undefined.

common_fields() ->
    [
        {mechanism, emqx_authn_schema:mechanism('jwt')},
        {acl_claim_name, #{
            type => binary(),
            default => <<"acl">>,
            desc => ?DESC(acl_claim_name)
        }},
        {verify_claims, fun verify_claims/1},
        {from, fun from/1}
    ] ++ emqx_authn_schema:common_fields().

secret(type) -> binary();
secret(desc) -> ?DESC(?FUNCTION_NAME);
secret(required) -> true;
secret(_) -> undefined.

secret_base64_encoded(type) -> boolean();
secret_base64_encoded(desc) -> ?DESC(?FUNCTION_NAME);
secret_base64_encoded(default) -> false;
secret_base64_encoded(_) -> undefined.

public_key(type) -> string();
public_key(desc) -> ?DESC(?FUNCTION_NAME);
public_key(required) -> ture;
public_key(_) -> undefined.

endpoint(type) -> string();
endpoint(desc) -> ?DESC(?FUNCTION_NAME);
endpoint(required) -> true;
endpoint(_) -> undefined.

refresh_interval(type) -> integer();
refresh_interval(desc) -> ?DESC(?FUNCTION_NAME);
refresh_interval(default) -> 300;
refresh_interval(validator) -> [fun(I) -> I > 0 end];
refresh_interval(_) -> undefined.

verify_claims(type) ->
    list();
verify_claims(desc) ->
    ?DESC(?FUNCTION_NAME);
verify_claims(default) ->
    #{};
verify_claims(validator) ->
    [fun do_check_verify_claims/1];
verify_claims(converter) ->
    fun(VerifyClaims) ->
        [{to_binary(K), V} || {K, V} <- maps:to_list(VerifyClaims)]
    end;
verify_claims(required) ->
    false;
verify_claims(_) ->
    undefined.

from(type) -> hoconsc:enum([username, password]);
from(desc) -> ?DESC(?FUNCTION_NAME);
from(default) -> password;
from(_) -> undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

refs() ->
    [
        hoconsc:ref(?MODULE, jwt_hmac),
        hoconsc:ref(?MODULE, jwt_public_key),
        hoconsc:ref(?MODULE, jwt_jwks)
    ].

union_member_selector(all_union_members) ->
    refs();
union_member_selector({value, V}) ->
    UseJWKS = maps:get(<<"use_jwks">>, V, undefined),
    select_ref(boolean(UseJWKS), V).

%% this field is technically a boolean type,
%% but union member selection is done before type casting (by typrefl),
%% so we have to allow strings too
boolean(<<"true">>) -> true;
boolean(<<"false">>) -> false;
boolean(Other) -> Other.

select_ref(true, _) ->
    [hoconsc:ref(?MODULE, 'jwt_jwks')];
select_ref(false, #{<<"public_key">> := _}) ->
    [hoconsc:ref(?MODULE, jwt_public_key)];
select_ref(false, _) ->
    [hoconsc:ref(?MODULE, jwt_hmac)];
select_ref(_, _) ->
    throw(#{
        field_name => use_jwks,
        expected => "true | false"
    }).

create(_AuthenticatorID, Config) ->
    create(Config).

create(#{verify_claims := VerifyClaims} = Config) ->
    create2(Config#{verify_claims => handle_verify_claims(VerifyClaims)}).

update(
    #{use_jwks := false} = Config,
    #{jwk_resource := ResourceId}
) ->
    _ = emqx_resource:remove_local(ResourceId),
    create(Config);
update(#{use_jwks := false} = Config, _State) ->
    create(Config);
update(
    #{use_jwks := true} = Config,
    #{jwk_resource := ResourceId} = State
) ->
    case emqx_resource:simple_sync_query(ResourceId, {update, connector_opts(Config)}) of
        ok ->
            case maps:get(verify_claims, Config, undefined) of
                undefined ->
                    {ok, State};
                VerifyClaims ->
                    {ok, State#{verify_claims => handle_verify_claims(VerifyClaims)}}
            end;
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "jwks_client_option_update_failed",
                resource => ResourceId,
                reason => Reason
            })
    end;
update(#{use_jwks := true} = Config, _State) ->
    create(Config).

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(
    Credential,
    #{
        verify_claims := VerifyClaims0,
        jwk := JWK,
        acl_claim_name := AclClaimName,
        from := From
    }
) ->
    JWT = maps:get(From, Credential),
    JWKs = [JWK],
    VerifyClaims = replace_placeholder(VerifyClaims0, Credential),
    verify(JWT, JWKs, VerifyClaims, AclClaimName);
authenticate(
    Credential,
    #{
        verify_claims := VerifyClaims0,
        jwk_resource := ResourceId,
        acl_claim_name := AclClaimName,
        from := From
    }
) ->
    case emqx_resource:simple_sync_query(ResourceId, get_jwks) of
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER(error, "get_jwks_failed", #{
                resource => ResourceId,
                reason => Reason
            }),
            ignore;
        {ok, JWKs} ->
            JWT = maps:get(From, Credential),
            VerifyClaims = replace_placeholder(VerifyClaims0, Credential),
            verify(JWT, JWKs, VerifyClaims, AclClaimName)
    end.

destroy(#{jwk_resource := ResourceId}) ->
    _ = emqx_resource:remove_local(ResourceId),
    ok;
destroy(_) ->
    ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

create2(#{
    use_jwks := false,
    algorithm := 'hmac-based',
    secret := Secret0,
    secret_base64_encoded := Base64Encoded,
    verify_claims := VerifyClaims,
    acl_claim_name := AclClaimName,
    from := From
}) ->
    case may_decode_secret(Base64Encoded, Secret0) of
        {error, Reason} ->
            {error, Reason};
        Secret ->
            JWK = jose_jwk:from_oct(Secret),
            {ok, #{
                jwk => JWK,
                verify_claims => VerifyClaims,
                acl_claim_name => AclClaimName,
                from => From
            }}
    end;
create2(#{
    use_jwks := false,
    algorithm := 'public-key',
    public_key := PublicKey,
    verify_claims := VerifyClaims,
    acl_claim_name := AclClaimName,
    from := From
}) ->
    JWK = create_jwk_from_public_key(PublicKey),
    {ok, #{
        jwk => JWK,
        verify_claims => VerifyClaims,
        acl_claim_name => AclClaimName,
        from => From
    }};
create2(
    #{
        use_jwks := true,
        verify_claims := VerifyClaims,
        acl_claim_name := AclClaimName,
        from := From
    } = Config
) ->
    ResourceId = emqx_authn_utils:make_resource_id(?MODULE),
    {ok, _Data} = emqx_resource:create_local(
        ResourceId,
        ?RESOURCE_GROUP,
        emqx_authn_jwks_connector,
        connector_opts(Config)
    ),
    {ok, #{
        jwk_resource => ResourceId,
        verify_claims => VerifyClaims,
        acl_claim_name => AclClaimName,
        from => From
    }}.

create_jwk_from_public_key(PublicKey) when
    is_binary(PublicKey); is_list(PublicKey)
->
    case filelib:is_file(PublicKey) of
        true ->
            jose_jwk:from_pem_file(PublicKey);
        false ->
            jose_jwk:from_pem(iolist_to_binary(PublicKey))
    end.

connector_opts(#{ssl := #{enable := Enable} = SSL} = Config) ->
    SSLOpts =
        case Enable of
            true -> maps:without([enable], SSL);
            false -> #{}
        end,
    Config#{ssl_opts => SSLOpts}.

may_decode_secret(false, Secret) ->
    Secret;
may_decode_secret(true, Secret) ->
    try
        base64:decode(Secret)
    catch
        error:_ ->
            {error, {invalid_parameter, secret}}
    end.

replace_placeholder(L, Variables) ->
    replace_placeholder(L, Variables, []).

replace_placeholder([], _Variables, Acc) ->
    Acc;
replace_placeholder([{Name, {placeholder, PL}} | More], Variables, Acc) ->
    Value = maps:get(PL, Variables),
    replace_placeholder(More, Variables, [{Name, Value} | Acc]);
replace_placeholder([{Name, Value} | More], Variables, Acc) ->
    replace_placeholder(More, Variables, [{Name, Value} | Acc]).

verify(undefined, _, _, _) ->
    ignore;
verify(JWT, JWKs, VerifyClaims, AclClaimName) ->
    case do_verify(JWT, JWKs, VerifyClaims) of
        {ok, Extra} ->
            {ok, acl(Extra, AclClaimName)};
        {error, {missing_claim, Claim}} ->
            ?TRACE_AUTHN_PROVIDER("missing_jwt_claim", #{jwt => JWT, claim => Claim}),
            {error, bad_username_or_password};
        {error, invalid_signature} ->
            ?TRACE_AUTHN_PROVIDER("invalid_jwt_signature", #{jwks => JWKs, jwt => JWT}),
            ignore;
        {error, {claims, Claims}} ->
            ?TRACE_AUTHN_PROVIDER("invalid_jwt_claims", #{jwt => JWT, claims => Claims}),
            {error, bad_username_or_password}
    end.

acl(Claims, AclClaimName) ->
    Acl =
        case Claims of
            #{AclClaimName := Rules} ->
                #{
                    acl => #{
                        rules => Rules,
                        expire => maps:get(<<"exp">>, Claims, undefined)
                    }
                };
            _ ->
                #{}
        end,
    maps:merge(emqx_authn_utils:is_superuser(Claims), Acl).

do_verify(_JWT, [], _VerifyClaims) ->
    {error, invalid_signature};
do_verify(JWT, [JWK | More], VerifyClaims) ->
    try jose_jws:verify(JWK, JWT) of
        {true, Payload, _JWT} ->
            Claims0 = emqx_utils_json:decode(Payload, [return_maps]),
            Claims = try_convert_to_num(Claims0, [<<"exp">>, <<"iat">>, <<"nbf">>]),
            case verify_claims(Claims, VerifyClaims) of
                ok ->
                    {ok, Claims};
                {error, Reason} ->
                    {error, Reason}
            end;
        {false, _, _} ->
            do_verify(JWT, More, VerifyClaims)
    catch
        _:Reason ->
            ?TRACE_AUTHN_PROVIDER("jwt_verify_error", #{jwk => JWK, jwt => JWT, reason => Reason}),
            do_verify(JWT, More, VerifyClaims)
    end.

verify_claims(Claims, VerifyClaims0) ->
    Now = erlang:system_time(seconds),
    VerifyClaims =
        [
            {<<"exp">>, fun(ExpireTime) ->
                is_number(ExpireTime) andalso Now < ExpireTime
            end},
            {<<"iat">>, fun(IssueAt) ->
                is_number(IssueAt) andalso IssueAt =< Now
            end},
            {<<"nbf">>, fun(NotBefore) ->
                is_number(NotBefore) andalso NotBefore =< Now
            end}
        ] ++ VerifyClaims0,
    do_verify_claims(Claims, VerifyClaims).

try_convert_to_num(Claims, [Name | Names]) ->
    case Claims of
        #{Name := Value} ->
            case Value of
                Int when is_number(Int) ->
                    try_convert_to_num(Claims#{Name => Int}, Names);
                Bin when is_binary(Bin) ->
                    case binary_to_number(Bin) of
                        {ok, Num} ->
                            try_convert_to_num(Claims#{Name => Num}, Names);
                        _ ->
                            try_convert_to_num(Claims, Names)
                    end;
                _ ->
                    try_convert_to_num(Claims, Names)
            end;
        _ ->
            try_convert_to_num(Claims, Names)
    end;
try_convert_to_num(Claims, []) ->
    Claims.

do_verify_claims(_Claims, []) ->
    ok;
do_verify_claims(Claims, [{Name, Fun} | More]) when is_function(Fun) ->
    case maps:take(Name, Claims) of
        error ->
            do_verify_claims(Claims, More);
        {Value, NClaims} ->
            case Fun(Value) of
                true ->
                    do_verify_claims(NClaims, More);
                _ ->
                    {error, {claims, {Name, Value}}}
            end
    end;
do_verify_claims(Claims, [{Name, Value} | More]) ->
    case maps:take(Name, Claims) of
        error ->
            {error, {missing_claim, Name}};
        {Value, NClaims} ->
            do_verify_claims(NClaims, More);
        {Value0, _} ->
            {error, {claims, {Name, Value0}}}
    end.

do_check_verify_claims([]) ->
    true;
do_check_verify_claims([{Name, Expected} | More]) ->
    check_claim_name(Name) andalso
        check_claim_expected(Expected) andalso
        do_check_verify_claims(More).

check_claim_name(exp) ->
    false;
check_claim_name(iat) ->
    false;
check_claim_name(nbf) ->
    false;
check_claim_name(Name) when
    Name == <<>>;
    Name == ""
->
    false;
check_claim_name(_) ->
    true.

check_claim_expected(Expected) ->
    try handle_placeholder(Expected) of
        _ -> true
    catch
        _:_ ->
            false
    end.

handle_verify_claims(VerifyClaims) ->
    handle_verify_claims(VerifyClaims, []).

handle_verify_claims([], Acc) ->
    Acc;
handle_verify_claims([{Name, Expected0} | More], Acc) ->
    Expected = handle_placeholder(Expected0),
    handle_verify_claims(More, [{Name, Expected} | Acc]).

handle_placeholder(Placeholder0) ->
    case re:run(Placeholder0, "^\\$\\{[a-z0-9\\-]+\\}$", [{capture, all}]) of
        {match, [{Offset, Length}]} ->
            Placeholder1 = binary:part(Placeholder0, Offset + 2, Length - 3),
            Placeholder2 = validate_placeholder(Placeholder1),
            {placeholder, Placeholder2};
        nomatch ->
            Placeholder0
    end.

validate_placeholder(<<"clientid">>) ->
    clientid;
validate_placeholder(<<"username">>) ->
    username.

to_binary(A) when is_atom(A) ->
    atom_to_binary(A);
to_binary(B) when is_binary(B) ->
    B.

sc(Type, Meta) -> hoconsc:mk(Type, Meta).

binary_to_number(Bin) ->
    try
        {ok, erlang:binary_to_integer(Bin)}
    catch
        _:_ ->
            try
                {ok, erlang:binary_to_float(Bin)}
            catch
                _:_ ->
                    false
            end
    end.
