-module(n2o_session).
-compile(export_all).


authenticate(ClientSessionId, ClientSessionToken) ->
    io:format("Session Init ~nClientId ~p: Token ~p~n~n", [ClientSessionId, ClientSessionToken]),
    Expiration = till(calendar:local_time(), ttl()),
    Response = case ClientSessionToken of
        [] ->
            NewSID = generate_sid(),
            ClientToken = encode_token(NewSID),
            io:format("1 ~p~n~n", [ClientToken]),
            Token = {{NewSID,<<"auth">>},os:timestamp(),Expiration},
            ets:insert(cookies,Token),
            io:format("Auth Token New: ~p~n~p~n~n", [Token, ClientToken]),
            {ok, ClientToken};
        ExistingToken ->
            SessionId = decode_token(ClientSessionToken),
            case SessionId of
                undefined -> {fail, "Invalid token signature"};
                Val ->
                 Lookup = lookup_ets({SessionId,<<"auth">>}),
                 InnerResponse = case Lookup of
                    undefined -> {fail, "Invalid authentication token"};
                    {{TokenValue,Key},Issued,Till} ->
                        case expired(Issued,Till) of
                            false ->
                                Token = {{TokenValue,Key},Issued,Till},
                                io:format("Auth Token Ok: ~p~n", [Token]),
                                {ok, ExistingToken};
                            true ->
                                UpdatedSID = generate_sid(),
                                UpdatedClientToken = encode_token(UpdatedSID),
                                Token = {{UpdatedSID,<<"auth">>},os:timestamp(),Expiration},
                                delete_old_token(TokenValue),
                                ets:insert(cookies,Token),
                                io:format("Auth Token Expired: ~p~nGenerated new token ~p~n", [TokenValue, Token]),
                                {ok, UpdatedClientToken} end;
                    What -> io:format("Auth Cookie Error: ~p~n",[What]), {fail, What} end,
             InnerResponse end
        end,
    Response.

encode_token(Data) ->
    n2o_secret:pickle(Data).

decode_token(Data) ->
    Res = n2o_secret:depickle(Data),
    case Res of
        <<>> -> undefined;
        Value -> Value end.

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
    nitro_conv:hex(binary:part(crypto:hmac(application:get_env(n2o,hmac,sha256),
         n2o_secret:secret(),term_to_binary(os:timestamp())),0,16)).

session_id() -> get(session_id).

invalidate_sessions() ->
    ets:foldl(fun(X,A) -> {Sid,Key} = element(1,X), get_value(Sid,Key,undefined), A end, 0, cookies).

get_value(Key, DefaultValue) ->
    get_value(session_id(), Key, DefaultValue).

get_value(SID, Key, DefaultValue) ->
    Res = case lookup_ets({SID,Key}) of
               undefined -> DefaultValue;
               {{SID,Key},_,Issued,Till,Value} -> case expired(Issued,Till) of
                       false -> Value;
                       true -> ets:delete(cookies,{SID,Key}), DefaultValue end end,
    Res.
