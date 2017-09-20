-module(n2o_vnode).
-license('ISC').
-copyright('Synrc Research Center').
-description('N2O Remote: Virtual Node Server').
-author('Maxim Sokhatsky').
-include("n2o.hrl").
-compile(export_all).

% N2O VNODE SERVER for MQTT

debug(Name,Topic,BERT,Address,Return) ->
    case application:get_env(n2o,dump_loop,no) of
         yes ->
    io:format("VNODE:~p Message on topic ~tp.\r~n", [Name, Topic]),
    io:format("BERT: ~tp\r~nAddress: ~p\r~n",[BERT,Address]),
    io:format("on_message_publish1: ~s.\r~n", [Topic]),
    case Return of
          {error,R} -> io:format("ERROR: ~p~n",[R]); _ -> skip end,
                ok;
           _ -> skip end.

send(C,T,M) -> send(C, T, M, [{qos,2}]).
send(C,T,M,Opts) -> emqttc:publish(C, T, M, Opts).

fix('') -> index;
fix(<<"index">>) -> index;
fix(Module) -> list_to_atom(binary_to_list(Module)).

gen_name(Pos) when is_integer(Pos) -> gen_name(integer_to_list(Pos));
gen_name(Pos) -> iolist_to_binary([lists:flatten([io_lib:format("~2.16.0b",[X])
              || <<X:8>> <= list_to_binary(atom_to_list(node())++"_"++Pos)])]).

proc(init,#handler{name=Name}=Async) ->
    io:format("VNode Init: ~p\r~n",[Name]),
    {ok, C} = emqttc:start_link([{host, "127.0.0.1"},
                                 {client_id, gen_name(Name)},
                                 {clean_sess, false},
                                 {logger, {console, error}},
                                 {reconnect, 5}]),
    {ok,Async#handler{state=C,seq=0}};

proc({publish, To, Request},
    State  = #handler{name=Name,state=C,seq=S}) ->
    Addr   = emqttd_topic:words(To),
    Bert   = binary_to_term(Request,[safe]),
    Return = case Addr of
        [ Origin, Vsn, Node, Module, Username, Id, Token | _ ] ->
        From = nitro:to_binary(["actions/", Vsn, "/", Module, "/", Id]),
        Sid  = nitro:to_binary(Token),
        Ctx  = #cx { module=fix(Module), session=Sid, node=Node,
                     params=Id, client_pid=C, from = From, vsn = Vsn},
        put(context, Ctx),
        case n2o_proto:info(Bert,[],Ctx) of
             {reply,{bert,  <<>>},_,_} -> skip;
             {reply,{json,  <<>>},_,_} -> skip;
             {reply,{binary,<<>>},_,_} -> skip;
             {reply,{bert,  Term},_,#cx{from=X}} -> {ok,send(C,X,n2o_bert:format(Term))};
             {reply,{json,  Term},_,#cx{from=X}} -> {ok,send(C,X,n2o_json:format(Term))};
             {reply,{binary,Term},_,#cx{from=X}} -> {ok,send(C,X,Term)};
             Reply -> {error,{"Invalid Return",Reply}} end;
              Addr -> {error,{"Unknown Address",Addr}} end,
    debug(Name,To,Bert,Addr,Return),
    {reply, Return, State#handler{seq=S+1}};

proc({mqttc, C, connected}, State=#handler{name=Name,state=C,seq=S}) ->
    emqttc:subscribe(C, nitro:to_binary([<<"events/+/">>, nitro:to_list(Name),"/#"]), 2),
    {ok, State#handler{seq = S+1}};

proc(Unknown,#handler{state=C,name=Name,seq=S}=Async) ->
%    io:format("VNODE ~p Unknown Message: ~p\r~n",[Name,Unknown]),
    {reply,{uknown,Unknown,S},Async#handler{seq=S+1}}.
