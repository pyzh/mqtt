-module(n2o_vnode).
-include("n2o.hrl").
-compile(export_all).

% N2O VNODE SERVER for MQTT

proc(init,#handler{name=Name}=Async) ->
    io:format("VNode Init: ~p\r~n",[Name]),
    {ok, C} = emqttc:start_link([{host, "127.0.0.1"}, 
                                 {client_id, Name},
                                 {logger, {console, error}},
                                 {reconnect, 5}]),
    {ok,Async#handler{state=C,seq=0}};

proc({publish, Topic, Payload}, State=#handler{name = Name, state = C,seq=S}) ->
    io:format("VNODE:~p Message on topic ~p.\r~n", [Name, Topic]),
    Address = emqttd_topic:words(Topic),
    BERT    = binary_to_term(Payload,[safe]),
    io:format("BERT: ~tp\r~nAddress: ~p\r~n",[BERT,Address]),
    io:format("on_message_publish: ~tp.\r~n", [{events, Topic}]),
    case Address of
         [Srv, Node, Mod, _Username, ClientId] ->
         RTopic  = iolist_to_binary(["actions/",ClientId]),
         Module = binary_to_atom(Mod, utf8),
         Cx     = #cx{module=Module,session=ClientId,formatter=bert},
         put(context,Cx),
         case n2o_proto:info(BERT,[],Cx) of % NITRO, HEART, ROSTER, FTP protocols....
            {reply, {binary, Msg}, _, _} -> emqttc:publish(C, RTopic, Msg, [{qos,0}]);
            Return -> io:format("ERR: Invalid Return ~p~n",  [Return]), ok end;
           Address -> io:format("ERR: Unknown Address ~p~n",[Address]), ok end,
    {ok,State#handler{seq = S+1}};

proc({mqttc, C, connected}, State=#handler{name=Name,state = C,seq=S}) ->
    emqttc:subscribe(C, iolist_to_binary([<<"events/">>,nitro:to_list(Name),"/#"]), 2),
    {ok,State#handler{seq = S+1}};

% > n2o_async:send(ring,2,"maxim").
% VNODE 2 Unknown Message: "maxim"
% {uknown,"maxim",3}

% > n2o:ring_send("hello").
% VNODE 1 Unknown Message: "hello"
% {uknown,"hello",2}

proc(Unknown,#handler{state=C,name=Name,seq=S}=Async) ->
    io:format("VNODE ~p Unknown Message: ~p\r~n",[Name,Unknown]),
    {reply,{uknown,Unknown,S},Async#handler{seq=S+1}}.
