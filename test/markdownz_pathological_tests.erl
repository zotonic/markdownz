-module(markdownz_pathological_tests).

-include_lib("eunit/include/eunit.hrl").

%% Adapted from markdown-it/test/markdown-it/pathological.test.mjs. Each input
%% is parsed in a monitored process, making a complexity regression a bounded
%% test failure instead of hanging the complete EUnit VM.

pathological_test_() ->
    ParseTimeout = pathological_timeout(),
    TestTimeout = max(10, (ParseTimeout + 999) div 1000 + 5),
    [
        {Name, {timeout, TestTimeout,
            fun() ->
                assert_bounded(Expected, Input, Options, ParseTimeout)
            end}}
        || {Name, Expected, Input, Options} <- cases()
    ].

assert_bounded(ok, Input, ExtraOptions, ParseTimeout) ->
    Config = config(ExtraOptions, ParseTimeout),
    ?assertMatch({ok, _}, markdownz:parse_bounded(Input, Config));
assert_bounded(max_nesting, Input, ExtraOptions, ParseTimeout) ->
    Config = config(ExtraOptions, ParseTimeout),
    ?assertMatch(
        {error, max_nesting, #{limit := 100}},
        markdownz:parse_bounded(Input, Config)).

config(ExtraOptions, ParseTimeout) ->
    markdownz:new(maps:merge(#{
        max_input_bytes => 8 * 1024 * 1024,
        max_nesting => 100,
        parse_timeout => ParseTimeout,
        max_parse_heap_words => 32 * 1024 * 1024
    }, ExtraOptions)).

pathological_timeout() ->
    case os:getenv("MARKDOWNZ_PATHOLOGICAL_TIMEOUT_MS") of
        false ->
            5000;
        Value ->
            positive_integer(Value, 5000)
    end.

positive_integer(Value, Default) ->
    try list_to_integer(Value) of
        Integer when Integer > 0 -> Integer;
        _ -> Default
    catch
        error:badarg -> Default
    end.

cases() ->
    [
        {"pathological integrity check", ok, <<"foo">>, #{}},
        {"nested inlines", ok,
            <<(repeat($*, 60000))/binary, "a", (repeat($*, 60000))/binary>>, #{}},
        {"nested strong emphasis", ok,
            repeated_around(<<"*a **a ">>, 5000, <<"b">>, <<" a** a*">>), #{}},
        {"many emphasis closers without openers", ok,
            binary:copy(<<"a_ ">>, 20000), #{}},
        {"many emphasis openers without closers", ok,
            binary:copy(<<"_a ">>, 20000), #{}},
        {"many link closers without openers", ok,
            binary:copy(<<"a]">>, 10000), #{}},
        {"many link openers without closers", ok,
            binary:copy(<<"[a">>, 5000), #{}},
        {"mismatched emphasis openers and closers", ok,
            binary:copy(<<"*a_ ">>, 20000), #{}},
        {"commonmark cmark issue 389", ok,
            <<(binary:copy(<<"*a ">>, 5000))/binary,
              (binary:copy(<<"_a*_ ">>, 5000))/binary>>, #{}},
        {"openers and closers multiple of three", ok,
            <<"a**b", (binary:copy(<<"c* ">>, 20000))/binary>>, #{}},
        {"link openers and emphasis closers", ok,
            binary:copy(<<"[ a_">>, 1000), #{}},
        {"repeated bracket-parenthesis pattern", ok,
            binary:copy(<<"[ (](">>, 2000), #{}},
        {"repeated image-link pattern", ok,
            binary:copy(<<"![[]()">>, 1000), #{}},
        {"nested brackets", ok,
            <<(repeat($[, 2000))/binary, "a", (repeat($], 2000))/binary>>, #{}},
        {"nested block quotes reach nesting limit", max_nesting,
            <<(binary:copy(<<"> ">>, 10000))/binary, "a">>, #{}},
        {"deeply nested lists reach nesting limit", max_nesting,
            deeply_nested_lists(300), #{}},
        {"NUL bytes", ok,
            binary:copy(<<"abc", 0, "de", 0>>, 100000), #{}},
        {"increasing backtick runs", ok,
            increasing_backticks(150), #{}},
        {"unclosed links with angle destination", ok,
            binary:copy(<<"[a](<b">>, 3000), #{}},
        {"unclosed links", ok,
            binary:copy(<<"[a](b">>, 3000), #{}},
        {"unclosed comments", ok,
            <<"</", (binary:copy(<<"<!--">>, 25000))/binary>>, #{}},
        {"empty lines in deeply nested list reach nesting limit", max_nesting,
            <<(binary:copy(<<"- ">>, 5000))/binary, "x",
              (binary:copy(<<"\n">>, 5000))/binary>>, #{}},
        {"deep list in blockquote reaches nesting limit", max_nesting,
            <<"> ", (binary:copy(<<"- ">>, 1000))/binary, "x\n",
              (binary:copy(<<">\n">>, 150))/binary>>, #{}},
        {"emphasis in deep blockquote reaches nesting limit", max_nesting,
            <<(repeat($>, 100000))/binary,
              (binary:copy(<<"a*">>, 100000))/binary>>, #{}},
        {"emphasis star-underscore pattern", ok,
            binary:copy(<<"**_* ">>, 10000), #{}},
        {"escaped backtick pattern", ok,
            binary:copy(<<"``\\">>, 1000), #{}},
        {"long autolink opener pattern", ok,
            <<(repeat($<, 100000))/binary, ">">>, #{}},
        {"hardbreak whitespace pattern", ok,
            <<"x", (repeat($\s, 150000))/binary, "x  \nx">>, #{}},
        {"linkify trailing asterisks", ok,
            <<"https://test.com?", (repeat($*, 70000))/binary, "a">>,
            #{linkify => true}},
        {"many smart quotes", ok,
            repeat($", 8000),
            #{typographer => true, smartquotes => true}}
    ].

repeat(Character, Count) ->
    binary:copy(<<Character>>, Count).

repeated_around(Open, Count, Middle, Close) ->
    <<(binary:copy(Open, Count))/binary, Middle/binary,
      (binary:copy(Close, Count))/binary>>.

deeply_nested_lists(Count) ->
    iolist_to_binary([
        [binary:copy(<<"  ">>, Level), <<"* a\n">>]
        || Level <- lists:seq(0, Count - 1)
    ]).

increasing_backticks(Count) ->
    iolist_to_binary([
        [<<"e">>, repeat($`, Length)]
        || Length <- lists:seq(0, Count - 1)
    ]).
