-module(markdownz_typographer_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TYPOGRAPHER_COUNT, 12).
-define(SMARTQUOTES_COUNT, 19).

typographer_fixture_count_test() ->
    ?assertEqual(?TYPOGRAPHER_COUNT, length(cases("typographer.txt"))).

smartquotes_fixture_count_test() ->
    ?assertEqual(?SMARTQUOTES_COUNT, length(cases("smartquotes.txt"))).

typographer_test_() ->
    fixture_tests("typographer", cases("typographer.txt")).

smartquotes_test_() ->
    fixture_tests("smartquotes", cases("smartquotes.txt")).

typographer_disabled_by_default_test() ->
    ?assertEqual(
        <<"<p>(c) &quot;plain&quot;</p>">>,
        markdownz:to_binary(<<"(c) \"plain\"">>)).

disabled_typographer_rule_leaves_no_internal_nodes_test() ->
    Config0 = markdownz:new(#{typographer => true}),
    Config = markdownz:disable(Config0, core, typographer),
    ?assertEqual(
        <<"<p>(c) &quot;plain&quot;</p>">>,
        markdownz:to_binary(<<"\\(c) \"plain\"">>, Config)).

custom_quotes_test() ->
    Config = markdownz:new(#{
        typographer => true,
        quotes => <<"«»‹›"/utf8>>
    }),
    ?assertEqual(
        <<"<p>«double ‹single›»</p>"/utf8>>,
        markdownz:to_binary(<<"\"double 'single'\"">>, Config)).

tight_list_typographer_test() ->
    Config = markdownz:new(#{typographer => true}),
    ?assertEqual(
        <<"<ul><li>“hello” and can’t</li></ul>"/utf8>>,
        markdownz:to_binary(<<"- \"hello\" and can't">>, Config)).

fixture_tests(Name, Cases) ->
    [
        {
            lists:flatten(io_lib:format(
                "markdown-it ~s example ~B", [Name, Number])),
            fun() ->
                ?assertEqual(Expected, markdownz:to_binary(Markdown, config()))
            end
        }
        || {Number, Markdown, Expected} <- Cases
    ].

config() ->
    markdownz:new(#{
        html => true,
        linkify => true,
        typographer => true
    }).

cases(Filename) ->
    {ok, Fixture} = file:read_file(fixture_path(Filename)),
    Lines = binary:split(Fixture, <<"\n">>, [global]),
    parse_cases(Lines, 1, []).

parse_cases([], _Number, Acc) ->
    lists:reverse(Acc);
parse_cases([Line | Rest], Number, Acc) ->
    case trim(Line) of
        <<".">> ->
            {MarkdownLines, AfterMarkdown} = take_until_dot(Rest, []),
            {HtmlLines, AfterHtml} = take_until_dot(AfterMarkdown, []),
            Example = {
                Number,
                join_lines(MarkdownLines),
                join_lines(HtmlLines)
            },
            parse_cases(AfterHtml, Number + 1, [Example | Acc]);
        _ ->
            parse_cases(Rest, Number, Acc)
    end.

take_until_dot([Line | Rest], Acc) ->
    case trim(Line) of
        <<".">> -> {lists:reverse(Acc), Rest};
        _ -> take_until_dot(Rest, [Line | Acc])
    end.

join_lines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

fixture_path(Filename) ->
    TestDirectory = filename:dirname(filename:absname(?FILE)),
    filename:join([
        TestDirectory,
        "fixtures",
        "markdown-it",
        Filename
    ]).

trim(Bin) ->
    string:trim(Bin, both, " \t\r\n").
