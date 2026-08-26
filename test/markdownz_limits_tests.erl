-module(markdownz_limits_tests).

-include_lib("eunit/include/eunit.hrl").

input_limit_test() ->
    Config = markdownz:new(#{max_input_bytes => 4}),
    ?assertMatch({ok, _}, markdownz:parse(<<"four">>, Config)),
    ?assertEqual(
        {error, input_too_large, #{limit => 4, actual => 5}},
        markdownz:parse(<<"fives">>, Config)).

converted_input_limit_test() ->
    Config = markdownz:new(#{max_input_bytes => 2}),
    ?assertEqual(
        {error, input_too_large, #{limit => 2, actual => 3}},
        markdownz:parse([16#20ac], Config)).

unlimited_input_test() ->
    Markdown = binary:copy(<<"a">>, 1024 * 1024 + 1),
    ?assertEqual(
        {error, input_too_large, #{
            limit => 1024 * 1024,
            actual => 1024 * 1024 + 1
        }},
        markdownz:parse(Markdown)),
    Config = markdownz:new(#{max_input_bytes => infinity}),
    ?assertMatch({ok, _}, markdownz:parse(Markdown, Config)).

blockquote_nesting_limit_test() ->
    Config = markdownz:new(#{max_nesting => 3}),
    ?assertMatch({ok, _}, markdownz:parse(nested_quote(3), Config)),
    ?assertEqual(
        {error, max_nesting, #{limit => 3, depth => 4}},
        markdownz:parse(nested_quote(4), Config)).

list_nesting_limit_test() ->
    Config = markdownz:new(#{max_nesting => 3}),
    ?assertMatch({ok, _}, markdownz:parse(nested_list(3), Config)),
    ?assertEqual(
        {error, max_nesting, #{limit => 3, depth => 4}},
        markdownz:parse(nested_list(4), Config)).

bounded_render_test() ->
    ?assertEqual(
        {ok, <<"<p>Hello</p>">>},
        markdownz:to_binary_bounded(<<"Hello">>)).

unlimited_worker_bounds_test() ->
    Config = markdownz:new(#{
        parse_timeout => infinity,
        max_parse_heap_words => infinity
    }),
    ?assertMatch({ok, _}, markdownz:parse_bounded(<<"Hello">>, Config)).

bounded_timeout_test() ->
    SlowRule = fun(_Lines, _State) ->
        receive after 100 -> nomatch end
    end,
    Config0 = markdownz:new(#{parse_timeout => 10}),
    Config = markdownz:add_rule(
        Config0, block, before, fence, {slow, SlowRule}),
    ?assertEqual(
        {error, timeout, #{limit => 10}},
        markdownz:parse_bounded(<<"Hello">>, Config)).

bounded_heap_limit_test() ->
    HungryRule = fun(_Lines, _State) ->
        Data = lists:seq(1, 100000),
        _ = erlang:phash2(Data),
        nomatch
    end,
    Config0 = markdownz:new(#{
        parse_timeout => 1000,
        max_parse_heap_words => 5000
    }),
    Config = markdownz:add_rule(
        Config0, block, before, fence, {hungry, HungryRule}),
    ?assertEqual(
        {error, resource_limit, #{reason => max_heap_size}},
        markdownz:parse_bounded(<<"Hello">>, Config)).

bounded_parser_crash_test() ->
    CrashRule = fun(_Lines, _State) -> erlang:error(test_crash) end,
    Config0 = markdownz:new(),
    Config = markdownz:add_rule(
        Config0, block, before, fence, {crash, CrashRule}),
    ?assertEqual(
        {error, parser_crash, #{class => error, reason => test_crash}},
        markdownz:parse_bounded(<<"Hello">>, Config)).

nested_quote(Depth) ->
    <<(binary:copy(<<"> ">>, Depth))/binary, "text">>.

nested_list(Depth) ->
    iolist_to_binary([
        [binary:copy(<<"  ">>, Level), <<"* item\n">>]
        || Level <- lists:seq(0, Depth - 1)
    ]).
