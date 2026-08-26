-module(markdownz_commonmark_tests).

-include_lib("eunit/include/eunit.hrl").

-export([
    cases/0,
    current_failures/0
]).

-define(EXAMPLE_MARKER_SIZE, 32).
-define(EXAMPLE_COUNT, 652).

-type example() :: #{
    number := pos_integer(),
    markdown := binary(),
    html := binary()
}.

commonmark_corpus_count_test() ->
    ?assertEqual(?EXAMPLE_COUNT, length(cases())).

commonmark_test_() ->
    KnownFailures = sets:from_list(known_failures()),
    [
        {
            lists:flatten(io_lib:format("CommonMark example ~B", [Number])),
            fun() -> check_example(Example, sets:is_element(Number, KnownFailures)) end
        }
        || #{number := Number} = Example <- cases()
    ].

-spec cases() -> [example()].
cases() ->
    Path = fixture_path(),
    {ok, Spec0} = file:read_file(Path),
    Spec = binary:replace(Spec0, <<226, 134, 146>>, <<$\t>>, [global]),
    Lines = binary:split(Spec, <<"\n">>, [global]),
    Marker = binary:copy(<<$`>>, ?EXAMPLE_MARKER_SIZE),
    parse_examples(Lines, Marker, 1, []).

-spec current_failures() -> [pos_integer()].
current_failures() ->
    [
        Number
        || #{number := Number} = Example <- cases(),
           not example_matches(Example)
    ].

check_example(#{number := Number} = Example, IsKnownFailure) ->
    Matches = example_matches(Example),
    case {Matches, IsKnownFailure} of
        {true, false} ->
            ok;
        {false, true} ->
            ok;
        {true, true} ->
            error({commonmark_unexpected_pass, Number});
        {false, false} ->
            assert_example(Example)
    end.

assert_example(#{markdown := Markdown, html := ExpectedHtml}) ->
    ActualHtml = markdownz:to_binary(Markdown, markdownz:new(commonmark)),
    ?assertEqual(canonical(ExpectedHtml), canonical(ActualHtml)).

example_matches(#{markdown := Markdown, html := ExpectedHtml}) ->
    ActualHtml = markdownz:to_binary(Markdown, markdownz:new(commonmark)),
    canonical(ExpectedHtml) =:= canonical(ActualHtml).

parse_examples([], _Marker, _Number, Acc) ->
    lists:reverse(Acc);
parse_examples([Line | Rest], Marker, Number, Acc) ->
    case trim(Line) of
        <<Marker:?EXAMPLE_MARKER_SIZE/binary, " example">> ->
            {MarkdownLines, AfterMarkdown} = take_until_dot(Rest, []),
            {HtmlLines, AfterHtml} = take_until_marker(AfterMarkdown, Marker, []),
            Example = #{
                number => Number,
                markdown => fixture_text(MarkdownLines),
                html => fixture_text(HtmlLines)
            },
            parse_examples(AfterHtml, Marker, Number + 1, [Example | Acc]);
        _ ->
            parse_examples(Rest, Marker, Number, Acc)
    end.

take_until_dot([Line | Rest], Acc) ->
    case trim(Line) of
        <<".">> -> {lists:reverse(Acc), Rest};
        _ -> take_until_dot(Rest, [Line | Acc])
    end.

take_until_marker([Line | Rest], Marker, Acc) ->
    case trim(Line) of
        Marker -> {lists:reverse(Acc), Rest};
        _ -> take_until_marker(Rest, Marker, [Line | Acc])
    end.

fixture_text([]) ->
    <<>>;
fixture_text(Lines) ->
    iolist_to_binary([lists:join(<<"\n">>, Lines), <<"\n">>]).

canonical(Html) ->
    NoCr = binary:replace(Html, <<"\r">>, <<>>, [global]),
    HtmlVoids = re:replace(
        NoCr,
        <<"<(br|hr|img)([^>]*)[ \\t]*/>">>,
        <<"<\\1\\2>">>,
        [global, {return, binary}]),
    BetweenTags = re:replace(
        HtmlVoids,
        <<">[ \\t]*\\n[ \\t]*<">>,
        <<"><">>,
        [global, {return, binary}]),
    string:trim(BetweenTags, trailing, "\n").

fixture_path() ->
    TestDirectory = filename:dirname(filename:absname(?FILE)),
    filename:join([
        TestDirectory,
        "fixtures",
        "commonmark",
        "spec.txt"
    ]).

%% Kept as an explicit baseline so a future specification update can record
%% intentional differences without weakening any of the 652 current checks.
known_failures() ->
    [].

trim(Bin) ->
    string:trim(Bin, both, " \t\r").
