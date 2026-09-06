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
- normalized links, images, references, safe autolinks, and optional linkification
- emphasis, strong, code spans, escapes, and common HTML entities
- tables, strikethrough, subscript, superscript, and optional typography
- Pandoc-style fenced divs, including semantic asides and notes
- optional YAML front matter exposed as uninterpreted document metadata
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

The suite also includes markdown-it's 13 link-normalization fixtures, 38 table
fixtures, 12 typographic-replacement fixtures, and 19 smart-quote fixtures.
Table output is compared semantically by element structure and text nodes, so
irrelevant serializer whitespace and attribute spelling do not affect those
tests. Link normalization covers percent encoding, human-readable autolink
text, IDN/Punycode hostnames, protocol-relative URLs, and email links. An
adapted set of 30 markdown-it pathological cases runs in bounded Erlang
processes to catch algorithmic-denial-of-service regressions without risking
the complete test VM.

```erlang
1> markdownz:to_html(<<"# Hello *Erlang*">>).
%% iodata(), without a final flattening pass

2> markdownz:to_binary(<<"H~2~O and x^2^">>).
<<"<p>H<sub>2</sub>O and x<sup>2</sup></p>">>

3> markdownz:parse(<<"**tree**">>).
{ok,[{<<"p">>,[],[{<<"strong">>,[],[<<"tree">>]}]}]}
```

## Documents and front matter

`split_document/1` separates optional YAML front matter from the Markdown
without interpreting its schema. `parse_document/1,2` also parses the body and
returns the HTML tree as `content`. Existing parsing functions deliberately do
not strip front matter.

```erlang
1> markdownz:split_document(<<"---\nkeywords: [cache, render]\n---\nBody">>).
{ok,#{
    front_matter => #{format => yaml,
                      source => <<"keywords: [cache, render]">>},
    content => <<"Body">>
}}
```

Front matter is limited to 16 KiB. Callers choose the YAML decoder and assign
meaning to fields such as `keywords`; `markdownz` does not create atoms or
impose an application-specific metadata schema.

## Fenced divs

The default and `zotonic` presets support Pandoc-style fenced divs. A bare name
is shorthand for a class, while braced attributes support classes, an id, and
safe `title`, `role`, `aria-*`, and `data-*` attributes.

```markdown
::: {.example #cache-key data-audience="developer"}
Normal **Markdown** content.
:::
```

Unknown types render as a `div`. Two semantic types are built in:

```markdown
::: aside
Tangential information rendered in an `<aside>`.
:::

::: {.note title="Remember"}
An admonition rendered as a `<div class="admonition note" role="note">`.
:::
```

The `container_types` option replaces the complete type map. To extend the
built-in definitions, merge custom definitions into
`markdownz:default_container_types/0`:

```erlang
ContainerTypes = (markdownz:default_container_types())#{
    <<"warning">> => #{
        tag => <<"div">>,
        add_class => <<"admonition">>,
        role => <<"note">>,
        default_title => <<"Warning">>
    }
},
Config = markdownz:new(#{container_types => ContainerTypes}).
```

The `commonmark` and `gfm` presets disable fenced divs so their compatibility
behavior remains unchanged.

## Configuration

`markdownz:new/1` accepts a preset atom or an option map. `markdownz:new/0`
and `markdownz:new(default)` are equivalent.

### Presets

- `default` enables the extended syntax used by Zotonic: linkification,
  tables, strikethrough, subscript, superscript, and task lists. Raw HTML and
  typography remain disabled.
- `zotonic` adds typographic replacements to the `default` preset, but keeps
  smart-quote conversion disabled. This changes `(c)` to `©` and `...` to `…`,
  while leaving straight single and double quotes unchanged.
- `commonmark` configures the parser and renderer for the bundled CommonMark
  0.31.2 corpus. It enables raw HTML, uses XHTML void elements and CommonMark
  fenced-code attributes, and disables the non-CommonMark extensions.
- `gfm` enables raw HTML, linkification, tables, strikethrough, and task lists.
  Subscript and superscript remain disabled because they are not GFM syntax.

### Option map

An option map is merged over the default options, so only changed values need
to be supplied:

```erlang
Config = markdownz:new(#{
    html => true,
    linkify => false,
    table_class => <<"table table-striped">>
}).
```

The supported options are:

- `html` (`boolean()`, default `false`) controls raw inline and block HTML.
  When enabled, raw HTML is returned as `{'=', Html}` nodes and emitted without
  escaping. Enable it only for trusted Markdown or after suitable sanitization.
- `breaks` (`boolean()`, default `false`) converts ordinary soft line breaks to
  `<br>` elements. Markdown hard breaks, written with two trailing spaces or a
  trailing backslash, produce `<br>` regardless of this option.
- `linkify` (`boolean()`, default `true`) turns bare `http://`, `https://`,
  `www.`, protocol-relative URLs, and email addresses into links. Explicit
  Markdown links and angle-bracket autolinks do not depend on this option.
- `tables` (`boolean()`, default `true`) enables pipe-table recognition.
- `strikethrough` (`boolean()`, default `true`) enables `~~deleted~~` syntax
  and emits a `del` element.
- `subscript` (`boolean()`, default `true`) enables `~text~` syntax without
  spaces and emits a `sub` element.
- `superscript` (`boolean()`, default `true`) enables `^text^` syntax without
  spaces and emits a `sup` element.
- `task_lists` (`boolean()`, default `true`) recognizes `[ ]` and `[x]` at the
  start of list items and adds disabled checkbox elements and task-list classes.
- `fenced_divs` (`boolean()`, default `true`) enables Pandoc-style fenced divs.
  It is disabled by the `commonmark` and `gfm` presets.
- `container_types` (`map()`) replaces the map from fenced-div classes to
  semantic rendering options. The defaults render `aside` as an `aside`
  element and `note` as an accessible admonition while other classes remain
  generic `div` elements. Merge custom definitions into
  `markdownz:default_container_types/0` to retain the built-in types.
- `typographer` (`boolean()`, default `false`) enables common replacements such
  as `(c)`, `(r)`, `(tm)`, `+-`, ellipses, repeated punctuation, en dashes,
  and em dashes. Escaped characters, entities, code, and autolinks are left
  unchanged.
- `smartquotes` (`boolean()`, default `false`) enables quote and apostrophe
  conversion when `typographer` is enabled.
- `quotes` (`binary()`, default `<<"“”‘’"/utf8>>`) supplies the opening double,
  closing double, opening single, and closing single quote characters, in that
  order. It is used only when `typographer` is enabled; for example,
  `<<"«»‹›"/utf8>>` selects French-style quote characters.
- `xhtml_out` (`boolean()`, default `false`) renders void elements as `<br />`,
  `<hr />`, and `<img />` instead of their HTML forms.
- `code_style` (`zotonic | commonmark`, default `zotonic`) controls attributes
  generated from a fenced code block's language. Zotonic style adds `lang` and
  `notranslate` attributes; CommonMark style only adds `class="language-..."`
  to the `code` element.
- `commonmark_render` (`boolean()`, default `false`) enables CommonMark-specific
  whitespace when serializing list items and blockquotes. It affects rendered
  HTML formatting, not Markdown recognition.
- `max_input_bytes` (`non_neg_integer() | infinity`, default `1048576`) rejects
  Markdown larger than one MiB before parsing. Binary inputs are checked before
  Unicode conversion; converted input is checked again.
- `max_nesting` (`non_neg_integer() | infinity`, default `100`) limits combined
  list and blockquote nesting. The `commonmark` preset uses `20`, matching
  markdown-it's CommonMark preset.
- `parse_timeout` (`non_neg_integer() | infinity`, default `5000`) is the
  maximum number of milliseconds used by the resource-bounded APIs.
- `max_parse_heap_words` (`non_neg_integer() | infinity`, default `8388608`)
  limits the Erlang process heap used by the resource-bounded APIs. This value
  is in Erlang words, not bytes.
- `table_class` (`binary() | undefined`, default `<<"table">>`) sets the
  generated table's `class` attribute. Use `undefined` or `<<>>` to omit it.
- `table_role` (`binary() | undefined`, default `<<"table">>`) sets the
  generated table's `role` attribute. Use `undefined` or `<<>>` to omit it.

### Resource-bounded parsing

`parse/1,2` always enforce `max_input_bytes` and `max_nesting`. For content
received from an untrusted boundary, the bounded variants additionally run the
complete operation in a monitored Erlang process with timeout and heap limits:

```erlang
case markdownz:to_binary_bounded(UserMarkdown, markdownz:new(zotonic)) of
    {ok, Html} ->
        Html;
    {error, input_too_large, Details} ->
        {reject, Details};
    {error, max_nesting, Details} ->
        {reject, Details};
    {error, timeout, Details} ->
        {reject, Details};
    {error, resource_limit, Details} ->
        {reject, Details}
end.
```

The available functions are `parse_bounded/1,2`, `to_html_bounded/1,2`, and
`to_binary_bounded/1,2`; all return `{ok, Result}` or a structured error. These
limits constrain CPU and memory use. They do not sanitize HTML: when `html` is
enabled, render the result only in a trusted context or pass it through an HTML
sanitizer such as Zotonic's `z_sanitize:html/2`.

## Extensions

A configuration contains independent ordered rulers for the `block`, `inline`,
and `core` phases. Rules are named, can be enabled or disabled, and can be
inserted before or after another rule:

### Parsing phases

| Phase      | Input                               | Purpose                                                                          |
| ---------- | ----------------------------------- | -------------------------------------------------------------------------------- |
| `block`    | Remaining Markdown lines            | Recognizes document structure and invokes inline rules for textual content.      |
| `inline`   | Remaining bytes of an inline binary | Recognizes markup within textual block content.                                  |
| `core`     | The complete HTML forest            | Transforms the complete tree after parsing, for example, decorating task lists.  |

The phase argument to `add_rule/5`, `replace_rule/4`, `enable/3`, or
`disable/3` selects one of these independent rulers. A `before` or `'after'`
anchor is resolved only within the selected phase; for example, `emphasis` is
an inline rule name.

Block and inline rules are tried in ruler order at the current input position.
Returning `nomatch` tries the next rule, while a successful rule must consume
input. Core rules are applied in order to the complete tree. Every phase
threads the parser state forward, allowing rules to share references and add
extension-specific state without mutation.

```erlang
Config0 = markdownz:new(),
Config1 = markdownz:add_rule(
    Config0,
    inline,
    before,
    emphasis,
    {mark, fun mark_rule/2}),
Config2 = markdownz:disable(Config1, inline, [subscript, superscript]).
```

The complete call has the following shape:

```erlang
markdownz:add_rule(Config, Phase, Position, Anchor, {Name, Handler})
```

- `Config` is an existing parser configuration, normally returned by
  `markdownz:new/0`, `markdownz:new/1`, or an earlier configuration operation.
- `Phase` is `block`, `inline`, or `core` and selects the ruler to change.
- `Position` is `before` or `'after'` and determines which side of `Anchor`
  receives the new rule. The quotes around `'after'` are required because it
  is an Erlang keyword.
- `Anchor` is the name of an existing rule in the selected phase. It need not
  be enabled, but it must exist.
- `Name` is the new rule's unique name within that phase. The same name can
  later be passed to `replace_rule/4`, `enable/3`, or `disable/3`.
- `Handler` is either a function of arity two or `{Module, Function}` naming
  an exported function of arity two. Its arguments and return value follow the
  contract of the selected phase.

The result is a new configuration containing the inserted rule; `Config`
itself remains unchanged. An unknown anchor or duplicate rule name raises an
error.

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
