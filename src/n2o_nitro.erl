-module(n2o_nitro).
-description('N2O Nitro Protocol: PICKLE, FLUSH, DIRECT, IO, INIT').
-license('ISC').
-author('Maxim Sokhatsky').
-include("n2o.hrl").
-compile(export_all).

% Nitrogen pickle handler

info({init,_Rest},Req,State = #cx{module = Module}) ->
    case try Elements = Module:main(),
             n2o:render(Elements),
             {ok,[]}
       catch X:Y -> Stack = n2o:stack(X,Y),
             n2o:error(?MODULE,"Event Main: ~p:~p~n~p", Stack),
             {error,Stack} end of
        {ok, _} ->
             UserCx = try Module:event(init)
             catch C:E -> Error = n2o:stack(C,E),
                          n2o:error(?MODULE,"Event Init: ~p:~p~n~p",Error),
                          {stack,Error} end,
             {reply,n2o:format({io,render_actions(n2o:actions()),<<>>}),
                    Req,n2o:context(State,?MODULE,{init,UserCx})};
        {error,E} ->
             {reply,n2o:format({io,<<>>,E}),
                    Req,n2o:context(State,?MODULE,{error,E})} end;

info({pickle,_,_,_}=Event, Req, State) ->
    n2o:actions([]),
    Result = try html_events(Event,State)
           catch E:R -> Stack = n2o:stack(E,R),
                        n2o:error(?MODULE,"Catch: ~p:~p~n~p", Stack),
                        {io,render_actions(n2o:actions()),Stack} end,

    {reply,n2o:format(Result),
           Req,n2o:context(State,?MODULE,{pickle,Result})};

info({flush,Actions}, Req, State) ->
    n2o:actions([]),
    Render = iolist_to_binary(render_actions(Actions)),
    io:format("Flush Message: ~tp",[Render]),
    {reply,n2o:format({io,Render,<<>>}),Req, State};

info({direct,Message}, Req, State) ->
    n2o:actions([]),
    Module = State#cx.module,
    Result = try Res = Module:event(Message), {direct,Res}
           catch E:R -> Stack = n2o:stack(E, R),
                        n2o:error(?MODULE,"Catch: ~p:~p~n~p", Stack),
                        {stack,Stack} end,
    {reply,n2o:format({io,render_actions(n2o:actions()),<<>>}),
           Req,n2o:context(State,?MODULE,Result)};

info(Message,Req,State) -> {unknown,Message,Req,State}.

% double render: actions could generate actions

render_actions(Actions) ->
    n2o:actions([]),
    First  = n2o:render(Actions),
    Second = n2o:render(n2o:actions()),
    n2o:actions([]),
    [First,Second].

% neo events

html_events({pickle,Source,Pickled,Linked}=Pickle, State) ->
    io:format("Pickle: ~tp",[Pickle]),
    Ev = n2o:depickle(Pickled),
    case Ev of
         #ev{} -> render_ev(Ev,Source,Linked,State);
         CustomEnvelop -> n2o:error("Only #ev{} events for now: ~p",[CustomEnvelop]) end,
    {io,render_actions(n2o:actions()),<<>>}.

render_ev(#ev{module=M,name=F,msg=P,trigger=T},_Source,Linked,State) ->
    case F of
         api_event -> M:F(P,Linked,State);
         event -> lists:map(fun({K,V})-> put(K,n2o:to_binary(V)) end,Linked), M:F(P);
         _UserCustomEvent -> M:F(P,T,State) end.
