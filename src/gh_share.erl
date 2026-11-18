%% Sharing (FS 3.3, 3.4; plan section 3.5; phase C, the part inside a lab): datasets the lab approves, with consent
%% coded in the GA4GH Data Use Ontology (DUO, https://www.ga4gh.org/product/data-use-ontology-duo/), served through
%% GA4GH DRS (gh_web_drs). An admin makes a dataset from finished analyses; that is the lab's approval. A dataset
%% holds, anonymised:
%%   genomes.fasta  the consensus genomes, renamed <dataset>-1, <dataset>-2, ... (no sample or job names leave)
%%   results.json   per genome: its new name, species, lineage, mutations, region and the ISO week of collection
%%                  (not the date)
%% Raw reads never go into a dataset. A withdrawn dataset is no longer served.
%%
%% Table (disc copies, this site only):
%%   gh_dataset {id, title, description, consent, jobs, files, created_by, created, state}
%%     files: [{Name, Hash}], state: approved | withdrawn
-module(gh_share).
-export([tables/0, duo/0, create/5, list/0, get/1, withdraw/1, served_file/1]).

-record(gh_dataset, {id, title, description, consent, jobs, files, created_by, created, state}).

%% the DUO codes a dataset may carry (DUO's data use permissions and modifiers most labs use), with their labels
-spec duo() -> #{binary() => binary()}.
duo() ->
    #{<<"DUO:0000042">> => <<"general research use">>,
      <<"DUO:0000006">> => <<"health or medical or biomedical research">>,
      <<"DUO:0000007">> => <<"disease specific research">>,
      <<"DUO:0000004">> => <<"no restriction">>,
      <<"DUO:0000043">> => <<"clinical care use">>,
      <<"DUO:0000044">> => <<"population origins or ancestry research prohibited">>,
      <<"DUO:0000045">> => <<"not for profit use only">>,
      <<"DUO:0000046">> => <<"non-commercial use only">>,
      <<"DUO:0000019">> => <<"publication required">>,
      <<"DUO:0000020">> => <<"collaboration required">>,
      <<"DUO:0000021">> => <<"ethics approval required">>,
      <<"DUO:0000022">> => <<"geographical restriction">>,
      <<"DUO:0000024">> => <<"publication moratorium">>,
      <<"DUO:0000026">> => <<"user specific restriction">>,
      <<"DUO:0000027">> => <<"project specific restriction">>,
      <<"DUO:0000028">> => <<"institution specific restriction">>,
      <<"DUO:0000029">> => <<"return to database or resource">>}.

-spec tables() -> ok.
tables() ->
    case mnesia:create_table(gh_dataset, [{attributes, record_info(fields, gh_dataset)}, {disc_copies, [node()]}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, gh_dataset}} -> ok
    end,
    ok = mnesia:wait_for_tables([gh_dataset], 60000).

%% a new dataset of finished genome or reads jobs: {ok, Dataset} or {error, Why}
-spec create(binary(), binary(), [binary()], [binary()], binary()) -> {ok, map()} | {error, term()}.
create(Title, Description, Consent, JobIds, By) ->
    Duo = duo(),
    Views = [gh_jobs:view(J) || J <- JobIds],
    if
        Title =:= <<>> -> {error, title_required};
        Consent =:= [] -> {error, consent_required};
        JobIds =:= [] -> {error, no_analyses};
        true ->
            case [C || C <- Consent, not is_map_key(C, Duo)] ++ [J || {J, V} <- lists:zip(JobIds, Views), not finished(V)] of
                [_ | _] = Bad -> {error, {not_allowed, Bad}};
                [] ->
                    Now = erlang:system_time(millisecond),
                    Id = iolist_to_binary(io_lib:format("ds-~.36b", [Now])),
                    {Fasta, Results} = anonymised(Id, Views),
                    Files = [{<<"genomes.fasta">>, gh_store:put_binary(Fasta)},
                             {<<"results.json">>, gh_store:put_binary(json:encode(Results))}],
                    D = #gh_dataset{id = Id, title = Title, description = Description, consent = lists:usort(Consent),
                                    jobs = JobIds, files = Files, created_by = By, created = Now, state = approved},
                    ok = mnesia:dirty_write(D),
                    {ok, to_map(D)}
            end
    end.

finished(#{state := done, kind := K}) when K =:= genome; K =:= reads -> true;
finished(_) -> false.

%% the genomes renamed <Id>-N in job order, and per genome its results; nothing that names a sample, job or person
anonymised(Id, Views) ->
    Items = lists:append([genomes_of(V) || V <- Views]),
    Named = [{<<Id/binary, "-", (integer_to_binary(N))/binary>>, G} || {N, G} <- lists:enumerate(Items)],
    Fasta = [[<<">">>, Name, <<"\n">>, Seq, <<"\n">>] || {Name, #{seq := Seq}} <- Named],
    Results = [#{name => Name, species => maps:get(species, G), lineage => maps:get(lineage, G),
                 mutations => maps:get(mutations, G), region => maps:get(region, G), collection_week => maps:get(week, G)}
               || {Name, G} <- Named],
    {Fasta, Results}.

%% the genomes of a finished job with their results and metadata (the week, not the date)
genomes_of(#{steps := Steps, params := Params} = V) ->
    File = case V of
               #{kind := genome} -> res(Steps, validate, output);
               #{kind := reads} -> res(Steps, consensus, genome)
           end,
    Meta = maps:get(metadata, Params, #{}),
    Per = maps:get(sequences, Meta, #{}),
    Rows = maps:from_list([{maps:get(query, R), R} || R <- gh_export:rows(V)]),
    Muts = maps:from_list([{Q, [iolist_to_binary([Acc, ":", Rf, integer_to_list(P), A]) || [P, Rf, A] <- Ss]}
                           || #{query := Q, aligned := true, reference := Acc, substitutions := Ss} <- results(Steps, mutations)]),
    [begin
         R = maps:get(Q, Rows, #{}),
         M = maps:merge(maps:with([region, collection_date], Meta), maps:get(Q, Per, #{})),
         #{seq => seq(Rest), species => maps:get(species, R, <<>>), lineage => maps:get(pango, R, <<>>),
           mutations => maps:get(Q, Muts, []), region => maps:get(region, M, null),
           week => case M of #{collection_date := D} -> gh_agg:week(D); _ -> null end}
     end || {Q, Rest} <- gh_fasta:records(gh_store:path(File))].

res(Steps, Step, Key) ->
    #{Step := #{results := [#{Key := H}]}} = Steps,
    H.

results(Steps, Step) ->
    case Steps of
        #{Step := #{results := R}} -> lists:append([X || X <- R, is_list(X)]);
        _ -> []
    end.

%% the sequence of a FASTA record's rest (the header's remainder, then lines)
seq(Rest) ->
    [_ | Lines] = binary:split(Rest, <<"\n">>, [global]),
    << <<L/binary>> || L <- Lines >>.

-spec list() -> [map()].
list() ->
    [to_map(D) || D <- lists:reverse(lists:keysort(#gh_dataset.created, mnesia:dirty_match_object(#gh_dataset{_ = '_'})))].

-spec get(binary()) -> map() | undefined.
get(Id) ->
    case mnesia:dirty_read(gh_dataset, Id) of
        [D] -> to_map(D);
        [] -> undefined
    end.

-spec withdraw(binary()) -> ok | {error, no_such_dataset}.
withdraw(Id) ->
    case mnesia:dirty_read(gh_dataset, Id) of
        [D] -> mnesia:dirty_write(D#gh_dataset{state = withdrawn});
        [] -> {error, no_such_dataset}
    end.

%% {ok, Name, Dataset} if Hash is a file of an approved dataset (what DRS may serve), or none
-spec served_file(binary()) -> {ok, binary(), map()} | none.
served_file(Hash) ->
    case [{N, D} || #gh_dataset{state = approved, files = Fs} = D <- mnesia:dirty_match_object(#gh_dataset{_ = '_'}),
                    {N, H} <- Fs, H =:= Hash] of
        [{N, D} | _] -> {ok, N, to_map(D)};
        [] -> none
    end.

to_map(#gh_dataset{id = Id, title = T, description = De, consent = C, jobs = J, files = F, created_by = B,
                   created = Cr, state = S}) ->
    Duo = duo(),
    #{id => Id, title => T, description => De, consent => [#{code => X, label => maps:get(X, Duo, <<>>)} || X <- C],
      jobs => length(J), files => [#{name => N, id => H} || {N, H} <- F], created_by => B, created => Cr, state => S,
      metadata => metadata(F)}.

%% what a dataset says about where and when its genomes come from (FS 3.1: source lab, country, date), from its own
%% anonymised results: the site, the genomes, their countries and regions, the range of collection weeks
metadata(Files) ->
    Rows = case [H || {<<"results.json">>, H} <- Files] of
               [H] -> json:decode(gh_store:read(H));
               [] -> []
           end,
    Regions = lists:usort([R || #{<<"region">> := R} <- Rows, is_binary(R)]),
    Weeks = lists:usort([W || #{<<"collection_week">> := W} <- Rows, is_binary(W)]),
    #{source => gh_monitor:site(), genomes => length(Rows),
      countries => lists:usort([binary:part(R, 0, 2) || R <- Regions]), regions => Regions,
      collection_weeks => case Weeks of [] -> []; _ -> [hd(Weeks), lists:last(Weeks)] end}.
