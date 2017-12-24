-module(n2o_ftp).
-description('N2O File Protocol: FTP').
-license('ISC').
-author('Andrii Zadorozhnii').
-include("n2o.hrl").
-include_lib("kernel/include/file.hrl").
-compile(export_all).

-define(ROOT, application:get_env(n2o,upload,code:priv_dir(n2o))).
-define(NEXT, 250*1024). % 256K chunks for best 25MB/s speed
-define(STOP, 0).

% Callbacks

filename(#ftp{sid=Sid,filename=FileName}) -> FileName. %filename:join(nitro:to_list(Sid),FileName).

% File Transfer Protocol

info(#ftp{status = {event, _}}=FTP, Req, State) ->
    io:format("Event Message: ~p~n", [ FTP#ftp{data = <<>>} ]),
    Module = case State#cx.module of [] -> index; M -> M end,
    Reply = try Module:event(FTP) catch E:R ->
        Error = n2o:stack(E,R),
        io:format("Catch: ~p:~p~n~p~n",Error),
        Error
    end,
    {reply, {binary, n2o_bert:format({io,n2o_nitro:render_actions(n2o:actions()), Reply})}, Req, State};

info(#ftp{id = Link, status = <<"init">>, block = Block, offset = Offset}=FTP, Req, State) ->
    Root=?ROOT,
    RelPath=(application:get_env(n2o,filename,n2o_ftp)):filename(FTP),
    io:format("RelPath: ~p~n",[ RelPath ]),
    FilePath = filename:join(Root, RelPath),
    ok = filelib:ensure_dir(FilePath),
    FileSize = case file:read_file_info(FilePath) of
        {ok, Fi} -> Fi#file_info.size;
        {error, _} -> 0
    end,
    io:format("Info Init: ~p Offset: ~p Block: ~p~n",[ FilePath, FileSize, Block ]),

    Block2 = case Block of 0 -> ?STOP; _ -> ?NEXT end,
    Offset2 = case FileSize >= Offset of true -> FileSize; false -> 0 end,
    FTP2 = FTP#ftp{block = Block2, offset = Offset2, data = <<>>},

    n2o_async:stop(file, Link),
    n2o_async:start(#handler{module=?MODULE, class=file, group=n2o, state=FTP2, name=Link}),

    {reply, {binary, n2o_bert:format(FTP2)}, Req, State};

info(#ftp{id = Link, status = <<"send">>}=FTP, Req, State) ->
    io:format("Info Send: ~p~n",[ FTP#ftp{data = <<>>} ]),
    Reply = try
        gen_server:call(n2o_async:pid(file, Link), FTP)
    catch E:R ->
        io:format("Info Error call the sync: ~p~n",[ {E,R} ]),
        FTP#ftp{data = <<>>,block = ?STOP}
    end,
    io:format("Send reply ~p~n",[ Reply#ftp{ data = <<>> }]),
    {reply, {binary, n2o_bert:format(Reply)}, Req, State};

info(Message, Req, State) -> {unknown, Message, Req, State}.

% n2o Handlers

proc(init, #handler{state = #ftp{sid = Sid, meta = ClientId} = FTP} = Async) ->
    io:format("Proc Init: ~p~n Sid: ~p ClientId: ~p~n",[ FTP#ftp{data = <<>>}, Sid, ClientId ]),
    FTP2 = FTP#ftp{data = <<>>, status = {event, init}},
    n2o_ring:send({publish, <<"events/1/index/anon/",ClientId/binary,"/",Sid/binary>>, term_to_binary(FTP2)}),
    {ok, Async};

proc(#ftp{id = Link, sid = Sid, data = Data, status = <<"send">>, block = Block, meta = ClientId} = FTP,
     #handler{state = #ftp{size = TotalSize, offset = Offset, filename = RelPath}} = Async) when Offset + Block >= TotalSize ->
        io:format("Proc Stop ~p, last piece size: ~p: ClientId: ~p~n", [ FTP#ftp{data = <<>>}, byte_size(Data), ClientId ]),
        case file:write_file(filename:join(?ROOT,RelPath), <<Data/binary>>, [append,raw]) of
            {error, Reason} ->
                io:format("WRITE ERROR: ~p~n", [ filename:join(?ROOT, RelPath) ]),
                {reply, {error, Reason}, Async};
            ok ->
                io:format("WRITE FINAL: ~p~n", [ filename:join(?ROOT, RelPath) ]),
                FTP2 = FTP#ftp{data = <<>>, offset = TotalSize, block = ?STOP},
                FTP3 = FTP2#ftp{status = {event, stop}, filename = RelPath},
                n2o_ring:send({publish, <<"events/1//index/anon/",ClientId/binary,"/",Sid/binary>>, term_to_binary(FTP3)}),
                spawn(fun() -> n2o_async:stop(file, Link) end),
                {stop, normal, FTP2, Async#handler{state = FTP2}}
        end;

proc(#ftp{data = Data, block = Block} = FTP, #handler{state = #ftp{offset = Offset, filename = RelPath}}=Async) ->
    io:format("WRITE: >>~p ~p ~p~n", [ Offset, Block, filename:join(?ROOT,RelPath) ]),
    FTP2 = FTP#ftp{status = <<"send">>, offset = Offset + Block },
    io:format("Proc Process ~p~n",[ FTP2#ftp{data = <<>>} ]),
    case file:write_file(filename:join(?ROOT, RelPath), <<Data/binary>>, [append,raw]) of
        {error, Reason} -> {reply, {error, Reason}, Async};
        ok -> {reply, FTP2#ftp{data = <<>>}, Async#handler{state = FTP2#ftp{filename = RelPath}}} end;

proc(_,Async) -> {reply, #ftpack{}, Async}.
