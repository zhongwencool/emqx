%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ds_shared_sub_leader_store).

-include_lib("emqx_utils/include/emqx_message.hrl").
-include_lib("emqx_durable_storage/include/emqx_ds.hrl").
-include_lib("snabbkaffe/include/trace.hrl").

-export([
    open/0,
    close/0
]).

%% Leadership API
-export([
    %% Leadership claims
    claim_leadership/3,
    renew_leadership/3,
    disown_leadership/2,
    %% Accessors
    leader_id/1,
    alive_until/1,
    heartbeat_interval/1
]).

%% Store API
-export([
    %% Lifecycle
    init/1,
    open/1,
    %% TODO
    %% destroy/1,
    %% Managing records
    get/3,
    get/4,
    fold/4,
    size/2,
    put/4,
    get/2,
    set/3,
    delete/3,
    dirty/1,
    commit_dirty/2,
    commit_renew/3
]).

-export_type([
    t/0,
    leader_claim/1
]).

-type group() :: binary().
-type leader_claim(ID) :: {ID, _Heartbeat :: emqx_message:timestamp()}.

-define(DS_DB, dqleader).

-define(LEADER_TTL, 30_000).
-define(LEADER_HEARTBEAT_INTERVAL, 10_000).

-define(LEADER_TOPIC_PREFIX, <<"$leader">>).
-define(LEADER_HEADER_HEARTBEAT, <<"$leader.ts">>).

-define(STORE_TOPIC_PREFIX, <<"$s">>).

-define(STORE_SK(SPACE, KEY), [SPACE | KEY]).
-define(STORE_PAYLOAD(ID, VALUE), [ID, VALUE]).
-define(STORE_BATCH_SIZE, 500).
-define(STORE_TOMBSTONE, '$tombstone').

%%

open() ->
    emqx_ds:open_db(?DS_DB, db_config()).

close() ->
    emqx_ds:close_db(?DS_DB).

db_config() ->
    Config = emqx_ds_schema:db_config([durable_storage, queues]),
    Config#{
        force_monotonic_timestamps => false
    }.

%%

-spec claim_leadership(group(), ID, emqx_message:timestamp()) ->
    {ok | exists, leader_claim(ID)} | emqx_ds:error(_).
claim_leadership(Group, LeaderID, TS) ->
    LeaderClaim = {LeaderID, TS},
    case try_replace_leader(Group, LeaderClaim, undefined) of
        ok ->
            {ok, LeaderClaim};
        {exists, ExistingClaim = {_, LastHeartbeat}} when LastHeartbeat > TS - ?LEADER_TTL ->
            {exists, ExistingClaim};
        {exists, ExistingClaim = {_LeaderDead, _}} ->
            case try_replace_leader(Group, LeaderClaim, ExistingClaim) of
                ok ->
                    {ok, LeaderClaim};
                {exists, ConcurrentClaim} ->
                    {exists, ConcurrentClaim};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec renew_leadership(group(), leader_claim(ID), emqx_message:timestamp()) ->
    {ok | exists, leader_claim(ID)} | emqx_ds:error(_).
renew_leadership(Group, LeaderClaim, TS) ->
    RenewedClaim = renew_claim(LeaderClaim, TS),
    case RenewedClaim =/= false andalso try_replace_leader(Group, RenewedClaim, LeaderClaim) of
        ok ->
            {ok, RenewedClaim};
        {exists, NewestClaim} ->
            {exists, NewestClaim};
        false ->
            {error, unrecoverable, leader_claim_outdated};
        Error ->
            Error
    end.

-spec renew_claim(leader_claim(ID), emqx_message:timestamp()) -> leader_claim(ID) | false.
renew_claim({LeaderID, LastHeartbeat}, TS) ->
    RenewedClaim = {LeaderID, TS},
    IsRenewable = (LastHeartbeat > TS - ?LEADER_TTL),
    IsRenewable andalso RenewedClaim.

-spec disown_leadership(group(), leader_claim(_ID)) ->
    ok | emqx_ds:error(_).
disown_leadership(Group, LeaderClaim) ->
    try_delete_leader(Group, LeaderClaim).

-spec leader_id(leader_claim(ID)) ->
    ID.
leader_id({LeaderID, _}) ->
    LeaderID.

-spec alive_until(leader_claim(_)) ->
    emqx_message:timestamp().
alive_until({_LeaderID, LastHeartbeatTS}) ->
    LastHeartbeatTS + ?LEADER_TTL.

-spec heartbeat_interval(leader_claim(_)) ->
    _Milliseconds :: pos_integer().
heartbeat_interval(_) ->
    ?LEADER_HEARTBEAT_INTERVAL.
try_replace_leader(Group, LeaderClaim, ExistingClaim) ->
    Batch = #dsbatch{
        preconditions = [mk_precondition(Group, ExistingClaim)],
        operations = [encode_leader_claim(Group, LeaderClaim)]
    },
    case emqx_ds:store_batch(?DS_DB, Batch, #{sync => true}) of
        ok ->
            ok;
        {error, unrecoverable, {precondition_failed, Mismatch}} ->
            {exists, decode_leader_msg(Mismatch)};
        Error ->
            Error
    end.

try_delete_leader(Group, LeaderClaim) ->
    {_Cond, Matcher} = mk_precondition(Group, LeaderClaim),
    emqx_ds:store_batch(?DS_DB, #dsbatch{operations = [{delete, Matcher}]}, #{sync => false}).

mk_precondition(Group, undefined) ->
    {unless_exists, #message_matcher{
        from = Group,
        topic = mk_leader_topic(Group),
        timestamp = 0,
        payload = '_'
    }};
mk_precondition(Group, {Leader, HeartbeatTS}) ->
    {if_exists, #message_matcher{
        from = Group,
        topic = mk_leader_topic(Group),
        timestamp = 0,
        payload = encode_leader(Leader),
        headers = #{?LEADER_HEADER_HEARTBEAT => HeartbeatTS}
    }}.

encode_leader_claim(Group, {Leader, HeartbeatTS}) ->
    #message{
        id = <<>>,
        qos = 0,
        from = Group,
        topic = mk_leader_topic(Group),
        timestamp = 0,
        payload = encode_leader(Leader),
        headers = #{?LEADER_HEADER_HEARTBEAT => HeartbeatTS}
    }.

decode_leader_msg(#message{from = _Group, payload = Payload, headers = Headers}) ->
    Leader = decode_leader(Payload),
    Heartbeat = maps:get(?LEADER_HEADER_HEARTBEAT, Headers, 0),
    {Leader, Heartbeat}.

encode_leader(Leader) ->
    %% NOTE: Lists are compact but easy to extend later.
    term_to_binary([Leader]).

decode_leader(Payload) ->
    [Leader | _Extra] = binary_to_term(Payload),
    Leader.

mk_leader_topic(GroupName) ->
    emqx_topic:join([?LEADER_TOPIC_PREFIX, GroupName]).

%%

-type space_name() :: stream | sequence.
-type var_name() :: start_time | rank_progress | seqnum.
-type space_key() :: nonempty_improper_list(space_name(), _Key).

%% NOTE
%% Instances of `emqx_ds:stream()` type are persisted in durable storage.
%% Given that streams are opaque and identity of a stream is stream itself (i.e.
%% if S1 =:= S2 then both are the same stream), it's critical to keep the "shape"
%% of the term intact between releases. Otherwise, if it changes then we will
%% need an additional API to deal with that (e.g. `emqx_ds:term_to_stream/2`).
%% Instances of `emqx_ds:iterator()` are also persisted in durable storage,
%% but those already has similar requirement because in some backends they travel
%% in RPCs between different nodes of potentially different releases.
-type t() :: #{
    %% General.
    group := group(),
    %% Spaces and variables: most up-to-date in-memory state.
    stream := #{emqx_ds:stream() => _StreamState},
    start_time => _SubsriptionStartTime :: emqx_message:timestamp(),
    rank_progress => _RankProgress,
    %% Internal _sequence number_ variable.
    seqnum => integer(),
    %% Mapping between complex keys and seqnums.
    seqmap := #{space_key() => _SeqNum :: integer()},
    %% Stage: uncommitted changes.
    stage := #{space_key() | var_name() => _Value}
}.

-spec init(group()) -> t().
init(Group) ->
    set(seqnum, 0, mk_store(Group)).

-spec open(group()) -> t() | false.
open(Group) ->
    open_store(mk_store(Group)).

mk_store(Group) ->
    #{
        group => Group,
        stream => #{},
        seqmap => #{},
        stage => #{}
    }.

open_store(Store = #{group := Group}) ->
    %% TODO: Unavailability concerns.
    TopicFilter = mk_store_wildcard(Group),
    Streams = emqx_ds:get_streams(?DS_DB, TopicFilter, _StartTime = 0),
    Streams =/= [] andalso
        ds_streams_fold(
            fun(Message, StoreAcc) -> open_message(Message, StoreAcc) end,
            Store,
            Streams,
            TopicFilter,
            0
        ).

-spec get(space_name(), _ID, t()) -> _Value.
get(SpaceName, ID, Store) ->
    Space = maps:get(SpaceName, Store),
    maps:get(ID, Space).

-spec get(space_name(), _ID, Default, t()) -> _Value | Default.
get(SpaceName, ID, Default, Store) ->
    Space = maps:get(SpaceName, Store),
    maps:get(ID, Space, Default).

-spec fold(space_name(), fun((_ID, _Value, Acc) -> Acc), Acc, t()) -> Acc.
fold(SpaceName, Fun, Acc, Store) ->
    Space = maps:get(SpaceName, Store),
    maps:fold(Fun, Acc, Space).

-spec size(space_name(), t()) -> non_neg_integer().
size(SpaceName, Store) ->
    map_size(maps:get(SpaceName, Store)).

-spec put(space_name(), _ID, _Value, t()) -> t().
put(SpaceName, ID, Value, Store0 = #{stage := Stage}) ->
    Space0 = maps:get(SpaceName, Store0),
    Space1 = maps:put(ID, Value, Space0),
    SK = ?STORE_SK(SpaceName, ID),
    Store1 = Store0#{
        SpaceName := Space1,
        stage := Stage#{SK => Value}
    },
    case map_size(Space1) of
        S when S > map_size(Space0) ->
            assign_seqnum(SK, Store1);
        _ ->
            Store1
    end.

assign_seqnum(SK, Store0 = #{seqmap := SeqMap}) ->
    SeqNum = get(seqnum, Store0) + 1,
    Store1 = set(seqnum, SeqNum, Store0),
    Store1#{
        seqmap := maps:put(SK, SeqNum, SeqMap)
    }.

get_seqnum(?STORE_SK(_SpaceName, _) = SK, SeqMap) ->
    maps:get(SK, SeqMap);
get_seqnum(_VarName, _SeqMap) ->
    0.

-spec get(var_name(), t()) -> _Value.
get(VarName, Store) ->
    maps:get(VarName, Store).

-spec set(var_name(), _Value, t()) -> t().
set(VarName, Value, Store0 = #{stage := Stage}) ->
    Store0#{
        VarName => Value,
        stage := Stage#{VarName => Value}
    }.

-spec delete(space_name(), _ID, t()) -> t().
delete(SpaceName, ID, Store = #{stage := Stage, seqmap := SeqMap}) ->
    Space0 = maps:get(SpaceName, Store),
    Space1 = maps:remove(ID, Space0),
    case map_size(Space1) of
        S when S < map_size(Space0) ->
            SK = ?STORE_SK(SpaceName, ID),
            Store#{
                SpaceName := Space1,
                stage := Stage#{SK => ?STORE_TOMBSTONE},
                seqmap := maps:remove(SK, SeqMap)
            };
        _ ->
            Store
    end.

-spec dirty(t()) -> boolean().
dirty(#{stage := Stage}) ->
    map_size(Stage) > 0.

%% @doc Commit staged changes to the storage.
%% Does nothing if there are no staged changes.
-spec commit_dirty(leader_claim(_), t()) ->
    {ok, t()} | emqx_ds:error(_).
commit_dirty(_LeaderClaim, Store = #{stage := Stage}) when map_size(Stage) =:= 0 ->
    {ok, Store};
commit_dirty(LeaderClaim, Store = #{group := Group}) ->
    Operations = mk_store_operations(Store),
    Batch = mk_store_batch(Group, LeaderClaim, Operations),
    case emqx_ds:store_batch(?DS_DB, Batch, #{sync => true}) of
        ok ->
            {ok, Store#{stage := #{}}};
        {error, unrecoverable, {precondition_failed, Mismatch}} ->
            {error, unrecoverable, {leadership_lost, decode_leader_msg(Mismatch)}};
        Error ->
            Error
    end.

%% @doc Commit staged changes and renew leadership at the same time.
%% Goes to the storage even if there are no staged changes.
-spec commit_renew(leader_claim(ID), emqx_message:timestamp(), t()) ->
    {ok, leader_claim(ID), t()} | emqx_ds:error(_).
commit_renew(LeaderClaim, TS, Store = #{group := Group}) ->
    case renew_claim(LeaderClaim, TS) of
        RenewedClaim when RenewedClaim =/= false ->
            Operations = mk_store_operations(Store),
            Batch = mk_store_batch(Group, LeaderClaim, RenewedClaim, Operations),
            case emqx_ds:store_batch(?DS_DB, Batch, #{sync => true}) of
                ok ->
                    {ok, RenewedClaim, Store#{stage := #{}}};
                {error, unrecoverable, {precondition_failed, Mismatch}} ->
                    {error, unrecoverable, {leadership_lost, decode_leader_msg(Mismatch)}};
                Error ->
                    Error
            end;
        false ->
            {error, unrecoverable, leader_claim_outdated}
    end.

mk_store_batch(Group, LeaderClaim, Operations) ->
    #dsbatch{
        preconditions = [mk_precondition(Group, LeaderClaim)],
        operations = Operations
    }.

mk_store_batch(Group, ExistingClaim, RenewedClaim, Operations) ->
    #dsbatch{
        preconditions = [mk_precondition(Group, ExistingClaim)],
        operations = [encode_leader_claim(Group, RenewedClaim) | Operations]
    }.

mk_store_operations(#{group := Group, stage := Stage, seqmap := SeqMap}) ->
    maps:fold(
        fun(SK, Value, Acc) ->
            [mk_store_operation(Group, SK, Value, SeqMap) | Acc]
        end,
        [],
        Stage
    ).

mk_store_operation(Group, SK, ?STORE_TOMBSTONE, SeqMap) ->
    {delete, #message_matcher{
        from = Group,
        topic = mk_store_topic(Group, SK, SeqMap),
        payload = '_',
        timestamp = get_seqnum(SK, SeqMap)
    }};
mk_store_operation(Group, SK, Value, SeqMap) ->
    %% NOTE
    %% Using `SeqNum` as timestamp to further disambiguate one record (message) from
    %% another in the DS DB keyspace. As an example, Skipstream-LTS storage layout
    %% _requires_ messages in the same stream to have unique timestamps.
    %% TODO
    %% Do we need to have wall-clock timestamp here?
    Payload = mk_store_payload(SK, Value),
    #message{
        id = <<>>,
        qos = 0,
        from = Group,
        topic = mk_store_topic(Group, SK, SeqMap),
        payload = term_to_binary(Payload),
        timestamp = get_seqnum(SK, SeqMap)
    }.

open_message(Msg = #message{topic = Topic, payload = Payload, timestamp = SeqNum}, Store) ->
    try
        case emqx_topic:tokens(Topic) of
            [_Prefix, _Group, SpaceTok, _SeqTok] ->
                SpaceName = token_to_space(SpaceTok),
                ?STORE_PAYLOAD(ID, Value) = binary_to_term(Payload),
                open_message(SpaceName, ID, SeqNum, Value, Store);
            [_Prefix, _Group, VarTok] ->
                VarName = token_to_varname(VarTok),
                Value = binary_to_term(Payload),
                open_message(VarName, Value, Store)
        end
    catch
        error:_ ->
            ?tp(warning, "dssubs_leader_store_unrecognized_message", #{
                group => maps:get(group, Store),
                message => Msg
            })
    end.

open_message(SpaceName, ID, SeqNum, Value, Store = #{seqmap := SeqMap}) ->
    Space0 = maps:get(SpaceName, Store),
    Space1 = maps:put(ID, Value, Space0),
    SK = ?STORE_SK(SpaceName, ID),
    Store#{
        SpaceName := Space1,
        seqmap := SeqMap#{SK => SeqNum}
    }.

open_message(VarName, Value, Store) ->
    Store#{VarName => Value}.

mk_store_payload(?STORE_SK(_SpaceName, ID), Value) ->
    ?STORE_PAYLOAD(ID, Value);
mk_store_payload(_VarName, Value) ->
    Value.

mk_store_topic(GroupName, ?STORE_SK(SpaceName, _) = SK, SeqMap) ->
    SeqNum = get_seqnum(SK, SeqMap),
    SeqTok = integer_to_binary(SeqNum),
    emqx_topic:join([?STORE_TOPIC_PREFIX, GroupName, space_to_token(SpaceName), SeqTok]);
mk_store_topic(GroupName, VarName, _SeqMap) ->
    emqx_topic:join([?STORE_TOPIC_PREFIX, GroupName, varname_to_token(VarName)]).

mk_store_wildcard(GroupName) ->
    [?STORE_TOPIC_PREFIX, GroupName, '#'].

ds_streams_fold(Fun, AccIn, Streams, TopicFilter, StartTime) ->
    lists:foldl(
        fun({_Rank, Stream}, Acc) ->
            ds_stream_fold(Fun, Acc, Stream, TopicFilter, StartTime)
        end,
        AccIn,
        Streams
    ).

ds_stream_fold(Fun, Acc, Stream, TopicFilter, StartTime) ->
    %% TODO: Gracefully handle `emqx_ds:error(_)`?
    {ok, It} = emqx_ds:make_iterator(?DS_DB, Stream, TopicFilter, StartTime),
    ds_stream_fold(Fun, Acc, It).

ds_stream_fold(Fun, Acc0, It0) ->
    %% TODO: Gracefully handle `emqx_ds:error(_)`?
    case emqx_ds:next(?DS_DB, It0, ?STORE_BATCH_SIZE) of
        {ok, It, Messages = [_ | _]} ->
            Acc1 = lists:foldl(fun({_Key, Msg}, Acc) -> Fun(Msg, Acc) end, Acc0, Messages),
            ds_stream_fold(Fun, Acc1, It);
        {ok, _It, []} ->
            Acc0;
        {ok, end_of_stream} ->
            Acc0
    end.

%%

space_to_token(stream) -> <<"s">>;
space_to_token(progress) -> <<"prog">>;
space_to_token(sequence) -> <<"seq">>.

token_to_space(<<"s">>) -> stream;
token_to_space(<<"prog">>) -> progress;
token_to_space(<<"seq">>) -> sequence.

varname_to_token(rank_progress) -> <<"rankp">>;
varname_to_token(start_time) -> <<"stime">>;
varname_to_token(seqnum) -> <<"seqn">>.

token_to_varname(<<"rankp">>) -> rank_progress;
token_to_varname(<<"stime">>) -> start_time;
token_to_varname(<<"seqn">>) -> seqnum.
