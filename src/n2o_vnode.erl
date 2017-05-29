-module(n2o_vnode).
-license('ISC').
-copyright('Synrc Research Center').
-description('N2O Remote: Virtual Node Server').
-author('Maxim Sokhatsky').
-include("n2o.hrl").
-compile(export_all).

% N2O VNODE SERVER for MQTT

debug(Name,Topic,BERT,Address) ->
    case application:get_env(n2o,dump_loop,yes) of
         yes -> 
    io:format("VNODE:~p Message on topic ~tp.\r~n", [Name, Topic]),
    io:format("BERT: ~tp\r~nAddress: ~p\r~n",[BERT,Address]),
    io:format("on_message_publish1: ~s.\r~n", [Topic]),
                ok;
           _ -> skip end.

qos({init,<<>>}) -> 0;
qos(_)           -> 2.

send(C,T,M,BERT) -> emqttc:publish(C, T, M, [{qos,qos(BERT)}]).

% Performed on VNODE init

proc(init,#handler{name=Name}=Async) ->
    io:format("VNode Init: ~p\r~n",[Name]),
    {ok, C} = emqttc:start_link([{host, "127.0.0.1"}, 
                                 {client_id, Name},
                                 {logger, {console, error}},
                                 {reconnect, 5}]),
    {ok,Async#handler{state=C,seq=0}};

% RPC over MQTT: All N2O messages go through this loop

% > n2o_ring:send({publish,
%             <<"events/4/index/anon/emqttd_198234215547984">>,
%              term_to_binary({client,1,2,{user,message}})}).

proc({publish, To, Request},
    State  = #handler{name=Name,state=C,seq=S}) ->
    Addr   = emqttd_topic:words(To),
    Bert   = binary_to_term(Request,[safe]),
    Return = case Addr of
         [ Origin, Node, Module, Username, Id | _ ] ->
         From = nitro:to_binary(["actions/",Module,"/",Id]),
         Ctx  = #cx { module=nitro:to_atom(Module), session=Id },
         % NITRO, HEART, ROSTER, FTP protocol loop
         case n2o_proto:info(Bert,[],Ctx) of 
              { reply, { binary, Response }, _ , _ } 
                    -> % io:format("Response: ~tp~n",[binary_to_term(Response)]),
                       { ok,    send(C, From, Response, Bert) };
              Reply -> { error, {"ERR: Invalid Return",Reply} } end;
               Addr -> { error, {"ERR: Unknown Address",Addr} } end,
    debug(Name,To,Bert,Addr),
    {reply, Return, State#handler{seq=S+1}};

% On connection subscribe to Server Events: "events/:node/#"

proc({mqttc, C, connected}, State=#handler{name=Name,state=C,seq=S}) ->
    emqttc:subscribe(C, nitro:to_binary([<<"events/">>,
                        nitro:to_list(Name),"/#"]), 2),
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
