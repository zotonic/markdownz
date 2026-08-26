-module(markdownz_normalize_tests).

-include_lib("eunit/include/eunit.hrl").

-define(EXAMPLE_COUNT, 13).

normalize_fixture_count_test() ->
    ?assertEqual(?EXAMPLE_COUNT, length(cases())).

normalize_test_() ->
    [
        {
            lists:flatten(io_lib:format("markdown-it normalize example ~B", [Number])),
            fun() ->
                Config = markdownz:new(#{html => true, linkify => true}),
                ?assertEqual(Expected, markdownz:to_binary(Markdown, Config))
            end
        }
        || {Number, Markdown, Expected} <- cases()
    ].

cases() ->
    {ok, Fixture} = file:read_file(fixture_path()),
    Lines = binary:split(Fixture, <<"\n">>, [global]),
    parse_cases(Lines, 1, []).

parse_cases([], _Number, Acc) ->
    lists:reverse(Acc);
parse_cases([Line | Rest], Number, Acc) ->
    case string:trim(Line, both, " \t\r") of
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
    case string:trim(Line, both, " \t\r") of
        <<".">> -> {lists:reverse(Acc), Rest};
        _ -> take_until_dot(Rest, [Line | Acc])
    end.

join_lines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

fixture_path() ->
    TestDirectory = filename:dirname(filename:absname(?FILE)),
    filename:join([
        TestDirectory,
        "fixtures",
        "markdown-it",
        "normalize.txt"
    ]).
