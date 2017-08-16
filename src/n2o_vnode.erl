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
fix(<<"index">>) -> index;
fix(Module) ->
  %io:format("Module: ~p~n",[Module]),
  list_to_atom(binary_to_list(Module)).

% Performed on VNODE init
gen_name(Pos) when is_integer(Pos)->
    gen_name(integer_to_list(Pos));
gen_name(Pos) ->
    iolist_to_binary([lists:flatten([io_lib:format("~2.16.0b",[X]) || <<X:8>> <= list_to_binary(atom_to_list(node())++"_"++Pos)])]).
%%    n2o_secret:pickle(atom_to_list(node())++Pos).

proc(init,#handler{name=Name}=Async) ->
    io:format("VNode Init: ~p\r~n",[Name]),
    {ok, C} = emqttc:start_link([{host, "127.0.0.1"},
                                 {client_id, gen_name(Name)},
                                 {clean_sess, false},
                                 {logger, {console, error}},
                                 {reconnect, 5}]),
    {ok,Async#handler{state=C,seq=0}};

% RPC over MQTT: All N2O messages go through this loop

proc({redir_publish, To, Payload, QosOpts}, State  = #handler{state=C,seq=S}) ->
    Return = send(C, To, Payload, QosOpts),
    {reply, Return, State#handler{seq=S+1}};

% > n2o_ring:send({publish,
%             <<"events/4/index/anon/emqttd_198234215547984">>,
%              term_to_binary({client,1,2,{user,message}})}).

proc({publish, To, Request},
    State  = #handler{name=Name,state=C,seq=S}) ->
    Addr   = emqttd_topic:words(To),
    Bert   = binary_to_term(Request,[safe]),
    Return = case Addr of
         [ Origin, Vsn, Node, Module, Username, Id, Token | _ ] ->
         From = nitro:to_binary(["actions/", Vsn, Module,"/",Id]),
         Sid  = nitro:to_binary(Token),
         % io:format("Module: ~p~n",[Module]),
         Ctx  = #cx { module=fix(Module), session=Sid, node=Node, params=Id, client_pid=C, from = From, vsn = Vsn},
         % NITRO, HEART, ROSTER, FTP protocol loop
         case n2o_proto:info(Bert,[],Ctx) of
              { reply, { binary, Response }, _ , #cx{from = From2}}
                    -> % io:format("Response: ~tp~n",[Response]),
                      { ok,    send(C, From2, Response)};
              Reply -> { error, {"ERR: Invalid Return",Reply} } end;
               Addr -> { error, {"ERR: Unknown Address",Addr} } end,
    debug(Name,To,Bert,Addr,Return),
    {reply, Return, State#handler{seq=S+1}};

% On connection subscribe to Server Events: "events/:node/#"

proc({mqttc, C, connected}, State=#handler{name=Name,state=C,seq=S}) ->
    emqttc:subscribe(C, nitro:to_binary([<<"events/+/">>, nitro:to_list(Name),"/#"]), 2),
    {ok, State#handler{seq = S+1}};

% Examples:

% > n2o_async:send(ring,2,"maxim").
% VNODE 2 Unknown Message: "maxim"
% {uknown,"maxim",3}

% > n2o_ring:send("hello").
% VNODE 1 Unknown Message: "hello"
% {uknown,"hello",2}

% Catch Unknown Messages

proc(Unknown,#handler{state=C,name=Name,seq=S}=Async) ->
%    io:format("VNODE ~p Unknown Message: ~p\r~n",[Name,Unknown]),
    {reply,{uknown,Unknown,S},Async#handler{seq=S+1}}.
