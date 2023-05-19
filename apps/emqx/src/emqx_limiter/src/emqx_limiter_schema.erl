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

-module(emqx_limiter_schema).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([
    roots/0,
    fields/1,
    to_rate/1,
    to_capacity/1,
    to_burst/1,
    default_period/0,
    to_burst_rate/1,
    to_initial/1,
    namespace/0,
    get_bucket_cfg_path/2,
    desc/1,
    types/0,
    short_paths/0,
    calc_capacity/1,
    extract_with_type/2,
    default_client_config/0,
    default_bucket_config/0,
    short_paths_fields/1,
    get_listener_opts/1,
    get_node_opts/1,
    convert_node_opts/1
]).

-define(KILOBYTE, 1024).
-define(LISTENER_BUCKET_KEYS, [
    bytes,
    messages,
    connection,
    message_routing
]).

-type limiter_type() ::
    bytes
    | messages
    | connection
    | message_routing
    %% internal limiter for unclassified resources
    | internal.

-type limiter_id() :: atom().
-type bucket_name() :: atom().
-type rate() :: infinity | float().
-type burst_rate() :: number().
%% this is a compatible type for the deprecated field and type `capacity`.
-type burst() :: burst_rate().
%% the capacity of the token bucket
%%-type capacity() :: non_neg_integer().
%% initial capacity of the token bucket
-type initial() :: non_neg_integer().
-type bucket_path() :: list(atom()).

%% the processing strategy after the failure of the token request

%% Forced to pass
-type failure_strategy() ::
    force
    %% discard the current request
    | drop
    %% throw an exception
    | throw.

-typerefl_from_string({rate/0, ?MODULE, to_rate}).
-typerefl_from_string({burst_rate/0, ?MODULE, to_burst_rate}).
-typerefl_from_string({burst/0, ?MODULE, to_burst}).
-typerefl_from_string({initial/0, ?MODULE, to_initial}).

-reflect_type([
    rate/0,
    burst_rate/0,
    burst/0,
    initial/0,
    failure_strategy/0,
    bucket_name/0
]).

-export_type([limiter_id/0, limiter_type/0, bucket_path/0]).

-define(UNIT_TIME_IN_MS, 1000).

namespace() -> limiter.

roots() ->
    [
        {limiter,
            hoconsc:mk(hoconsc:ref(?MODULE, limiter), #{
                importance => ?IMPORTANCE_HIDDEN
            })}
    ].

fields(limiter) ->
    short_paths_fields(?MODULE) ++
        [
            {Type,
                ?HOCON(?R_REF(node_opts), #{
                    desc => ?DESC(Type),
                    importance => ?IMPORTANCE_HIDDEN,
                    required => {false, recursively},
                    aliases => alias_of_type(Type)
                })}
         || Type <- types()
        ] ++
        [
            %% This is an undocumented feature, and it won't be support anymore
            {client,
                ?HOCON(
                    ?R_REF(client_fields),
                    #{
                        desc => ?DESC(client),
                        importance => ?IMPORTANCE_HIDDEN,
                        required => {false, recursively},
                        deprecated => {since, "5.0.25"}
                    }
                )}
        ];
fields(node_opts) ->
    [
        {rate, ?HOCON(rate(), #{desc => ?DESC(rate), default => <<"infinity">>})},
        {burst,
            ?HOCON(burst_rate(), #{
                desc => ?DESC(burst),
                default => <<"0">>
            })}
    ];
fields(client_fields) ->
    client_fields(types());
fields(bucket_opts) ->
    fields_of_bucket(<<"infinity">>);
fields(client_opts) ->
    [
        {rate, ?HOCON(rate(), #{default => <<"infinity">>, desc => ?DESC(rate)})},
        {initial,
            ?HOCON(initial(), #{
                default => <<"0">>,
                desc => ?DESC(initial),
                importance => ?IMPORTANCE_HIDDEN
            })},
        %% low_watermark add for emqx_channel and emqx_session
        %% both modules consume first and then check
        %% so we need to use this value to prevent excessive consumption
        %% (e.g, consumption from an empty bucket)
        {low_watermark,
            ?HOCON(
                initial(),
                #{
                    desc => ?DESC(low_watermark),
                    default => <<"0">>,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {burst,
            ?HOCON(burst(), #{
                desc => ?DESC(burst),
                default => <<"0">>,
                importance => ?IMPORTANCE_HIDDEN,
                aliases => [capacity]
            })},
        {divisible,
            ?HOCON(
                boolean(),
                #{
                    desc => ?DESC(divisible),
                    default => false,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {max_retry_time,
            ?HOCON(
                emqx_schema:duration(),
                #{
                    desc => ?DESC(max_retry_time),
                    default => <<"10s">>,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {failure_strategy,
            ?HOCON(
                failure_strategy(),
                #{
                    desc => ?DESC(failure_strategy),
                    default => force,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )}
    ];
fields(listener_fields) ->
    composite_bucket_fields(?LISTENER_BUCKET_KEYS, listener_client_fields);
fields(listener_client_fields) ->
    client_fields(?LISTENER_BUCKET_KEYS);
fields(Type) ->
    simple_bucket_field(Type).

short_paths_fields(DesModule) ->
    [
        {Name,
            ?HOCON(rate(), #{desc => ?DESC(DesModule, Name), required => false, example => Example})}
     || {Name, Example} <-
            lists:zip(short_paths(), [<<"1000/s">>, <<"1000/s">>, <<"100MB/s">>])
    ].

desc(limiter) ->
    "Settings for the rate limiter.";
desc(node_opts) ->
    "Settings for the limiter of the node level.";
desc(bucket_opts) ->
    "Settings for the bucket.";
desc(client_opts) ->
    "Settings for the client in bucket level.";
desc(client_fields) ->
    "Fields of the client level.";
desc(listener_fields) ->
    "Fields of the listener.";
desc(listener_client_fields) ->
    "Fields of the client level of the listener.";
desc(internal) ->
    "Internal limiter.";
desc(_) ->
    undefined.

%% default period is 100ms
default_period() ->
    100.

to_rate(Str) ->
    to_rate(Str, true, false).

-spec get_bucket_cfg_path(limiter_type(), bucket_name()) -> bucket_path().
get_bucket_cfg_path(Type, BucketName) ->
    [limiter, Type, bucket, BucketName].

types() ->
    [bytes, messages, connection, message_routing, internal].

short_paths() ->
    [max_conn_rate, messages_rate, bytes_rate].

calc_capacity(#{rate := infinity}) ->
    infinity;
calc_capacity(#{rate := Rate, burst := Burst}) ->
    erlang:floor(1000 * Rate / default_period()) + Burst.

extract_with_type(_Type, undefined) ->
    undefined;
extract_with_type(Type, #{client := ClientCfg} = BucketCfg) ->
    BucketVal = maps:find(Type, BucketCfg),
    ClientVal = maps:find(Type, ClientCfg),
    merge_client_bucket(Type, ClientVal, BucketVal);
extract_with_type(Type, BucketCfg) ->
    BucketVal = maps:find(Type, BucketCfg),
    merge_client_bucket(Type, undefined, BucketVal).

%% Since the client configuration can be absent and be a undefined value,
%% but we must need some basic settings to control the behaviour of the limiter,
%% so here add this helper function to generate a default setting.
%% This is a temporary workaround until we found a better way to simplify.
default_client_config() ->
    #{
        rate => infinity,
        initial => 0,
        low_watermark => 0,
        burst => 0,
        divisible => false,
        max_retry_time => timer:seconds(10),
        failure_strategy => force
    }.

default_bucket_config() ->
    #{
        rate => infinity,
        burst => 0,
        initial => 0
    }.

get_listener_opts(Conf) ->
    Limiter = maps:get(limiter, Conf, undefined),
    ShortPaths = maps:with(short_paths(), Conf),
    get_listener_opts(Limiter, ShortPaths).

get_node_opts(Type) ->
    Opts = emqx:get_config([limiter, Type], default_bucket_config()),
    case type_to_short_path_name(Type) of
        undefined ->
            Opts;
        Name ->
            case emqx:get_config([limiter, Name], undefined) of
                undefined ->
                    Opts;
                Rate ->
                    Opts#{rate := Rate}
            end
    end.

convert_node_opts(Conf) ->
    DefBucket = default_bucket_config(),
    ShorPaths = short_paths(),
    Fun = fun
        %% The `client` in the node options was deprecated
        (client, _Value, Acc) ->
            Acc;
        (Name, Value, Acc) ->
            case lists:member(Name, ShorPaths) of
                true ->
                    Type = short_path_name_to_type(Name),
                    Acc#{Type => DefBucket#{rate => Value}};
                _ ->
                    Acc#{Name => Value}
            end
    end,
    maps:fold(Fun, #{}, Conf).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

to_burst_rate(Str) ->
    to_rate(Str, false, true).

%% The default value of `capacity` is `infinity`,
%% but we have changed `capacity` to `burst` which should not be `infinity`
%% and its default value is 0, so we should convert `infinity` to 0
to_burst(Str) ->
    case to_rate(Str, true, true) of
        {ok, infinity} ->
            {ok, 0};
        Any ->
            Any
    end.

%% rate can be: 10 10MB 10MB/s 10MB/2s infinity
%% e.g. the bytes_in regex tree is:
%%
%%        __ infinity
%%        |                 - xMB
%%  rate -|                 |
%%        __ ?Size(/?Time) -|            - xMB/s
%%                          |            |
%%                          - xMB/?Time -|
%%                                       - xMB/ys
to_rate(Str, CanInfinity, CanZero) ->
    Regex = "^\s*(?:([0-9]+[a-zA-Z]*)(?:/([0-9]*)([m s h d M S H D]{1,2}))?\s*$)|infinity\s*$",
    {ok, MP} = re:compile(Regex),
    case re:run(Str, MP, [{capture, all_but_first, list}]) of
        {match, []} when CanInfinity ->
            {ok, infinity};
        %% if time unit is 1s, it can be omitted
        {match, [QuotaStr]} ->
            Fun = fun(Quota) ->
                {ok, Quota * default_period() / ?UNIT_TIME_IN_MS}
            end,
            to_capacity(QuotaStr, Str, CanZero, Fun);
        {match, [QuotaStr, TimeVal, TimeUnit]} ->
            Interval =
                case TimeVal of
                    %% for xM/s
                    [] -> "1" ++ TimeUnit;
                    %% for xM/ys
                    _ -> TimeVal ++ TimeUnit
                end,
            Fun = fun(Quota) ->
                try
                    case emqx_schema:to_duration_ms(Interval) of
                        {ok, Ms} when Ms > 0 ->
                            {ok, Quota * default_period() / Ms};
                        {ok, 0} when CanZero ->
                            {ok, 0};
                        _ ->
                            {error, Str}
                    end
                catch
                    _:_ ->
                        {error, Str}
                end
            end,
            to_capacity(QuotaStr, Str, CanZero, Fun);
        _ ->
            {error, Str}
    end.

to_capacity(QuotaStr, Str, CanZero, Fun) ->
    case to_capacity(QuotaStr) of
        {ok, Val} -> check_capacity(Str, Val, CanZero, Fun);
        {error, _Error} -> {error, Str}
    end.

check_capacity(_Str, 0, true, Cont) ->
    %% must check the interval part or maybe will get incorrect config, e.g. "0/0sHello"
    Cont(0);
check_capacity(Str, 0, false, _Cont) ->
    {error, Str};
check_capacity(_Str, Quota, _CanZero, Cont) ->
    Cont(Quota).

to_capacity(Str) ->
    Regex = "^\s*(?:([0-9]+)([a-zA-Z]*))|infinity\s*$",
    to_quota(Str, Regex).

to_initial(Str) ->
    Regex = "^\s*([0-9]+)([a-zA-Z]*)\s*$",
    to_quota(Str, Regex).

to_quota(Str, Regex) ->
    {ok, MP} = re:compile(Regex),
    try
        Result = re:run(Str, MP, [{capture, all_but_first, list}]),
        case Result of
            {match, [Quota, Unit]} ->
                Val = erlang:list_to_integer(Quota),
                Unit2 = string:to_lower(Unit),
                {ok, apply_unit(Unit2, Val)};
            {match, [Quota, ""]} ->
                {ok, erlang:list_to_integer(Quota)};
            {match, ""} ->
                {ok, infinity};
            _ ->
                {error, Str}
        end
    catch
        _:Error ->
            {error, Error}
    end.

apply_unit("", Val) -> Val;
apply_unit("kb", Val) -> Val * ?KILOBYTE;
apply_unit("mb", Val) -> Val * ?KILOBYTE * ?KILOBYTE;
apply_unit("gb", Val) -> Val * ?KILOBYTE * ?KILOBYTE * ?KILOBYTE;
apply_unit(Unit, _) -> throw("invalid unit:" ++ Unit).

%% A bucket with only one type
simple_bucket_field(Type) when is_atom(Type) ->
    fields(bucket_opts) ++
        [
            {client,
                ?HOCON(
                    ?R_REF(?MODULE, client_opts),
                    #{
                        desc => ?DESC(client),
                        required => {false, recursively},
                        importance => importance_of_type(Type),
                        aliases => alias_of_type(Type)
                    }
                )}
        ].

%% A bucket with multi types
composite_bucket_fields(Types, ClientRef) ->
    [
        {Type,
            ?HOCON(?R_REF(?MODULE, bucket_opts), #{
                desc => ?DESC(?MODULE, Type),
                required => {false, recursively},
                importance => importance_of_type(Type),
                aliases => alias_of_type(Type)
            })}
     || Type <- Types
    ] ++
        [
            {client,
                ?HOCON(
                    ?R_REF(?MODULE, ClientRef),
                    #{
                        desc => ?DESC(client),
                        required => {false, recursively}
                    }
                )}
        ].

fields_of_bucket(Default) ->
    [
        {rate, ?HOCON(rate(), #{desc => ?DESC(rate), default => Default})},
        {burst,
            ?HOCON(burst(), #{
                desc => ?DESC(burst),
                default => <<"0">>,
                importance => ?IMPORTANCE_HIDDEN,
                aliases => [capacity]
            })},
        {initial,
            ?HOCON(initial(), #{
                default => <<"0">>,
                desc => ?DESC(initial),
                importance => ?IMPORTANCE_HIDDEN
            })}
    ].

client_fields(Types) ->
    [
        {Type,
            ?HOCON(?R_REF(client_opts), #{
                desc => ?DESC(Type),
                required => false,
                importance => importance_of_type(Type),
                aliases => alias_of_type(Type)
            })}
     || Type <- Types
    ].

importance_of_type(interval) ->
    ?IMPORTANCE_HIDDEN;
importance_of_type(message_routing) ->
    ?IMPORTANCE_HIDDEN;
importance_of_type(connection) ->
    ?IMPORTANCE_HIDDEN;
importance_of_type(_) ->
    ?DEFAULT_IMPORTANCE.

alias_of_type(messages) ->
    [message_in];
alias_of_type(bytes) ->
    [bytes_in];
alias_of_type(_) ->
    [].

merge_client_bucket(Type, {ok, ClientVal}, {ok, BucketVal}) ->
    #{Type => BucketVal, client => #{Type => ClientVal}};
merge_client_bucket(Type, {ok, ClientVal}, _) ->
    #{client => #{Type => ClientVal}};
merge_client_bucket(Type, _, {ok, BucketVal}) ->
    #{Type => BucketVal};
merge_client_bucket(_, _, _) ->
    undefined.

short_path_name_to_type(max_conn_rate) ->
    connection;
short_path_name_to_type(messages_rate) ->
    messages;
short_path_name_to_type(bytes_rate) ->
    bytes.

type_to_short_path_name(connection) ->
    max_conn_rate;
type_to_short_path_name(messages) ->
    messages_rate;
type_to_short_path_name(bytes) ->
    bytes_rate;
type_to_short_path_name(_) ->
    undefined.

get_listener_opts(Limiter, ShortPaths) when map_size(ShortPaths) =:= 0 ->
    Limiter;
get_listener_opts(undefined, ShortPaths) ->
    convert_listener_short_paths(ShortPaths);
get_listener_opts(Limiter, ShortPaths) ->
    Shorts = convert_listener_short_paths(ShortPaths),
    emqx_utils_maps:deep_merge(Limiter, Shorts).

convert_listener_short_paths(ShortPaths) ->
    DefBucket = default_bucket_config(),
    DefClient = default_client_config(),
    Fun = fun(Name, Rate, Acc) ->
        Type = short_path_name_to_type(Name),
        case Name of
            max_conn_rate ->
                Acc#{Type => DefBucket#{rate => Rate}};
            _ ->
                Client = maps:get(client, Acc, #{}),
                Acc#{client => Client#{Type => DefClient#{rate => Rate}}}
        end
    end,
    maps:fold(Fun, #{}, ShortPaths).
