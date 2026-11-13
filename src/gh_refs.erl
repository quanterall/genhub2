%% Reference data (FS 3.2, 4.5: replicated to every node by content hash): a bundle is a set of named files, each in
%% the store, and its manifest is itself a stored file, so the bundle's hash names all of it. Tasks carry bundle
%% hashes; a node materialises a bundle as a directory of hard links with the names the tools expect (refs.fasta next
%% to refs.fasta.fai, ...).
%%
%% Bundles of phase A:
%%   viral references  refs.fasta (+ .fai), refs.sketch (gh2k), taxonomy.tsv (accession, taxid, species, genus,
%%                     family, organism)
%%   host              host.mmi (minimap2 index of the human genome, for dehost)
%%   lineage dataset   dataset.zip (a Nextclade dataset)
-module(gh_refs).
-export([bundle/1, manifest/2, dir/2, file/3, taxonomy/2, taxon/3]).

-spec bundle(#{string() => file:filename()}) -> gh_store:hash().
bundle(Files) ->
    Manifest = maps:from_list([{Name, gh_store:put_file(Path)} || {Name, Path} <- maps:to_list(Files)]),
    gh_store:put_binary(term_to_binary(Manifest, [deterministic])).

-spec manifest(gh_store:hash(), node()) -> #{string() => gh_store:hash()}.
manifest(Bundle, Home) ->
    {ok, B} = file:read_file(gh_store:ensure(Bundle, Home)),
    binary_to_term(B).

%% The bundle's directory on this node, with every file in place. Tasks running at once may ask for the same
%% bundle: each builds it in a directory of its own and renames that into place, so the directory appears whole or
%% not at all.
-spec dir(gh_store:hash(), node()) -> file:filename().
dir(Bundle, Home) ->
    Dir = filename:join([application:get_env(genhub2, data_dir, "data"), "refs", binary_to_list(Bundle)]),
    case filelib:is_regular(filename:join(Dir, ".complete")) of
        true -> Dir;
        false ->
            Tmp = Dir ++ ".part-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase)),
            ok = filelib:ensure_path(Tmp),
            [link(gh_store:ensure(H, Home), filename:join(Tmp, Name)) || {Name, H} <- maps:to_list(manifest(Bundle, Home))],
            ok = file:write_file(filename:join(Tmp, ".complete"), <<>>),
            case file:rename(Tmp, Dir) of
                ok -> Dir;
                {error, _} ->
                    _ = file:del_dir_r(Tmp),
                    case filelib:is_regular(filename:join(Dir, ".complete")) of
                        true -> Dir;                          % another task put it in place
                        false -> _ = file:del_dir_r(Dir), dir(Bundle, Home)    % left incomplete by a crash
                    end
            end
    end.

link(Src, Dst) ->
    case file:make_link(Src, Dst) of
        ok -> ok;
        {error, _} -> {ok, _} = file:copy(Src, Dst), ok
    end.

-spec file(gh_store:hash(), string(), node()) -> file:filename().
file(Bundle, Name, Home) ->
    filename:join(dir(Bundle, Home), Name).

%% accession => #{taxid, species, genus, family, organism}, cached per bundle
-spec taxonomy(gh_store:hash(), node()) -> #{binary() => map()}.
taxonomy(Bundle, Home) ->
    Key = {?MODULE, taxonomy, Bundle},
    case persistent_term:get(Key, undefined) of
        undefined ->
            {ok, B} = file:read_file(file(Bundle, "taxonomy.tsv", Home)),
            T = maps:from_list([row(binary:split(L, <<"\t">>, [global]))
                                || L <- binary:split(B, <<"\n">>, [global, trim_all]),
                                   binary:first(L) =/= $#]),
            persistent_term:put(Key, T),
            T;
        T -> T
    end.

row([Acc, TaxId, Species, Genus, Family, Organism]) ->
    {Acc, #{taxid => binary_to_integer(TaxId), species => Species, genus => Genus, family => Family,
            organism => Organism}}.

-spec taxon(gh_store:hash(), binary(), node()) -> map().
taxon(Bundle, Acc, Home) ->
    maps:get(Acc, taxonomy(Bundle, Home), #{taxid => 0, species => <<>>, genus => <<>>, family => <<>>,
                                             organism => <<>>}).
