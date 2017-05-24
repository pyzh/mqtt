-module(n2o_session).
-compile(export_all).


authenticate(ClientSessionId,ClientSessionToken) ->
    io:format("Session Init ClientId ~p: Token ~p~n",[ClientSessionId,ClientSessionToken]),
    Lookup = lookup_ets({ClientSessionToken,<<"auth">>}),
    Expiration = till(calendar:local_time(), ttl()),
    SessionToken = case Lookup of
        undefined ->
            Token = {{generate_sid(),<<"auth">>},os:timestamp(),Expiration},
            ets:insert(cookies,Token),
            io:format("Auth Token New: ~p~n", [Token]),
            Token;
        {{TokenValue,Key},Issued,Till} ->
            case expired(Issued,Till) of
                false ->
                    Token = {{TokenValue,Key},Issued,Till},
                    io:format("Auth Token Ok: ~p~n", [Token]),
                    Token;
                true ->
                    Token = {{generate_sid(),<<"auth">>},os:timestamp(),Expiration},
                    delete_old_token(TokenValue),
                    ets:insert(cookies,Token),
                    io:format("Auth Token Expired: ~p~nGenerated new token ~p~n", [TokenValue, Token]),
                    Token end;
        What -> io:format("Auth Cookie Error: ~p~n",[What])
    end,
% ?????????????????????????????????????????
%    {{ID,_},_,_,_,_} = SessionCookie,
%    put(session_id,ID),
    {ok, SessionToken}.

expired(_Issued,Till) -> Till < calendar:local_time().

lookup_ets(Key) ->
    Res = ets:lookup(cookies,Key),
    io:format("Lookup ETS: ~p~n",[{Res,Key}]),
    case Res of
         [] -> undefined;
         [Value] -> Value;
         Values -> Values end.

delete_old_token(Session) ->
    [ ets:delete(cookies,X) || X <- ets:select(cookies,
        ets:fun2ms(fun(A) when (element(1,element(1,A)) == Session) -> element(1,A) end)) ].

ttl() -> application:get_env(n2o,ttl,60*15).

till(Now,TTL) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(Now) + TTL).

generate_sid() ->
    wf_convert:hex(binary:part(crypto:hmac(application:get_env(n2o,hmac,sha256),
         n2o_secret:secret(),term_to_binary(os:timestamp())),0,16)).

% ?????????????????????? invalidate session ??????????????????????
session_id() -> get(session_id).

invalidate_sessions() ->
    ets:foldl(fun(X,A) -> {Sid,Key} = element(1,X), n2o_session:get_value(Sid,Key,undefined), A end, 0, cookies).

get_value(Key, DefaultValue) ->
    get_value(session_id(), Key, DefaultValue).

get_value(SID, Key, DefaultValue) ->
    Res = case lookup_ets({SID,Key}) of
               undefined -> DefaultValue;
               {{SID,Key},_,Issued,Till,Value} -> case expired(Issued,Till) of
                       false -> Value;
                       true -> ets:delete(cookies,{SID,Key}), DefaultValue end end,
    Res.