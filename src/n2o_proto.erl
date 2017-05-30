-module(n2o_proto).
-description('N2O Federation: NITRO, FTP').
-license('ISC').
-author('Maxim Sokhatsky').
-include("n2o.hrl").
-compile(export_all).

formatter(O)       -> case lists:keyfind(formatter,1,O) of {formatter,F} -> F; X -> X end.
protocols()        -> application:get_env(n2o,protocols,[ n2o_nitro ]).
info(M,R,S)        -> filter(M,R,S,protocols(),[]).
filter(M,R,S,P,A)  -> {Mod,Fun} = (application:get_env(n2o,filter,{?MODULE,push})),
                      put(context,S),
                      Mod:Fun(M,R,S,P,A).

nop(R,S)                  -> {reply,{binary,<<>>},R,S}.
reply(M,R,S)              -> {reply,M,R,S}.
push(_,R,S,[],_)          -> nop(R,S);
push(M,R,S,[H|T],Acc)     ->
    case H:info(M,R,S) of
         {unknown,_,_,_}  -> push(M,R,S,T,Acc);
         {reply,M1,R1,S1} -> reply(M1,R1,S1);
                        A -> push(M,R,S,T,[A|Acc]) end.
