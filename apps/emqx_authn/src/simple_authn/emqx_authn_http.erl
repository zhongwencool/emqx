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

-module(emqx_authn_http).

-include("emqx_authn.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx_connector/include/emqx_connector.hrl").

-behaviour(hocon_schema).
-behaviour(emqx_authentication).

-export([
    namespace/0,
    tags/0,
    roots/0,
    fields/1,
    desc/1,
    validations/0
]).

-export([
    headers_no_content_type/1,
    headers/1
]).

-export([check_headers/1, check_ssl_opts/1]).

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

fields(http_get) ->
    [
        {method, #{type => get, required => true, desc => ?DESC(method)}},
        {headers, fun headers_no_content_type/1}
    ] ++ common_fields();
fields(http_post) ->
    [
        {method, #{type => post, required => true, desc => ?DESC(method)}},
        {headers, fun headers/1}
    ] ++ common_fields().

desc(http_get) ->
    ?DESC(get);
desc(http_post) ->
    ?DESC(post);
desc(_) ->
    undefined.

common_fields() ->
    [
        {mechanism, emqx_authn_schema:mechanism(password_based)},
        {backend, emqx_authn_schema:backend(http)},
        {url, fun url/1},
        {body,
            hoconsc:mk(map([{fuzzy, term(), binary()}]), #{
                required => false, desc => ?DESC(body)
            })},
        {request_timeout, fun request_timeout/1}
    ] ++ emqx_authn_schema:common_fields() ++
        maps:to_list(
            maps:without(
                [
                    pool_type
                ],
                maps:from_list(emqx_connector_http:fields(config))
            )
        ).

validations() ->
    [
        {check_ssl_opts, fun ?MODULE:check_ssl_opts/1},
        {check_headers, fun ?MODULE:check_headers/1}
    ].

url(type) -> binary();
url(desc) -> ?DESC(?FUNCTION_NAME);
url(validator) -> [?NOT_EMPTY("the value of the field 'url' cannot be empty")];
url(required) -> true;
url(_) -> undefined.

headers(type) ->
    map();
headers(desc) ->
    ?DESC(?FUNCTION_NAME);
headers(converter) ->
    fun(Headers) ->
        maps:merge(default_headers(), transform_header_name(Headers))
    end;
headers(default) ->
    default_headers();
headers(_) ->
    undefined.

headers_no_content_type(type) ->
    map();
headers_no_content_type(desc) ->
    ?DESC(?FUNCTION_NAME);
headers_no_content_type(converter) ->
    fun(Headers) ->
        maps:without(
            [<<"content-type">>],
            maps:merge(default_headers_no_content_type(), transform_header_name(Headers))
        )
    end;
headers_no_content_type(default) ->
    default_headers_no_content_type();
headers_no_content_type(_) ->
    undefined.

request_timeout(type) -> emqx_schema:duration_ms();
request_timeout(desc) -> ?DESC(?FUNCTION_NAME);
request_timeout(default) -> <<"5s">>;
request_timeout(_) -> undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

refs() ->
    [
        hoconsc:ref(?MODULE, http_get),
        hoconsc:ref(?MODULE, http_post)
    ].

union_member_selector(all_union_members) ->
    refs();
union_member_selector({value, Value}) ->
    refs(Value).

refs(#{<<"method">> := <<"get">>}) ->
    [hoconsc:ref(?MODULE, http_get)];
refs(#{<<"method">> := <<"post">>}) ->
    [hoconsc:ref(?MODULE, http_post)];
refs(_) ->
    throw(#{
        field_name => method,
        expected => "get | post"
    }).

create(_AuthenticatorID, Config) ->
    create(Config).

create(Config0) ->
    ResourceId = emqx_authn_utils:make_resource_id(?MODULE),
    {Config, State} = parse_config(Config0),
    {ok, _Data} = emqx_authn_utils:create_resource(
        ResourceId,
        emqx_connector_http,
        Config
    ),
    {ok, State#{resource_id => ResourceId}}.

update(Config0, #{resource_id := ResourceId} = _State) ->
    {Config, NState} = parse_config(Config0),
    case emqx_authn_utils:update_resource(emqx_connector_http, Config, ResourceId) of
        {error, Reason} ->
            error({load_config_error, Reason});
        {ok, _} ->
            {ok, NState#{resource_id => ResourceId}}
    end.

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(
    Credential,
    #{
        resource_id := ResourceId,
        method := Method,
        request_timeout := RequestTimeout
    } = State
) ->
    Request = generate_request(Credential, State),
    Response = emqx_resource:simple_sync_query(ResourceId, {Method, Request, RequestTimeout}),
    ?TRACE_AUTHN_PROVIDER("http_response", #{
        request => request_for_log(Credential, State),
        response => response_for_log(Response),
        resource => ResourceId
    }),
    case Response of
        {ok, 204, _Headers} ->
            {ok, #{is_superuser => false}};
        {ok, 200, Headers, Body} ->
            handle_response(Headers, Body);
        {ok, _StatusCode, _Headers} = Response ->
            ignore;
        {ok, _StatusCode, _Headers, _Body} = Response ->
            ignore;
        {error, _Reason} ->
            ignore
    end.

destroy(#{resource_id := ResourceId}) ->
    _ = emqx_resource:remove_local(ResourceId),
    ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

default_headers() ->
    maps:put(
        <<"content-type">>,
        <<"application/json">>,
        default_headers_no_content_type()
    ).

default_headers_no_content_type() ->
    #{
        <<"accept">> => <<"application/json">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>,
        <<"keep-alive">> => <<"timeout=30, max=1000">>
    }.

transform_header_name(Headers) ->
    maps:fold(
        fun(K0, V, Acc) ->
            K = list_to_binary(string:to_lower(to_list(K0))),
            maps:put(K, V, Acc)
        end,
        #{},
        Headers
    ).

check_ssl_opts(Conf) ->
    case is_backend_http(Conf) of
        true ->
            Url = get_conf_val("url", Conf),
            {BaseUrl, _Path, _Query} = parse_url(Url),
            case BaseUrl of
                <<"https://", _/binary>> ->
                    case get_conf_val("ssl.enable", Conf) of
                        true ->
                            ok;
                        false ->
                            <<"it's required to enable the TLS option to establish a https connection">>
                    end;
                <<"http://", _/binary>> ->
                    ok
            end;
        false ->
            ok
    end.

check_headers(Conf) ->
    case is_backend_http(Conf) of
        true ->
            Headers = get_conf_val("headers", Conf),
            case to_bin(get_conf_val("method", Conf)) of
                <<"post">> ->
                    ok;
                <<"get">> ->
                    case maps:is_key(<<"content-type">>, Headers) of
                        false -> ok;
                        true -> <<"HTTP GET requests cannot include content-type header.">>
                    end
            end;
        false ->
            ok
    end.

is_backend_http(Conf) ->
    case get_conf_val("backend", Conf) of
        http -> true;
        _ -> false
    end.

parse_url(Url) ->
    case string:split(Url, "//", leading) of
        [Scheme, UrlRem] ->
            case string:split(UrlRem, "/", leading) of
                [HostPort, Remaining] ->
                    BaseUrl = iolist_to_binary([Scheme, "//", HostPort]),
                    case string:split(Remaining, "?", leading) of
                        [Path, QueryString] ->
                            {BaseUrl, <<"/", Path/binary>>, QueryString};
                        [Path] ->
                            {BaseUrl, <<"/", Path/binary>>, <<>>}
                    end;
                [HostPort] ->
                    {iolist_to_binary([Scheme, "//", HostPort]), <<>>, <<>>}
            end;
        [Url] ->
            throw({invalid_url, Url})
    end.

parse_config(
    #{
        method := Method,
        url := RawUrl,
        headers := Headers,
        request_timeout := RequestTimeout
    } = Config
) ->
    {BaseUrl0, Path, Query} = parse_url(RawUrl),
    {ok, BaseUrl} = emqx_http_lib:uri_parse(BaseUrl0),
    State = #{
        method => Method,
        path => Path,
        headers => ensure_header_name_type(Headers),
        base_path_template => emqx_authn_utils:parse_str(Path),
        base_query_template => emqx_authn_utils:parse_deep(
            cow_qs:parse_qs(to_bin(Query))
        ),
        body_template => emqx_authn_utils:parse_deep(maps:get(body, Config, #{})),
        request_timeout => RequestTimeout,
        url => RawUrl
    },
    {Config#{base_url => BaseUrl, pool_type => random}, State}.

generate_request(Credential, #{
    method := Method,
    headers := Headers0,
    base_path_template := BasePathTemplate,
    base_query_template := BaseQueryTemplate,
    body_template := BodyTemplate
}) ->
    Headers = maps:to_list(Headers0),
    Path = emqx_authn_utils:render_urlencoded_str(BasePathTemplate, Credential),
    Query = emqx_authn_utils:render_deep(BaseQueryTemplate, Credential),
    Body = emqx_authn_utils:render_deep(BodyTemplate, Credential),
    case Method of
        get ->
            NPathQuery = append_query(to_list(Path), to_list(Query) ++ maps:to_list(Body)),
            {NPathQuery, Headers};
        post ->
            NPathQuery = append_query(to_list(Path), to_list(Query)),
            ContentType = proplists:get_value(<<"content-type">>, Headers),
            NBody = serialize_body(ContentType, Body),
            {NPathQuery, Headers, NBody}
    end.

append_query(Path, []) ->
    Path;
append_query(Path, Query) ->
    Path ++ "?" ++ binary_to_list(qs(Query)).

qs(KVs) ->
    qs(KVs, []).

qs([], Acc) ->
    <<$&, Qs/binary>> = iolist_to_binary(lists:reverse(Acc)),
    Qs;
qs([{K, V} | More], Acc) ->
    qs(More, [["&", uri_encode(K), "=", uri_encode(V)] | Acc]).

serialize_body(<<"application/json">>, Body) ->
    emqx_utils_json:encode(Body);
serialize_body(<<"application/x-www-form-urlencoded">>, Body) ->
    qs(maps:to_list(Body)).

handle_response(Headers, Body) ->
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    case safely_parse_body(ContentType, Body) of
        {ok, NBody} ->
            case maps:get(<<"result">>, NBody, <<"ignore">>) of
                <<"allow">> ->
                    Res = emqx_authn_utils:is_superuser(NBody),
                    %% TODO: Return by user property
                    {ok, Res#{user_property => maps:get(<<"user_property">>, NBody, #{})}};
                <<"deny">> ->
                    {error, not_authorized};
                <<"ignore">> ->
                    ignore;
                _ ->
                    ignore
            end;
        {error, Reason} ->
            ?TRACE_AUTHN_PROVIDER(
                error,
                "parse_http_response_failed",
                #{content_type => ContentType, body => Body, reason => Reason}
            ),
            ignore
    end.

safely_parse_body(ContentType, Body) ->
    try
        parse_body(ContentType, Body)
    catch
        _Class:_Reason ->
            {error, invalid_body}
    end.

parse_body(<<"application/json", _/binary>>, Body) ->
    {ok, emqx_utils_json:decode(Body, [return_maps])};
parse_body(<<"application/x-www-form-urlencoded", _/binary>>, Body) ->
    Flags = [<<"result">>, <<"is_superuser">>],
    RawMap = maps:from_list(cow_qs:parse_qs(Body)),
    NBody = maps:with(Flags, RawMap),
    {ok, NBody};
parse_body(ContentType, _) ->
    {error, {unsupported_content_type, ContentType}}.

uri_encode(T) ->
    emqx_http_lib:uri_encode(to_list(T)).

request_for_log(Credential, #{url := Url} = State) ->
    SafeCredential = emqx_authn_utils:without_password(Credential),
    case generate_request(SafeCredential, State) of
        {PathQuery, Headers} ->
            #{
                method => post,
                base_url => Url,
                path_query => PathQuery,
                headers => Headers
            };
        {PathQuery, Headers, Body} ->
            #{
                method => post,
                base_url => Url,
                path_query => PathQuery,
                headers => Headers,
                mody => Body
            }
    end.

response_for_log({ok, StatusCode, Headers}) ->
    #{status => StatusCode, headers => Headers};
response_for_log({ok, StatusCode, Headers, Body}) ->
    #{status => StatusCode, headers => Headers, body => Body};
response_for_log({error, Error}) ->
    #{error => Error}.

to_list(A) when is_atom(A) ->
    atom_to_list(A);
to_list(B) when is_binary(B) ->
    binary_to_list(B);
to_list(L) when is_list(L) ->
    L.

to_bin(A) when is_atom(A) ->
    atom_to_binary(A);
to_bin(B) when is_binary(B) ->
    B;
to_bin(L) when is_list(L) ->
    list_to_binary(L).

get_conf_val(Name, Conf) ->
    hocon_maps:get(?CONF_NS ++ "." ++ Name, Conf).

ensure_header_name_type(Headers) ->
    Fun = fun
        (Key, _Val, Acc) when is_binary(Key) ->
            Acc;
        (Key, Val, Acc) when is_atom(Key) ->
            Acc2 = maps:remove(Key, Acc),
            BinKey = erlang:atom_to_binary(Key),
            Acc2#{BinKey => Val}
    end,
    maps:fold(Fun, Headers, Headers).
