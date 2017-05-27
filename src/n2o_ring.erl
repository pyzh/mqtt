-module(n2o_ring).
-description('Ring Master').
-copyright('Synrc Research Center s.r.o.').
-compile(export_all).
-define(DEFRING, 4).
-define(RINGTOP, trunc(math:pow(2,160)-1)). % SHA-1 space

init() -> application:set_env(n2o,peers,[{  'cr@127.0.0.1',9000,9001,9002},
                                         { 'cr2@127.0.0.1',9004,9005,9006},
                                         { 'cr3@127.0.0.1',9008,9009,9010}]).

key_of(Object) -> crypto:hash(sha, term_to_binary(Object)).
inc(N) -> ?RINGTOP div N.
fresh(N, Seed) -> {N, [{Int,Seed} || Int <- lists:seq(0,(?RINGTOP-1),inc(N))]}.
succ(Idx,{N,Nodes}) -> <<Int:160/integer>> =Idx, {A,B}=lists:split((Int div inc(N))+1,Nodes), B++A.
hash(Object)   -> hd(seq(Object)).
rep(Object)    -> roll(element(2,hash(Object))).
roll(N)        -> lists:seq(N,length(peers())) ++ lists:seq(1,N-1).
seq(Object)    -> lists:keydelete(0,1,succ(key_of(Object),ring())).
ring()         -> ring(?DEFRING).
ring(C)        -> {Nodes,[{0,1}|Rest]} = fresh(length(peers())*C,1),
                  {Nodes,[{0,0}|lists:map(fun({{I,1},X})->{I,(X-1) div C+1} end,
                                lists:zip(Rest,lists:seq(1,length(Rest))))]}.
chain(Object) ->
    {N,_} = ring(),
    lists:map(fun(X) -> lists:nth((X-1)*?DEFRING+1,seq(Object)) end,
              roll(element(2,hash(Object)))).

peers()        -> {ok,Peers}=application:get_env(n2o,peers),Peers.
peers(N)       -> lists:zip(lists:seq(1,N),lists:seq(1,N)).
