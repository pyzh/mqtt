-module(n2o_nitro).
-description('N2O Nitro Protocol: PICKLE, FLUSH, DIRECT, IO, INIT').
-license('ISC').
-author('Maxim Sokhatsky').
-include("n2o.hrl").
-compile(export_all).

% Nitrogen pickle handler

info({init, <<"krocks">>}, Req, State = #cx{session = Session}) ->
    {'Token', Token} = n2o_session:authenticate(Session, []),
    info({init, Token}, Req, State);
info({init, Token}, Req, State = #cx{module = Module, session = Session}) ->
%    io:format("IToken: ~p~n",[Token]),
    case try Elements = Module:main(),
             n2o:render(Elements),
             {ok,[]}
       catch X:Y -> Stack = n2o:stack(X,Y),
             io:format("Event Main: ~p:~p~n~p", Stack),
             {error,Stack} end of
        {ok, _} ->
             UserCx = try Module:event(init)
             catch C:E -> Error = n2o:stack(C,E),
                          io:format("Event Init: ~p:~p~n~p~n",Error),
                          {stack,Error} end,
%             io:format("Token: ~p~n",[Token]),
             {reply,n2o:format({io,render_actions(n2o:actions()), {'Token', Token}}),
                    Req,State};
        {error,E} ->
             {reply,n2o:format({io,<<>>,E}),
                    Req,State} end;

info({client,Id,Topic,Message}=Client, Req, State) ->
    Module = State#cx.module,
    Reply = try Module:event(Client)
          catch E:R -> Error = n2o:stack(E,R),
                       io:format("Catch: ~p:~p~n~p",Error), Error end,
    {reply,n2o:format({io,render_actions(n2o:actions()),<<>>}),Req,State};

info({pickle,_,_,_}=Event, Req, State) ->
    n2o:actions([]),
    Result = try html_events(Event,State)
           catch E:R -> Stack = n2o:stack(E,R),
                        io:format("Catch: ~p:~p~n~p", Stack),
                        {io,render_actions(n2o:actions()),Stack} end,

    {reply,n2o:format(Result),
           Req,State};

info({flush,Actions}, Req, State) ->
    n2o:actions([]),
    Render = iolist_to_binary(render_actions(Actions)),
    {reply,n2o:format({io,Render,<<>>}),Req, State};

info({direct,Message}, Req, State) ->
    n2o:actions([]),
    Module = State#cx.module,
    Result = try Res = Module:event(Message), {direct,Res}
           catch E:R -> Stack = n2o:stack(E, R),
                        io:format("Catch: ~p:~p~n~p", Stack),
                        {stack,Stack} end,
    {reply,n2o:format({io,render_actions(n2o:actions()),<<>>}),
           Req,State};

info(Message,Req,State) -> {unknown,Message,Req,State}.

% double render: actions could generate actions

render_actions(Actions) ->
    n2o:actions([]),
    First  = n2o:render(Actions),
    Second = n2o:render(n2o:actions()),
    n2o:actions([]),
    [First,Second].

% n2o events

html_events({pickle,Source,Pickled,Linked}=Pickle, State) ->
    Ev = n2o:depickle(Pickled),
    case Ev of
         #ev{} -> render_ev(Ev,Source,Linked,State);
         CustomEnvelop -> io:format("EV expected: ~p~n",[CustomEnvelop]) end,
    {io,render_actions(n2o:actions()),<<>>}.

render_ev(#ev{name=F,msg=P,trigger=T},_Source,Linked,State) ->
    #cx{module=M} = get(context),
    case F of
         api_event -> M:F(P,Linked,State);
         event -> lists:map(fun({K,V})-> put(K,nitro:to_binary(V)) end,Linked), M:F(P);
         _UserCustomEvent -> M:F(P,T,State) end.
