-module(n2o_format).
-description('N2O Fortmatter: JSON, BERT').
-license('ISC').
-copyright('Maxim Sokhatsky').
-include("n2o.hrl").
-compile(export_all).

% TODO 4.5+: should be compiled from config

io(Data)     -> iolist_to_binary(Data).
bin(Data)    -> Data.
list(Data)   -> binary_to_list(term_to_binary(Data)).

% JSON Encoder

format({Io,Eval,Data}, json) ->
%    io:format("JSON {~p,_,_}: ~tp~n",[Io,io(Eval)]),
    ?N2O_JSON:encode([{t,104},{v,[
                     [{t,100},{v,io}],
                     [{t,109},{v,io(Eval)}],
                     [{t,109},{v,list(Data)}]]}]);

format({Atom,Data}, json) ->
%    io:format("JSON {~p,_}: ~tp~n",[Atom,list(Data)]),
    ?N2O_JSON:encode([{t,104},{v,[
                     [{t,100},{v,Atom}],
                     [{t,109},{v,list(Data)}]]}]);

% BERT Encoder

format({Io,Eval,Data}, bert) ->
%    io:format("BERT {~p,_,_}: ~tp~n",[Io,{io,io(Eval),bin(Data)}]),
    {binary,term_to_binary({Io,io(Eval),bin(Data)})};

format({bin,Data}, bert) ->
%    io:format("BERT {bin,_}: ~tp~n",[Data]),
    {binary,term_to_binary({bin,Data})};

format({Atom,Data}, bert) ->
%    io:format("BERT {~p,_}: ~tp~n",[Atom,bin(Data)]),
    {binary,term_to_binary({Atom,bin(Data)})};

format(#ftp{}=FTP, bert) ->
%    io:format("BERT {ftp,_,_,_,_,_,_,_,_,_,_,_,_}: ~tp~n",
%             [FTP#ftp{data= <<>>}]),
    {binary,term_to_binary(setelement(1,FTP,ftpack))};

format(Term, bert) ->
    {binary,term_to_binary(Term)};

format(_,_) ->
    {binary,term_to_binary({error,<<>>,
            <<"Only JSON/BERT formatters are available.">>})}.
