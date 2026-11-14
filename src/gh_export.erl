%% Exports of results (FS 3.1): CSV and PDF of a job's results, SVG of a phylogenetic tree. JSON is the job itself
%% (gh_web_api). Everything is written here, without libraries: a CSV table, a plain PDF 1.4 text report, and a
%% rectangular tree drawing.
-module(gh_export).
-export([csv/1, pdf/1, newick/1, svg/1, rows/1]).

%%% CSV: one row per sequence

-spec csv(map()) -> iodata().
csv(Job) ->
    Header = ["sequence", "species", "genus", "family", "organism", "identity", "confidence", "method", "nearest_reference",
              "pango", "clade", "substitutions", "insertions", "deletions", "missing"],
    [line(Header) | [line(row(R)) || R <- rows(Job)]].

line(Fields) -> [lists:join($,, [field(F) || F <- Fields]), "\r\n"].

field(F) when is_number(F) -> io_lib:format("~p", [F]);
field(F) ->
    B = unicode:characters_to_binary(io_lib:format("~ts", [F])),
    case binary:match(B, [<<",">>, <<"\"">>, <<"\n">>, <<"\r">>]) of
        nomatch -> B;
        _ -> [$", binary:replace(B, <<"\"">>, <<"\"\"">>, [global]), $"]
    end.

row(R) ->
    [maps:get(K, R, <<>>) || K <- [query, species, genus, family, organism, ani, confidence, method, ref, pango, clade,
                                    substitutions, insertions, deletions, missing]].

%% per sequence: the call, the lineage and the mutation counts of a job (gh_jobs:view/1); used by the monitoring too
-spec rows(map()) -> [map()].
rows(#{steps := Steps}) ->
    Res = fun(S) -> case maps:get(S, Steps, undefined) of
                        undefined -> [];
                        #{results := R} -> lists:append([X || X <- R, is_list(X)])
                    end
          end,
    Lin = maps:from_list([{maps:get(query, L), L} || L <- Res(lineage)]),
    Prot = maps:from_list([{maps:get(query, P), maps:get(call, P)} || P <- Res(protein),
                           maps:get(confidence, maps:get(call, P)) =/= unclassified]),
    Mut = maps:from_list([{maps:get(query, M), M} || M <- Res(mutations)]),
    [begin
         Q = maps:get(<<"query">>, C),
         Call = case maps:get(Q, Prot, none) of
                    none -> (maps:get(<<"call">>, C))#{<<"method">> => <<"minhash">>};
                    P -> #{<<"species">> => maps:get(species, P), <<"genus">> => maps:get(genus, P),
                           <<"family">> => maps:get(family, P), <<"organism">> => maps:get(organism, P),
                           <<"ani">> => maps:get(aa_identity, P), <<"confidence">> => atom_to_binary(maps:get(confidence, P)),
                           <<"ref">> => maps:get(protein, P), <<"method">> => <<"protein">>}
                end,
         L = maps:get(Q, Lin, #{}),
         M = maps:get(Q, Mut, #{}),
         #{query => Q, species => maps:get(<<"species">>, Call, <<>>), genus => maps:get(<<"genus">>, Call, <<>>),
           family => maps:get(<<"family">>, Call, <<>>), organism => maps:get(<<"organism">>, Call, <<>>),
           ani => maps:get(<<"ani">>, Call, <<>>), confidence => maps:get(<<"confidence">>, Call),
           method => maps:get(<<"method">>, Call),
           ref => maps:get(<<"ref">>, Call, <<>>), pango => maps:get(pango, L, <<>>), clade => maps:get(clade, L, <<>>),
           substitutions => length(maps:get(substitutions, M, [])), insertions => length(maps:get(insertions, M, [])),
           deletions => length(maps:get(deletions, M, [])), missing => maps:get(missing, M, <<>>)}
     end || C <- Res(classify)];
rows(_) -> [].

%%% PDF: a text report

-spec pdf(map()) -> binary().
pdf(#{id := Id, kind := Kind, state := State} = Job) ->
    Rows = rows(Job),
    Know = case maps:get(steps, Job, #{}) of
               #{knowledge := #{results := K}} -> [L || #{links := Ls} <- K, L <- Ls];
               _ -> []
           end,
    Lines = [{14, ["GenHub2 report: ", Id]},
             {10, ["Kind: ", atom_to_list(Kind), ". State: ", atom_to_list(State), ". Created: ",
                   calendar:system_time_to_rfc3339(maps:get(created, Job), [{unit, millisecond}, {offset, "Z"}])]},
             {10, ""},
             {12, "Classification"}]
        ++ lists:append([[{10, [maps:get(query, R), ": ", maps:get(species, R), " (", maps:get(family, R),
                               "), identity ", fmt(maps:get(ani, R)), ", confidence ", maps:get(confidence, R),
                               " (", maps:get(method, R), ")"]},
                          {10, ["    nearest reference ", maps:get(ref, R), " ", maps:get(organism, R)]},
                          {10, ["    lineage ", maps:get(pango, R), " ", maps:get(clade, R), "; substitutions ",
                                integer_to_list(maps:get(substitutions, R)), ", insertions ",
                                integer_to_list(maps:get(insertions, R)), ", deletions ",
                                integer_to_list(maps:get(deletions, R))]}] || R <- Rows])
        ++ [{10, ""}, {12, "Related knowledge (information, not clinical advice)"}]
        ++ [{10, [maps:get(title, L), ": ", maps:get(url, L)]} || L <- Know]
        ++ [{10, ""}, {8, "Every result carries its provenance record (task hash, code checksum, node, time) in the JSON export."}],
    pdf_document([wrap(S, T) || {S, T} <- Lines]).

fmt(X) when is_float(X) -> io_lib:format("~.3f", [X]);
fmt(X) -> io_lib:format("~ts", [X]).

%% lines longer than the page are cut into pieces
wrap(Size, Text) ->
    B = unicode:characters_to_binary(Text),
    Max = trunc(95 * 10 / Size),
    {Size, chunks(B, Max)}.

chunks(B, Max) when byte_size(B) =< Max -> [B];
chunks(B, Max) -> [binary:part(B, 0, Max) | chunks(binary:part(B, Max, byte_size(B) - Max), Max)].

pdf_document(Wrapped) ->
    Lines = [{S, T} || {S, Ts} <- Wrapped, T <- Ts],
    Pages = pages(Lines, 760, [], []),
    N = length(Pages),
    %% objects: 1 catalog, 2 pages, 3 font, then per page: page object, content stream
    PageIds = [4 + 2 * I || I <- lists:seq(0, N - 1)],
    Objs = [{1, "<< /Type /Catalog /Pages 2 0 R >>"},
            {2, ["<< /Type /Pages /Count ", integer_to_list(N), " /Kids [",
                 lists:join(" ", [[integer_to_list(P), " 0 R"] || P <- PageIds]), "] >>"]},
            {3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"}]
        ++ lists:append([[{P, ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >>"
                               " /Contents ", integer_to_list(P + 1), " 0 R >>"]},
                          {P + 1, stream(Content)}] || {P, Content} <- lists:zip(PageIds, Pages)]),
    {Body, Offsets} = lists:foldl(fun({Id, O}, {Acc, Offs}) ->
                                          Pos = iolist_size(Acc),
                                          {[Acc, integer_to_list(Id), " 0 obj\n", O, "\nendobj\n"], [Pos | Offs]}
                                  end, {["%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"], []}, Objs),
    XrefPos = iolist_size(Body),
    Count = length(Objs) + 1,
    iolist_to_binary([Body, "xref\n0 ", integer_to_list(Count), "\n0000000000 65535 f \n",
                      [io_lib:format("~10..0B 00000 n \n", [O]) || O <- lists:reverse(Offsets)],
                      "trailer\n<< /Size ", integer_to_list(Count), " /Root 1 0 R >>\nstartxref\n",
                      integer_to_list(XrefPos), "\n%%EOF\n"]).

pages([], _Y, Cur, Done) -> lists:reverse([lists:reverse(Cur) | Done]);
pages([{S, _} | _] = L, Y, Cur, Done) when Y - S < 40 -> pages(L, 760, [], [lists:reverse(Cur) | Done]);
pages([{S, T} | Rest], Y, Cur, Done) ->
    Op = ["BT /F1 ", integer_to_list(S), " Tf 40 ", integer_to_list(Y), " Td (", pdf_text(T), ") Tj ET\n"],
    pages(Rest, Y - S - 4, [Op | Cur], Done).

stream(Content) ->
    C = iolist_to_binary(Content),
    ["<< /Length ", integer_to_list(byte_size(C)), " >>\nstream\n", C, "\nendstream"].

%% PDF string: Latin-1 (WinAnsi), parentheses and backslashes escaped, other characters as ?
pdf_text(B) ->
    << <<(esc(C))/binary>> || C <- unicode:characters_to_list(B) >>.

esc($() -> <<"\\(">>;
esc($)) -> <<"\\)">>;
esc($\\) -> <<"\\\\">>;
esc(C) when C >= 32, C < 256 -> <<C>>;
esc(_) -> <<"?">>.

%%% Newick and SVG

-type tree() :: {node, [tree()], binary(), float()}.

%% the tree of a Newick string: {node, Children, Name, BranchLength}
-spec newick(binary()) -> tree().
newick(B) ->
    {T, Rest} = subtree(string:trim(B)),
    <<";", _/binary>> = Rest,
    T.

subtree(<<"(", R/binary>>) ->
    {Kids, R2} = children(R, []),
    {Name, R3} = label(R2),
    {Len, R4} = length_of(R3),
    {{node, Kids, Name, Len}, R4};
subtree(R) ->
    {Name, R2} = label(R),
    {Len, R3} = length_of(R2),
    {{node, [], Name, Len}, R3}.

children(R, Acc) ->
    {T, R2} = subtree(R),
    case R2 of
        <<",", R3/binary>> -> children(R3, [T | Acc]);
        <<")", R3/binary>> -> {lists:reverse([T | Acc]), R3}
    end.

label(R) ->
    case re:run(R, "^[^(),:;]*", [{capture, first, binary}]) of
        {match, [L]} -> {L, binary:part(R, byte_size(L), byte_size(R) - byte_size(L))};
        nomatch -> {<<>>, R}
    end.

length_of(<<":", R/binary>>) ->
    {match, [N]} = re:run(R, "^[-+0-9.eE]+", [{capture, first, binary}]),
    {num(N), binary:part(R, byte_size(N), byte_size(R) - byte_size(N))};
length_of(R) -> {0.0, R}.

%% Newick numbers: 1, 1.5, -0.25, 3e-05, 3.0E2
num(N) ->
    {Mant, Exp} = case re:split(N, "[eE]", [{return, binary}]) of
                      [M] -> {M, <<"0">>};
                      [M, E] -> {M, E}
                  end,
    M2 = case binary:match(Mant, <<".">>) of nomatch -> <<Mant/binary, ".0">>; _ -> Mant end,
    binary_to_float(<<M2/binary, "e", Exp/binary>>).

%% A rectangular drawing of the tree: leaves one under the other, branch lengths to scale, a scale bar. A tree whose
%% branches all have length 0 (identical sequences) is drawn with unit branches, and says so.
-spec svg(binary()) -> iodata().
svg(Newick) ->
    T0 = newick(Newick),
    {T, Note} = case max_depth(T0, 0.0) > 0 of
                    true -> {T0, none};
                    false -> {unit(T0), <<"identical sequences: every branch length is 0">>}
                end,
    Leaves = leaves(T),
    Depth = max_depth(T, 0.0),
    LabelW = 8 * lists:max([byte_size(L) || L <- Leaves] ++ [4]),
    W = 900,
    Scale = case Depth > 0 of true -> (W - LabelW - 40) / Depth; false -> 1.0 end,
    {_, Y, Lines} = draw(T, 0.0, Scale, 1),
    H = Y * 14 + 50,
    Bar = bar(Depth),
    ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"", integer_to_list(W), "\" height=\"", integer_to_list(H),
     "\" viewBox=\"0 0 ", integer_to_list(W), " ", integer_to_list(H), "\" font-family=\"sans-serif\" font-size=\"11\">",
     "<style>line{stroke:#555;stroke-width:1.2}text{fill:#222}</style>",
     Lines,
     case Note of
         none -> ["<line x1=\"20\" y1=\"", n(H - 20), "\" x2=\"", n(20 + Bar * Scale), "\" y2=\"", n(H - 20), "\"/>",
                  "<text x=\"20\" y=\"", n(H - 6), "\">", float_to_list(Bar, [{decimals, 6}, compact]),
                  " substitutions per site</text>"];
         _ -> ["<text x=\"20\" y=\"", n(H - 6), "\">", Note, "</text>"]
     end, "</svg>"].

unit({node, Kids, Name, _}) -> {node, [unit(K) || K <- Kids], Name, 1.0}.

leaves({node, [], Name, _}) -> [Name];
leaves({node, Kids, _, _}) -> lists:append([leaves(K) || K <- Kids]).

max_depth({node, [], _, L}, D) -> D + max(L, 0.0);
max_depth({node, Kids, _, L}, D) -> lists:max([max_depth(K, D + max(L, 0.0)) || K <- Kids]).

%% {NodeY, NextLeafIndex, SVG}: X is where the node's branch starts
draw({node, [], Name, L}, X, Scale, I) ->
    Y = 20 + I * 14,
    X2 = 20 + (X + max(L, 0.0)) * Scale,
    {Y, I + 1, [ln(20 + X * Scale, Y, X2, Y),
                ["<text x=\"", n(X2 + 4), "\" y=\"", n(Y + 4), "\">", xml(Name), "</text>"]]};
draw({node, Kids, _, L}, X, Scale, I) ->
    X1 = X + max(L, 0.0),
    {Ys, Next, Svgs} = lists:foldl(fun(K, {Ys0, I0, S0}) ->
                                           {Yk, I1, Sk} = draw(K, X1, Scale, I0),
                                           {[Yk | Ys0], I1, [S0, Sk]}
                                   end, {[], I, []}, Kids),
    Y = (lists:min(Ys) + lists:max(Ys)) / 2,
    XP = 20 + X1 * Scale,
    {Y, Next, [Svgs, ln(XP, lists:min(Ys), XP, lists:max(Ys)), ln(20 + X * Scale, Y, XP, Y)]}.

ln(X1, Y1, X2, Y2) -> ["<line x1=\"", n(X1), "\" y1=\"", n(Y1), "\" x2=\"", n(X2), "\" y2=\"", n(Y2), "\"/>"].

n(X) when is_integer(X) -> integer_to_list(X);
n(X) -> io_lib:format("~.1f", [X]).

%% a round scale bar length, about a fifth of the tree's depth
bar(Depth) when Depth =< 0 -> 1.0;
bar(Depth) ->
    P = math:pow(10, math:floor(math:log10(Depth / 5))),
    hd([S * P || S <- [5, 2, 1], S * P =< Depth / 2] ++ [P]).

xml(B) ->
    binary:replace(binary:replace(binary:replace(B, <<"&">>, <<"&amp;">>, [global]), <<"<">>, <<"&lt;">>, [global]),
                   <<">">>, <<"&gt;">>, [global]).
