-module(hbbft_rbc).

-export([init/2, input/2, handle_msg/3]).

-record(data, {
          state = init :: init | waiting | aborted | done,
          n :: pos_integer(),
          f :: pos_integer(),
          msg = undefined :: binary() | undefined,
          h = undefined :: binary() | undefined,
          shares = [] :: [{merkerl:proof(), {pos_integer(), binary()}}],
          num_echoes = sets:new() :: sets:set(non_neg_integer()),
          num_readies = sets:new() :: sets:set(non_neg_integer()),
          ready_sent = false :: boolean()
         }).

-type val_msg() :: {val, merkerl:hash(), merkerl:proof(), binary()}.
-type echo_msg() :: {echo, merkerl:hash(), merkerl:proof(), binary()}.
-type ready_msg() :: {ready, merkerl:hash()}.

-type multicast() :: {multicast, echo_msg() | ready_msg()}.
-type unicast() :: {unicast, J :: non_neg_integer(), val_msg()}.
-type send_commands() :: [unicast() | multicast()].

%% API.
-spec init(pos_integer(), pos_integer()) -> #data{}.
init(N, F) ->
    #data{n=N, f=F}.

-spec input(#data{}, binary()) -> {#data{}, {send, send_commands()} | {error, already_initialized}}.
input(Data = #data{state=init, n=N, f=F}, Msg) ->
    %% Figure2 from honeybadger WP
    %%%% let {Sj} j∈[N] be the blocks of an (N − 2 f , N)-erasure coding
    %%%% scheme applied to v
    %%%% let h be a Merkle tree root computed over {Sj}
    %%%% send VAL(h, b j , s j ) to each party P j , where b j is the jth
    %%%% Merkle tree branch
    Threshold = N - 2*F,
    {ok, Shards} = leo_erasure:encode({Threshold, N - Threshold}, Msg),
    MsgSize = byte_size(Msg),
    ShardsWithSize = [{MsgSize, Shard} || Shard <- Shards],
    Merkle = merkerl:new(ShardsWithSize, fun merkerl:hash_value/1),
    MerkleRootHash = merkerl:root_hash(Merkle),
    %% gen_proof = branches for each merkle node (Hash(shard))
    BranchesForShards = [merkerl:gen_proof(Hash, Merkle) || {Hash, _} <- merkerl:leaves(Merkle)],
    %% TODO add our identity to the ready/echo sets?
    NewData = Data#data{msg=Msg, h=MerkleRootHash},
    Result = [ {unicast, J, {val, MerkleRootHash, lists:nth(J+1, BranchesForShards), lists:nth(J+1, ShardsWithSize)}} || J <- lists:seq(0, N-1)],
    %% unicast all the VAL packets and multicast the ECHO for our own share
    {NewData#data{state=waiting}, {send, Result ++ [{multicast, {echo, MerkleRootHash, hd(BranchesForShards), hd(ShardsWithSize)}}]}};
input(Data, _Msg) ->
    %% can't init twice
    {Data, {error, already_initialized}}.

handle_msg(Data, _J, {val, H, Bj, Sj}) ->
    val(Data, H, Bj, Sj);
handle_msg(Data, J, {echo, H, Bj, Sj}) ->
    echo(Data, J, H, Bj, Sj);
handle_msg(Data, J, {ready, H}) ->
    ready(Data, J, H).

-spec val(#data{}, merkerl:hash(), merkerl:proof(), binary()) -> {#data{}, ok | {send, send_commands()}}.
val(Data = #data{state=init}, H, Bj, Sj) ->
    NewData = Data#data{h=H, shares=[{Bj, Sj}]},
    {NewData, {send, [{multicast, {echo, H, Bj, Sj}}]}};
val(Data, _H, _Bi, _Si) ->
    %% we already had a val, just ignore this
    {Data, ok}.

-spec echo(#data{}, non_neg_integer(), merkerl:hash(), merkerl:proof(), binary()) -> {#data{}, ok | {send, send_commands()} | {result, V :: binary()} | abort}.
echo(Data = #data{state=aborted}, _J, _H, _Bj, _Sj) ->
    {Data, ok};
echo(Data = #data{state=done}, _J, _H, _Bj, _Sj) ->
    {Data, ok};
echo(Data = #data{n=N, f=F}, J, H, Bj, Sj) ->
    %% Check that Bj is a valid merkle branch for root h and and leaf Sj
    case merkerl:verify_proof(merkerl:hash_value(Sj), H, Bj) of
        ok ->
            NewData = Data#data{h=H, shares=lists:usort([{Bj, Sj}|Data#data.shares]), num_echoes=sets:add_element(J, Data#data.num_echoes)},
            case sets:size(NewData#data.num_echoes) >= (N - F) of
                true ->
                    %% interpolate Sj from any N-2f leaves received
                    Threshold = N - 2*F,
                    {_, ShardsWithSize} = lists:unzip(NewData#data.shares),
                    {_, Shards} = lists:unzip(ShardsWithSize),
                    case leo_erasure:decode({Threshold, N - Threshold}, Shards, element(1, hd(ShardsWithSize))) of
                        {ok, Msg} ->
                            %% recompute merkle root H
                            MsgSize = byte_size(Msg),
                            {ok, AllShards} = leo_erasure:encode({Threshold, N - Threshold}, Msg),
                            AllShardsWithSize = [{MsgSize, Shard} || Shard <- AllShards],
                            Merkle = merkerl:new(AllShardsWithSize, fun merkerl:hash_value/1),
                            MerkleRootHash = merkerl:root_hash(Merkle),
                            case H == MerkleRootHash of
                                true ->
                                    %% root hashes match
                                    %% check if ready already sent
                                    case NewData#data.ready_sent of
                                        true ->
                                            %% check if we have enough readies and enough echoes
                                            %% N-2F echoes and 2F + 1 readies
                                            case sets:size(NewData#data.num_echoes) >= Threshold andalso sets:size(NewData#data.num_readies) >= (2*F + 1) of
                                                true ->
                                                    %% decode V. Done
                                                    {NewData#data{state=done}, {result, Msg}};
                                                false ->
                                                    %% wait for enough echoes and readies?
                                                    {NewData#data{state=waiting, msg=Msg}, ok}
                                            end;
                                        false ->
                                            %% send ready(h)
                                            {NewData#data{state=waiting, msg=Msg, ready_sent=true}, {send, [{multicast, {ready, H}}]}}
                                    end;
                                false ->
                                    %% abort
                                    {NewData#data{state=aborted}, abort}
                            end;
                        {error, _Reason} ->
                            {NewData#data{state=waiting}, ok}
                    end;
                false ->
                    {NewData#data{state=waiting}, ok}
            end;
        {error, _} ->
            %% otherwise discard
            {Data, ok}
    end.


-spec ready(#data{}, non_neg_integer(), merkerl:hash()) -> {#data{}, ok | {send, send_commands()} | {result, V :: binary()}}.
ready(Data = #data{state=waiting, n=N, f=F}, J, H) ->
    %% increment num_readies
    NewData = Data#data{num_readies=sets:add_element(J, Data#data.num_readies)},
    case sets:size(NewData#data.num_readies) >= F + 1 of
        true ->
            Threshold = N - 2*F,
            %% check if we have 2*F + 1 readies and N - 2*F echoes
            case sets:size(NewData#data.num_echoes) >= Threshold andalso sets:size(NewData#data.num_readies) >= 2*F + 1 of
                true ->
                    %% done
                    {NewData#data{state=done}, {result, NewData#data.msg}};
                false when not NewData#data.ready_sent ->
                    %% multicast ready
                    {NewData#data{ready_sent=true}, {send, [{multicast, {ready, H}}]}};
                _ ->
                    {NewData, ok}
            end;
        false ->
            %% waiting
            {NewData, ok}
    end;
ready(Data, _J, _H) ->
    {Data, ok}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

kill(Data) ->
    Data#data{state=aborted}.

init_test() ->
    N = 5,
    F = 1,
    Msg = crypto:strong_rand_bytes(512),
    S0 = hbbft_rbc:init(N, F),
    S1 = hbbft_rbc:init(N, F),
    S2 = hbbft_rbc:init(N, F),
    S3 = hbbft_rbc:init(N, F),
    S4 = hbbft_rbc:init(N, F),
    {NewS0, {send, MsgsToSend}} = hbbft_rbc:input(S0, Msg),
    States = [NewS0, S1, S2, S3, S4],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, [{0, {send, MsgsToSend}}], StatesWithId, sets:new()),
    %% everyone should converge
    ?assertEqual(N, sets:size(ConvergedResults)),
    ok.


pid_dying_test() ->
    N = 5,
    F = 1,
    Msg = crypto:strong_rand_bytes(512),
    S0 = hbbft_rbc:init(N, F),
    S1 = hbbft_rbc:init(N, F),
    S2 = hbbft_rbc:init(N, F),
    S3 = hbbft_rbc:init(N, F),
    S4 = hbbft_rbc:init(N, F),
    {NewS0, {send, MsgsToSend}} = hbbft_rbc:input(S0, Msg),
    States = [NewS0, S1, kill(S2), S3, S4],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, [{0, {send, MsgsToSend}}], StatesWithId, sets:new()),
    %% everyone but the dead node should converge
    ?assertEqual(N - 1, sets:size(ConvergedResults)),
    ok.

two_pid_dying_test() ->
    N = 5,
    F = 1,
    Msg = crypto:strong_rand_bytes(512),
    S0 = hbbft_rbc:init(N, F),
    S1 = hbbft_rbc:init(N, F),
    S2 = hbbft_rbc:init(N, F),
    S3 = hbbft_rbc:init(N, F),
    S4 = hbbft_rbc:init(N, F),
    {NewS0, {send, MsgsToSend}} = hbbft_rbc:input(S0, Msg),
    States = [NewS0, S1, kill(S2), S3, kill(S4)],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, [{0, {send, MsgsToSend}}], StatesWithId, sets:new()),
    %% nobody should converge
    ?assertEqual(0, sets:size(ConvergedResults)),
    ok.
-endif.