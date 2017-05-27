-module(n2o_vnode).
-include("n2o.hrl").
-compile(export_all).

proc(init,#handler{name=Name}=Async) ->
    io:format("VNode Init: ~p\r~n",[Name]),
    {ok, C} = emqttc:start_link([{host, "127.0.0.1"}, 
                                 {client_id, nitro:to_binary(Name)},
                                 {logger, {console, error}},
                                 {reconnect, 3}]),
    {ok,Async#handler{state=C,seq=0}};

proc({publish, Topic, Payload}, State=#handler{name = Name, state = C,seq=S}) ->
    io:format("VNODE:~p Message on topic ~p.\r~n", [Name, Topic]),
    {ok,State#handler{seq = S+1}};

proc({mqttc, C, connected}, State=#handler{name=Name,state = C,seq=S}) ->
    io:format("VNODE Client ~p is connected.\r~n", [C]),
    emqttc:subscribe(C, iolist_to_binary([<<"events/">>,nitro:to_list(Name)]), 2),
    {ok,State#handler{seq = S+1}};

% > n2o_async:send(ring,2,"maxim").
% n2o Unknown Message: "maxim"
% ok

% > n2o:ring_send("Hello").
% VNODE 63735 Unknown Message: "Hello"
% ok

proc(Unknown,#handler{state=C,name=Name,seq=S}=Async) ->
    io:format("VNODE ~p Unknown Message: ~p\r~n",[Name,Unknown]),
    {reply,{uknown,Unknown,S},Async#handler{seq=S+1}}.
