-module(markdownz_tests).

-include_lib("eunit/include/eunit.hrl").

html_tree_test() ->
    ?assertEqual(
        {ok, [
            {<<"h1">>, [], [<<"Hello ">>, {<<"em">>, [], [<<"world">>]}]},
            {<<"p">>, [], [<<"Safe & sound">>]}
        ]},
        markdownz:parse(<<"# Hello *world*\n\nSafe &amp; sound">>)).

heading_and_escape_test() ->
    ?assertEqual(
        <<"<h1>Hello &lt;world&gt;</h1>\n<h2>Second</h2>">>,
        markdownz:to_binary(<<"# Hello <world>\n\nSecond\n------">>)).

tabs_and_hard_break_test() ->
    ?assertEqual(
        <<"<pre><code>code\n</code></pre>\n<p>a<br>\nb</p>">>,
        markdownz:to_binary(<<"\tcode\n\na  \nb">>)).

inline_extensions_test() ->
    ?assertEqual(
        <<"<p>H<sub>2</sub>O, x<sup>2</sup>, <del>old</del>, "
          "<strong>bold</strong>, and <code>&lt;x&gt;</code>.</p>">>,
        markdownz:to_binary(
            <<"H~2~O, x^2^, ~~old~~, **bold**, and `<x>`. ">>)).

zotonic_inline_boundary_test() ->
    ?assertEqual(<<"<p>foo_bar and test*value</p>">>,
        markdownz:to_binary(<<"foo_bar and test*value">>)),
    ?assertEqual(<<"<p><em>foo</em> bar</p>">>,
        markdownz:to_binary(<<"_foo_ bar">>)).

nested_delimiters_test() ->
    ?assertEqual(
        <<"<p><em><strong>both</strong></em> and "
          "<strong>outer <em>inner</em></strong></p>">>,
        markdownz:to_binary(<<"***both*** and **outer *inner***">>)).

emphasis_delimiter_balance_test() ->
    ?assertEqual(
        <<"<p><em><strong>strong</strong> in emph</em></p>">>,
        markdownz:to_binary(<<"***strong** in emph*">>)),
    ?assertEqual(
        <<"<p><strong><em>emph</em> in strong</strong></p>">>,
        markdownz:to_binary(<<"***emph* in strong**">>)),
    ?assertEqual(
        <<"<p>*<em>foo</em></p>">>,
        markdownz:to_binary(<<"**foo*">>)),
    ?assertEqual(
        <<"<p><em>foo</em>*</p>">>,
        markdownz:to_binary(<<"*foo**">>)).

emphasis_rule_of_three_test() ->
    ?assertEqual(
        <<"<p><em>foo<strong>bar</strong>baz</em></p>">>,
        markdownz:to_binary(<<"*foo**bar**baz*">>)),
    ?assertEqual(
        <<"<p><em><strong>foo</strong> bar</em></p>">>,
        markdownz:to_binary(<<"***foo** bar*">>)),
    ?assertEqual(
        <<"<p>foo_bar_baz and foo<em>bar</em>baz</p>">>,
        markdownz:to_binary(<<"foo_bar_baz and foo*bar*baz">>)).

emphasis_opaque_inline_test() ->
    ?assertEqual(
        <<"<p><em><a href=\"https://example.com\">link</a></em></p>">>,
        markdownz:to_binary(<<"*[link](https://example.com)*">>)),
    ?assertEqual(
        <<"<p><em><code>code * marker</code></em></p>">>,
        markdownz:to_binary(<<"*`code * marker`*">>)),
    ?assertEqual(
        <<"<p>*<a href=\"url\">foo*</a></p>">>,
        markdownz:to_binary(<<"*[foo*](url)">>)).

linkified_content_is_opaque_to_emphasis_test() ->
    Config = markdownz:new(#{linkify => true}),
    ?assertEqual(
        <<"<p><em>see <a href=\"mailto:foo*bar@example.com\">"
          "foo*bar@example.com</a> now</em></p>">>,
        markdownz:to_binary(<<"*see foo*bar@example.com now*">>, Config)),
    ?assertEqual(
        <<"<p><em>see <a href=\"//example.com/a*b\">"
          "//example.com/a*b</a> now</em></p>">>,
        markdownz:to_binary(<<"*see //example.com/a*b now*">>, Config)).

disabled_opaque_rule_affects_emphasis_test() ->
    Config = markdownz:disable(markdownz:new(), inline, code),
    ?assertEqual(
        <<"<p><em>`x</em> y`*</p>">>,
        markdownz:to_binary(<<"*`x* y`*">>, Config)).

pathological_emphasis_run_test() ->
    Input = binary:copy(<<"**_* ">>, 1000),
    ?assertMatch(<<"<p>", _/binary>>, markdownz:to_binary(Input)).

links_images_and_references_test() ->
    Markdown = <<
        "[Erlang][language] and ![logo](logo.png \"Logo\")\n\n"
        "[language]: https://www.erlang.org/ \"Erlang\""
    >>,
    ?assertEqual(
        <<"<p><a href=\"https://www.erlang.org/\" title=\"Erlang\">Erlang</a> and "
          "<img src=\"logo.png\" alt=\"logo\" title=\"Logo\"></p>">>,
        markdownz:to_binary(Markdown)).

unsafe_link_test() ->
    ?assertEqual(
        <<"<p>[bad](javascript:alert(1))</p>">>,
        markdownz:to_binary(<<"[bad](javascript:alert(1))">>)).

numeric_entity_test() ->
    ?assertEqual(
        <<"<p>&quot; �</p>"/utf8>>,
        markdownz:to_binary(<<"&#X22; &#0;">>)).

autolink_with_html_enabled_test() ->
    ?assertEqual(
        <<"<p><a href=\"https://example.com/a\">https://example.com/a</a></p>">>,
        markdownz:to_binary(<<"<https://example.com/a>">>, markdownz:new(commonmark))).

table_test() ->
    Markdown = <<
        "| Hallo | Daar | Enzo |\n"
        "| ----: | :---: | :--- |\n"
        "| Foo | *Bår* | **Baz** |\n"/utf8,
        "| A\\|a | Bbb | CcC |\n"
    >>,
    ?assertEqual(
        <<"<table role=\"table\" class=\"table\"><thead><tr>"
          "<th align=\"right\">Hallo</th><th align=\"center\">Daar</th>"
          "<th align=\"left\">Enzo</th></tr></thead><tbody>"
          "<tr><td align=\"right\">Foo</td><td align=\"center\"><em>Bår</em></td>"
          "<td align=\"left\"><strong>Baz</strong></td></tr>"
          "<tr><td align=\"right\">A|a</td><td align=\"center\">Bbb</td>"
          "<td align=\"left\">CcC</td></tr></tbody></table>"/utf8>>,
        markdownz:to_binary(Markdown)).

fenced_code_test() ->
    Markdown = <<"```html\nThis is <code>foo</code>!\n```">>,
    ?assertEqual(
        <<"<pre lang=\"html\" class=\"notranslate\"><code "
          "class=\"notranslate language-html\">This is &lt;code&gt;foo&lt;/code&gt;!\n"
          "</code></pre>">>,
        markdownz:to_binary(Markdown)).

blockquote_and_nested_list_test() ->
    ?assertEqual(
        <<"<blockquote><p>quoted\nline</p></blockquote>\n"
          "<ul><li>one<ul><li>nested</li></ul></li><li>two</li></ul>">>,
        markdownz:to_binary(
            <<"> quoted\n> line\n\n- one\n  - nested\n- two">>)).

task_list_test() ->
    ?assertEqual(
        <<"<ul class=\"contains-task-list\">"
          "<li class=\"task-list-item\"><input class=\"task-list-item-checkbox\" "
          "type=\"checkbox\" checked disabled> done</li>"
          "<li class=\"task-list-item\"><input class=\"task-list-item-checkbox\" "
          "type=\"checkbox\" disabled> todo</li></ul>">>,
        markdownz:to_binary(<<"- [x] done\n- [ ] todo">>)).

loose_list_test() ->
    ?assertEqual(
        <<"<ul><li><p>one</p></li><li><p>two</p></li></ul>">>,
        markdownz:to_binary(<<"- one\n\n- two">>)).

raw_html_option_test() ->
    ?assertEqual(
        <<"<p>&lt;b&gt;safe&lt;/b&gt;</p>">>,
        markdownz:to_binary(<<"<b>safe</b>">>)),
    ?assertEqual(
        <<"<p><b>safe</b></p>">>,
        markdownz:to_binary(<<"<b>safe</b>">>, #{html => true})).

gfm_preset_test() ->
    ?assertEqual(
        <<"<p>H~2~O and <del>gone</del></p>">>,
        markdownz:to_binary(<<"H~2~O and ~~gone~~">>, markdownz:new(gfm))).

custom_inline_rule_test() ->
    MarkRule = fun
        (<<"==", Rest/binary>>, State) ->
            case binary:match(Rest, <<"==">>) of
                {Position, 2} ->
                    <<Content:Position/binary, "==", Tail/binary>> = Rest,
                    {ok, [{<<"mark">>, [], [Content]}], Tail, State};
                nomatch -> nomatch
            end;
        (_Source, _State) ->
            nomatch
    end,
    Config0 = markdownz:new(),
    Config = markdownz:add_rule(Config0, inline, before, emphasis, {mark, MarkRule}),
    ?assertEqual(
        <<"<p>A <mark>marked</mark> word.</p>">>,
        markdownz:to_binary(<<"A ==marked== word.">>, Config)).

renderer_override_test() ->
    Renderer = fun({<<"a">>, Attrs, Children}, Config) ->
        markdownz_html:render(
            {<<"a">>, [{<<"rel">>, <<"nofollow">>} | Attrs], Children},
            Config#{renderers := #{}})
    end,
    Config = markdownz:set_renderer(markdownz:new(), <<"a">>, Renderer),
    ?assertEqual(
        <<"<p><a rel=\"nofollow\" href=\"https://example.com\">link</a></p>">>,
        markdownz:to_binary(<<"[link](https://example.com)">>, Config)).

zipper_test() ->
    Tree = [
        {<<"p">>, [], [<<"one">>]},
        {<<"p">>, [], [<<"two">>]}
    ],
    Z0 = markdownz_zipper:from_list(Tree),
    Z1 = markdownz_zipper:next(Z0),
    Z2 = markdownz_zipper:down(Z1),
    Z3 = markdownz_zipper:replace(<<"changed">>, Z2),
    ?assertEqual(
        [{<<"p">>, [], [<<"one">>]}, {<<"p">>, [], [<<"changed">>]}],
        markdownz_zipper:to_list(markdownz_zipper:top(Z3))).

document_front_matter_test() ->
    Markdown = <<
        "---\r\n",
        "keywords:\r\n",
        "  - cache\r\n",
        "---\r\n",
        "Body\r\n"
    >>,
    ?assertEqual(
        {ok, #{
            front_matter => #{
                format => yaml,
                source => <<"keywords:\n  - cache">>
            },
            content => <<"Body\r\n">>
        }},
        markdownz:split_document(Markdown)),
    ?assertMatch(
        {ok, #{
            front_matter := #{format := yaml},
            content := [{<<"p">>, [], [<<"Body">>]}]
        }},
        markdownz:parse_document(Markdown)).

invalid_front_matter_test() ->
    ?assertEqual(
        {error, invalid_front_matter, #{reason => missing_closing_delimiter}},
        markdownz:split_document(<<"---\nkeywords: [cache]">>)).

fenced_div_test() ->
    ?assertEqual(
        <<"<div class=\"box\" id=\"sample\" data-kind=\"demo\">"
          "<p>Content.</p></div>">>,
        markdownz:to_binary(
            <<"::: {.box #sample data-kind=\"demo\"}\nContent.\n:::\n">>)),
    ?assertEqual(
        <<"<div id=\"standalone\"><p>Content.</p></div>">>,
        markdownz:to_binary(
            <<"::: {#standalone}\nContent.\n:::\n">>)).

aside_container_test() ->
    ?assertEqual(
        <<"<aside><p>Tangential <strong>detail</strong>.</p></aside>">>,
        markdownz:to_binary(
            <<"::: aside\nTangential **detail**.\n:::\n">>)).

note_container_test() ->
    ?assertEqual(
        <<"<div role=\"note\" class=\"admonition note\">"
          "<p class=\"first admonition-title\">Escaping</p>"
          "<p class=\"last\">Results are safe.</p></div>">>,
        markdownz:to_binary(
            <<"::: {.note title=\"Escaping\"}\nResults are safe.\n:::\n">>)).

nested_fenced_div_and_code_test() ->
    Markdown = <<
        "::: box\n",
        "```text\n",
        ":::\n",
        "```\n\n",
        ":::: note\n",
        "Nested.\n",
        "::::\n",
        ":::\n"
    >>,
    ?assertEqual(
        <<"<div class=\"box\"><pre lang=\"text\" class=\"notranslate\">"
          "<code class=\"notranslate language-text\">:::\n</code></pre>"
          "<div role=\"note\" class=\"admonition note\">"
          "<p class=\"first admonition-title\">Note</p>"
          "<p class=\"last\">Nested.</p></div></div>">>,
        markdownz:to_binary(Markdown)).

fenced_div_disabled_in_compatibility_presets_test() ->
    ?assertMatch(
        <<"<p>::: aside", _/binary>>,
        markdownz:to_binary(<<"::: aside\nContent.\n:::\n">>, markdownz:new(gfm))).
