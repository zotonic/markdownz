-module(markdownz_tables_tests).

-include_lib("eunit/include/eunit.hrl").

-export([current_failures/0]).

-define(EXAMPLE_COUNT, 38).

tables_fixture_count_test() ->
    ?assertEqual(?EXAMPLE_COUNT, length(cases())).

tables_test_() ->
    [
        {
            lists:flatten(io_lib:format("markdown-it table example ~B", [Number])),
            fun() -> assert_example(Example) end
        }
        || #{number := Number} = Example <- cases()
    ].

-spec current_failures() -> [pos_integer()].
current_failures() ->
    [
        Number
        || #{number := Number} = Example <- cases(),
           not example_matches(Example)
    ].

assert_example(#{markdown := Markdown, html := ExpectedHtml}) ->
    {ok, ActualTree} = markdownz:parse(Markdown, config()),
    ?assertEqual(
        html_signature(ExpectedHtml),
        tree_signature(ActualTree)).

example_matches(#{markdown := Markdown, html := ExpectedHtml}) ->
    {ok, ActualTree} = markdownz:parse(Markdown, config()),
    html_signature(ExpectedHtml) =:= tree_signature(ActualTree).

config() ->
    markdownz:new(#{
        html => true,
        linkify => true,
        tables => true,
        typographer => true,
        table_class => undefined,
        table_role => undefined
    }).

cases() ->
    {ok, Fixture} = file:read_file(fixture_path()),
    Lines = binary:split(Fixture, <<"\n">>, [global]),
    parse_cases(Lines, 1, []).

parse_cases([], _Number, Acc) ->
    lists:reverse(Acc);
parse_cases([Line | Rest], Number, Acc) ->
    case trim(Line) of
        <<".">> ->
            {MarkdownLines, AfterMarkdown} = take_until_dot(Rest, []),
            {HtmlLines, AfterHtml} = take_until_dot(AfterMarkdown, []),
            Example = #{
                number => Number,
                markdown => join_lines(MarkdownLines),
                html => join_lines(HtmlLines)
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

%% Compare elements and their text, while deliberately ignoring serialization
%% whitespace and attributes such as style="text-align:..." versus align="...".
html_signature(Html) ->
    merge_text(html_signature(Html, [])).

html_signature(<<>>, Acc) ->
    lists:reverse(Acc);
html_signature(<<$<, Rest/binary>>, Acc) ->
    {TagSource, Tail} = take_tag(Rest),
    case tag_event(TagSource) of
        ignore -> html_signature(Tail, Acc);
        Event -> html_signature(Tail, [Event | Acc])
    end;
html_signature(Html, Acc) ->
    {Text, Rest} = take_text(Html),
    case trim(Text) of
        <<>> -> html_signature(Rest, Acc);
        _ ->
            Decoded = markdownz_inline:decode_entities(Text),
            html_signature(Rest, [{text, Decoded} | Acc])
    end.

take_tag(Bin) ->
    {Position, 1} = binary:match(Bin, <<$>>>),
    After = Position + 1,
    {binary:part(Bin, 0, Position),
        binary:part(Bin, After, byte_size(Bin) - After)}.

take_text(Bin) ->
    case binary:match(Bin, <<$<>>) of
        {Position, 1} ->
            {binary:part(Bin, 0, Position),
                binary:part(Bin, Position, byte_size(Bin) - Position)};
        nomatch -> {Bin, <<>>}
    end.

tag_event(<<$!, _/binary>>) -> ignore;
tag_event(<<$/, Rest/binary>>) -> {close, tag_name(Rest)};
tag_event(TagSource) -> {open, tag_name(TagSource)}.

tag_name(TagSource) ->
    case re:run(TagSource, <<"^([A-Za-z0-9]+)">>,
            [{capture, [1], binary}]) of
        {match, [Name]} -> string:lowercase(Name);
        nomatch -> <<>>
    end.

tree_signature(Tree) ->
    merge_text(lists:append([node_signature(Node) || Node <- Tree])).

node_signature(Text) when is_binary(Text) ->
    [{text, Text}];
node_signature({Tag, _Attrs, Children}) ->
    [{open, Tag}]
        ++ lists:append([node_signature(Child) || Child <- Children])
        ++ [{close, Tag}];
node_signature({'=', Html}) ->
    html_signature(Html).

merge_text(Events) ->
    lists:reverse(lists:foldl(
        fun
            ({text, Text}, [{text, Previous} | Rest]) ->
                [{text, <<Previous/binary, Text/binary>>} | Rest];
            (Event, Acc) ->
                [Event | Acc]
        end,
        [],
        Events)).

fixture_path() ->
    TestDirectory = filename:dirname(filename:absname(?FILE)),
    filename:join([
        TestDirectory,
        "fixtures",
        "markdown-it",
        "tables.txt"
    ]).

trim(Bin) ->
    string:trim(Bin, both, " \t\r\n").
