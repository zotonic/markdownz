# markdownz for Erlang

This is an Erlang/OTP Markdown parser inspired by
[markdown-it](https://github.com/markdown-it/markdown-it). The upstream
TypeScript project is used as a behavioral reference but is not included in
this repository. The Erlang implementation is intentionally functional: it
consumes binaries through recursive pattern matching, builds immutable HTML
trees, traverses those trees with a zipper, and returns HTML as `iodata()`.

The project currently implements the practical CommonMark core and the syntax
used by Zotonic, including:

- ATX and Setext headings, paragraphs, blockquotes, thematic breaks
- ordered, unordered, nested, and task lists
- indented and fenced code blocks with Zotonic highlighting attributes
- links, images, reference links, safe autolinks, and optional linkification
- emphasis, strong, code spans, escapes, and common HTML entities
- tables, strikethrough, subscript, and superscript
- optional raw HTML, disabled by default

The parser returns the same basic terms as `z_html_parse` in `z_stdlib`:

```erlang
Text = binary(),
Element = {TagBinary, [{AttributeBinary, Value}], [Text | Element]}.
```

Raw HTML, when enabled, uses z_stdlib's `{'=', HtmlBinary}` node.

## Build and use

```shell
make
make test
make xref
make dialyzer
make edoc
```

The EUnit suite loads all 652 examples from the CommonMark 0.31.2 fixture in
`test/fixtures/commonmark/spec.txt`. Each example is rendered and compared
with its specified HTML. All 652 examples currently conform. The explicit
`markdownz_commonmark_tests:known_failures/0` baseline is empty, so every
example is a regression check.

```erlang
1> markdownz:to_html(<<"# Hello *Erlang*">>).
%% iodata(), without a final flattening pass

2> markdownz:to_binary(<<"H~2~O and x^2^">>).
<<"<p>H<sub>2</sub>O and x<sup>2</sup></p>">>

3> markdownz:parse(<<"**tree**">>).
{ok,[{<<"p">>,[],[{<<"strong">>,[],[<<"tree">>]}]}]}
```

`markdownz:new/1` accepts the presets `commonmark`, `gfm`, and `zotonic`, or
an option map. The default is the Zotonic-oriented extended syntax. Relevant options are `html`,
`breaks`, `linkify`, `tables`, `strikethrough`, `subscript`, `superscript`,
`task_lists`, `table_class`, and `table_role`.

## Extensions

A configuration contains independent ordered rulers for the `block`, `inline`,
and `core` phases. Rules are named, can be enabled or disabled, and can be
inserted before or after another rule:

```erlang
Config1 = markdownz:add_rule(
    Config0,
    inline,
    before,
    emphasis,
    {mark, fun mark_rule/2}),
Config2 = markdownz:disable(Config1, inline, [subscript, superscript]).
```

An inline rule has this contract:

```erlang
Rule(SourceBinary, State) ->
    nomatch |
    {ok, HtmlNodes, UnconsumedBinary, NewState}.
```

A block rule receives the remaining lines instead:

```erlang
Rule(Lines, State) ->
    nomatch |
    {ok, HtmlNodes, UnconsumedLines, NewState}.
```

Core rules receive `Tree` and `State` as two arguments and return
`{NewTree, NewState}`.
`markdownz_zipper` is provided for local, immutable edits to the HTML forest;
its `map/2` is bottom-up, so parent rewrites can depend on transformed children.

A plugin module implements `markdownz_plugin` and its `init/2` callback. Tag
rendering can be overridden with `markdownz:set_renderer/3` without changing
the parsed tree.

## Scope

This implementation passes the complete bundled CommonMark 0.31.2 corpus.
Its public tree and ruler APIs are designed so GFM and Zotonic-specific rules
can continue to evolve without changing callers.

## License

This Erlang implementation is released under the [MIT License](LICENSE).
