%% Task knowledge (FS 3.6): links to what is known about the classified virus, marked as information, not clinical
%% advice: its NCBI Taxonomy and ENA records, registered clinical trials and the literature on its treatment. No
%% ranking or recommendation (plan, decision 6; EU MDR and AI Act).
%%   {knowledge, TaxId, Species} -> #{information_only := true, notice, links := [#{title, url}]}
-module(gh_knowledge).
-behaviour(pq_task).
-export([run/2, describe/1]).

run({knowledge, TaxId, Species}, _Ctx) ->
    Id = integer_to_binary(TaxId),
    Q = uri_string:quote(Species),
    #{information_only => true,
      notice => <<"Information, not clinical advice: links to public records for a clinician or public-health "
                  "expert to judge.">>,
      links => [#{title => <<"NCBI Taxonomy: ", Species/binary>>,
                  url => <<"https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=", Id/binary>>},
                #{title => <<"ENA: taxon ", Id/binary>>,
                  url => <<"https://www.ebi.ac.uk/ena/browser/view/Taxon:", Id/binary>>},
                #{title => <<"Registered clinical trials (ClinicalTrials.gov)">>,
                  url => <<"https://clinicaltrials.gov/search?cond=", Q/binary>>},
                #{title => <<"Treatment literature (PubMed)">>,
                  url => <<"https://pubmed.ncbi.nlm.nih.gov/?term=", Q/binary, "%20treatment">>}]}.

describe({knowledge, TaxId, _}) -> #{task => knowledge, taxid => TaxId}.
